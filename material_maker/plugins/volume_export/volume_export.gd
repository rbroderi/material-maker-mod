extends RefCounted


# Exports 3D textures (TEX3D outputs) and 3D signed distance fields (SDF3D
# outputs) as volumes: OpenVDB (.vdb), 3D DDS (.dds) and KTX2 (.ktx2) files.
#
# The output is sampled at the centers of a resolution³ grid that covers
# [-extent/2, extent/2]³ (Material Maker's 3D textures and SDFs are centered
# on the origin), rendering all z slices at once in a 2D atlas.


const VOLUME_TYPES : Array[String] = [ "tex3d", "tex3d_gs", "sdf3d", "sdf3dc" ]
const FORMATS : Array[String] = [ "vdb", "dds", "ktx2" ]
## Texel formats of DDS and KTX2 files: Godot image format, texel size,
## component size (bytes), DXGI format (DDS) and Vulkan format (KTX2)
const TEXEL_FORMATS : Dictionary = {
	rgba16f={ image=Image.FORMAT_RGBAH, size=8, type_size=2, dxgi=10, vulkan=97 },
	rgba32f={ image=Image.FORMAT_RGBAF, size=16, type_size=4, dxgi=2, vulkan=109 },
	rgba8={ image=Image.FORMAT_RGBA8, size=4, type_size=1, dxgi=28, vulkan=37 },
	r16f={ image=Image.FORMAT_RH, size=2, type_size=2, dxgi=54, vulkan=76 },
	r32f={ image=Image.FORMAT_RF, size=4, type_size=4, dxgi=41, vulkan=100 },
}


