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

# GPU memory budget (see design/gpu_memory_budget.md): textures that have a
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

## 16 bits integer formats, read back as 32 bits float images (by a compute
## shader, Godot images have no 16 bits integer formats)
const UNORM16_FORMATS : Dictionary = {
	RenderingDevice.DATA_FORMAT_R16_UNORM: 1,
	RenderingDevice.DATA_FORMAT_R16G16_UNORM: 2,
	RenderingDevice.DATA_FORMAT_R16G16B16A16_UNORM: 4
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
			# Most textures never get a rendering device texture (e.g. the
			# Material node's preview textures, recreated on every shader
			# update): don't make them wait for the rendering thread. At exit,
			# the renderer (and its device) is already gone.
			if rid.is_valid() and is_instance_valid(mm_renderer) and mm_renderer.is_inside_tree():
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
	mutex.lock()
	if rid != evicted_rid or texture_needs_update or image == null or image.get_size() != texture_size:
		mutex.unlock()
		return false
	rid = RID()
	mutex.unlock()
	gpu_textures.erase(texture_id)
	await mm_renderer.thread_run(in_thread_free_rid, [evicted_rid, rd])
	return true

## Name of the buffer (in mm_deps) of a released texture, that must be
## rendered again before the texture can be used (see release())
var released_buffer : String = ""

## Frees the texture in the rendering device and its image in RAM (unlike
## evict(), the texture is lost and its buffer must render it again)
func release(buffer_name : String) -> void:
	mutex.lock()
	var released_rid : RID = rid
	rid = RID()
	texture_needs_update = false
	# Other objects may still use the old image texture
	texture = ImageTexture.new()
	texture_version += 1
	released_buffer = buffer_name
	mutex.unlock()
	gpu_textures.erase(texture_id)
	if released_rid.is_valid():
		await mm_renderer.thread_run(in_thread_free_rid, [released_rid, rd])

## Renders a released texture again (does nothing for other textures)
func restore() -> void:
	if released_buffer != "":
		await mm_deps.restore_buffer(released_buffer)

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
		var format : RenderingDevice.DataFormat = texture_format
		var version : int = texture_version
		mutex.unlock()
		var image : Image = source.get_image()
		if image == null or image.get_width() == 0 or image.get_height() == 0:
			#print("No image for texture %s" % str(texture))
			image = Image.create(1, 1, false, Image.FORMAT_RH)
			format = RenderingDevice.DATA_FORMAT_R16_SFLOAT
		elif UNORM16_FORMATS.has(format) or image_data_format(image.get_format()) != format:
			# 16 bits integer textures are read back as float images
			var data_format : int = image_data_format(image.get_format())
			if data_format >= 0:
				format = data_format
		var fmt : RDTextureFormat = RDTextureFormat.new()
		fmt.width = image.get_width()
		fmt.height = image.get_height()
		fmt.format = format
		fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		# Evicted textures that are uploaded again may be reused as compute
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
		return
	if rid.is_valid():
		rd.free_rid(rid)
	rd = new_rd
	rid = new_rid
	texture_size = size
	texture_format = format
	texture_needs_update = true
	released_buffer = ""
	touch()

func in_thread_get_texture() -> Texture2D:
	if texture_needs_update:
		var image : Image = in_thread_read_image()
		if image != null:
			texture.set_image.call_deferred(image)
		texture_needs_update = false
	return texture

## Reads the texture back from the rendering device. Large textures are read
## in strips, since drivers may fail to allocate a staging buffer for the whole
## texture (e.g. 2 GB for 16384x16384 RGBA16F)
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
	if UNORM16_FORMATS.has(texture_format):
		return in_thread_read_unorm16_image(rd, rid, texture_size, UNORM16_FORMATS[texture_format])
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
	return -1

## Compute shaders that copy 16 bits integer textures to float textures, by
## channel count
static var unorm16_shaders : Dictionary = {}

## Copies a strip of the source texture (from row offset.y, size rows) to the
## output texture
const UNORM16_TO_FLOAT_SHADER : String = """#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D source_texture;
layout(set = 0, binding = 1, @FORMAT) restrict uniform writeonly image2D output_texture;
layout(push_constant, std430) uniform Strip {
	ivec2 offset;
	ivec2 size;
} strip;
void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(p, strip.size))) {
		return;
	}
	imageStore(output_texture, p, texelFetch(source_texture, p+strip.offset, 0));
}
"""

## Reads a 16 bits integer texture back as a 32 bits float image (in the
## rendering thread). The texture is converted by a compute shader and read
## back in strips of at most MAX_READBACK_SIZE bytes (as floats), so large
## textures need neither a float copy nor a staging buffer of their whole
## size (e.g. 4 GB for 16384x16384 RGBA). Returns null if it fails.
static func in_thread_read_unorm16_image(rendering_device : RenderingDevice, source : RID, size : Vector2i, channels : int) -> Image:
	var formats : Dictionary = {
		1: [ "r32f", RenderingDevice.DATA_FORMAT_R32_SFLOAT, Image.FORMAT_RF ],
		2: [ "rg32f", RenderingDevice.DATA_FORMAT_R32G32_SFLOAT, Image.FORMAT_RGF ],
		4: [ "rgba32f", RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, Image.FORMAT_RGBAF ] }
	var format : Array = formats[channels]
	var key : String = "%d:%d" % [ rendering_device.get_instance_id(), channels ]
	if not unorm16_shaders.has(key):
		var src : RDShaderSource = RDShaderSource.new()
		src.source_compute = UNORM16_TO_FLOAT_SHADER.replace("@FORMAT", format[0])
		var spirv : RDShaderSPIRV = rendering_device.shader_compile_spirv_from_source(src)
		if spirv.compile_error_compute != "":
			push_error(spirv.compile_error_compute)
			return null
		var new_shader : RID = rendering_device.shader_create_from_spirv(spirv)
		if not new_shader.is_valid():
			push_error("Failed to create the 16 bits texture readback shader")
			return null
		unorm16_shaders[key] = new_shader
	var shader : RID = unorm16_shaders[key]
	var row_size : int = size.x*4*channels
	var strip_height : int = clampi(MAX_READBACK_SIZE/row_size, 1, size.y)
	var fmt : RDTextureFormat = RDTextureFormat.new()
	fmt.width = size.x
	fmt.height = strip_height
	fmt.format = format[1]
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var output : RID = rendering_device.texture_create(fmt, RDTextureView.new(), [])
	var sampler : RID = rendering_device.sampler_create(RDSamplerState.new())
	var uniform_set : RID = RID()
	var pipeline : RID = RID()
	if output.is_valid() and sampler.is_valid():
		var source_uniform : RDUniform = RDUniform.new()
		source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		source_uniform.binding = 0
		source_uniform.add_id(sampler)
		source_uniform.add_id(source)
		var output_uniform : RDUniform = RDUniform.new()
		output_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		output_uniform.binding = 1
		output_uniform.add_id(output)
		uniform_set = rendering_device.uniform_set_create([ source_uniform, output_uniform ], shader, 0)
		pipeline = rendering_device.compute_pipeline_create(shader)
	var data : PackedByteArray = PackedByteArray()
	if uniform_set.is_valid() and pipeline.is_valid():
		var strip_parameters : PackedByteArray = PackedInt32Array([ 0, 0, size.x, 0 ]).to_byte_array()
		var y : int = 0
		while y < size.y:
			var height : int = min(strip_height, size.y-y)
			strip_parameters.encode_s32(4, y)
			strip_parameters.encode_s32(12, height)
			var compute_list : int = rendering_device.compute_list_begin()
			rendering_device.compute_list_bind_compute_pipeline(compute_list, pipeline)
			rendering_device.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
			rendering_device.compute_list_set_push_constant(compute_list, strip_parameters, strip_parameters.size())
			rendering_device.compute_list_dispatch(compute_list, (size.x+7)/8, (height+7)/8, 1)
			rendering_device.compute_list_end()
			rendering_device.submit()
			rendering_device.sync()
			var strip_data : PackedByteArray = rendering_device.texture_get_data(output, 0)
			if strip_height == size.y:
				# A single strip (no copy)
				data = strip_data
			elif not append_strip(data, strip_data, row_size, strip_height, height):
				data = PackedByteArray()
				break
			y += height
	# Freeing the output texture also frees the uniform set that uses it
	for r in [ pipeline, sampler, output ]:
		if r.is_valid():
			rendering_device.free_rid(r)
	return image_from_strips(size, format[2], data, row_size)

func get_texture() -> Texture2D:
	await restore()
	if texture_needs_update:
		if rd and rid.is_valid():
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
			Image.FORMAT_DXT1:
				format = RenderingDevice.DATA_FORMAT_BC1_RGBA_SRGB_BLOCK
			Image.FORMAT_DXT3:
				format = RenderingDevice.DATA_FORMAT_BC2_SRGB_BLOCK
			Image.FORMAT_DXT5:
				format = RenderingDevice.DATA_FORMAT_BC3_SRGB_BLOCK
			#Image.FORMAT_RGBA8:
			#	format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
			_:
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
## files, and formats of plugins with bits=8)
static func is_saved_as_8_bits(image : Image, file_name : String, options : Dictionary = {}) -> bool:
	if image == null or image_bits(image.get_format()) == 8:
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
		Image.FORMAT_L8, Image.FORMAT_R8, Image.FORMAT_RH, Image.FORMAT_RF:
			return 1
		Image.FORMAT_LA8, Image.FORMAT_RG8, Image.FORMAT_RGH, Image.FORMAT_RGF:
			return 2
		Image.FORMAT_RGB8, Image.FORMAT_RGBH, Image.FORMAT_RGBF:
			return 3
	return 4

## Component size of a Godot image format, in bits
static func image_bits(format : int) -> int:
	match format:
		Image.FORMAT_RH, Image.FORMAT_RGH, Image.FORMAT_RGBH, Image.FORMAT_RGBAH:
			return 16
		Image.FORMAT_RF, Image.FORMAT_RGF, Image.FORMAT_RGBF, Image.FORMAT_RGBAF:
			return 32
	return 8

## Saves an image in the format given by the file extension (formats added
## by plugins get the options)
static func save_image(image : Image, file_name : String, options : Dictionary = {}) -> Error:
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
