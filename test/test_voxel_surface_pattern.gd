extends GutTest

# Tests of the Voxel Surface Pattern node (design/zcity_plan.md, WP15)

const MMGraphCost = preload("res://material_maker/plugins/graph_cost/graph_cost.gd")
const FORBIDDEN : String = "\\b(mat[234]|uvec[234]|bvec[234]|lessThan|greaterThan|dFdx|dFdy|fwidth|texelFetch|textureSize)\\b"
const VOXEL_DIR : String = "res://material_maker/plugins/voxel/nodes"
const TARGET : String = "Unreal/Unreal Engine 5 Voxel"
const TARGET_DIR : String = "res://material_maker/plugins/voxel/export_targets"
const OUT_DIR : String = "user://voxel_surface_pattern_test"

# Points on the faces of a cube of 1 m (the coordinate that is fixed depends on the face)
const POINTS : Array = [
	Vector3(0.137, 0.291, 0.463), Vector3(0.352, 0.718, 0.126), Vector3(0.811, 0.054, 0.637),
	Vector3(0.466, 0.583, 0.874), Vector3(0.923, 0.347, 0.219), Vector3(0.071, 0.862, 0.508),
	Vector3(0.644, 0.129, 0.771), Vector3(0.289, 0.436, 0.092)
]

var graph : MMGenGraph

