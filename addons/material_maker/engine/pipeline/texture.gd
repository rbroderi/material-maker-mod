extends RefCounted
class_name MMTexture


var rd : RenderingDevice
var rid : RID
var texture_size : Vector2i
var texture_format : RenderingDevice.DataFormat
var texture : Texture2D
var texture_needs_update : bool = false
## Increased by set_texture() and release(), so the rendering thread can tell
## whether the texture it read is still current
var texture_version : int = 0
## Makes set_texture() (main thread) atomic for get_texture_rid() (rendering
## thread): texture, texture_format, texture_size, texture_version and rid
## change together. Only held for a few assignments, never while a texture is
## being created.
var mutex : Mutex = Mutex.new()

## GPU memory budget (see design/gpu_memory_budget.md): textures that have a
## copy in the rendering device are registered, so that the least recently
## used rendered ones can be spilled (read back to RAM and freed in the
## rendering device) when the textures use more than the budget.
## get_texture_rid() uploads them again when they are used.
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
## The rendering device texture that was last counted in the peak memory
## (see register())
var counted_rid : RID = RID()

const BYTES_PER_PIXEL : Dictionary = {
	RenderingDevice.DATA_FORMAT_R16_SFLOAT: 2,
	RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT: 8,
	RenderingDevice.DATA_FORMAT_R32_SFLOAT: 4,
	RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT: 16,
	RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM: 4,
	RenderingDevice.DATA_FORMAT_R8_UNORM: 1,
	RenderingDevice.DATA_FORMAT_R16_UNORM: 2,
	RenderingDevice.DATA_FORMAT_R16G16B16A16_UNORM: 8,
	RenderingDevice.DATA_FORMAT_R8G8_UNORM: 2,
	RenderingDevice.DATA_FORMAT_R16G16_SFLOAT: 4,
	RenderingDevice.DATA_FORMAT_R32G32_SFLOAT: 8,
	RenderingDevice.DATA_FORMAT_R16G16_UNORM: 4
}
# Textures larger than this (in bytes) are read back in strips
const MAX_READBACK_SIZE : int = 1 << 29
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
			# Most textures never get a rendering device texture (e.g. the
			# Material node's preview textures, recreated on every shader
			# update): don't make them wait for the rendering thread. At exit,
			# the renderer (and its device) is already gone.
			if rid.is_valid() and is_instance_valid(mm_renderer) and mm_renderer.is_inside_tree():
				await mm_renderer.thread_run(in_thread_free_rid, [rid, rd])

## Size of the texture in the rendering device, in bytes
func get_gpu_size() -> int:
	if not rid.is_valid():
		return 0
	return texture_size.x*texture_size.y*BYTES_PER_PIXEL.get(texture_format, 8)

## Marks the texture as used (may be called from the rendering thread)
func touch() -> void:
	last_used = Time.get_ticks_msec()
	register.call_deferred()

func register() -> void:
	if rid.is_valid():
		if not gpu_textures.has(texture_id):
			gpu_textures[texture_id] = weakref(self)
		# The memory used by the textures only grows when one of them gets a
		# new rendering device texture (rendered, resized or uploaded again)
		if rid != counted_rid and mm_renderer:
			counted_rid = rid
			mm_renderer.update_peak_texture_memory()
	if mm_renderer:
		mm_renderer.request_texture_budget_check()

## Copies a rendered texture to RAM and frees it in the rendering device (in
## the rendering thread, where renders use the textures). Returns false if the
## texture cannot be spilled.
func in_thread_evict() -> bool:
	var evicted_rid : RID = rid
	if not evicted_rid.is_valid() or not rendered or not BYTES_PER_PIXEL.has(texture_format):
		return false
	if rd != mm_renderer.rendering_device:
		return false
	if Time.get_ticks_msec()-last_used < SPILL_MIN_IDLE_MS:
		return false
	var image : Image = in_thread_read_image()
	if image == null or image.get_size() != texture_size:
		return false
	mutex.lock()
	# set_texture() or release() may have replaced the texture meanwhile
	var evicted : bool = rendered and rid == evicted_rid
	if evicted:
		spilled_image = image
		rid = RID()
	mutex.unlock()
	if evicted:
		rd.free_rid(evicted_rid)
	# Spilled textures are removed from gpu_textures when it is read (they may
	# already have been used and uploaded again)
	return evicted

