extends RefCounted


# KTX2 files (Khronos Texture 2.0): 2D textures with mipmaps, and 3D textures
# (the volume_export plugin), uncompressed or with Zstandard supercompression. The data
# format descriptor is a basic block with one sample per channel.


## Texel formats: Godot image format, Vulkan formats (linear and sRGB),
## component size (bytes) and channels
const FORMATS : Dictionary = {
	r8={ image=Image.FORMAT_R8, vulkan=9, vulkan_srgb=15, type_size=1, channels=1 },
	rgba8={ image=Image.FORMAT_RGBA8, vulkan=37, vulkan_srgb=43, type_size=1, channels=4 },
	r16f={ image=Image.FORMAT_RH, vulkan=76, type_size=2, channels=1 },
	rgba16f={ image=Image.FORMAT_RGBAH, vulkan=97, type_size=2, channels=4 },
	r32f={ image=Image.FORMAT_RF, vulkan=100, type_size=4, channels=1 },
	rgba32f={ image=Image.FORMAT_RGBAF, vulkan=109, type_size=4, channels=4 },
}

const IDENTIFIER : PackedByteArray = [ 0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A ]
const SUPERCOMPRESSION_ZSTD : int = 2


static func is_float(texel_format : String) -> bool:
	return texel_format.ends_with("f")

static func texel_size(texel_format : String) -> int:
	return FORMATS[texel_format].type_size*FORMATS[texel_format].channels

## Saves an image as a 2D KTX2 texture. Options: grayscale (one channel, by
## default for one channel images), bits (8, 16 or 32, by default those of
## the image), srgb (8 bits only, by default for RGBA images), mipmaps
## (default true), normal_map (renormalized mipmaps) and supercompression
## (Zstandard, default true).
static func save_image(image : Image, file_name : String, options : Dictionary = {}) -> Error:
	var channels : int = 1 if options.get("grayscale", MMTexture.image_channels(image.get_format()) == 1) else 4
	var bits : int = int(options.get("bits", MMTexture.image_bits(image.get_format())))
	var texel_format : String = ("r" if channels == 1 else "rgba")+{ 8: "8", 16: "16f", 32: "32f" }.get(bits, "8")
	var srgb : bool = options.get("srgb", channels == 4) and bits == 8
	var converted : Image = image.duplicate()
	if converted.has_mipmaps():
		converted.clear_mipmaps()
	converted.convert(FORMATS[texel_format].image)
	if options.get("mipmaps", true):
		converted.generate_mipmaps(options.get("normal_map", false))
	var levels : Array[PackedByteArray] = []
	var data : PackedByteArray = converted.get_data()
	var level_count : int = converted.get_mipmap_count()+1
	for level in level_count:
		var end : int = converted.get_mipmap_offset(level+1) if level+1 < level_count else data.size()
		levels.append(data.slice(converted.get_mipmap_offset(level), end))
	return write(file_name, levels, Vector3i(image.get_width(), image.get_height(), 0), texel_format, srgb, options.get("supercompression", true))