func before_all() -> void:
	mm_loader.get_predefined_generators_from_dir(VOXEL_DIR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

func after_each() -> void:
	if graph != null:
		graph.free()
		graph = null

func gdprint(text : String) -> void:
	print(text)

func gpu_available() -> bool:
	return RenderingServer.get_rendering_device() != null

func all_text(source : MMGenBase.ShaderCode) -> String:
	var rv : String = source.defs+source.code+source.get_globals_string()
	for k in source.output_values.keys():
		rv += str(source.output_values[k])
	return rv

# The node N, with its normal input fed by a uniform 3D texture holding the normal n
func build(n : Vector3, params : Dictionary = {}) -> MMGenBase:
	var nodes : Array = [ { name="N", type="voxel_surface_pattern", parameters=params } ]
	var connections : Array = []
	if n != Vector3.ZERO:
		nodes.append({ name="Nrm", type="tex3d_uniform", parameters={ color={ r=n.x, g=n.y, b=n.z, a=1.0, type="Color" } } })
		connections.append({ from="Nrm", from_port=0, to="N", to_port=1 })
	graph = await mm_loader.create_gen({ nodes=nodes, connections=connections })
	add_child(graph)
	return graph.get_node("N")

func list_function(points : PackedVector3Array) -> String:
	var items : PackedStringArray = PackedStringArray()
	for p in points:
		items.append("vec3(%f, %f, %f)" % [ p.x, p.y, p.z ])
	return """const vec3 mm_ptl[%d] = vec3[%d](%s);
vec4 mm_pts(vec2 uv) {
	int idx = int(floor(uv.y*64.0))*64+int(floor(uv.x*64.0));
	if (idx >= %d) {
		idx = %d;
	}
	return vec4(mm_ptl[idx], 0.0);
}
""" % [ points.size(), points.size(), ", ".join(items), points.size(), points.size()-1 ]

# Renders an output of a generator at the points of a point function (64x64 pixels)
func render_with(gen : MMGenBase, output_index : int, point_function : String) -> Image:
	var type : String = gen.get_output_defs()[output_index].type
	var source : MMGenBase.ShaderCode = gen.get_shader_code("mm_pts(uv)", output_index, MMGenContext.new())
	var value : String = source.output_values[type]
	match type:
		"tex3d":
			value = "vec4(%s, 1.0)" % value
		_:
			value = "vec4(vec3(%s), 1.0)" % value
	source.defs = point_function+source.defs
	source.output_values = { rgba=value }
	source.output_type = "rgba"
	var compute : MMComputeShader = MMComputeShader.new()
	if not await compute.set_shader_from_shadercode(source, true):
		return null
	var texture : MMTexture = MMTexture.new()
	if not await compute.render_ext([ texture ], Vector2i(64, 64)):
		return null
	var image : Image = (await texture.get_texture()).get_image()
	if image.get_format() != Image.FORMAT_RGBAF:
		image.convert(Image.FORMAT_RGBAF)
	return image

# The points moved onto a face of the cube: axis is 0, 1 or 2, value 0 or 1
func face_points(axis : int, value : float) -> PackedVector3Array:
	var rv : PackedVector3Array = PackedVector3Array()
	for p in POINTS:
		var q : Vector3 = p
		q[axis] = value
		rv.append(q)
	return rv

# The expected (u, v) before scale, offset and fract, as specified for Up = Z (up_y false) or Y
func expected_uv(p : Vector3, n : Vector3, up_y : bool) -> Vector2:
	var h : float = -p.z if up_y else p.y
	var u : float = p.y if up_y else p.z
	var nh : float = -n.z if up_y else n.y
	var nu : float = n.y if up_y else n.z
	var a : Vector3 = Vector3(absf(n.x), absf(nh), absf(nu))
	if a.z >= a.x and a.z >= a.y:
		return Vector2(p.x if nu >= 0.0 else -p.x, h)
	elif a.x >= a.y:
		return Vector2(h if n.x >= 0.0 else -h, u)
	return Vector2(-p.x if nh >= 0.0 else p.x, u)

func expected_colour(p : Vector3, n : Vector3, up_y : bool, scale : Vector2, offset : Vector2) -> Vector2:
	var uv : Vector2 = expected_uv(p, n, up_y)
	var c : Vector2 = Vector2(uv.x*scale.x+offset.x, uv.y*scale.y+offset.y)
	return Vector2(c.x-floorf(c.x), c.y-floorf(c.y))

# Checks the colour output on a face against the expected plane coordinates; returns the worst difference
func check_face(gen : MMGenBase, points : PackedVector3Array, n : Vector3, up_y : bool, scale : Vector2, offset : Vector2) -> float:
	var image : Image = await render_with(gen, 0, list_function(points))
	assert_not_null(image)
	if image == null:
		return 1.0
	var worst : float = 0.0
	for idx in points.size():
		var c : Color = image.get_pixel(idx % 64, idx/64)
		var e : Vector2 = expected_colour(points[idx], n, up_y, scale, offset)
		worst = maxf(worst, maxf(absf(c.r-e.x), maxf(absf(c.g-e.y), absf(c.b))))
	return worst

# ---- headless

func test_node_instantiates() -> void:
	var gen : MMGenBase = await build(Vector3.ZERO)
	assert_not_null(gen)
	var inputs : Array = []
	for i in gen.get_input_defs():
		inputs.append(i.name)
	assert_eq(inputs, [ "in", "normal_in", "mask_in" ])
	var outputs : Array = []
	for o in gen.get_output_defs():
		outputs.append(o.shortdesc)
	assert_eq(outputs, [ "Colour", "Height" ])
	var params : Array = []
	for p in gen.get_parameter_defs():
		params.append(p.name)
	for expected in [ "scale_u", "scale_v", "up", "mode", "blend_sharpness", "offset_u", "offset_v" ]:
		assert_true(params.has(expected), expected)

func test_generated_code() -> void:
	var regex : RegEx = RegEx.new()
	regex.compile(FORBIDDEN)
	var gen : MMGenBase = await build(Vector3(1, 0, 0))
	for i in gen.get_output_defs().size():
		var source : MMGenBase.ShaderCode = gen.get_shader_code("vec4(0.0)", i, MMGenContext.new())
		var text : String = all_text(source)
		assert_eq(text.find("$"), -1, "output %d has a $ left" % i)
		assert_null(regex.search(text), "output %d has code outside of the HLSL safe subset" % i)
		assert_eq(MMGraphCost.lint_parity(text).size(), 0, "output %d parity: %s" % [ i, str(MMGraphCost.lint_parity(text)) ])

func test_identifiers_avoid_translated_words() -> void:
	var f : FileAccess = FileAccess.open(VOXEL_DIR+"/voxel_surface_pattern.mmg", FileAccess.READ)
	var data : Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var code : String = "\n".join(data.shader_model.instance)
	for m in RegEx.create_from_string("\\b([A-Za-z_]\\w*)\\b").search_all(code):
		var id : String = m.get_string()
		if id in [ "vec2", "vec3", "vec4", "fract" ]:
			continue
		for bad in [ "vec2", "vec3", "vec4", "mat2", "mix", "fract", "atan", "uniform", "sampler2D", "elapsed_time", "texture_" ]:
			assert_eq(id.find(bad), -1, "identifier %s contains %s" % [ id, bad ])

# The node between Voxel Inputs and a Voxel Material, exported with the Unreal voxel target and compiled by dxc
func test_export_and_compile() -> void:
	MMPlugins.load_export_targets(TARGET_DIR)
	graph = await mm_loader.create_gen({
		nodes=[
			{ name="Material", type="material_voxel" },
			{ name="In", type="voxel_inputs" },
			{ name="Pattern", type="voxel_surface_pattern", parameters={ mode=1 } },
			{ name="Grad", type="tex3d_gradient" }
		],
		connections=[
			{ from="In", from_port=1, to="Pattern", to_port=1 },
			{ from="Pattern", from_port=0, to="Material", to_port=0 },
			{ from="Pattern", from_port=1, to="Grad", to_port=0 },
			{ from="Grad", from_port=0, to="Material", to_port=6 }
		]
	})
	add_child(graph)
	var material : MMGenMaterial = graph.get_node("Material")
	assert_true(material.get_export_profiles().has(TARGET), "target registered")
	var prefix : String = ProjectSettings.globalize_path(OUT_DIR).path_join("pattern")
	await material.export_material(prefix, TARGET, 0, true)
	var shader : String = FileAccess.get_file_as_string(prefix+".shader")
	assert_ne(shader, "")
	for forbidden in [ "\\bvec[234]\\b", "\\bmix\\(", "\\bfract\\(", "uniform ", "\\$" ]:
		var m : RegExMatch = RegEx.create_from_string(forbidden).search(shader)
		assert_null(m, "found %s in the shader: %s" % [ forbidden, m.get_string() if m != null else "" ])
	if MMTestHlsl.find_tool("dxc") == "":
		pending("dxc not found")
		return
	var inputs : Array = []
	for n in [ "Position", "Normal" ]:
		inputs.append({ name=n, type="float3" })
	for n in [ "Seed", "Age", "Upkeep", "Fresh", "Char", "Wet" ]:
		inputs.append({ name=n, type="float" })
	inputs.append({ name="Axis", type="float3" })
	inputs.append({ name="Origin", type="float3" })
	inputs.append({ name="Footprint", type="float" })
	inputs.append({ name="Time", type="float" })
	var outputs : Array = [ { name="metallic", type="float" }, { name="roughness", type="float" },
			{ name="normal", type="float3" }, { name="emission", type="float3" },
			{ name="occlusion", type="float" }, { name="opacity", type="float" } ]
	var path : String = OUT_DIR.path_join("pattern.hlsl")
	var f : FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(MMTestHlsl.wrap_custom_node(shader, inputs, outputs))
	f.close()
	for hv in [ "2018", "2021" ]:
		var r : Dictionary = MMTestHlsl.compile_hlsl(path, "ps_6_0", "main", hv)
		assert_true(r.ok, "-HV %s: %s" % [ hv, r.output ])

# ---- GPU

func test_faces_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	var scale : Vector2 = Vector2(2.0, 3.0)
	var faces : Array = [
		[ Vector3(1, 0, 0), 0, 1.0 ], [ Vector3(-1, 0, 0), 0, 0.0 ],
		[ Vector3(0, 1, 0), 1, 1.0 ], [ Vector3(0, -1, 0), 1, 0.0 ],
		[ Vector3(0, 0, 1), 2, 1.0 ], [ Vector3(0, 0, -1), 2, 0.0 ]
	]
	for up_y in [ false, true ]:
		for mode in [ 0, 1 ]:
			for f in faces:
				var gen : MMGenBase = await build(f[0], { scale_u=scale.x, scale_v=scale.y, up=1 if up_y else 0, mode=mode })
				var worst : float = await check_face(gen, face_points(f[1], f[2]), f[0], up_y, scale, Vector2.ZERO)
				gdprint("up %s mode %d normal %s: max diff %f" % [ "Y" if up_y else "Z", mode, str(f[0]), worst ])
				assert_lt(worst, 1e-5, "up %s mode %d normal %s" % [ "Y" if up_y else "Z", mode, str(f[0]) ])
				graph.free()
				graph = null

func test_u_is_mirrored_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	# The same points on the +X and -X faces: U runs in opposite directions, V is equal.
	# With scale 1 and a fract of v+0.5 shift avoided, u(+X) + u(-X) is a whole number.
	var pts : PackedVector3Array = PackedVector3Array([ Vector3(0, 0.25, 0.3), Vector3(0, 0.6, 0.45), Vector3(0, 0.1, 0.8) ])
	var positive : Image = await render_with(await build(Vector3(1, 0, 0), { scale_u=1.0, scale_v=1.0 }), 0, list_function(pts))
	graph.free()
	graph = null
	var negative : Image = await render_with(await build(Vector3(-1, 0, 0), { scale_u=1.0, scale_v=1.0 }), 0, list_function(pts))
	assert_not_null(positive)
	assert_not_null(negative)
	if positive == null or negative == null:
		return
	for idx in pts.size():
		var a : Color = positive.get_pixel(idx, 0)
		var b : Color = negative.get_pixel(idx, 0)
		assert_almost_eq(a.r, pts[idx].y, 1e-5, "u on +X")
		assert_almost_eq(b.r, 1.0-pts[idx].y, 1e-5, "u on -X is mirrored")
		assert_almost_eq(a.g, b.g, 1e-6, "v is the same")
		assert_almost_eq(a.g, pts[idx].z, 1e-5, "v is the height")

func test_offset_and_scale_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	var n : Vector3 = Vector3(0, 0, 1)
	var gen : MMGenBase = await build(n, { scale_u=1.5, scale_v=0.5, offset_u=0.25, offset_v=-0.125 })
	var worst : float = await check_face(gen, face_points(2, 1.0), n, false, Vector2(1.5, 0.5), Vector2(0.25, -0.125))
	assert_lt(worst, 1e-5)

func test_oblique_dominant_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	var n : Vector3 = Vector3(-0.3, 0.9, 0.2).normalized()
	var gen : MMGenBase = await build(n, { scale_u=2.0, scale_v=2.0 })
	var worst : float = await check_face(gen, PackedVector3Array(POINTS), n, false, Vector2(2, 2), Vector2.ZERO)
	assert_lt(worst, 1e-5, "the +Y projection is chosen")

func test_triplanar_blend_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	# At 45 degrees between +X and +Z the two projections get equal weights: the result is their average
	var n : Vector3 = Vector3(1, 0, 1).normalized()
	var p : Vector3 = Vector3(0.37, 0.21, 0.58)
	var gen : MMGenBase = await build(n, { mode=1, scale_u=1.0, scale_v=1.0 })
	var image : Image = await render_with(gen, 0, list_function(PackedVector3Array([ p ])))
	assert_not_null(image)
	if image == null:
		return
	var c : Color = image.get_pixel(0, 0)
	var ex : Vector2 = expected_colour(p, Vector3(1, 0, 0), false, Vector2.ONE, Vector2.ZERO)
	var ez : Vector2 = expected_colour(p, Vector3(0, 0, 1), false, Vector2.ONE, Vector2.ZERO)
	assert_almost_eq(c.r, (ex.x+ez.x)*0.5, 1e-5)
	assert_almost_eq(c.g, (ex.y+ez.y)*0.5, 1e-5)

func test_fallback_height_and_mask_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	# Without a normal the Z projection is used; Height is the luminance of the colour
	var gen : MMGenBase = await build(Vector3.ZERO, { scale_u=1.0, scale_v=1.0 })
	var pts : PackedVector3Array = PackedVector3Array(POINTS)
	var colour : Image = await render_with(gen, 0, list_function(pts))
	var height : Image = await render_with(gen, 1, list_function(pts))
	assert_not_null(colour)
	assert_not_null(height)
	if colour == null or height == null:
		return
	for idx in pts.size():
		var c : Color = colour.get_pixel(idx % 64, idx/64)
		assert_almost_eq(c.r, pts[idx].x, 1e-5, "u is x")
		assert_almost_eq(c.g, pts[idx].y, 1e-5, "v is y")
		assert_almost_eq(height.get_pixel(idx % 64, idx/64).r, 0.2126*c.r+0.7152*c.g, 1e-5, "luminance")