## Name of the buffer (in mm_deps) of a released texture, that must be
## rendered again before the texture can be used (see release())
var released_buffer : String = ""

## Frees the texture in the rendering device and its image in RAM (unlike
## spilling, the texture is lost and its buffer must render it again)
func release(buffer_name : String) -> void:
	mutex.lock()
	var released_rid : RID = rid
	rid = RID()
	texture_needs_update = false
	# Other objects may still use the old image texture
	texture = ImageTexture.new()
	texture_version += 1
	rendered = false
	spilled_image = null
	released_buffer = buffer_name
	mutex.unlock()
	if released_rid.is_valid():
		await mm_renderer.thread_run(in_thread_free_rid, [released_rid, rd])

## Renders a released texture again (does nothing for other textures)
func restore() -> void:
	if released_buffer != "":
		await mm_deps.restore_buffer(released_buffer)

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

## Spills the least recently used rendered textures until the textures in
## the rendering device fit in budget (in bytes). Returns the number of
## spilled textures.
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

## Frees a texture of the renderer's RenderingDevice from any thread. The device
## can only be used from the rendering thread, so the free is queued there (it
## then also runs after any render that may still be using the texture).
static func free_rid_in_render_thread(texture_rid : RID, rendering_device : RenderingDevice) -> void:
	var rendering_thread : Thread = mm_renderer.rendering_thread
	if rendering_thread != null and rendering_thread.get_id() == str(OS.get_thread_caller_id()):
		in_thread_free_rid(texture_rid, rendering_device)
	else:
		mm_renderer.thread_run(in_thread_free_rid, [texture_rid, rendering_device])

func get_texture_rid(target_rd : RenderingDevice) -> RID:
	mutex.lock()
	while ! rid.is_valid():
		# Read the texture and its format together, then create the RD texture
		# without holding the lock
		var source : Texture2D = texture
		var spilled : Image = spilled_image
		var format : RenderingDevice.DataFormat = texture_format
		var version : int = texture_version
		mutex.unlock()
		var image : Image = spilled if spilled != null else source.get_image()
		if image == null or image.get_width() == 0 or image.get_height() == 0:
			#print("No image for texture %s" % str(texture))
			image = Image.create(1, 1, false, Image.FORMAT_RH)
			format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
		elif image_data_format(image.get_format()) != format:
			var data_format : int = image_data_format(image.get_format())
			if data_format >= 0:
				format = data_format
		var fmt : RDTextureFormat = RDTextureFormat.new()
		fmt.width = image.get_width()
		fmt.height = image.get_height()
		fmt.format = format
		fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		# Spilled textures that are uploaded again may be reused as compute
		# outputs (e.g. by iterate buffers)
		if BYTES_PER_PIXEL.has(format):
			fmt.usage_bits |= RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		var view : RDTextureView = RDTextureView.new()
		var new_rid : RID = target_rd.texture_create(fmt, view, [ image.get_data() ])
		mutex.lock()
		if version == texture_version:
			texture_format = format
			rd = target_rd
			rid = new_rid
			spilled_image = null
			break
		# set_texture() or release() was called meanwhile: start again with
		# the new texture
		if new_rid.is_valid():
			target_rd.free_rid(new_rid)
	assert(target_rd == rd)
	var texture_rid : RID = rid
	mutex.unlock()
	touch()
	return texture_rid

func set_texture_rid(new_rid : RID, size : Vector2i, format : RenderingDevice.DataFormat, new_rd : RenderingDevice) -> void:
	if new_rid == rid:
		texture_needs_update = true
		released_buffer = ""
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
	released_buffer = ""
	touch()