## Writes a KTX2 file: levels are the texel data of each mip level, from the
## largest (rows from the top, then slices for 3D textures whose size.z is
## not 0)
static func write(file_name : String, levels : Array[PackedByteArray], size : Vector3i, texel_format : String, srgb : bool = false, zstd : bool = false) -> Error:
	var format : Dictionary = FORMATS[texel_format]
	var file : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	var dfd : PackedByteArray = data_format_descriptor(texel_format, srgb)
	var kvd : PackedByteArray = key_value_data()
	# Level data is stored from the smallest level, aligned on the texel size
	# and 4 bytes when it is not supercompressed
	var stored : Array[PackedByteArray] = []
	for l in levels:
		stored.append(l.compress(FileAccess.COMPRESSION_ZSTD) if zstd else l)
	var alignment : int = 1 if zstd else lcm(texel_size(texel_format), 4)
	var dfd_offset : int = 80+24*levels.size()
	var offset : int = dfd_offset+dfd.size()+kvd.size()
	var offsets : Array[int] = []
	offsets.resize(levels.size())
	var paddings : Array[int] = []
	paddings.resize(levels.size())
	for level in range(levels.size()-1, -1, -1):
		paddings[level] = (alignment-offset%alignment)%alignment
		offset += paddings[level]
		offsets[level] = offset
		offset += stored[level].size()
	var header : StreamPeerBuffer = StreamPeerBuffer.new()
	header.put_data(IDENTIFIER)
	header.put_u32(format.vulkan_srgb if srgb and format.has("vulkan_srgb") else format.vulkan)
	header.put_u32(format.type_size)
	header.put_u32(size.x)
	header.put_u32(size.y)
	header.put_u32(size.z)
	# Layers, faces, levels, supercompression
	header.put_u32(0)
	header.put_u32(1)
	header.put_u32(levels.size())
	header.put_u32(SUPERCOMPRESSION_ZSTD if zstd else 0)
	header.put_u32(dfd_offset)
	header.put_u32(dfd.size())
	header.put_u32(dfd_offset+dfd.size())
	header.put_u32(kvd.size())
	# No supercompression global data
	header.put_u64(0)
	header.put_u64(0)
	for level in levels.size():
		header.put_u64(offsets[level])
		header.put_u64(stored[level].size())
		header.put_u64(levels[level].size())
	file.store_buffer(header.data_array)
	file.store_buffer(dfd)
	file.store_buffer(kvd)
	for level in range(levels.size()-1, -1, -1):
		var padding : PackedByteArray = PackedByteArray()
		padding.resize(paddings[level])
		file.store_buffer(padding)
		file.store_buffer(stored[level])
	return OK

static func lcm(a : int, b : int) -> int:
	var x : int = a
	var y : int = b
	while y != 0:
		var t : int = y
		y = x%y
		x = t
	return a*b/x

## Data format descriptor: a basic block (RGBSDA color model, BT.709
## primaries, linear or sRGB transfer, straight alpha) with a sample per
## channel
static func data_format_descriptor(texel_format : String, srgb : bool) -> PackedByteArray:
	var format : Dictionary = FORMATS[texel_format]
	var channel_count : int = format.channels
	var bits : int = 8*format.type_size
	var float_format : bool = is_float(texel_format)
	var block_size : int = 24+16*channel_count
	var dfd : StreamPeerBuffer = StreamPeerBuffer.new()
	dfd.put_u32(4+block_size)
	dfd.put_u32(0)
	dfd.put_u32(2 | (block_size << 16))
	dfd.put_u32(1 | (1 << 8) | ((2 if srgb else 1) << 16))
	dfd.put_u32(0)
	dfd.put_u32(texel_size(texel_format))
	dfd.put_u32(0)
	for c in channel_count:
		var channel_id : int = [ 0, 1, 2, 15 ][c]
		var channel_type : int = channel_id | (0xC0 if float_format else 0)
		# Alpha is linear in sRGB formats
		if srgb and channel_id == 15:
			channel_type |= 0x10
		dfd.put_u32((c*bits) | ((bits-1) << 16) | (channel_type << 24))
		dfd.put_u32(0)
		if float_format:
			dfd.put_u32(0xBF800000)
			dfd.put_u32(0x3F800000)
		else:
			dfd.put_u32(0)
			dfd.put_u32((1 << bits)-1)
	return dfd.data_array

static func key_value_data() -> PackedByteArray:
	var kvd : StreamPeerBuffer = StreamPeerBuffer.new()
	var entry : PackedByteArray = "KTXwriter".to_utf8_buffer()
	entry.append(0)
	entry.append_array("Material Maker".to_utf8_buffer())
	entry.append(0)
	kvd.put_u32(entry.size())
	kvd.put_data(entry)
	while kvd.get_size()%4 != 0:
		kvd.put_u8(0)
	return kvd.data_array
