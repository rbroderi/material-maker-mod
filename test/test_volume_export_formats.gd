extends GutTest

## Tests for the unorm texel formats, the raw and slices formats and the origin
## of the volumes exported by the volume_export plugin. The volume is hand built:
## 4 slices in an 8x8 atlas, r = x/4, g = y/4, b = z/4.

const VolumeExport = preload("res://material_maker/plugins/volume_export/volume_export.gd")

const N : int = 4

func make_volume() -> VolumeExport.Volume:
	var volume : VolumeExport.Volume = VolumeExport.Volume.new()
	volume.resolution = N
	volume.columns = 2
	volume.extent = 2.0
	volume.kind = "color"
	volume.atlas = Image.create(8, 8, false, Image.FORMAT_RGBAF)
	for z in N:
		for y in N:
			for x in N:
				volume.atlas.set_pixel((z%2)*N+x, (z/2)*N+y, Color(x/4.0, y/4.0, z/4.0, 1.0))
	return volume

func test_r8() -> void:
	var data : PackedByteArray = VolumeExport.get_texel_data(make_volume(), "r8")
	assert_eq(data.size(), N*N*N)
	# 0, 0.25, 0.5 and 0.75 rounded to 8 bits
	assert_eq(Array(data.slice(0, 4)), [ 0, 64, 128, 191 ])
	# y varies after x
	assert_eq(Array(data.slice(4, 8)), [ 0, 64, 128, 191 ])

func test_rg8() -> void:
	var data : PackedByteArray = VolumeExport.get_texel_data(make_volume(), "rg8")
	assert_eq(data.size(), N*N*N*2)
	# x = 2, y = 3, z = 0: r = 0.5, g = 0.75
	var offset : int = ((0*N+3)*N+2)*2
	assert_eq(data[offset], 128)
	assert_eq(data[offset+1], 191)

func test_r16() -> void:
	var data : PackedByteArray = VolumeExport.get_texel_data(make_volume(), "r16")
	assert_eq(data.size(), N*N*N*2)
	# x = 3: 0.75*65535 = 49151.25
	assert_eq(data.decode_u16(3*2), 49151)
	# little endian
	assert_eq(data[6], 49151 & 255)
	assert_eq(data[7], 49151 >> 8)

func test_rg16() -> void:
	var data : PackedByteArray = VolumeExport.get_texel_data(make_volume(), "rg16")
	assert_eq(data.size(), N*N*N*4)
	# x = 1, y = 2, z = 0
	var offset : int = ((0*N+2)*N+1)*4
	assert_eq(data.decode_u16(offset), 16384)
	assert_eq(data.decode_u16(offset+2), 32768)
	# x = 1, y = 0, z = 3: g = 0 and the first slice of the second row of the atlas
	offset = ((3*N+0)*N+1)*4
	assert_eq(data.decode_u16(offset), 16384)
	assert_eq(data.decode_u16(offset+2), 0)

func test_values_are_clamped() -> void:
	var volume : VolumeExport.Volume = make_volume()
	volume.atlas.set_pixel(0, 0, Color(-3.0, 7.0, 0.0, 1.0))
	var data : PackedByteArray = VolumeExport.get_texel_data(volume, "rg8")
	assert_eq(data[0], 0)
	assert_eq(data[1], 255)

func test_dds_header() -> void:
	for f in [ "r8", "rg8", "r16", "rg16" ]:
		var path : String = "user://test_volume_export_formats_%s.dds" % f
		assert_eq(VolumeExport.write_dds(path, make_volume(), f), OK)
		var bytes : PackedByteArray = FileAccess.get_file_as_bytes(path)
		assert_eq(bytes.slice(0, 4).get_string_from_ascii(), "DDS ")
		# height, width and depth
		assert_eq(bytes.decode_u32(12), N)
		assert_eq(bytes.decode_u32(16), N)
		assert_eq(bytes.decode_u32(24), N)
		# DX10 header: DXGI format, TEXTURE3D
		assert_eq(bytes.decode_u32(128), { r8=61, rg8=49, r16=56, rg16=35 }[f], f)
		assert_eq(bytes.decode_u32(132), 4)
		assert_eq(bytes.size(), 148+N*N*N*VolumeExport.texel_size(f), f)
		DirAccess.remove_absolute(path)

func test_raw() -> void:
	var path : String = "user://test_volume_export_formats.raw"
	assert_eq(VolumeExport.write_raw(path, make_volume(), "rg16"), OK)
	assert_eq(FileAccess.get_file_as_bytes(path).size(), N*N*N*4)
	var description = JSON.parse_string(FileAccess.get_file_as_string(path+".json"))
	assert_eq(int(description["resolution"]), N)
	assert_eq(description["texel_format"], "rg16")
	assert_eq(int(description["channels"]), 2)
	assert_eq(description["extent"], 2.0)
	assert_eq(description["origin"], "center")
	assert_eq(description["order"], "xyz")
	assert_eq(description.size(), 6)
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path+".json")

func test_raw_is_deterministic() -> void:
	var path : String = "user://test_volume_export_formats_a.raw"
	VolumeExport.write_raw(path, make_volume(), "rgba16f")
	var first : PackedByteArray = FileAccess.get_file_as_bytes(path)
	var first_json : String = FileAccess.get_file_as_string(path+".json")
	VolumeExport.write_raw(path, make_volume(), "rgba16f")
	assert_eq(FileAccess.get_file_as_bytes(path), first)
	assert_eq(FileAccess.get_file_as_string(path+".json"), first_json)
	assert_eq(first.size(), N*N*N*8)
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path+".json")

