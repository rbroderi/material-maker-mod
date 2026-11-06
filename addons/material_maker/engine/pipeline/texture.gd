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
			Image.FORMAT_RGBA16:
				# 16 bits PNG files (load_png_16)
				texture_format = RenderingDevice.DATA_FORMAT_R16G16B16A16_UNORM
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

## Loads an image file. 16 bits non interlaced PNG files are decoded by
## load_png_16() so they keep their precision (Godot's loader reduces them
## to 8 bits), other files are loaded by Godot.
static func load_image_file(file_name : String) -> Image:
	if file_name.get_extension().to_lower() == "png":
		var image : Image = load_png_16(file_name)
		if image != null:
			return image
	return Image.load_from_file(file_name)

## Decodes a 16 bits non interlaced PNG file as an RGBA16 image (gray is
## copied to red, green and blue, alpha is 1 without alpha channel). Returns
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
	if color_type == 6:
		return Image.create_from_data(width, height, false, Image.FORMAT_RGBA16, data)
	# Other color types are expanded to RGBA (single channel textures are
	# sampled as red, not gray)
	var values : PackedInt32Array = PackedInt32Array()
	var count : int = width*height
	var rgba : PackedInt64Array = PackedInt64Array()
	rgba.resize(count)
	if color_type == 0:
		# Two gray values per 32 bits integer
		if count % 2 == 1:
			data.append_array(PackedByteArray([ 0, 0 ]))
		values = data.to_int32_array()
		const OPAQUE : int = 0xFFFF << 48
		for i in values.size():
			var pair : int = values[i]
			var gray : int = pair & 0xFFFF
			rgba[2*i] = gray | (gray << 16) | (gray << 32) | OPAQUE
			if 2*i+1 < count:
				gray = (pair >> 16) & 0xFFFF
				rgba[2*i+1] = gray | (gray << 16) | (gray << 32) | OPAQUE
	elif color_type == 2:
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