func in_thread_get_texture() -> Texture2D:
	if texture_needs_update:
		var image : Image = in_thread_read_image() if rid.is_valid() else spilled_image
		if image != null:
			texture.set_image.call_deferred(image)
		texture_needs_update = false
	return texture

## Reads the texture back from the rendering device (16 bits integer textures
## as 16 bits integer images). Large textures are read in strips, since drivers
## may fail to allocate a staging buffer for the whole texture (e.g. 2 GB for
## 16384x16384 RGBA16F)
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
		RenderingDevice.DATA_FORMAT_R8_UNORM:
			image_format = Image.FORMAT_R8
		RenderingDevice.DATA_FORMAT_R8G8_UNORM:
			image_format = Image.FORMAT_RG8
		RenderingDevice.DATA_FORMAT_R16G16_SFLOAT:
			image_format = Image.FORMAT_RGH
		RenderingDevice.DATA_FORMAT_R32G32_SFLOAT:
			image_format = Image.FORMAT_RGF
		RenderingDevice.DATA_FORMAT_R16_UNORM:
			image_format = Image.FORMAT_R16
		RenderingDevice.DATA_FORMAT_R16G16_UNORM:
			image_format = Image.FORMAT_RG16
		RenderingDevice.DATA_FORMAT_R16G16B16A16_UNORM:
			image_format = Image.FORMAT_RGBA16
	var row_size : int = texture_size.x*BYTES_PER_PIXEL.get(texture_format, 0)
	if row_size == 0 or row_size*texture_size.y <= MAX_READBACK_SIZE:
		return Image.create_from_data(texture_size.x, texture_size.y, false, image_format, rd.texture_get_data(rid, 0))
	var strip_height : int = max(1, MAX_READBACK_SIZE/row_size)
	var fmt : RDTextureFormat = RDTextureFormat.new()
	fmt.width = texture_size.x
	fmt.height = strip_height
	fmt.format = texture_format
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var strip_rid : RID = rd.texture_create(fmt, RDTextureView.new(), [])
	if not strip_rid.is_valid():
		push_error("Failed to read back texture of size %dx%d" % [ texture_size.x, texture_size.y ])
		return null
	var data : PackedByteArray = PackedByteArray()
	var y : int = 0
	while y < texture_size.y:
		var height : int = min(strip_height, texture_size.y-y)
		if rd.texture_copy(rid, strip_rid, Vector3(0, y, 0), Vector3.ZERO, Vector3(texture_size.x, height, 1), 0, 0, 0, 0) != OK or not append_strip(data, rd.texture_get_data(strip_rid, 0), row_size, strip_height, height):
			data = PackedByteArray()
			break
		y += height
	rd.free_rid(strip_rid)
	return image_from_strips(texture_size, image_format, data, row_size)

## Appends the first rows of a strip read back from the rendering device to
## the data of an image (strips are assembled as raw data, since
## Image.blit_rect() fails for images of 4 GB or more, e.g. 16384x16384 RGBA
## 32 bits floats)
static func append_strip(data : PackedByteArray, strip_data : PackedByteArray, row_size : int, strip_height : int, height : int) -> bool:
	if strip_data.size() != row_size*strip_height:
		return false
	data.append_array(strip_data if height == strip_height else strip_data.slice(0, row_size*height))
	return true

## The image of data assembled by append_strip(), or null (with an error) if
## the data is incomplete
static func image_from_strips(size : Vector2i, image_format : Image.Format, data : PackedByteArray, row_size : int) -> Image:
	if data.size() != row_size*size.y:
		push_error("Failed to read back texture of size %dx%d" % [ size.x, size.y ])
		return null
	return Image.create_from_data(size.x, size.y, false, image_format, data)

