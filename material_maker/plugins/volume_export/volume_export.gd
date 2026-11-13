extends RefCounted


# Exports 3D textures (TEX3D outputs) and 3D signed distance fields (SDF3D
# outputs) as volumes: OpenVDB (.vdb), 3D DDS (.dds) and KTX2 (.ktx2) files.
#
# The output is sampled at the centers of a resolution³ grid that covers
# [-extent/2, extent/2]³ (Material Maker's 3D textures and SDFs are centered
# on the origin), rendering all z slices at once in a 2D atlas.


const VOLUME_TYPES : Array[String] = [ "tex3d", "tex3d_gs", "sdf3d", "sdf3dc" ]
const FORMATS : Array[String] = [ "vdb", "dds", "ktx2", "raw", "slices" ]
## Texel formats of DDS, KTX2, raw and slices files: Godot image format (-1
## for the unorm formats, quantised by get_texel_data), texel size, channels
## and DXGI format (DDS; KTX2 files are written by the ktx2_format plugin)
const TEXEL_FORMATS : Dictionary = {
	rgba16f={ image=Image.FORMAT_RGBAH, size=8, channels=4, dxgi=10 },
	rgba32f={ image=Image.FORMAT_RGBAF, size=16, channels=4, dxgi=2 },
	rgba8={ image=Image.FORMAT_RGBA8, size=4, channels=4, dxgi=28 },
	r16f={ image=Image.FORMAT_RH, size=2, channels=1, dxgi=54 },
	r32f={ image=Image.FORMAT_RF, size=4, channels=1, dxgi=41 },
	r8={ image=-1, size=1, channels=1, bits=8, dxgi=61 },
	rg8={ image=-1, size=2, channels=2, bits=8, dxgi=49 },
	r16={ image=-1, size=2, channels=1, bits=16, dxgi=56 },
	rg16={ image=-1, size=4, channels=2, bits=16, dxgi=35 },
}
const MIN_RESOLUTION : int = 8
## All slices are rendered at once, in a 32 bits float atlas (4096x4096 for
## 256³ voxels; 512³ voxels would need 2.2 GB)
const MAX_RESOLUTION : int = 256
const ORIGINS : Array[String] = [ "center", "corner" ]


## A sampled volume: z slices in an atlas of columns x columns tiles
class Volume:
	extends RefCounted
	var resolution : int
	var columns : int
	var extent : float
	## "center" ([-extent/2, extent/2]³) or "corner" ([0, extent]³)
	var origin : String = "center"
	## "color" (TEX3D), "density" (grayscale TEX3D) or "sdf"
	var kind : String
	## RGBA 32 bits floats
	var atlas : Image

	func get_slice(z : int) -> Image:
		return atlas.get_region(Rect2i((z%columns)*resolution, (z/columns)*resolution, resolution, resolution))

	func voxel_size() -> float:
		return extent/resolution

	## The values of a channel (0 to 3), x varying fastest, then y, then z
	func get_channel(channel : int) -> PackedFloat32Array:
		var rv : PackedFloat32Array = PackedFloat32Array()
		rv.resize(resolution*resolution*resolution)
		var i : int = 0
		for z in resolution:
			var data : PackedFloat32Array = get_slice(z).get_data().to_float32_array()
			for p in range(channel, data.size(), 4):
				rv[i] = data[p]
				i += 1
		return rv


static func is_volume_output(generator : MMGenBase, output_index : int) -> bool:
	var outputs : Array = generator.get_output_defs()
	return output_index < outputs.size() and outputs[output_index].get("type", "") in VOLUME_TYPES

