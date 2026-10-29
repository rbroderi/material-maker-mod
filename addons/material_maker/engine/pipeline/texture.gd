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
# Textures larger than this (in bytes) are read back in strips
const MAX_READBACK_SIZE : int = 1 << 29

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

func save_to_file(file_name : String) -> Error:
	var image : Image
	if texture_needs_update and rd and rid.is_valid():
		# Read the rendered texture directly, without uploading it again as
		# an ImageTexture (which may not fit in GPU memory for 16k textures)
		image = await mm_renderer.thread_run(in_thread_read_image)
	else:
		var texture : ImageTexture = await get_texture()
		image = texture.get_image()
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