## The data format of the textures of an image format, or -1
static func image_data_format(image_format : int) -> int:
	match image_format:
		Image.FORMAT_RF:
			return RenderingDevice.DATA_FORMAT_R32_SFLOAT
		Image.FORMAT_RGF:
			return RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
		Image.FORMAT_RGBAF:
			return RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		Image.FORMAT_RH:
			return RenderingDevice.DATA_FORMAT_R16_SFLOAT
		Image.FORMAT_RGH:
			return RenderingDevice.DATA_FORMAT_R16G16_SFLOAT
		Image.FORMAT_RGBAH:
			return RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		Image.FORMAT_R8:
			return RenderingDevice.DATA_FORMAT_R8_UNORM
		Image.FORMAT_RG8:
			return RenderingDevice.DATA_FORMAT_R8G8_UNORM
		Image.FORMAT_RGBA8:
			return RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
		Image.FORMAT_R16:
			return RenderingDevice.DATA_FORMAT_R16_UNORM
		Image.FORMAT_RG16:
			return RenderingDevice.DATA_FORMAT_R16G16_UNORM
		Image.FORMAT_RGBA16:
			return RenderingDevice.DATA_FORMAT_R16G16B16A16_UNORM
	return -1

func get_texture() -> Texture2D:
	await restore()
	if texture_needs_update:
		if rd and (rid.is_valid() or spilled_image != null):
			await mm_renderer.thread_run(in_thread_get_texture)
	return texture

func set_texture(new_texture : ImageTexture) -> void:
	var format : RenderingDevice.DataFormat = texture_format
	var size : Vector2i = new_texture.get_size()
	var image : Image = new_texture.get_image()
	if image:
		match image.get_format():
			Image.FORMAT_RF:
				format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
			Image.FORMAT_RGBAF:
				format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
			Image.FORMAT_RH:
				format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
			Image.FORMAT_RGBAH:
				format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
			Image.FORMAT_RGF:
				format = RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
			Image.FORMAT_RGH:
				format = RenderingDevice.DATA_FORMAT_R16G16_SFLOAT
			Image.FORMAT_RG8:
				format = RenderingDevice.DATA_FORMAT_R8G8_UNORM
			Image.FORMAT_R16:
				format = RenderingDevice.DATA_FORMAT_R16_UNORM
			Image.FORMAT_RG16:
				format = RenderingDevice.DATA_FORMAT_R16G16_UNORM
			Image.FORMAT_RGBA16:
				format = RenderingDevice.DATA_FORMAT_R16G16B16A16_UNORM
			Image.FORMAT_DXT1:
				format = RenderingDevice.DATA_FORMAT_BC1_RGBA_SRGB_BLOCK
			Image.FORMAT_DXT3:
				format = RenderingDevice.DATA_FORMAT_BC2_SRGB_BLOCK
			Image.FORMAT_DXT5:
				format = RenderingDevice.DATA_FORMAT_BC3_SRGB_BLOCK
			#Image.FORMAT_RGBA8:
			#	format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
			_:
				# Other formats are converted to 16 bit floats. This is expected
				# for 8 bit images (Image nodes loading PNG or JPG files, Text
				# nodes), so only report the others
				if not image.get_format() in [ Image.FORMAT_L8, Image.FORMAT_LA8, Image.FORMAT_R8, Image.FORMAT_RG8, Image.FORMAT_RGB8, Image.FORMAT_RGBA8 ]:
					print("Unsupported texture format "+str(image.get_format()))
				image.convert(Image.FORMAT_RGBAH)
				new_texture.set_image(image)
				format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		size = image.get_size()
	# The rendering thread may upload the texture at any time (when it has
	# no copy in the rendering device): only use the new texture once its
	# image has been converted, and swap it in together with its format and
	# size
	mutex.lock()
	texture_format = format
	texture_size = size
	texture = new_texture
	texture_version += 1
	var old_rid : RID = rid
	var old_rd : RenderingDevice = rd
	rid = RID()
	rendered = false
	spilled_image = null
	released_buffer = ""
	mutex.unlock()
	if old_rid.is_valid():
		free_rid_in_render_thread(old_rid, old_rd)

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