func test_slices() -> void:
	var base : String = "user://test_volume_export_formats_slices"
	assert_eq(VolumeExport.write_slices(base, make_volume(), "r8"), OK)
	var image : Image = Image.load_from_file("%s_z0003.png" % base)
	assert_not_null(image)
	assert_eq(image.get_width(), N)
	# x = 2: 0.5
	assert_eq(int(round(image.get_pixel(2, 1).r*255.0)), 128)
	for z in N:
		DirAccess.remove_absolute("%s_z%04d.png" % [ base, z ])
	assert_eq(VolumeExport.write_slices(base, make_volume(), "rg16"), OK)
	assert_true(FileAccess.file_exists("%s_z0000.exr" % base))
	for z in N:
		DirAccess.remove_absolute("%s_z%04d.exr" % [ base, z ])

func test_rgba8_rounds() -> void:
	var data : PackedByteArray = VolumeExport.get_texel_data(make_volume(), "rgba8")
	assert_eq(data.size(), N*N*N*4)
	# x = 2, y = 3, z = 1: 0.5, 0.75 and 0.25 are 127.5, 191.25 and 63.75 in 8 bits
	var offset : int = ((1*N+3)*N+2)*4
	assert_eq(Array(data.slice(offset, offset+4)), [ 128, 191, 64, 255 ])
	# The slices are rounded as well
	var base : String = "user://test_volume_export_formats_rgba8"
	assert_eq(VolumeExport.write_slices(base, make_volume(), "rgba8"), OK)
	var image : Image = Image.load_from_file("%s_z0001.png" % base)
	assert_not_null(image)
	var c : Color = image.get_pixel(2, 3)
	assert_eq([ int(roundf(c.r*255.0)), int(roundf(c.g*255.0)), int(roundf(c.b*255.0)) ], [ 128, 191, 64 ])
	for z in N:
		DirAccess.remove_absolute("%s_z%04d.png" % [ base, z ])

func test_vdb_transform_follows_origin() -> void:
	var volume : VolumeExport.Volume = make_volume()
	# Voxel size 0.5, extent 2: voxel i is centered at translation+i*0.5
	var expected : Dictionary = { center=0.25-1.0, corner=0.25 }
	for origin in expected.keys():
		volume.origin = origin
		var values : Array = VolumeExport.vdb_transform_values(volume)
		assert_almost_eq(values[0], expected[origin], 1e-9, origin)
		assert_almost_eq(values[1], 0.5, 1e-9)
		assert_almost_eq(values[3], 2.0, 1e-9)
		var file : StreamPeerBuffer = StreamPeerBuffer.new()
		VolumeExport.write_vdb_transform(file, volume)
		var bytes : PackedByteArray = file.data_array
		var name_size : int = bytes.decode_u32(0)
		assert_eq(bytes.slice(4, 4+name_size).get_string_from_ascii(), "UniformScaleTranslateMap")
		assert_eq(bytes.size(), 4+name_size+18*8)
		for c in 3:
			assert_almost_eq(bytes.decode_double(4+name_size+c*8), expected[origin], 1e-9, origin)

## A graph with one output whose value is sin of the phase (an expression of the position)
func make_field(phase : String) -> MMGenGraph:
	var graph : MMGenGraph = await mm_loader.create_gen({ nodes=[ {
		name="f", type="shader", parameters={},
		shader_model={ name="Field", parameters=[], inputs=[], instance="", code="", global="",
			outputs=[ { type="tex3d_gs", tex3d_gs="0.5+0.5*sin(%s)" % phase } ] } } ], connections=[] })
	add_child(graph)
	return graph

func test_check_tileable_checks_each_axis() -> void:
	if RenderingServer.get_rendering_device() == null:
		pending("no rendering device (headless)")
		return
	var path : String = "user://test_volume_export_formats_tileable.raw"
	# Periodic along each axis with the period 1
	var tileable : MMGenGraph = await make_field("6.2831853*($uv.x+$uv.y+$uv.z)")
	var error : String = await VolumeExport.export_volume(tileable.get_node("f"), 0, path, 8, 1.0, "r8", "center", true)
	assert_eq(error, "")
	tileable.free()
	# Periodic along the diagonal (period 3 along each axis, so shifting by (1, 1, 1) is
	# a whole number of periods) but not along x
	var diagonal : MMGenGraph = await make_field("6.2831853*($uv.x+$uv.y+$uv.z)/3.0")
	error = await VolumeExport.export_volume(diagonal.get_node("f"), 0, path, 8, 1.0, "r8", "center", true)
	assert_string_contains(error, "not tileable along x")
	diagonal.free()
	# Only periodic along x and z
	var no_y : MMGenGraph = await make_field("6.2831853*($uv.x+$uv.z)+$uv.y*2.0")
	error = await VolumeExport.export_volume(no_y.get_node("f"), 0, path, 8, 1.0, "r8", "center", true)
	assert_string_contains(error, "not tileable along y")
	no_y.free()
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path+".json")

func test_unknown_formats_are_errors() -> void:
	var generator : MMGenBase = MMGenBase.new()
	var error : String = await VolumeExport.export_volume(generator, 0, "user://x.raw", 8, 1.0, "r12")
	assert_string_contains(error, "unknown texel format")
	error = await VolumeExport.export_volume(generator, 0, "user://x.raw", 8, 1.0, "r8", "middle")
	assert_string_contains(error, "unknown volume origin")
	generator.free()