## Samples a 3D output of a generator
## ("origin" is "center" or "corner", offset moves the sampled box)
static func render_volume(generator : MMGenBase, output_index : int, resolution : int, extent : float = 1.0, origin : String = "center", offset : Vector3 = Vector3.ZERO) -> Volume:
	if not is_volume_output(generator, output_index):
		return null
	var type : String = generator.get_output_defs()[output_index].type
	resolution = clampi(resolution, MIN_RESOLUTION, MAX_RESOLUTION)
	var columns : int = int(ceil(sqrt(float(resolution))))
	# Buffers used by the output must be rendered first
	generator.get_shader_code("vec4(0.0)" if type.begins_with("tex3d") else "vec3(0.0)", output_index, MMGenContext.new())
	await MMCliTools.wait_for_renders(generator.get_tree())
	var p : String = "mm_volume_p(uv)" if type.begins_with("tex3d") else "mm_volume_p(uv).xyz"
	var source : MMGenBase.ShaderCode = generator.get_shader_code(p, output_index, MMGenContext.new())
	if not source.output_values.has(type):
		return null
	var value : String = source.output_values[type]
	match type:
		"tex3d":
			value = "vec4(%s, 1.0)" % value
		"tex3d_gs", "sdf3d":
			value = "vec4(vec3(%s), 1.0)" % value
		"sdf3dc":
			value = "vec4((%s).xyy, 1.0)" % value
	# Position of the voxel of each pixel of the atlas
	var shift : float = 0.0 if origin == "corner" else 0.5
	source.defs = "\n".join([
		"vec4 mm_volume_p(vec2 uv) {",
		"\tvec2 cell = floor(uv*%d.0);" % columns,
		"\tvec2 local = fract(uv*%d.0);" % columns,
		"\tfloat z = (cell.y*%d.0+cell.x+0.5)/%d.0;" % [ columns, resolution ],
		"\treturn vec4((vec3(local, z)-vec3(%.1f))*%.9f+vec3(%.9f, %.9f, %.9f), 0.0);" % [ shift, extent, offset.x, offset.y, offset.z ],
		"}", "" ])+source.defs
	source.output_values = { rgba=value }
	source.output_type = "rgba"
	var compute : MMComputeShader = MMComputeShader.new()
	if not await compute.set_shader_from_shadercode(source, true):
		return null
	var texture : MMTexture = MMTexture.new()
	if not await compute.render_ext([ texture ], Vector2i(columns*resolution, columns*resolution)):
		return null
	var volume : Volume = Volume.new()
	volume.resolution = resolution
	volume.columns = columns
	volume.extent = extent
	volume.origin = "corner" if origin == "corner" else "center"
	volume.kind = { tex3d="color", tex3d_gs="density", sdf3d="sdf", sdf3dc="sdf" }[type]
	volume.atlas = (await texture.get_texture()).get_image()
	if volume.atlas.get_format() != Image.FORMAT_RGBAF:
		volume.atlas.convert(Image.FORMAT_RGBAF)
	return volume

## Checks the options of an export: returns an error message, or ""
static func check_options(extension : String, resolution : int, extent : float, texel_format : String, origin : String = "center") -> String:
	if not extension in FORMATS:
		return "unknown volume format '%s' (use %s)" % [ extension, ", ".join(FORMATS) ]
	if not origin in ORIGINS:
		return "unknown volume origin '%s' (use %s)" % [ origin, ", ".join(ORIGINS) ]
	if resolution < MIN_RESOLUTION or resolution > MAX_RESOLUTION:
		return "incorrect resolution %d (voxels in each direction, from %d to %d)" % [ resolution, MIN_RESOLUTION, MAX_RESOLUTION ]
	if not extent > 0.0 or is_inf(extent):
		return "incorrect extent %s (the size of the sampled box must be positive)" % str(extent)
	if texel_format != "" and not TEXEL_FORMATS.has(texel_format):
		return "unknown texel format '%s' (use %s)" % [ texel_format, ", ".join(TEXEL_FORMATS.keys()) ]
	return ""