func save_to_file(file_name : String, options : Dictionary = {}) -> Error:
	await restore()
	var image : Image
	if texture_needs_update and rd and rid.is_valid():
		# Read the rendered texture directly, without uploading it again as
		# an ImageTexture (which may not fit in GPU memory for 16k textures)
		image = await mm_renderer.thread_run(in_thread_read_image)
	else:
		var texture : ImageTexture = await get_texture()
		image = texture.get_image()
	return await save_image_rounded(image, file_name, options)

## Whether an image is saved with 8 bits per channel (PNG, JPEG and WebP
## files, and formats of plugins with bits=8). 16 bits integer images are
## saved as 16 bits PNG files.
static func is_saved_as_8_bits(image : Image, file_name : String, options : Dictionary = {}) -> bool:
	if image == null or image_bits(image.get_format()) == 8:
		return false
	if is_16_bits_integer(image.get_format()) and file_name.get_extension().to_lower() == "png":
		return false
	if file_name.get_extension().to_lower() in [ "png", "jpg", "jpeg", "webp" ]:
		return true
	return int(options.get("bits", 0)) == 8

## An 8 bits copy of a float image, with values rounded to the nearest (Godot's
## image conversions truncate them, so exact 8 bits values that are a little
## lower in floats would lose a level). It is rendered by a compute shader.
static func round_image_to_8_bits(image : Image) -> Image:
	var source : MMTexture = MMTexture.from_image(image)
	var code : MMGenBase.ShaderCode = MMGenBase.ShaderCode.new()
	code.output_type = "rgba"
	code.add_uniform("mm_source_image", "sampler2D", source)
	code.output_values.rgba = "texelFetch(mm_source_image, ivec2(pixel), 0)"
	var compute_shader : MMComputeShader = MMComputeShader.new()
	if not await compute_shader.set_shader_from_shadercode_storage(code, MMPipeline.STORAGE_8, false, MMPipeline.ROUNDING_HALF_UP):
		return image
	var rounded : MMTexture = MMTexture.new()
	if not await compute_shader.render_ext([ rounded ], image.get_size()):
		return image
	var rv : Image = (await rounded.get_texture()).get_image()
	return rv if rv != null else image

## Saves an image as save_image(), values of files that are saved as 8 bits
## being rounded to the nearest
static func save_image_rounded(image : Image, file_name : String, options : Dictionary = {}) -> Error:
	if is_saved_as_8_bits(image, file_name, options):
		image = await round_image_to_8_bits(image)
	return save_image(image, file_name, options)

## Channel count of a Godot image format
static func image_channels(format : int) -> int:
	match format:
		Image.FORMAT_L8, Image.FORMAT_R8, Image.FORMAT_RH, Image.FORMAT_RF, Image.FORMAT_R16:
			return 1
		Image.FORMAT_LA8, Image.FORMAT_RG8, Image.FORMAT_RGH, Image.FORMAT_RGF, Image.FORMAT_RG16:
			return 2
		Image.FORMAT_RGB8, Image.FORMAT_RGBH, Image.FORMAT_RGBF:
			return 3
	return 4

## Component size of a Godot image format, in bits
static func image_bits(format : int) -> int:
	match format:
		Image.FORMAT_RH, Image.FORMAT_RGH, Image.FORMAT_RGBH, Image.FORMAT_RGBAH, Image.FORMAT_R16, Image.FORMAT_RG16, Image.FORMAT_RGBA16:
			return 16
		Image.FORMAT_RF, Image.FORMAT_RGF, Image.FORMAT_RGBF, Image.FORMAT_RGBAF:
			return 32
	return 8

## Whether an image format holds 16 bits integers (16 bits integer buffers)
static func is_16_bits_integer(format : int) -> bool:
	return format in [ Image.FORMAT_R16, Image.FORMAT_RG16, Image.FORMAT_RGBA16 ]

