extends GutTest

# Tests of the per mesh bake of a voxel material (design/zcity_plan.md, WP12):
# a unit cube with one UV island per face, baked with albedo = Position.

const VoxelMeshBake = preload("res://material_maker/plugins/voxel_mesh_bake/voxel_mesh_bake.gd")
const TEST_DIR : String = "user://voxel_mesh_bake_test"
const SIZE : int = 64

var graph : MMGenGraph

func before_each() -> void:
	mm_loader.get_predefined_generators_from_dir("res://material_maker/plugins/voxel/nodes")
	DirAccess.make_dir_recursive_absolute(TEST_DIR)

func after_each() -> void:
	if graph != null:
		graph.free()
		graph = null

func gpu_available() -> bool:
	return RenderingServer.get_rendering_device() != null

# Voxel Inputs Position -> Voxel Material albedo (linear)
func make_graph() -> void:
	graph = await mm_loader.create_gen({
		nodes=[
			{ name="In", type="voxel_inputs" },
			{ name="Material", type="material_voxel", parameters={ linear_albedo=true } },
		],
		connections=[
			{ from="In", from_port=0, to="Material", to_port=0 },
		]
	})
	add_child(graph)

# The faces of the unit cube [0, 1]^3: normal, and the corners
const FACES : Array[Dictionary] = [
	{ n=Vector3(1, 0, 0), a=Vector3(1, 0, 0), u=Vector3(0, 1, 0), v=Vector3(0, 0, 1) },
	{ n=Vector3(-1, 0, 0), a=Vector3(0, 0, 0), u=Vector3(0, 1, 0), v=Vector3(0, 0, 1) },
	{ n=Vector3(0, 1, 0), a=Vector3(0, 1, 0), u=Vector3(1, 0, 0), v=Vector3(0, 0, 1) },
	{ n=Vector3(0, -1, 0), a=Vector3(0, 0, 0), u=Vector3(1, 0, 0), v=Vector3(0, 0, 1) },
	{ n=Vector3(0, 0, 1), a=Vector3(0, 0, 1), u=Vector3(1, 0, 0), v=Vector3(0, 1, 0) },
	{ n=Vector3(0, 0, -1), a=Vector3(0, 0, 0), u=Vector3(1, 0, 0), v=Vector3(0, 1, 0) },
]

# Face f has the UV rectangle of cell (f%3, f/3) of a 3x2 layout, with margins
func face_rect(f : int) -> Rect2:
	var cell : Vector2 = Vector2(f%3, f/3)
	return Rect2((cell+Vector2(0.1, 0.1))*Vector2(1.0/3.0, 0.5), Vector2(0.8, 0.8)*Vector2(1.0/3.0, 0.5))

func make_cube() -> ArrayMesh:
	var vertices : PackedVector3Array = PackedVector3Array()
	var normals : PackedVector3Array = PackedVector3Array()
	var uvs : PackedVector2Array = PackedVector2Array()
	var indices : PackedInt32Array = PackedInt32Array()
	for f in FACES.size():
		var face : Dictionary = FACES[f]
		var rect : Rect2 = face_rect(f)
		var base : int = vertices.size()
		for c in [ Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1) ]:
			vertices.append(face.a+face.u*c.x+face.v*c.y)
			normals.append(face.n)
			uvs.append(rect.position+rect.size*c)
		indices.append_array([ base, base+1, base+2, base, base+2, base+3 ])
	var arrays : Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh : ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

# The same cube as a Wavefront OBJ (V axis up in files)
func make_cube_obj() -> String:
	var text : String = ""
	for f in FACES.size():
		var face : Dictionary = FACES[f]
		var rect : Rect2 = face_rect(f)
		for c in [ Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1) ]:
			var p : Vector3 = face.a+face.u*c.x+face.v*c.y
			var uv : Vector2 = rect.position+rect.size*c
			text += "v %f %f %f\nvt %f %f\n" % [ p.x, p.y, p.z, uv.x, 1.0-uv.y ]
		text += "vn %f %f %f\n" % [ face.n.x, face.n.y, face.n.z ]
		var b : int = 4*f+1
		text += "f %d/%d/%d %d/%d/%d %d/%d/%d\nf %d/%d/%d %d/%d/%d %d/%d/%d\n" % [
			b, b, f+1, b+1, b+1, f+1, b+2, b+2, f+1,
			b, b, f+1, b+2, b+2, f+1, b+3, b+3, f+1 ]
	return text