## Renders and saves a volume, the format being chosen by the file extension
## The "raw" format writes <name>.raw and <name>.raw.json, and "slices" (file
## extension .slices) writes <name>_z0000.png (8 bits formats) or .exr files.
## With check_tileable, fails if the volume is not periodic with the period
## extent (it is compared to the volume sampled one extent further).
static func export_volume(generator : MMGenBase, output_index : int, file_name : String, resolution : int, extent : float = 1.0, texel_format : String = "", origin : String = "center", check_tileable : bool = false) -> String:
	var extension : String = file_name.get_extension().to_lower()
	var option_error : String = check_options(extension, resolution, extent, texel_format, origin)
	if option_error != "":
		return option_error
	var volume : Volume = await render_volume(generator, output_index, resolution, extent, origin)
	if volume == null:
		return "the output is not a 3D texture or SDF, or could not be rendered"
	if check_tileable:
		for axis in 3:
			var shift : Vector3 = Vector3()
			shift[axis] = extent
			var shifted : Volume = await render_volume(generator, output_index, resolution, extent, origin, shift)
			if shifted == null:
				return "the output could not be rendered to check that it is tileable"
			var difference : float = max_difference(volume, shifted)
			if difference > 1.0/255.0:
				return "the volume is not tileable along %s (maximum difference %f with the volume offset by the extent, more than 1/255)" % [ "xyz"[axis], difference ]
	if texel_format == "":
		texel_format = default_texel_format(volume)
	var error : Error
	match extension:
		"vdb":
			error = write_vdb(file_name, volume)
		"dds":
			error = write_dds(file_name, volume, texel_format)
		"ktx2":
			if not MMPlugins.load_plugin_file("ktx2_format", "ktx2.gd").FORMATS.has(texel_format):
				return "KTX2 files do not support the texel format %s" % texel_format
			error = write_ktx2(file_name, volume, texel_format)
		"raw":
			error = write_raw(file_name, volume, texel_format)
		"slices":
			error = write_slices(file_name.get_basename(), volume, texel_format)
	return "" if error == OK else "cannot write '%s' (%s)" % [ file_name, error_string(error) ]

## The maximum absolute difference between the samples of two volumes
static func max_difference(a : Volume, b : Volume) -> float:
	var da : PackedFloat32Array = a.atlas.get_data().to_float32_array()
	var db : PackedFloat32Array = b.atlas.get_data().to_float32_array()
	if da.size() != db.size():
		return INF
	var rv : float = 0.0
	for i in da.size():
		rv = max(rv, abs(da[i]-db[i]))
	return rv

static func default_texel_format(volume : Volume) -> String:
	return "rgba16f" if volume.kind == "color" else "r16f"

#
# DDS and KTX2
#

## Texel data of all slices (x fastest, then y, then z) in a texel format
static func get_texel_data(volume : Volume, texel_format : String) -> PackedByteArray:
	var image_format : int = TEXEL_FORMATS[texel_format].image
	if image_format < 0:
		return quantize_texels(volume, TEXEL_FORMATS[texel_format])
	if image_format == Image.FORMAT_RGBA8:
		# Image.convert may truncate: round like the other unorm formats
		return quantize_texels(volume, { channels=4, bits=8 })
	var data : PackedByteArray = PackedByteArray()
	for z in volume.resolution:
		var slice : Image = volume.get_slice(z)
		slice.convert(image_format)
		data.append_array(slice.get_data())
	return data

static func texel_size(texel_format : String) -> int:
	return TEXEL_FORMATS[texel_format].size

## Unorm texels (8 or 16 bits, little endian, channels interleaved): each
## value is clamped to [0, 1] and rounded
static func quantize_texels(volume : Volume, format : Dictionary) -> PackedByteArray:
	var channels : int = format.channels
	var bytes : int = format.bits/8
	var maximum : float = 255.0 if bytes == 1 else 65535.0
	var values : Array = []
	for c in channels:
		values.append(volume.get_channel(c))
	var count : int = values[0].size()
	var data : PackedByteArray = PackedByteArray()
	data.resize(count*channels*bytes)
	var offset : int = 0
	for i in count:
		for c in channels:
			var v : int = int(roundf(clampf(values[c][i], 0.0, 1.0)*maximum))
			if bytes == 1:
				data.encode_u8(offset, v)
			else:
				data.encode_u16(offset, v)
			offset += bytes
	return data

## <name>.raw (the texels of get_texel_data) and <name>.raw.json (what the
## raw file contains)
static func write_raw(file_name : String, volume : Volume, texel_format : String) -> Error:
	var f : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(get_texel_data(volume, texel_format))
	f.close()
	var description : Dictionary = {
		resolution=volume.resolution,
		texel_format=texel_format,
		channels=TEXEL_FORMATS[texel_format].channels,
		extent=volume.extent,
		origin=volume.origin,
		order="xyz",
	}
	f = FileAccess.open(file_name+".json", FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(description, "\t", true))
	return OK

