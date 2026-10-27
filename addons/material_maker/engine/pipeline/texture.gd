extends RefCounted
class_name MMTexture


var rd : RenderingDevice
var rid : RID
var texture_size : Vector2i
var texture_format : RenderingDevice.DataFormat
var texture : Texture2D
var texture_needs_update : bool = false

# GPU memory budget (see design/hybrid_evaluator.md): textures that have a
# copy in the rendering device are registered, so the least recently used
# ones can be evicted (copied back to RAM and freed) when over budget.
# They are uploaded again by get_texture_rid() when needed.
static var gpu_textures : Dictionary = {}
var last_used : int = 0
# get_instance_id() cannot be called when the texture is deleted
var texture_id : int = 0

const BYTES_PER_PIXEL : Dictionary = {
	RenderingDevice.DATA_FORMAT_R16_SFLOAT: 2,
	RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT: 8,
	RenderingDevice.DATA_FORMAT_R32_SFLOAT: 4,
	RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT: 16,
	RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM: 4,
	RenderingDevice.DATA_FORMAT_R8_UNORM: 1
}
# Textures used more recently than this are probably part of the current
# render and are never evicted
const EVICTION_MIN_IDLE_MS : int = 1000


func _init() -> void:
	rid = RID()
	texture = ImageTexture.new()
	texture_id = get_instance_id()

func _notification(what : int) -> void:
	match what:
		NOTIFICATION_PREDELETE:
			gpu_textures.erase(texture_id)
			# At exit, the renderer (and its device) is already gone
			if is_instance_valid(mm_renderer) and mm_renderer.is_inside_tree():
				await mm_renderer.thread_run(in_thread_free_rid, [rid, rd])

func get_gpu_size() -> int:
	if not rid.is_valid():
		return 0
	return texture_size.x*texture_size.y*BYTES_PER_PIXEL.get(texture_format, 8)

## Marks the texture as used (may be called from the rendering thread)
func touch() -> void:
	last_used = Time.get_ticks_msec()
	register.call_deferred()

func register() -> void:
	if rid.is_valid() and not gpu_textures.has(texture_id):
		gpu_textures[texture_id] = weakref(self)
	if mm_renderer:
		mm_renderer.request_texture_budget_check()

## Copies the texture to RAM and frees its copy in the rendering device
func evict() -> bool:
	var evicted_rid : RID = rid
	if not evicted_rid.is_valid():
		return false
	if texture_needs_update:
		await get_texture()
		# The texture's image is updated in a deferred call
		await mm_renderer.get_tree().process_frame
	var image : Image = texture.get_image()
	# Give up if the texture was rendered again or could not be read
	if rid != evicted_rid or texture_needs_update or image == null or image.get_size() != texture_size:
		return false
	rid = RID()
	gpu_textures.erase(texture_id)
	await mm_renderer.thread_run(in_thread_free_rid, [evicted_rid, rd])
	return true

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

## Evicts the least recently used textures until the memory used in the
## rendering device fits in budget (in bytes), returns the number of
## evicted textures
static func enforce_budget(budget : int) -> int:
	var textures : Array = []
	var total : int = 0
	for id in gpu_textures.keys():
		var t = gpu_textures[id].get_ref()
		if t == null or not t.rid.is_valid():
			gpu_textures.erase(id)
			continue
		textures.append(t)
		total += t.get_gpu_size()
	if total <= budget:
		return 0
	textures.sort_custom(func(a, b): return a.last_used < b.last_used)
	var now : int = Time.get_ticks_msec()
	var evicted : int = 0
	for t in textures:
		if total <= budget:
			break
		if now-t.last_used < EVICTION_MIN_IDLE_MS:
			continue
		var size : int = t.get_gpu_size()
		if await t.evict():
			total -= size
			evicted += 1
	return evicted

static func in_thread_free_rid(texture_rid, rendering_device):
	if texture_rid.is_valid():
		rendering_device.free_rid(texture_rid)

func get_texture_rid(target_rd : RenderingDevice) -> RID:
	if ! rid.is_valid():
		var image : Image = texture.get_image()
		if image == null or image.get_width() == 0 or image.get_height() == 0:
			#print("No image for texture %s" % str(texture))
			image = Image.create(1, 1, false, Image.FORMAT_RH)
			texture_format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
		var fmt : RDTextureFormat = RDTextureFormat.new()
		fmt.width = image.get_width()
		fmt.height = image.get_height()
		fmt.format = texture_format
		fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		# Evicted textures that are uploaded again may be reused as compute
		# outputs (e.g. by iterate buffers)
		if BYTES_PER_PIXEL.has(texture_format):
			fmt.usage_bits |= RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		var view : RDTextureView = RDTextureView.new()
		rd = target_rd
		rid = rd.texture_create(fmt, view, [ image.get_data() ])
	else:
		assert(target_rd == rd)
	touch()
	return rid

func set_texture_rid(new_rid : RID, size : Vector2i, format : RenderingDevice.DataFormat, new_rd : RenderingDevice) -> void:
	if new_rid == rid:
		texture_needs_update = true
		return
	if rid.is_valid():
		rd.free_rid(rid)
	rd = new_rd
	rid = new_rid
	texture_size = size
	texture_format = format
	texture_needs_update = true
	touch()

func in_thread_get_texture() -> Texture2D:
	if texture_needs_update:
		var byte_data : PackedByteArray = rd.texture_get_data(rid, 0)
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
			RenderingDevice.DATA_FORMAT_R8_UNORM:
				image_format = Image.FORMAT_R8
		var image : Image = Image.create_from_data(texture_size.x, texture_size.y, false, image_format, byte_data)
		texture.set_image.call_deferred(image)
		texture_needs_update = false
	return texture

func get_texture() -> Texture2D:
	if texture_needs_update:
		if rd and rid.is_valid():
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

## A texture of an image
static func from_image(image : Image) -> MMTexture:
	var rv : MMTexture = MMTexture.new()
	rv.set_texture(ImageTexture.create_from_image(image))
	return rv

## Floats (4 per texel) in an RGBA float image, in rows of 4096 texels (for
## mesh attributes read by shaders)
static func pack_texels(values : PackedFloat32Array) -> Image:
	var texel_count : int = max(1, values.size()/4)
	var width : int = min(texel_count, 4096)
	var height : int = (texel_count+width-1)/width
	values.resize(width*height*4)
	return Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, values.to_byte_array())

func get_width() -> int:
	return texture_size.x

func get_height() -> int:
	return texture_size.y

func save_to_file(file_name : String) -> Error:
	var texture : ImageTexture = await get_texture()
	return save_image(texture.get_image(), file_name)

## Saves an image in the format given by the file extension
static func save_image(image : Image, file_name : String) -> Error:
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
