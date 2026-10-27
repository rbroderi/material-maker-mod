extends RefCounted


# TX files: tiled TIFF files with a mip level per directory, as written by
# OpenImageIO's maketx and read by renderers that cache textures (Arnold,
# RenderMan's OpenImageIO path, Cycles, ...). Tiles are 64x64 and compressed
# with Deflate (zlib), 8 bits, half float or float components.


const TILE_SIZE : int = 64

# TIFF tags
const NEW_SUBFILE_TYPE : int = 254
const IMAGE_WIDTH : int = 256
const IMAGE_LENGTH : int = 257
const BITS_PER_SAMPLE : int = 258
const COMPRESSION : int = 259
const PHOTOMETRIC : int = 262
const SAMPLES_PER_PIXEL : int = 277
const PLANAR_CONFIGURATION : int = 284
const SOFTWARE : int = 305
const TILE_WIDTH : int = 322
const TILE_LENGTH : int = 323
const TILE_OFFSETS : int = 324
const TILE_BYTE_COUNTS : int = 325
const EXTRA_SAMPLES : int = 338
const SAMPLE_FORMAT : int = 339
# Pixar's tags, that OpenImageIO reads as textureformat and wrapmodes
const TEXTURE_FORMAT : int = 33302
const WRAP_MODES : int = 33303

# TIFF types
const TYPE_ASCII : int = 2
const TYPE_SHORT : int = 3
const TYPE_LONG : int = 4

const COMPRESSION_NONE : int = 1
const COMPRESSION_DEFLATE : int = 8


## Godot image formats by channel count (1, 3 or 4) and component size
const IMAGE_FORMATS : Dictionary = {
	1: { 8: Image.FORMAT_R8, 16: Image.FORMAT_RH, 32: Image.FORMAT_RF },
	3: { 8: Image.FORMAT_RGB8, 16: Image.FORMAT_RGBH, 32: Image.FORMAT_RGBF },
	4: { 8: Image.FORMAT_RGBA8, 16: Image.FORMAT_RGBAH, 32: Image.FORMAT_RGBAF },
}