## One file per z slice, <path>_z0000.png for 8 bits formats (one channel
## images are grayscale, two channels images have a null blue channel) and
## <path>_z0000.exr for the others (16 bits unorm formats are saved as 32 bits
## floats, two channels ones with a null blue channel and an alpha of 1)
static func write_slices(path : String, volume : Volume, texel_format : String) -> Error:
	var format : Dictionary = TEXEL_FORMATS[texel_format]
	var n : int = volume.resolution
	var is_png : bool = format.image == Image.FORMAT_RGBA8 or format.get("bits", 0) == 8
	var all_texels : PackedByteArray
	if format.image < 0 or format.image == Image.FORMAT_RGBA8:
		all_texels = get_texel_data(volume, texel_format)
	var slice_bytes : int = n*n*format.size
	for z in n:
		var slice : Image
		if format.image == Image.FORMAT_RGBA8:
			slice = Image.create_from_data(n, n, false, Image.FORMAT_RGBA8, all_texels.slice(z*slice_bytes, (z+1)*slice_bytes))
		elif format.image >= 0:
			slice = volume.get_slice(z)
			slice.convert(format.image)
		else:
			var texels : PackedByteArray = all_texels.slice(z*slice_bytes, (z+1)*slice_bytes)
			slice = unorm_slice_image(texels, n, format)
		var slice_name : String = "%s_z%04d.%s" % [ path, z, "png" if is_png else "exr" ]
		var error : Error = slice.save_png(slice_name) if is_png else slice.save_exr(slice_name)
		if error != OK:
			return error
	return OK

static func unorm_slice_image(texels : PackedByteArray, n : int, format : Dictionary) -> Image:
	var channels : int = format.channels
	if format.bits == 8:
		if channels == 1:
			return Image.create_from_data(n, n, false, Image.FORMAT_L8, texels)
		var rgb : PackedByteArray = PackedByteArray()
		rgb.resize(n*n*3)
		for i in n*n:
			rgb[i*3] = texels[i*2]
			rgb[i*3+1] = texels[i*2+1]
		return Image.create_from_data(n, n, false, Image.FORMAT_RGB8, rgb)
	var image : Image = Image.create(n, n, false, Image.FORMAT_RF if channels == 1 else Image.FORMAT_RGBAF)
	for i in n*n:
		var r : float = texels.decode_u16(i*channels*2)/65535.0
		var g : float = texels.decode_u16(i*channels*2+2)/65535.0 if channels == 2 else 0.0
		image.set_pixel(i%n, i/n, Color(r, g, 0.0, 1.0))
	return image

static func write_dds(file_name : String, volume : Volume, texel_format : String) -> Error:
	var size : int = volume.resolution
	var header : StreamPeerBuffer = StreamPeerBuffer.new()
	header.put_data("DDS ".to_ascii_buffer())
	header.put_u32(124)
	# CAPS, HEIGHT, WIDTH, PITCH, PIXELFORMAT and DEPTH
	header.put_u32(0x1 | 0x2 | 0x4 | 0x8 | 0x1000 | 0x800000)
	header.put_u32(size)
	header.put_u32(size)
	header.put_u32(size*texel_size(texel_format))
	header.put_u32(size)
	header.put_u32(0)
	for i in 11:
		header.put_u32(0)
	# Pixel format: a DX10 header follows
	header.put_u32(32)
	header.put_u32(0x4)
	header.put_data("DX10".to_ascii_buffer())
	for i in 5:
		header.put_u32(0)
	# Caps: COMPLEX and TEXTURE, caps2: VOLUME
	header.put_u32(0x8 | 0x1000)
	header.put_u32(0x200000)
	header.put_u32(0)
	header.put_u32(0)
	header.put_u32(0)
	# DX10 header: format, TEXTURE3D dimension, flags, array size, flags 2
	header.put_u32(TEXEL_FORMATS[texel_format].dxgi)
	header.put_u32(4)
	header.put_u32(0)
	header.put_u32(1)
	header.put_u32(0)
	var file : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(header.data_array)
	file.store_buffer(get_texel_data(volume, texel_format))
	return OK

