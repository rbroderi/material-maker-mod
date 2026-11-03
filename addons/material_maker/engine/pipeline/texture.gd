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
			RenderingDevice.DATA_FORMAT_R8_UNORM:
				image_format = Image.FORMAT_R8
			RenderingDevice.DATA_FORMAT_R16_UNORM:
				image_format = Image.FORMAT_R16
			RenderingDevice.DATA_FORMAT_R16G16B16A16_UNORM:
				image_format = Image.FORMAT_RGBA16
			RenderingDevice.DATA_FORMAT_R8G8_UNORM:
				image_format = Image.FORMAT_RG8
			RenderingDevice.DATA_FORMAT_R16G16_SFLOAT:
				image_format = Image.FORMAT_RGH
			RenderingDevice.DATA_FORMAT_R32G32_SFLOAT:
				image_format = Image.FORMAT_RGF
			RenderingDevice.DATA_FORMAT_R16G16_UNORM:
				image_format = Image.FORMAT_RG16
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

func save_to_file(file_name : String) -> Error:
	var texture : ImageTexture = await get_texture()
	var image : Image = texture.get_image()
	if image != null:
		var export_image : Image = image
		if image.get_format() in [ Image.FORMAT_R16, Image.FORMAT_RG16, Image.FORMAT_RGBA16 ]:
			# 16 bits integer images (of 16 bits integer buffers)
			if file_name.get_extension() == "png":
				return save_png_16(image, file_name)
			image.convert(Image.FORMAT_RF if image.get_format() == Image.FORMAT_R16 and file_name.get_extension() == "exr" else Image.FORMAT_RGBAF)
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
