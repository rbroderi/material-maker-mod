extends GutTest

# Tests of the point evaluation (design/zcity_plan.md, WP8): .npy files, parameters,
# and (with a GPU) the evaluation of voxel materials and noises at given points.

const Noise3d = preload("res://test/test_noise3d.gd")

var graph : MMGenGraph

func before_each() -> void:
	mm_loader.get_predefined_generators_from_dir("res://material_maker/plugins/voxel/nodes")

func after_each() -> void:
	if graph != null:
		graph.free()
		graph = null

func gpu_available() -> bool:
	return RenderingServer.get_rendering_device() != null

# Voxel Inputs In -> Voxel Material (albedo = Normal, roughness = Fresh, linear albedo)
# and a value noise seeded by In (scale 4)
func make_graph() -> void:
	graph = await mm_loader.create_gen({
		nodes=[
			{ name="In", type="voxel_inputs" },
			{ name="Material", type="material_voxel", parameters={ linear_albedo=true } },
			{ name="Noise", type="tex3d_noise_value", parameters={ scale_x=4, scale_y=4, scale_z=4 } },
		],
		connections=[
			{ from="In", from_port=1, to="Material", to_port=0 },
			{ from="In", from_port=5, to="Material", to_port=2 },
			{ from="In", from_port=2, to="Noise", to_port=0 },
		]
	})
	add_child(graph)

# Random points (metres), unit normals and fresh values
func make_arrays(count : int) -> Dictionary:
	var rng : RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 1234
	var points : PackedFloat32Array = PackedFloat32Array()
	var normals : PackedFloat32Array = PackedFloat32Array()
	var fresh : PackedFloat32Array = PackedFloat32Array()
	for i in count:
		points.append_array([ rng.randf_range(-3.0, 3.0), rng.randf_range(-3.0, 3.0), rng.randf_range(-3.0, 3.0) ])
		var n : Vector3 = Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		normals.append_array([ n.x, n.y, n.z ])
		fresh.append(rng.randf())
	return { points=points, normals=normals, fresh=fresh }

func max_error(a : PackedFloat32Array, b : PackedFloat32Array) -> float:
	assert_eq(a.size(), b.size())
	var rv : float = 0.0
	for i in mini(a.size(), b.size()):
		rv = maxf(rv, absf(a[i]-b[i]))
	return rv

# ---- .npy files (headless)

func test_npy_round_trip() -> void:
	var path : String = "user://test_voxel_eval_roundtrip.npy"
	var data : PackedFloat32Array = PackedFloat32Array()
	for i in 12:
		data.append(i*0.25-1.0)
	assert_eq(MMNpy.save(path, [ 4, 3 ], data), OK)
	var loaded : Dictionary = MMNpy.load(path)
	assert_false(loaded.has("error"))
	assert_eq(loaded.shape, [ 4, 3 ])
	assert_eq(loaded.data, data)
	assert_eq(MMNpy.save(path, [ 12 ], data), OK)
	loaded = MMNpy.load(path)
	assert_eq(loaded.shape, [ 12 ])
	assert_eq(loaded.data, data)
	# The header is padded to a multiple of 64 bytes, ends with a newline
	var bytes : PackedByteArray = FileAccess.get_file_as_bytes(path)
	assert_eq(bytes.slice(0, 8), PackedByteArray([ 0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 1, 0 ]))
	assert_eq((10+bytes.decode_u16(8)) % 64, 0)
	assert_eq(bytes[10+bytes.decode_u16(8)-1], 10)
	assert_eq(MMNpy.save(path, [ 5 ], data), ERR_INVALID_PARAMETER)

func npy_bytes(header : String, count : int, version : Array = [ 1, 0 ]) -> PackedByteArray:
	var rv : PackedByteArray = PackedByteArray([ 0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, version[0], version[1], 0, 0 ])
	rv.encode_u16(8, header.length())
	rv.append_array(header.to_ascii_buffer())
	var data : PackedFloat32Array = PackedFloat32Array()
	data.resize(count)
	rv.append_array(data.to_byte_array())
	return rv

func test_npy_reads_numpy_header() -> void:
	# (a header as written by numpy.save)
	var header : String = "{'descr': '<f4', 'fortran_order': False, 'shape': (2, 3), }"+" ".repeat(10)+"\n"
	var loaded : Dictionary = MMNpy.parse(npy_bytes(header, 6))
	assert_false(loaded.has("error"), str(loaded))
	assert_eq(loaded.shape, [ 2, 3 ])
	assert_eq(loaded.data.size(), 6)