## Writes a 3D KTX2 file with the KTX2 writer of the ktx2_format plugin
## (a dependency of this plugin)
static func write_ktx2(file_name : String, volume : Volume, texel_format : String) -> Error:
	var ktx2 = MMPlugins.load_plugin_file("ktx2_format", "ktx2.gd")
	if ktx2 == null:
		return ERR_UNAVAILABLE
	var size : int = volume.resolution
	var levels : Array[PackedByteArray] = [ get_texel_data(volume, texel_format) ]
	return ktx2.write(file_name, levels, Vector3i(size, size, size), texel_format)

#
# OpenVDB
#
# Grids are written uncompressed, in the OpenVDB file format version 224, as
# a tree with the standard 5-4-3 configuration: a root node with one 32³
# internal node (4096 voxels wide), 16³ internal nodes (128 voxels wide)
# and 8³ leaf nodes. Leaves that only contain inactive voxels are not
# written: fog volumes keep their non zero voxels, and SDFs are written as
# narrow band level sets.

const VDB_FILE_VERSION : int = 224
const VDB_HALF_WIDTH : float = 3.0

static func write_vdb(file_name : String, volume : Volume) -> Error:
	var grids : Array = []
	match volume.kind:
		"sdf":
			grids.append({ "name": "surface", "class": "level set", "values": [ volume.get_channel(0) ] })
		"density":
			grids.append({ "name": "density", "class": "fog volume", "values": [ volume.get_channel(0) ] })
		"color":
			var r : PackedFloat32Array = volume.get_channel(0)
			var g : PackedFloat32Array = volume.get_channel(1)
			var b : PackedFloat32Array = volume.get_channel(2)
			var density : PackedFloat32Array = PackedFloat32Array()
			density.resize(r.size())
			for i in r.size():
				density[i] = (r[i]+g[i]+b[i])/3.0
			grids.append({ "name": "density", "class": "fog volume", "values": [ density ] })
			grids.append({ "name": "color", "class": "unknown", "values": [ r, g, b ], "active": density })
	var file : StreamPeerBuffer = StreamPeerBuffer.new()
	# Header: magic, versions, grid offsets, UUID, no metadata, grid count
	file.put_64(0x56444220)
	file.put_u32(VDB_FILE_VERSION)
	file.put_u32(10)
	file.put_u32(0)
	file.put_u8(1)
	file.put_data(random_uuid().to_ascii_buffer())
	file.put_u32(0)
	file.put_32(grids.size())
	for g in grids:
		write_vdb_grid(file, volume, g)
	var f : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(file.data_array)
	return OK

static func random_uuid() -> String:
	var hex : String = ""
	for i in 32:
		hex += "0123456789abcdef"[randi()%16]
	return "%s-%s-%s-%s-%s" % [ hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4), hex.substr(16, 4), hex.substr(20, 12) ]

static func put_string(file : StreamPeerBuffer, s : String) -> void:
	var data : PackedByteArray = s.to_utf8_buffer()
	file.put_u32(data.size())
	file.put_data(data)

static func write_vdb_grid(file : StreamPeerBuffer, volume : Volume, grid : Dictionary) -> void:
	var is_level_set : bool = grid["class"] == "level set"
	var background : float = VDB_HALF_WIDTH*volume.voxel_size() if is_level_set else 0.0
	var offsets_position : int = write_vdb_grid_descriptor(file, grid)
	var grid_position : int = file.get_position()
	# No compression
	file.put_u32(0)
	write_vdb_metadata(file, grid)
	write_vdb_transform(file, volume)
	var tree : Dictionary = collect_vdb_leaves(volume, grid, is_level_set, background)
	write_vdb_topology(file, volume, grid, tree, is_level_set, background)
	var block_position : int = file.get_position()
	# Buffers, in the same order
	for k in tree.keys:
		for leaf in tree.internal_nodes[k]:
			file.put_data(leaf.mask)
			file.put_8(6)
			file.put_data(leaf.values)
	var end_position : int = file.get_position()
	file.seek(offsets_position)
	file.put_64(grid_position)
	file.put_64(block_position)
	file.put_64(end_position)
	file.seek(end_position)

