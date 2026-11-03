extends RefCounted
class_name MMTexture


var rd : RenderingDevice
var rid : RID
var texture_size : Vector2i
var texture_format : RenderingDevice.DataFormat
var texture : Texture2D
var texture_needs_update : bool = false

const BYTES_PER_PIXEL : Dictionary = {
	RenderingDevice.DATA_FORMAT_R16_SFLOAT: 2,
	RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT: 8,
	RenderingDevice.DATA_FORMAT_R32_SFLOAT: 4,
	RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT: 16,
	RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM: 4
}

## GPU memory budget: textures that have a copy in the rendering device are
## registered, so that the least recently used rendered ones can be spilled
## (read back to RAM and freed in the rendering device) when the textures use
## more than the gpu_memory_budget preference. get_texture_rid() uploads them
## again when they are used.
static var gpu_textures : Dictionary = {}
## Time (in ms) the texture was last rendered or used by a render
var last_used : int = 0
## get_instance_id() cannot be called when the texture is being deleted
var texture_id : int = 0
## Whether the rendering device texture was rendered (by set_texture_rid())
## rather than uploaded from an image (by set_texture()): only rendered
## textures are spilled
var rendered : bool = false
## RAM copy of a spilled texture, uploaded again by get_texture_rid()
var spilled_image : Image = null
## Textures used more recently than this (in ms) are probably needed by the
## current renders and are not spilled
const SPILL_MIN_IDLE_MS : int = 200


func _init() -> void:
	rid = RID()
	texture = ImageTexture.new()
	texture_id = get_instance_id()

func _notification(what : int) -> void:
	match what:
		NOTIFICATION_PREDELETE:
			gpu_textures.erase(texture_id)
			if mm_renderer:
				await mm_renderer.thread_run(in_thread_free_rid, [rid, rd])

## Size of the texture in the rendering device, in bytes
func get_gpu_size() -> int:
	if not rid.is_valid():
		return 0
	return texture_size.x*texture_size.y*BYTES_PER_PIXEL.get(texture_format, 8)

## Marks the texture as used (called in the rendering thread)
func touch() -> void:
	last_used = Time.get_ticks_msec()
	register.call_deferred()

func register() -> void:
	if rid.is_valid() and not gpu_textures.has(texture_id):
		gpu_textures[texture_id] = weakref(self)
	mm_renderer.request_texture_budget_check()

## Copies a rendered texture to RAM and frees it in the rendering device (in
## the rendering thread, where renders use the textures). Returns false if the
## texture cannot be spilled.
func in_thread_evict() -> bool:
	if not rid.is_valid() or not rendered or not BYTES_PER_PIXEL.has(texture_format):
		return false
	if Time.get_ticks_msec()-last_used < SPILL_MIN_IDLE_MS:
		return false
	var image : Image = in_thread_read_image()
	if image == null or image.get_size() != texture_size:
		return false
	spilled_image = image
	rd.free_rid(rid)
	rid = RID()
	return true

## Memory used by textures in the rendering device: bytes and texture count
static func get_gpu_memory_usage() -> Dictionary:
	var total : int = 0
	var count : int = 0
	for id in gpu_textures.keys():
		var t = gpu_textures[id].get_ref()
		if t == null or not t.rid.is_valid():
			gpu_textures.erase(id)
			continue
		total += t.get_gpu_size()
		count += 1
	return { bytes=total, count=count }

## Spills the least recently used textures until the textures in the
## rendering device fit in budget (in bytes). Returns the number of spilled
## textures.
static func enforce_budget(budget : int) -> int:
	var candidates : Dictionary = get_spill_candidates(budget)
	if candidates.is_empty():
		return 0
	# Textures are spilled in a single job of the rendering thread, and are
	# not kept alive while it waits for its turn. Those it uses are kept in
	# used, so that they are released in this thread.
	var used : Array = []
	var spilled = await mm_renderer.thread_run(in_thread_spill, [ candidates.textures, candidates.excess, used ])
	used.clear()
	# Spilled textures are removed from gpu_textures when it is read (they may
	# already have been used and uploaded again)
	return spilled if spilled is int else 0

## The rendered textures (as weak references) that can be spilled, least
## recently used first, and the excess memory, or an empty dictionary
static func get_spill_candidates(budget : int) -> Dictionary:
	var textures : Array = []
	var total : int = 0
	for id in gpu_textures.keys():
		var t = gpu_textures[id].get_ref()
		if t == null or not t.rid.is_valid():
			gpu_textures.erase(id)
			continue
		total += t.get_gpu_size()
		if t.rendered:
			textures.append(t)
	if total <= budget or textures.is_empty():
		return {}
	textures.sort_custom(func(a, b): return a.last_used < b.last_used)
	return { textures=textures.map(func(t): return weakref(t)), excess=total-budget }