func read_image(path : String) -> Image:
	var image : Image = Image.load_from_file(path)
	assert_not_null(image, "cannot read "+path)
	return image

# Checks the pixels inside the islands: the base color is the position on the
# surface of the cube, and the normal map is the normal of the face
func check_cube_maps(prefix : String) -> void:
	var basecolor : Image = read_image(prefix+"_basecolor.png")
	var normal : Image = read_image(prefix+"_normal_object.png")
	assert_eq(basecolor.get_size(), Vector2i(SIZE, SIZE))
	var checked : int = 0
	var worst_position : float = 0.0
	var worst_normal : float = 0.0
	var margin : int = 4
	for f in FACES.size():
		var rect : Rect2 = face_rect(f)
		var min_px : Vector2i = Vector2i(ceil(rect.position.x*SIZE)+margin, ceil(rect.position.y*SIZE)+margin)
		var max_px : Vector2i = Vector2i(floor(rect.end.x*SIZE)-margin, floor(rect.end.y*SIZE)-margin)
		for y in range(min_px.y, max_px.y):
			for x in range(min_px.x, max_px.x):
				var c : Color = basecolor.get_pixel(x, y)
				if c.a < 0.5:
					fail_test("island interior texel %d,%d of face %d is transparent" % [ x, y, f ])
					return
				# The position (sRGB decoded) is on the face
				var p : Vector3 = Vector3(c.srgb_to_linear().r, c.srgb_to_linear().g, c.srgb_to_linear().b)
				var axis : int = FACES[f].n.abs().max_axis_index()
				var on_face : float = 1.0 if FACES[f].n[axis] > 0.0 else 0.0
				worst_position = maxf(worst_position, absf(p[axis]-on_face))
				var n : Color = normal.get_pixel(x, y)
				var nv : Vector3 = Vector3(n.r, n.g, n.b)*2.0-Vector3.ONE
				var diff : Vector3 = (nv-FACES[f].n).abs()
				worst_normal = maxf(worst_normal, maxf(diff.x, maxf(diff.y, diff.z)))
				checked += 1
	assert_gt(checked, 500)
	# (colors are 8 bit sRGB: 2/255 in sRGB is less than 2/255 in linear values
	# near 1, more near 0; the check is made on the linear values with the
	# tolerance of the 8 bit encoding at 0.5 sRGB)
	assert_lt(worst_position, 0.02, "position on the face")
	assert_lt(worst_normal, 2.0/255.0+0.003, "face normal")

func check_uv_positions(prefix : String) -> void:
	# The center of each island is the center of its face (whatever the
	# orientation of the V axis, the center is the same)
	var basecolor : Image = read_image(prefix+"_basecolor.png")
	for f in FACES.size():
		var rect : Rect2 = face_rect(f)
		var center : Vector2 = rect.get_center()*SIZE
		var c : Color = basecolor.get_pixel(int(center.x), int(center.y)).srgb_to_linear()
		var expected : Vector3 = FACES[f].a+0.5*(FACES[f].u+FACES[f].v)
		var worst : float = maxf(absf(c.r-expected.x), maxf(absf(c.g-expected.y), absf(c.b-expected.z)))
		assert_lt(worst, 0.03, "center of face %d" % f)

func test_bake_cube() -> void:
	if not gpu_available():
		pending("needs a GPU")
		return
	await make_graph()
	var prefix : String = ProjectSettings.globalize_path(TEST_DIR).path_join("cube")
	var result : Dictionary = await VoxelMeshBake.bake(graph, make_cube(), SIZE, prefix)
	assert_false(result.has("error"), str(result.get("error", "")))
	if result.has("error"):
		return
	assert_eq(result.files.size(), 5)
	for suffix in [ "basecolor", "orm", "normal_object", "emission", "opacity" ]:
		assert_true(FileAccess.file_exists("%s_%s.png" % [ prefix, suffix ]), suffix)
	check_cube_maps(prefix)
	check_uv_positions(prefix)
	# opacity is 1 in the islands
	var opacity : Image = read_image(prefix+"_opacity.png")
	var rect : Rect2 = face_rect(0)
	assert_eq(opacity.get_pixel(int(rect.get_center().x*SIZE), int(rect.get_center().y*SIZE)).r8, 255)

