extends GutTest

## Tests for the 16 bits PNG loader (MMTexture.load_png_16), the
## counterpart of MMTexture.save_png_16.

const MMTextureScript = preload("res://addons/material_maker/engine/pipeline/texture.gd")

var file_name : String

func before_each() -> void:
	file_name = OS.get_user_data_dir().path_join("test_png_16.png")

func after_each() -> void:
	DirAccess.remove_absolute(file_name)

## A gradient with every 16 bits value that is not a multiple of 257 (those
## would survive an 8 bits round trip)
func gradient(format : int, channels : int, width : int, height : int) -> Image:
	var data : PackedByteArray = PackedByteArray()
	data.resize(width*height*channels*2)
	for i in width*height*channels:
		data.encode_u16(2*i, (i*7919+i/3) & 0xFFFF)
	return Image.create_from_data(width, height, false, format, data)

func test_grayscale_round_trip() -> void:
	var image : Image = gradient(Image.FORMAT_R16, 1, 37, 23)
	assert_eq(MMTextureScript.save_png_16(image, file_name), OK)
	var loaded : Image = MMTextureScript.load_image_file(file_name)
	assert_eq(loaded.get_format(), Image.FORMAT_R16)
	assert_eq(loaded.get_size(), image.get_size())
	assert_eq(loaded.get_data(), image.get_data())

func test_rgba_round_trip() -> void:
	var image : Image = gradient(Image.FORMAT_RGBA16, 4, 19, 11)
	assert_eq(MMTextureScript.save_png_16(image, file_name), OK)
	var loaded : Image = MMTextureScript.load_image_file(file_name)
	assert_eq(loaded.get_format(), Image.FORMAT_RGBA16)
	assert_eq(loaded.get_data(), image.get_data())

## Rows with each filter type, written by hand (save_png_16 only writes
## filter 0)
func test_filters_and_color_types() -> void:
	for color_type in [ 0, 2, 4, 6 ]:
		var channels : int = { 0: 1, 2: 3, 4: 2, 6: 4 }[color_type]
		var width : int = 5
		var height : int = 5
		var bpp : int = 2*channels
		var row_size : int = width*bpp
		var raw : PackedByteArray = PackedByteArray()
		for i in row_size*height:
			raw.append((i*37+11) & 255)
		var rows : PackedByteArray = PackedByteArray()
		for y in height:
			rows.append(y)
			for x in row_size:
				var a : int = raw[y*row_size+x-bpp] if x >= bpp else 0
				var b : int = raw[(y-1)*row_size+x] if y > 0 else 0
				var c : int = raw[(y-1)*row_size+x-bpp] if y > 0 and x >= bpp else 0
				var predictor : int = 0
				match y:
					1: predictor = a
					2: predictor = b
					3: predictor = (a+b) >> 1
					4:
						var p : int = a+b-c
						var pa : int = absi(p-a)
						var pb : int = absi(p-b)
						var pc : int = absi(p-c)
						predictor = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
				rows.append((raw[y*row_size+x]-predictor) & 255)
		var png : PackedByteArray = PackedByteArray([ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ])
		var header : PackedByteArray = MMTextureScript.png_u32(width)
		header.append_array(MMTextureScript.png_u32(height))
		header.append_array(PackedByteArray([ 16, color_type, 0, 0, 0 ]))
		png.append_array(MMTextureScript.png_chunk("IHDR", header))
		png.append_array(MMTextureScript.png_chunk("IDAT", rows.compress(FileAccess.COMPRESSION_DEFLATE)))
		png.append_array(MMTextureScript.png_chunk("IEND", PackedByteArray()))
		var file : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
		file.store_buffer(png)
		file.close()
		var loaded : Image = MMTextureScript.load_png_16(file_name)
		assert_not_null(loaded, "color type %d" % color_type)
		var out_channels : int = 1 if color_type == 0 else 4
		var data : PackedByteArray = loaded.get_data()
		for p in width*height:
			for oc in out_channels:
				var sc : int
				match color_type:
					0, 6: sc = oc
					2: sc = oc if oc < 3 else -1
					4: sc = 0 if oc < 3 else 1
				var expected : int = 0xFFFF if sc < 0 else (raw[p*bpp+2*sc] << 8) | raw[p*bpp+2*sc+1]
				assert_eq(data.decode_u16(2*(p*out_channels+oc)), expected, "color type %d pixel %d channel %d" % [ color_type, p, oc ])

func test_8_bits_png_falls_back_to_godot() -> void:
	var image : Image = Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.5, 0.25, 1.0))
	image.save_png(file_name)
	assert_null(MMTextureScript.load_png_16(file_name))
	var loaded : Image = MMTextureScript.load_image_file(file_name)
	assert_eq(loaded.get_format(), Image.FORMAT_RGBA8)