## A sampled volume: z slices in an atlas of columns x columns tiles
class Volume:
	extends RefCounted
	var resolution : int
	var columns : int
	var extent : float
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
static func render_volume(generator : MMGenBase, output_index : int, resolution : int, extent : float = 1.0) -> Volume:
	if not is_volume_output(generator, output_index):
		return null
	var type : String = generator.get_output_defs()[output_index].type
	resolution = clampi(resolution, 8, 512)
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
	source.defs = "\n".join([
		"vec4 mm_volume_p(vec2 uv) {",
		"\tvec2 cell = floor(uv*%d.0);" % columns,
		"\tvec2 local = fract(uv*%d.0);" % columns,
		"\tfloat z = (cell.y*%d.0+cell.x+0.5)/%d.0;" % [ columns, resolution ],
		"\treturn vec4((vec3(local, z)-vec3(0.5))*%f, 0.0);" % extent,
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
	volume.kind = { tex3d="color", tex3d_gs="density", sdf3d="sdf", sdf3dc="sdf" }[type]
	volume.atlas = (await texture.get_texture()).get_image()
	if volume.atlas.get_format() != Image.FORMAT_RGBAF:
		volume.atlas.convert(Image.FORMAT_RGBAF)
	return volume

## Renders and saves a volume, the format being chosen by the file extension
static func export_volume(generator : MMGenBase, output_index : int, file_name : String, resolution : int, extent : float = 1.0, texel_format : String = "") -> String:
	var volume : Volume = await render_volume(generator, output_index, resolution, extent)
	if volume == null:
		return "the output is not a 3D texture or SDF, or could not be rendered"
	var error : Error
	match file_name.get_extension().to_lower():
		"vdb":
			error = write_vdb(file_name, volume)
		"dds":
			error = write_dds(file_name, volume, texel_format if texel_format != "" else default_texel_format(volume))
		"ktx2":
			error = write_ktx2(file_name, volume, texel_format if texel_format != "" else default_texel_format(volume))
		_:
			return "unknown volume format '%s' (use .vdb, .dds or .ktx2)" % file_name.get_extension()
	return "" if error == OK else "cannot write '%s' (%s)" % [ file_name, error_string(error) ]

static func default_texel_format(volume : Volume) -> String:
	return "rgba16f" if volume.kind == "color" else "r16f"

#
# DDS and KTX2
#

## Texel data of all slices (x fastest, then y, then z) in a texel format
static func get_texel_data(volume : Volume, texel_format : String) -> PackedByteArray:
	var image_format : int = TEXEL_FORMATS[texel_format].image
	var data : PackedByteArray = PackedByteArray()
	for z in volume.resolution:
		var slice : Image = volume.get_slice(z)
		slice.convert(image_format)
		data.append_array(slice.get_data())
	return data

static func texel_size(texel_format : String) -> int:
	return TEXEL_FORMATS[texel_format].size

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

static func write_ktx2(file_name : String, volume : Volume, texel_format : String) -> Error:
	var size : int = volume.resolution
	var channel_count : int = 4 if texel_format.begins_with("rgba") else 1
	var is_float : bool = texel_format.ends_with("f")
	var bits : int = 8*TEXEL_FORMATS[texel_format].type_size
	# Data format descriptor: a basic block with one sample per channel
	var dfd : StreamPeerBuffer = StreamPeerBuffer.new()
	var block_size : int = 24+16*channel_count
	dfd.put_u32(4+block_size)
	dfd.put_u32(0)
	dfd.put_u32(2 | (block_size << 16))
	# Color model RGBSDA, BT709 primaries, linear transfer, straight alpha
	dfd.put_u32(1 | (1 << 8) | (1 << 16))
	dfd.put_u32(0)
	dfd.put_u32(texel_size(texel_format))
	dfd.put_u32(0)
	for c in channel_count:
		var channel_id : int = [ 0, 1, 2, 15 ][c]
		var channel_type : int = channel_id | (0xC0 if is_float else 0)
		dfd.put_u32((c*bits) | ((bits-1) << 16) | (channel_type << 24))
		dfd.put_u32(0)
		if is_float:
			dfd.put_u32(0xBF800000)
			dfd.put_u32(0x3F800000)
		else:
			dfd.put_u32(0)
			dfd.put_u32((1 << bits)-1)
	# Key/value data
	var kvd : StreamPeerBuffer = StreamPeerBuffer.new()
	var entry : PackedByteArray = "KTXwriter".to_utf8_buffer()
	entry.append(0)
	entry.append_array("Material Maker".to_utf8_buffer())
	entry.append(0)
	kvd.put_u32(entry.size())
	kvd.put_data(entry)
	while kvd.get_size()%4 != 0:
		kvd.put_u8(0)
	var data : PackedByteArray = get_texel_data(volume, texel_format)
	var dfd_offset : int = 80+24
	var kvd_offset : int = dfd_offset+dfd.get_size()
	var data_offset : int = kvd_offset+kvd.get_size()
	var padding : int = (16-data_offset%16)%16
	data_offset += padding
	var header : StreamPeerBuffer = StreamPeerBuffer.new()
	header.put_data(PackedByteArray([ 0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A ]))
	header.put_u32(TEXEL_FORMATS[texel_format].vulkan)
	header.put_u32(TEXEL_FORMATS[texel_format].type_size)
	header.put_u32(size)
	header.put_u32(size)
	header.put_u32(size)
	# Layers, faces, levels, supercompression
	header.put_u32(0)
	header.put_u32(1)
	header.put_u32(1)
	header.put_u32(0)
	header.put_u32(dfd_offset)
	header.put_u32(dfd.get_size())
	header.put_u32(kvd_offset)
	header.put_u32(kvd.get_size())
	header.put_u64(0)
	header.put_u64(0)
	# Level 0
	header.put_u64(data_offset)
	header.put_u64(data.size())
	header.put_u64(data.size())
	var file : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(header.data_array)
	file.store_buffer(dfd.data_array)
	file.store_buffer(kvd.data_array)
	var zeros : PackedByteArray = PackedByteArray()
	zeros.resize(padding)
	file.store_buffer(zeros)
	file.store_buffer(data)
	return OK

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

## Transform: voxel centers at ((i+0.5)/n-0.5)*extent
static func write_vdb_transform(file : StreamPeerBuffer, volume : Volume) -> void:
	var voxel_size : float = volume.voxel_size()
	put_string(file, "UniformScaleTranslateMap")
	var translation : float = 0.5*voxel_size-0.5*volume.extent
	for v in [ translation, voxel_size, voxel_size, 1.0/voxel_size, 1.0/(voxel_size*voxel_size), 0.5/voxel_size ]:
		for c in 3:
			file.put_double(v)

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