static func in_thread_spill(textures : Array, excess : int, used : Array) -> int:
	var spilled : int = 0
	for w in textures:
		if excess <= 0:
			break
		var t = w.get_ref()
		if t == null:
			continue
		used.append(t)
		var size : int = t.get_gpu_size()
		if t.in_thread_evict():
			excess -= size
			spilled += 1
	if spilled > 0:
		# The rendering device frees textures when its frame ends
		var rendering_device : RenderingDevice = mm_renderer.rendering_device
		rendering_device.submit()
		rendering_device.sync()
	return spilled

static func in_thread_free_rid(texture_rid, rendering_device):
	if texture_rid.is_valid():
		rendering_device.free_rid(texture_rid)

func get_texture_rid(target_rd : RenderingDevice) -> RID:
	if ! rid.is_valid():
		var image : Image = spilled_image if spilled_image != null else texture.get_image()
		if image == null or image.get_width() == 0 or image.get_height() == 0:
			#print("No image for texture %s" % str(texture))
			image = Image.create(1, 1, false, Image.FORMAT_RH)
			texture_format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
		var fmt : RDTextureFormat = RDTextureFormat.new()
		fmt.width = image.get_width()
		fmt.height = image.get_height()
		fmt.format = texture_format
		fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		if spilled_image != null:
			# Spilled textures may be used again as compute outputs (e.g. by
			# iterate buffers)
			fmt.usage_bits |= RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		var view : RDTextureView = RDTextureView.new()
		rd = target_rd
		rid = rd.texture_create(fmt, view, [ image.get_data() ])
		spilled_image = null
	else:
		assert(target_rd == rd)
	touch()
	return rid

func set_texture_rid(new_rid : RID, size : Vector2i, format : RenderingDevice.DataFormat, new_rd : RenderingDevice) -> void:
	if new_rid == rid:
		texture_needs_update = true
		touch()
		return
	if rid.is_valid():
		rd.free_rid(rid)
	rd = new_rd
	rid = new_rid
	texture_size = size
	texture_format = format
	texture_needs_update = true
	rendered = true
	spilled_image = null
	touch()

func in_thread_get_texture() -> Texture2D:
	if texture_needs_update:
		var image : Image = in_thread_read_image() if rid.is_valid() else spilled_image
		if image != null:
			texture.set_image.call_deferred(image)
		texture_needs_update = false
	return texture

## Reads the texture back from the rendering device
func in_thread_read_image() -> Image:
	var image_format : Image.Format
	match texture_format:
		RenderingDevice.DATA_FORMAT_R32_SFLOAT:
			image_format = Image.FORMAT_RF
		RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT:
			image_format = Image.FORMAT_RGBAF
		RenderingDevice.DATA_FORMAT_R16_SFLOAT:
			image_format = Image.FORMAT_RH
		RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT:
			image_format = Image.FORMAT_RGBAH
		RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM:
			image_format = Image.FORMAT_RGBA8
	return Image.create_from_data(texture_size.x, texture_size.y, false, image_format, rd.texture_get_data(rid, 0))

func get_texture() -> Texture2D:
	if texture_needs_update:
		if rd and (rid.is_valid() or spilled_image != null):
			await mm_renderer.thread_run(in_thread_get_texture)
	return texture

func set_texture(new_texture : ImageTexture) -> void:
	texture = new_texture
	texture_size = texture.get_size()
	var image : Image = texture.get_image()
	if image:
		match image.get_format():
			Image.FORMAT_RF:
				texture_format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
			Image.FORMAT_RGBAF:
				texture_format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
			Image.FORMAT_RH:
				texture_format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
			Image.FORMAT_RGBAH:
				texture_format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
			Image.FORMAT_DXT1:
				texture_format = RenderingDevice.DATA_FORMAT_BC1_RGBA_SRGB_BLOCK
			Image.FORMAT_DXT3:
				texture_format = RenderingDevice.DATA_FORMAT_BC2_SRGB_BLOCK
			Image.FORMAT_DXT5:
				texture_format = RenderingDevice.DATA_FORMAT_BC3_SRGB_BLOCK
			#Image.FORMAT_RGBA8:
			#	texture_format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
			_:
				print("Unsupported texture format "+str(image.get_format()))
				image.convert(Image.FORMAT_RGBAH)
				texture.set_image(image)
				texture_format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		texture_size = image.get_size()
	if rid.is_valid():
		rd.free_rid(rid)
	rid = RID()
	rendered = false
	spilled_image = null

func get_width() -> int:
	return texture_size.x

func get_height() -> int:
	return texture_size.y

func save_to_file(file_name : String) -> Error:
	var texture : ImageTexture = await get_texture()
	var image : Image = texture.get_image()
	if image != null:
		var export_image : Image = image
		match file_name.get_extension():
			"png":
				export_image.convert(Image.FORMAT_RGBA8) # force RGBA8 to preserve alpha
				return export_image.save_png(file_name)
			"jpg":
				return export_image.save_jpg(file_name, 1.0)
			"webp":
				return export_image.save_webp(file_name)
			"exr":
				match image.get_format():
					Image.FORMAT_RF,Image.FORMAT_RH:
						return export_image.save_exr(file_name, true)
					_:
						return export_image.save_exr(file_name, false)
	return ERR_DOES_NOT_EXIST