## Saves an image in the format given by the file extension (formats added
## by plugins get the options)
static func save_image(image : Image, file_name : String, options : Dictionary = {}) -> Error:
	if image != null and is_16_bits_integer(image.get_format()):
		# 16 bits integer images are saved as 16 bits PNG files, and as 32 bits
		# floats in other formats (e.g. EXR)
		if file_name.get_extension() == "png":
			return save_png_16(image, file_name)
		image = image.duplicate() as Image
		image.convert({ Image.FORMAT_R16: Image.FORMAT_RF, Image.FORMAT_RG16: Image.FORMAT_RGF }.get(image.get_format(), Image.FORMAT_RGBAF))
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
			_:
				return MMPlugins.save_image(export_image, file_name, options)
	return ERR_DOES_NOT_EXIST

## Saves a 16 bits integer image (R16, RG16 or RGBA16) as a 16 bits grayscale
## or RGBA PNG file (Godot only writes 8 bits PNG files)
static func save_png_16(image : Image, file_name : String) -> Error:
	if image.get_format() == Image.FORMAT_RG16:
		image = rg16_to_rgba16(image)
	var grayscale : bool = image.get_format() == Image.FORMAT_R16
	var width : int = image.get_width()
	var height : int = image.get_height()
	var row_size : int = width*(2 if grayscale else 8)
	var data : PackedByteArray = get_big_endian_data(image)
	# Each row starts with its filter type (0, none)
	var rows : PackedByteArray = PackedByteArray()
	for y in height:
		rows.append(0)
		rows.append_array(data.slice(y*row_size, (y+1)*row_size))
	data.clear()
	var png : PackedByteArray = PackedByteArray([ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ])
	# Width, height, bit depth, color type (0: grayscale, 6: RGBA), compression, filter, interlace
	var header : PackedByteArray = png_u32(width)
	header.append_array(png_u32(height))
	header.append_array(PackedByteArray([ 16, 0 if grayscale else 6, 0, 0, 0 ]))
	png.append_array(png_chunk("IHDR", header))
	var compressed : PackedByteArray = rows.compress(FileAccess.COMPRESSION_DEFLATE)
	rows.clear()
	const MAX_CHUNK_SIZE : int = 1 << 24
	for offset in range(0, compressed.size(), MAX_CHUNK_SIZE):
		png.append_array(png_chunk("IDAT", compressed.slice(offset, offset+MAX_CHUNK_SIZE)))
	png.append_array(png_chunk("IEND", PackedByteArray()))
	var file : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(png)
	return file.get_error()

## Loads an image file. 16 bits non interlaced PNG files are decoded by
## load_png_16() so they keep their precision (Godot's loader reduces them
## to 8 bits), other files are loaded by Godot.
static func load_image_file(file_name : String) -> Image:
	if file_name.get_extension().to_lower() == "png":
		var image : Image = load_png_16(file_name)
		if image != null:
			return image
	return Image.load_from_file(file_name)