## The grid descriptor: name, type, instance parent, then room for the
## offsets (written once known), whose position is returned
static func write_vdb_grid_descriptor(file : StreamPeerBuffer, grid : Dictionary) -> int:
	put_string(file, grid.name)
	put_string(file, "Tree_float_5_4_3" if grid["values"].size() == 1 else "Tree_vec3s_5_4_3")
	put_string(file, "")
	var offsets_position : int = file.get_position()
	file.put_64(0)
	file.put_64(0)
	file.put_64(0)
	return offsets_position

## Metadata: the grid's class and name (OpenVDB reads the name from it)
static func write_vdb_metadata(file : StreamPeerBuffer, grid : Dictionary) -> void:
	file.put_u32(2)
	put_string(file, "class")
	put_string(file, "string")
	put_string(file, grid["class"])
	put_string(file, "name")
	put_string(file, "string")
	put_string(file, grid.name)

## Transform: voxel centers at ((i+0.5)/n-0.5)*extent for the "center" origin
## and at (i+0.5)/n*extent for the "corner" one
static func write_vdb_transform(file : StreamPeerBuffer, volume : Volume) -> void:
	put_string(file, "UniformScaleTranslateMap")
	for v in vdb_transform_values(volume):
		for c in 3:
			file.put_double(v)

## The 6 values (each written for x, y and z) of the map: translation, scale,
## voxel size, inverse scale, inverse scale squared and half inverse scale
static func vdb_transform_values(volume : Volume) -> Array[float]:
	var voxel_size : float = volume.voxel_size()
	var translation : float = 0.5*voxel_size-(0.0 if volume.origin == "corner" else 0.5*volume.extent)
	return [ translation, voxel_size, voxel_size, 1.0/voxel_size, 1.0/(voxel_size*voxel_size), 0.5/voxel_size ]

## The leaves with active voxels (inside the narrow band for level sets),
## grouped by 128³ internal node, in the order of the node's slots (x, then y,
## then z): { keys (the internal nodes), internal_nodes (key -> leaves) }
static func collect_vdb_leaves(volume : Volume, grid : Dictionary, is_level_set : bool, background : float) -> Dictionary:
	var n : int = volume.resolution
	var activity : PackedFloat32Array = grid.get("active", grid["values"][0])
	var leaf_count : int = (n+7)/8
	var leaves : Array = []
	for lx in leaf_count:
		for ly in leaf_count:
			for lz in leaf_count:
				var leaf : Dictionary = make_leaf(Vector3i(lx*8, ly*8, lz*8), n, grid["values"], activity, is_level_set, background)
				if not leaf.is_empty():
					leaves.append(leaf)
	var internal_nodes : Dictionary = {}
	for leaf in leaves:
		var o : Vector3i = leaf.origin
		var key : Vector3i = Vector3i(o.x >> 7, o.y >> 7, o.z >> 7)
		if not internal_nodes.has(key):
			internal_nodes[key] = []
		internal_nodes[key].append(leaf)
	var keys : Array = internal_nodes.keys()
	keys.sort_custom(func(a, b): return (a.x*32+a.y)*32+a.z < (b.x*32+b.y)*32+b.z)
	for k in keys:
		internal_nodes[k].sort_custom(func(a, b): return leaf_slot(a.origin) < leaf_slot(b.origin))
	return { keys=keys, internal_nodes=internal_nodes }