## Saves an image as a TX file. Options: grayscale (one channel) and alpha
## (RGBA, else RGB; by default, the image's channels), bits (8, 16 or 32, by
## default those of the image), normal_map (renormalized mipmaps), compress
## (default true) and wrap (OpenImageIO's wrap mode, default periodic since
## Material Maker's textures tile)
static func save_image(image : Image, file_name : String, options : Dictionary = {}) -> Error:
	var channels : int = MMTexture.image_channels(image.get_format())
	if channels == 2:
		channels = 3
	if options.get("grayscale", false):
		channels = 1
	elif options.has("alpha"):
		channels = 4 if options.alpha else 3
	var bits : int = int(options.get("bits", MMTexture.image_bits(image.get_format())))
	if not bits in [ 8, 16, 32 ]:
		bits = 8
	var format : int = IMAGE_FORMATS[channels][bits]
	var converted : Image = image.duplicate()
	if converted.has_mipmaps():
		converted.clear_mipmaps()
	converted.convert(format)
	converted.generate_mipmaps(options.get("normal_map", false))
	var compress : bool = options.get("compress", true)
	var wrap : String = options.get("wrap", "periodic")
	var file : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	# Header (little endian), the first directory's offset is written later
	file.store_buffer("II".to_ascii_buffer())
	file.store_16(42)
	file.store_32(0)
	var next_offset_position : int = 4
	var data : PackedByteArray = converted.get_data()
	var level_count : int = converted.get_mipmap_count()+1
	for level in level_count:
		var level_size : Vector2i = Vector2i(maxi(converted.get_width() >> level, 1), maxi(converted.get_height() >> level, 1))
		var end : int = converted.get_mipmap_offset(level+1) if level+1 < level_count else data.size()
		var level_image : Image = Image.create_from_data(level_size.x, level_size.y, false, format, data.slice(converted.get_mipmap_offset(level), end))
		# Tiles (edge tiles are padded with zeros)
		var tile_offsets : PackedInt32Array = PackedInt32Array()
		var tile_byte_counts : PackedInt32Array = PackedInt32Array()
		var tile : Image = Image.create_empty(TILE_SIZE, TILE_SIZE, false, format)
		for ty in ceili(float(level_size.y)/TILE_SIZE):
			for tx in ceili(float(level_size.x)/TILE_SIZE):
				tile.fill(Color(0, 0, 0, 0))
				tile.blit_rect(level_image, Rect2i(tx*TILE_SIZE, ty*TILE_SIZE, TILE_SIZE, TILE_SIZE), Vector2i())
				var tile_data : PackedByteArray = tile.get_data()
				if compress:
					tile_data = tile_data.compress(FileAccess.COMPRESSION_DEFLATE)
				tile_offsets.append(file.get_position())
				tile_byte_counts.append(tile_data.size())
				file.store_buffer(tile_data)
		var tags : Array = [
			[ NEW_SUBFILE_TYPE, TYPE_LONG, [ 1 if level > 0 else 0 ] ],
			[ IMAGE_WIDTH, TYPE_LONG, [ level_size.x ] ],
			[ IMAGE_LENGTH, TYPE_LONG, [ level_size.y ] ],
			[ BITS_PER_SAMPLE, TYPE_SHORT, range(channels).map(func(_c): return bits) ],
			[ COMPRESSION, TYPE_SHORT, [ COMPRESSION_DEFLATE if compress else COMPRESSION_NONE ] ],
			[ PHOTOMETRIC, TYPE_SHORT, [ 1 if channels == 1 else 2 ] ],
			[ SAMPLES_PER_PIXEL, TYPE_SHORT, [ channels ] ],
			[ PLANAR_CONFIGURATION, TYPE_SHORT, [ 1 ] ],
			[ SOFTWARE, TYPE_ASCII, "Material Maker" ],
			[ TILE_WIDTH, TYPE_LONG, [ TILE_SIZE ] ],
			[ TILE_LENGTH, TYPE_LONG, [ TILE_SIZE ] ],
			[ TILE_OFFSETS, TYPE_LONG, Array(tile_offsets) ],
			[ TILE_BYTE_COUNTS, TYPE_LONG, Array(tile_byte_counts) ],
		]
		if channels == 4:
			# Unassociated (straight) alpha
			tags.append([ EXTRA_SAMPLES, TYPE_SHORT, [ 2 ] ])
		tags.append([ SAMPLE_FORMAT, TYPE_SHORT, range(channels).map(func(_c): return 3 if bits > 8 else 1) ])
		tags.append([ TEXTURE_FORMAT, TYPE_ASCII, "Plain Texture" ])
		tags.append([ WRAP_MODES, TYPE_ASCII, "%s,%s" % [ wrap, wrap ] ])
		# Directories start on a word boundary
		if file.get_position()%2 != 0:
			file.store_8(0)
		var directory_offset : int = file.get_position()
		file.seek(next_offset_position)
		file.store_32(directory_offset)
		file.seek(directory_offset)
		next_offset_position = write_directory(file, tags)
	return OK

## Writes a directory (tags sorted by number) and the values that do not fit
## in its entries after it. Returns the position of its next directory offset.
static func write_directory(file : FileAccess, tags : Array) -> int:
	var directory_offset : int = file.get_position()
	var directory_size : int = 2+12*tags.size()+4
	var extra : StreamPeerBuffer = StreamPeerBuffer.new()
	var entries : StreamPeerBuffer = StreamPeerBuffer.new()
	entries.put_u16(tags.size())
	for t in tags:
		var values : PackedByteArray = PackedByteArray()
		var count : int
		match t[1]:
			TYPE_ASCII:
				values = t[2].to_ascii_buffer()
				values.append(0)
				count = values.size()
			TYPE_SHORT:
				for v in t[2]:
					values.append_array(PackedByteArray([ v & 0xFF, (v >> 8) & 0xFF ]))
				count = t[2].size()
			TYPE_LONG:
				var longs : StreamPeerBuffer = StreamPeerBuffer.new()
				for v in t[2]:
					longs.put_u32(v)
				values = longs.data_array
				count = t[2].size()
		entries.put_u16(t[0])
		entries.put_u16(t[1])
		entries.put_u32(count)
		if values.size() <= 4:
			values.resize(4)
			entries.put_data(values)
		else:
			entries.put_u32(directory_offset+directory_size+extra.get_size())
			extra.put_data(values)
			if extra.get_size()%2 != 0:
				extra.put_u8(0)
	# No next directory (yet)
	entries.put_u32(0)
	file.store_buffer(entries.data_array)
	file.store_buffer(extra.data_array)
	return directory_offset+directory_size-4