## Decodes a 16 bits non interlaced PNG file: grayscale files become R16
## images, other color types (RGB, gray+alpha, RGBA) RGBA16 images. Returns
## null for other files (8 bits or less, interlaced, invalid), that are left
## to Godot's loader.
static func load_png_16(file_name : String) -> Image:
	var png : PackedByteArray = FileAccess.get_file_as_bytes(file_name)
	if png.size() < 33 or png.slice(0, 8) != PackedByteArray([ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ]):
		return null
	var width : int = 0
	var height : int = 0
	var color_type : int = -1
	var idat : PackedByteArray = PackedByteArray()
	var offset : int = 8
	while offset+12 <= png.size():
		var size : int = png_read_u32(png, offset)
		var type : String = png.slice(offset+4, offset+8).get_string_from_ascii()
		if offset+12+size > png.size():
			return null
		match type:
			"IHDR":
				width = png_read_u32(png, offset+8)
				height = png_read_u32(png, offset+12)
				# Bit depth 16, compression 0, filter 0, no interlace
				if png[offset+16] != 16 or png[offset+18] != 0 or png[offset+19] != 0 or png[offset+20] != 0:
					return null
				color_type = png[offset+17]
				if not color_type in [ 0, 2, 4, 6 ]:
					return null
			"IDAT":
				idat.append_array(png.slice(offset+8, offset+8+size))
			"IEND":
				break
		offset += 12+size
	png.clear()
	if width <= 0 or height <= 0 or color_type < 0:
		return null
	var channels : int = { 0: 1, 2: 3, 4: 2, 6: 4 }[color_type]
	var bpp : int = 2*channels
	var row_size : int = width*bpp
	var data : PackedByteArray = png_unfilter_natively(idat, width, height, color_type)
	if data.is_empty():
		# IDAT chunks hold a zlib stream (Godot's deflate mode)
		var rows : PackedByteArray = idat.decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE)
		idat.clear()
		if rows.size() < height*(row_size+1):
			return null
		data = png_unfilter(rows, width*bpp, height, bpp)
		rows.clear()
	if data.is_empty():
		return null
	# Big endian to little endian
	data = get_big_endian_data(Image.create_from_data(width*channels, height, false, Image.FORMAT_R16, data))
	match color_type:
		0:
			return Image.create_from_data(width, height, false, Image.FORMAT_R16, data)
		6:
			return Image.create_from_data(width, height, false, Image.FORMAT_RGBA16, data)
	# RGB and gray+alpha are expanded to RGBA
	var values : PackedInt32Array = PackedInt32Array()
	var count : int = width*height
	var rgba : PackedInt64Array = PackedInt64Array()
	rgba.resize(count)
	if color_type == 2:
		for i in count:
			var r : int = data.decode_u16(6*i)
			var g : int = data.decode_u16(6*i+2)
			var b : int = data.decode_u16(6*i+4)
			rgba[i] = r | (g << 16) | (b << 32) | (0xFFFF << 48)
	else:
		values = data.to_int32_array()
		for i in count:
			var gray : int = values[i] & 0xFFFF
			var alpha : int = (values[i] >> 16) & 0xFFFF
			rgba[i] = gray | (gray << 16) | (gray << 32) | (alpha << 48)
	return Image.create_from_data(width, height, false, Image.FORMAT_RGBA16, rgba.to_byte_array())

## The unfiltered big endian data of a 16 bits grayscale (0) or gray+alpha
## (4) PNG, decoded by Godot's loader (much faster than png_unfilter): their
## rows have the same bytes, and filters the same byte distance, as 8 bits
## gray+alpha and RGBA PNG files of the same size, so the IDAT data is
## loaded with such a header. Returns an empty array for other color types
## or when Godot's loader does not give the expected 8 bits image.
static func png_unfilter_natively(idat : PackedByteArray, width : int, height : int, color_type : int) -> PackedByteArray:
	if not color_type in [ 0, 4 ]:
		return PackedByteArray()
	var png : PackedByteArray = PackedByteArray([ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ])
	var header : PackedByteArray = png_u32(width)
	header.append_array(png_u32(height))
	header.append_array(PackedByteArray([ 8, 4 if color_type == 0 else 6, 0, 0, 0 ]))
	png.append_array(png_chunk("IHDR", header))
	png.append_array(png_chunk("IDAT", idat))
	png.append_array(png_chunk("IEND", PackedByteArray()))
	var image : Image = Image.new()
	if image.load_png_from_buffer(png) != OK:
		return PackedByteArray()
	var expected_format : int = Image.FORMAT_LA8 if color_type == 0 else Image.FORMAT_RGBA8
	if image.get_format() != expected_format or image.get_size() != Vector2i(width, height):
		return PackedByteArray()
	return image.get_data()