func test_npy_rejects_malformed_files() -> void:
	var good : String = "{'descr': '<f4', 'fortran_order': False, 'shape': (2, 3), }\n"
	assert_false(MMNpy.parse(npy_bytes(good, 6)).has("error"))
	assert_true(MMNpy.parse(PackedByteArray([ 1, 2, 3 ])).has("error"), "too short")
	var bad_magic : PackedByteArray = npy_bytes(good, 6)
	bad_magic[1] = 0
	assert_true(MMNpy.parse(bad_magic).has("error"), "magic")
	assert_true(MMNpy.parse(npy_bytes(good, 6, [ 2, 0 ])).has("error"), "version 2.0")
	assert_true(MMNpy.parse(npy_bytes(good.replace("<f4", "<f8"), 6)).has("error"), "float64")
	assert_true(MMNpy.parse(npy_bytes(good.replace("<f4", ">f4"), 6)).has("error"), "big endian")
	assert_true(MMNpy.parse(npy_bytes(good.replace("False", "True"), 6)).has("error"), "fortran order")
	assert_true(MMNpy.parse(npy_bytes("{'descr': '<f4'}\n", 6)).has("error"), "missing fields")
	assert_true(MMNpy.parse(npy_bytes(good.replace("(2, 3)", "(2, x)"), 6)).has("error"), "bad shape")
	assert_true(MMNpy.parse(npy_bytes(good, 5)).has("error"), "short data")
	assert_true(MMNpy.parse(npy_bytes(good, 7)).has("error"), "long data")
	assert_true(MMNpy.load("user://test_voxel_eval_missing.npy").has("error"), "missing file")

# ---- arrays and parameters (headless)

func test_load_arrays_checks_shapes() -> void:
	var points : String = "user://test_voxel_eval_points.npy"
	var normals : String = "user://test_voxel_eval_normals.npy"
	var fresh : String = "user://test_voxel_eval_fresh.npy"
	var six : PackedFloat32Array = PackedFloat32Array([ 1, 2, 3, 4, 5, 6 ])
	MMNpy.save(points, [ 2, 3 ], six)
	MMNpy.save(normals, [ 2, 3 ], six)
	MMNpy.save(fresh, [ 2 ], PackedFloat32Array([ 0.5, 1.0 ]))
	var arrays : Dictionary = MMVoxelEval.load_arrays(points, normals, fresh)
	assert_false(arrays.has("error"))
	assert_eq(arrays.points, six)
	assert_eq(arrays.fresh, PackedFloat32Array([ 0.5, 1.0 ]))
	MMNpy.save(fresh, [ 2, 1 ], PackedFloat32Array([ 0.5, 1.0 ]))
	assert_false(MMVoxelEval.load_arrays(points, normals, fresh).has("error"))
	MMNpy.save(fresh, [ 3 ], PackedFloat32Array([ 0.5, 1.0, 0.0 ]))
	assert_true(MMVoxelEval.load_arrays(points, normals, fresh).has("error"), "fresh count")
	MMNpy.save(normals, [ 3, 2 ], six)
	assert_true(MMVoxelEval.load_arrays(points, normals).has("error"), "normals shape")
	MMNpy.save(points, [ 3, 2 ], six)
	assert_true(MMVoxelEval.load_arrays(points).has("error"), "points shape")

func test_apply_params() -> void:
	await make_graph()
	var errors : PackedStringArray = MMVoxelEval.apply_params(graph, { "seed": 12345, "age": 0.25, "axis": [ 0, 1, 0 ], "In:vox_wet": 0.5, "vox_char": 0.75, "origin": [ 1, 2, 3 ] })
	assert_eq(errors, PackedStringArray())
	var inputs : MMGenBase = graph.get_node("In")
	assert_eq(inputs.get_parameter("vox_seed"), 12345.0)
	assert_eq(inputs.get_parameter("vox_age"), 0.25)
	assert_eq(inputs.get_parameter("vox_axis_x"), 0.0)
	assert_eq(inputs.get_parameter("vox_axis_y"), 1.0)
	assert_eq(inputs.get_parameter("vox_wet"), 0.5)
	assert_eq(inputs.get_parameter("vox_char"), 0.75)
	assert_eq(inputs.get_parameter("vox_origin_z"), 3.0)
	errors = MMVoxelEval.apply_params(graph, { "axis": [ 1, 2 ], "nonsense": 1.0, "Nope:x": 1.0, "seed": "abc" })
	assert_eq(errors.size(), 4, str(errors))

func test_find_voxel_materials() -> void:
	await make_graph()
	var materials : Array = MMVoxelEval.find_voxel_materials(graph)
	assert_eq(materials.size(), 1)
	assert_eq(materials[0].name, "Material")

func test_rejects_bad_sizes() -> void:
	await make_graph()
	var points : PackedFloat32Array = PackedFloat32Array([ 0, 0, 0, 1, 1, 1 ])
	var rgba : PackedFloat32Array = await MMVoxelEval.evaluate(graph.get_node("Noise"), 0, points, PackedFloat32Array([ 0, 0, 1 ]))
	assert_true(rgba.is_empty())
	assert_ne(MMVoxelEval.last_error, "")
	rgba = await MMVoxelEval.evaluate(graph.get_node("Noise"), 0, points, PackedFloat32Array(), PackedFloat32Array([ 0 ]))
	assert_true(rgba.is_empty())
	rgba = await MMVoxelEval.evaluate(graph.get_node("Noise"), 7, points)
	assert_true(rgba.is_empty())

# ---- GPU

