extends RefCounted
class_name MMTexture


var rd : RenderingDevice
var rid : RID
var texture_size : Vector2i
var texture_format : RenderingDevice.DataFormat
var texture : Texture2D
var texture_needs_update : bool = false


func _init() -> void:
	rid = RID()
	texture = ImageTexture.new()

func _notification(what : int) -> void:
	match what:
		NOTIFICATION_PREDELETE:
			if mm_renderer:
				await mm_renderer.thread_run(in_thread_free_rid, [rid, rd])

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
		var view : RDTextureView = RDTextureView.new()
		rd = target_rd
		rid = rd.texture_create(fmt, view, [ image.get_data() ])
	else:
		assert(target_rd == rd)
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

func get_width() -> int:
	return texture_size.x

func get_height() -> int:
	return texture_size.y

## Extensions of the image files that are saved with 8 bits per channel
const EIGHT_BITS_EXTENSIONS : Array[String] = [ "png", "jpg", "webp" ]

## Rounds each value to the nearest 8 bits level k and stores it a quarter of
## a level above k/255: converting the result to 8 bits then gives k, whether
## the conversion truncates (as Godot's does) or rounds, even after the
## precision loss of 16 bits floats.
const ROUND_TO_8_BITS_SHADER : String = """#version 450

layout(local_size_x = @LOCAL_SIZE, local_size_y = 1, local_size_z = 1) in;

@DECLARATIONS

layout(set = 3, binding = 0, std140) restrict buffer MM {
	int mm_chunk_y;
};

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy)+ivec2(0, mm_chunk_y);
	vec4 levels = floor(clamp(texelFetch(mm_source, pixel, 0), 0.0, 1.0)*255.0+0.5);
	imageStore(mm_rounded, pixel, (levels+0.25)/255.0);
}
"""

## Compiled rounding shaders, by output texture type
static var round_to_8_bits_shaders : Dictionary = {}
static var round_to_8_bits_busy : bool = false

## Returns a texture with the values of this one rounded to the nearest 8 bits
## level, for files saved with 8 bits per channel. Godot's image conversions
## to 8 bits truncate values, and rendered values that should be exactly k/255
## are often a little lower in floats, so most values would lose one level.
## Returns this texture if the rounding shader fails.
func get_rounded_to_8_bits() -> MMTexture:
	if texture_size.x <= 0 or texture_size.y <= 0:
		return self
	var output_type : int = MMPipeline.TEXTURE_TYPE_RGBA16F
	if texture_format == RenderingDevice.DATA_FORMAT_R16_SFLOAT or texture_format == RenderingDevice.DATA_FORMAT_R32_SFLOAT:
		output_type = MMPipeline.TEXTURE_TYPE_R16F
	while round_to_8_bits_busy:
		await Engine.get_main_loop().process_frame
	round_to_8_bits_busy = true
	var shader : MMComputeShader = round_to_8_bits_shaders.get(output_type)
	if shader == null:
		shader = MMComputeShader.new()
		shader.add_parameter_or_texture("mm_source", "sampler2D", null)
		var output_textures : Array[Dictionary] = [ { name="mm_rounded", type=output_type } ]
		if await shader.set_shader_ext(ROUND_TO_8_BITS_SHADER, output_textures):
			round_to_8_bits_shaders[output_type] = shader
		else:
			shader = null
	var rv : MMTexture = self
	if shader != null:
		shader.set_parameter("mm_source", self)
		var rounded : MMTexture = MMTexture.new()
		if await shader.render_ext([ rounded ], texture_size):
			rv = rounded
		shader.set_parameter("mm_source", null)
	round_to_8_bits_busy = false
	return rv

func save_to_file(file_name : String) -> Error:
	var source : MMTexture = self
	if file_name.get_extension() in EIGHT_BITS_EXTENSIONS:
		source = await get_rounded_to_8_bits()
	var texture : ImageTexture = await source.get_texture()
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