# Texels outside the islands are transparent, the islands are extended by 4 texels
func test_island_mask() -> void:
	var arrays : Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([ Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0) ])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([ Vector2(0.25, 0.25), Vector2(0.5, 0.25), Vector2(0.25, 0.5) ])
	var mesh : ArrayMesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mask : PackedByteArray = VoxelMeshBake.island_mask(mesh, 64, 0)
	assert_eq(mask[18*64+18], 255, "inside")
	assert_eq(mask[30*64+30], 0, "beyond the hypotenuse")
	assert_eq(mask[18*64+14], 0, "left of the triangle")
	mask = VoxelMeshBake.island_mask(mesh, 64, 4)
	assert_eq(mask[18*64+14], 255, "dilated")
	assert_eq(mask[18*64+10], 0, "far")
	assert_eq(mask[63*64+63], 0, "corner")

func test_bake_scale_and_exr() -> void:
	if not gpu_available():
		pending("needs a GPU")
		return
	await make_graph()
	var prefix : String = ProjectSettings.globalize_path(TEST_DIR).path_join("cube_scaled")
	var result : Dictionary = await VoxelMeshBake.bake(graph, make_cube(), SIZE, prefix, 2.0, "exr")
	assert_false(result.has("error"), str(result.get("error", "")))
	if result.has("error"):
		return
	assert_almost_eq(result.position_scale, Vector3(2, 2, 2), Vector3(1e-4, 1e-4, 1e-4))
	var basecolor : Image = read_image(prefix+"_basecolor.exr")
	var rect : Rect2 = face_rect(0)
	var c : Color = basecolor.get_pixel(int(rect.get_center().x*SIZE), int(rect.get_center().y*SIZE))
	# face 0 is x = 1 (2 m with a unit scale of 2): the linear value is exact
	assert_almost_eq(c.r, 2.0, 0.01)
	assert_almost_eq(c.g, 1.0, 0.1)
	assert_almost_eq(c.b, 1.0, 0.1)

func test_deterministic_and_obj() -> void:
	if not gpu_available():
		pending("needs a GPU")
		return
	await make_graph()
	# The mesh is loaded from a file, as the command line does
	var obj_path : String = ProjectSettings.globalize_path(TEST_DIR).path_join("cube.obj")
	var file : FileAccess = FileAccess.open(obj_path, FileAccess.WRITE)
	file.store_string(make_cube_obj())
	file.close()
	var graph_path : String = ProjectSettings.globalize_path(TEST_DIR).path_join("voxel_position.ptex")
	file = FileAccess.open(graph_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(graph.serialize(), "\t"))
	file.close()
	var mesh : Mesh = MMMeshLoader.load_mesh(obj_path)
	assert_not_null(mesh)
	var hashes : Array = []
	for i in 2:
		var prefix : String = ProjectSettings.globalize_path(TEST_DIR).path_join("obj_%d" % i)
		var result : Dictionary = await VoxelMeshBake.bake(graph, mesh, SIZE, prefix)
		assert_false(result.has("error"), str(result.get("error", "")))
		if result.has("error"):
			return
		var h : Array = []
		for f in result.files:
			h.append(FileAccess.get_sha256(f))
		hashes.append(h)
		if i == 0:
			check_cube_maps(prefix)
	assert_eq(hashes[0], hashes[1])

func test_errors() -> void:
	graph = MMGenGraph.new()
	add_child(graph)
	var result : Dictionary = await VoxelMeshBake.bake(graph, make_cube(), SIZE, "user://nothing")
	assert_true(result.has("error"))
	result = await VoxelMeshBake.bake(graph, make_cube(), SIZE, "user://nothing", 1.0, "tga")
	assert_true(result.has("error"))