## Topology: the root, its 32³ internal node, the 16³ internal nodes and the
## leaf masks
static func write_vdb_topology(file : StreamPeerBuffer, volume : Volume, grid : Dictionary, tree : Dictionary, is_level_set : bool, background : float) -> void:
	var n : int = volume.resolution
	var components : int = grid["values"].size()
	var keys : Array = tree.keys
	file.put_32(1)
	put_value(file, background, components)
	file.put_u32(0)
	file.put_u32(1 if not keys.is_empty() else 0)
	if keys.is_empty():
		return
	file.put_32(0)
	file.put_32(0)
	file.put_32(0)
	# 32³ internal node
	var mask : PackedByteArray = PackedByteArray()
	mask.resize(32768/8)
	for k in keys:
		set_bit(mask, (k.x*32+k.y)*32+k.z)
	file.put_data(mask)
	file.put_data(empty_mask(32768))
	file.put_8(6)
	file.put_data(tile_values(32768, components, func(i : int) -> float:
		return tile_value(i, 32, 128, n, grid["values"][0], is_level_set, background)))
	for k in keys:
		# 16³ internal node
		var child_mask : PackedByteArray = empty_mask(4096)
		for leaf in tree.internal_nodes[k]:
			set_bit(child_mask, leaf_slot(leaf.origin))
		file.put_data(child_mask)
		file.put_data(empty_mask(4096))
		file.put_8(6)
		var base : Vector3i = k*128
		file.put_data(tile_values(4096, components, func(i : int) -> float:
			return tile_value(i, 16, 8, n, grid["values"][0], is_level_set, background, base)))
		for leaf in tree.internal_nodes[k]:
			file.put_data(leaf.mask)

static func leaf_slot(origin : Vector3i) -> int:
	return (((origin.x & 127) >> 3)*16+((origin.y & 127) >> 3))*16+((origin.z & 127) >> 3)

static func empty_mask(bits : int) -> PackedByteArray:
	var mask : PackedByteArray = PackedByteArray()
	mask.resize(bits/8)
	return mask

static func set_bit(mask : PackedByteArray, bit : int) -> void:
	mask[bit >> 3] |= 1 << (bit & 7)

static func put_value(file : StreamPeerBuffer, value : float, components : int) -> void:
	for c in components:
		file.put_float(value)

## Values of the tiles of an internal node: for level sets, the background
## with the sign of the distance at the tile's center
static func tile_values(count : int, components : int, value : Callable) -> PackedByteArray:
	var values : PackedFloat32Array = PackedFloat32Array()
	values.resize(count*components)
	for i in count:
		var v : float = value.call(i)
		for c in components:
			values[i*components+c] = v
	return values.to_byte_array()

static func tile_value(i : int, dim : int, tile_size : int, n : int, distances : PackedFloat32Array, is_level_set : bool, background : float, base : Vector3i = Vector3i()) -> float:
	if not is_level_set:
		return 0.0
	var p : Vector3i = base+Vector3i(i/(dim*dim), (i/dim)%dim, i%dim)*tile_size+Vector3i(tile_size/2, tile_size/2, tile_size/2)
	if p.x >= n or p.y >= n or p.z >= n:
		return background
	return -background if distances[(p.z*n+p.y)*n+p.x] < 0.0 else background

## A leaf (8³ voxels at origin), or an empty dictionary if it has no active
## voxels
static func make_leaf(origin : Vector3i, n : int, values : Array, activity : PackedFloat32Array, is_level_set : bool, background : float) -> Dictionary:
	var components : int = values.size()
	var mask : PackedByteArray = empty_mask(512)
	var data : PackedFloat32Array = PackedFloat32Array()
	data.resize(512*components)
	var active : bool = false
	for x in 8:
		for y in 8:
			for z in 8:
				var offset : int = (x << 6) | (y << 3) | z
				var p : Vector3i = origin+Vector3i(x, y, z)
				if p.x >= n or p.y >= n or p.z >= n:
					for c in components:
						data[offset*components+c] = background
					continue
				var index : int = (p.z*n+p.y)*n+p.x
				var a : float = activity[index]
				var voxel_active : bool = abs(a) < background if is_level_set else abs(a) > 0.000001
				if voxel_active:
					set_bit(mask, offset)
					active = true
				for c in components:
					var v : float = values[c][index]
					if is_level_set:
						v = clampf(v, -background, background)
					data[offset*components+c] = v
	if not active:
		return {}
	return { origin=origin, mask=mask, values=data.to_byte_array() }