func test_evaluate_material() -> void:
	if not gpu_available():
		pending("needs a rendering device")
		return
	await make_graph()
	# More than 2048 points: several rows of texels
	var count : int = 5000
	var arrays : Dictionary = make_arrays(count)
	var results : Dictionary = await MMVoxelEval.evaluate_material(graph.get_node("Material"), arrays.points, arrays.normals, arrays.fresh)
	assert_false(results.is_empty(), MMVoxelEval.last_error)
	assert_eq(results.base_color.size(), count*3)
	assert_eq(results.orm.size(), count*3)
	assert_eq(results.emission.size(), count*3)
	assert_eq(results.normal.size(), count*3)
	assert_eq(results.opacity.size(), count)
	# albedo = the normal of each point
	assert_lt(max_error(results.base_color, arrays.normals), 1e-6)
	# roughness (orm.g) = the fresh value of each point
	var roughness : PackedFloat32Array = PackedFloat32Array()
	for i in count:
		roughness.append(results.orm[i*3+1])
	assert_lt(max_error(roughness, arrays.fresh), 1e-6)
	# No bump, no emission, opaque
	assert_lt(max_error(results.normal, arrays.normals), 1e-5)
	assert_eq(results.emission[0], 0.0)
	assert_eq(results.opacity[count-1], 1.0)
	# Without normals and fresh values, the normal falls back to the direction of the point and fresh is 0
	results = await MMVoxelEval.evaluate_material(graph.get_node("Material"), arrays.points)
	assert_eq(results.orm[1], 0.0)
	var p : Vector3 = Vector3(arrays.points[0], arrays.points[1], arrays.points[2]).normalized()
	assert_almost_eq(results.base_color[0], p.x, 1e-5)
	assert_almost_eq(results.base_color[2], p.z, 1e-5)

func test_evaluate_noise() -> void:
	if not gpu_available():
		pending("needs a rendering device")
		return
	await make_graph()
	var count : int = 3000
	var arrays : Dictionary = make_arrays(count)
	for seed_value in [ 0, 12345 ]:
		assert_eq(MMVoxelEval.apply_params(graph, { seed=seed_value }), PackedStringArray())
		var rgba : PackedFloat32Array = await MMVoxelEval.evaluate(graph.get_node("Noise"), 0, arrays.points)
		assert_eq(rgba.size(), count*4)
		var worst : float = 0.0
		for i in count:
			var p : Vector3 = Vector3(arrays.points[i*3], arrays.points[i*3+1], arrays.points[i*3+2])*4.0
			var expected : float = Noise3d.value_noise(p, seed_value)
			worst = maxf(worst, absf(rgba[i*4]-expected))
			worst = maxf(worst, absf(rgba[i*4+1]-expected))
			assert_eq(rgba[i*4+3], 1.0)
		assert_lt(worst, 1e-5, "seed %d" % seed_value)

func test_evaluate_files() -> void:
	if not gpu_available():
		pending("needs a rendering device")
		return
	await make_graph()
	var count : int = 2500
	var arrays : Dictionary = make_arrays(count)
	MMNpy.save("user://test_voxel_eval_p.npy", [ count, 3 ], arrays.points)
	MMNpy.save("user://test_voxel_eval_n.npy", [ count, 3 ], arrays.normals)
	MMNpy.save("user://test_voxel_eval_f.npy", [ count ], arrays.fresh)
	# One node output: (N, 4)
	var result : Dictionary = await MMVoxelEval.evaluate_files(graph, "user://test_voxel_eval_p.npy", "", "", "In:0", {}, "user://test_voxel_eval_out")
	assert_false(result.has("error"), str(result))
	assert_eq(result.files, [ "user://test_voxel_eval_out.npy" ])
	var loaded : Dictionary = MMNpy.load(result.files[0])
	assert_eq(loaded.shape, [ count, 4 ])
	# (the position output of Voxel Inputs returns the points)
	for i in count:
		assert_almost_eq(loaded.data[i*4], arrays.points[i*3], 1e-6)
		assert_almost_eq(loaded.data[i*4+2], arrays.points[i*3+2], 1e-6)
	# The voxel material
	result = await MMVoxelEval.evaluate_files(graph, "user://test_voxel_eval_p.npy", "user://test_voxel_eval_n.npy", "user://test_voxel_eval_f.npy", "", { age=0.5 }, "user://test_voxel_eval_mat.npy")
	assert_false(result.has("error"), str(result))
	assert_eq(result.files.size(), 5)
	assert_true(result.files[0].ends_with("test_voxel_eval_mat_base_color.npy"))
	loaded = MMNpy.load(result.files[0])
	assert_eq(loaded.shape, [ count, 3 ])
	assert_lt(max_error(loaded.data, arrays.normals), 1e-6)
	assert_eq(MMNpy.load(result.files[4]).shape, [ count ])
	# Errors
	result = await MMVoxelEval.evaluate_files(graph, "user://test_voxel_eval_p.npy", "", "", "Nope", {}, "user://test_voxel_eval_out")
	assert_true(result.has("error"))
	result = await MMVoxelEval.evaluate_files(graph, "user://test_voxel_eval_missing.npy", "", "", "", {}, "user://test_voxel_eval_out")
	assert_true(result.has("error"))