## Reverts the PNG filters of decompressed rows (each row starts with its
## filter type: none, sub, up, average or Paeth). Returns an empty array for
## invalid filters.
static func png_unfilter(rows : PackedByteArray, row_size : int, height : int, bpp : int) -> PackedByteArray:
	var data : PackedByteArray = PackedByteArray()
	data.resize(row_size*height)
	for y in height:
		var src : int = y*(row_size+1)
		var filter : int = rows[src]
		src += 1
		var dst : int = y*row_size
		var prev : int = dst-row_size
		match filter:
			0:
				for x in row_size:
					data[dst+x] = rows[src+x]
			1:
				for x in row_size:
					var a : int = data[dst+x-bpp] if x >= bpp else 0
					data[dst+x] = (rows[src+x]+a) & 255
			2:
				for x in row_size:
					var b : int = data[prev+x] if y > 0 else 0
					data[dst+x] = (rows[src+x]+b) & 255
			3:
				for x in row_size:
					var a : int = data[dst+x-bpp] if x >= bpp else 0
					var b : int = data[prev+x] if y > 0 else 0
					data[dst+x] = (rows[src+x]+((a+b) >> 1)) & 255
			4:
				for x in row_size:
					var a : int = data[dst+x-bpp] if x >= bpp else 0
					var b : int = data[prev+x] if y > 0 else 0
					var c : int = data[prev+x-bpp] if y > 0 and x >= bpp else 0
					var p : int = a+b-c
					var pa : int = absi(p-a)
					var pb : int = absi(p-b)
					var pc : int = absi(p-c)
					var predictor : int = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
					data[dst+x] = (rows[src+x]+predictor) & 255
			_:
				return PackedByteArray()
	return data

## A big endian 32 bits integer read from PNG data
static func png_read_u32(data : PackedByteArray, offset : int) -> int:
	return (data[offset] << 24) | (data[offset+1] << 16) | (data[offset+2] << 8) | data[offset+3]

## The data of a 16 bits integer image with big endian values (for PNG
## files). PackedByteArray.reverse() swaps the bytes of each value but also
## reverses their order, which flipping an image of one value per pixel
## restores (faster than swapping the values one by one in a script).
static func get_big_endian_data(image : Image) -> PackedByteArray:
	var data : PackedByteArray = image.get_data()
	var values_per_row : int = data.size()/(2*image.get_height())
	data.reverse()
	var values : Image = Image.create_from_data(values_per_row, image.get_height(), false, Image.FORMAT_R16, data)
	values.flip_x()
	values.flip_y()
	return values.get_data()

## An RGBA16 copy of an RG16 image (blue 0, alpha 1). Image.convert() is
## not used since it loses one level for some values.
static func rg16_to_rgba16(image : Image) -> Image:
	var rg : PackedInt32Array = image.get_data().to_int32_array()
	var rgba : PackedInt64Array = PackedInt64Array()
	rgba.resize(rg.size())
	const ALPHA : int = 0xFFFF << 48
	for i in rg.size():
		rgba[i] = (rg[i] & 0xFFFFFFFF) | ALPHA
	return Image.create_from_data(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA16, rgba.to_byte_array())

## A big endian 32 bits integer (for PNG files)
static func png_u32(value : int) -> PackedByteArray:
	return PackedByteArray([ (value >> 24) & 255, (value >> 16) & 255, (value >> 8) & 255, value & 255 ])

## A PNG chunk: size, type, data and CRC (the CRC-32 that ends gzip data)
static func png_chunk(type : String, data : PackedByteArray) -> PackedByteArray:
	var body : PackedByteArray = type.to_ascii_buffer()
	body.append_array(data)
	var gzip : PackedByteArray = body.compress(FileAccess.COMPRESSION_GZIP)
	var rv : PackedByteArray = png_u32(data.size())
	rv.append_array(body)
	rv.append_array(png_u32(gzip.decode_u32(gzip.size()-8)))
	return rv
