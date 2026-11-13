extends GutTest

# Tests of the Voxel Wood node (design/zcity_plan.md, WP13)

const MMGraphCost = preload("res://material_maker/plugins/graph_cost/graph_cost.gd")
const FORBIDDEN : String = "\\b(mat[234]|uvec[234]|bvec[234]|lessThan|greaterThan|dFdx|dFdy|fwidth|texelFetch|textureSize)\\b"
const VOXEL_DIR : String = "res://material_maker/plugins/voxel/nodes"
const UPM : float = 81.0

# Values computed with ZCity/Tools/voxkit/appearance.py::wood() (pith at the origin point, absolute coordinates, aged finish everywhere,
# normals across the grain): points in metres, the unit normals, the linear colours, the bumped normals, the spec
const REFERENCE : Array = [
	{ "axis": 0, "porous": true, "seed": 777, "org": [ 0.03, 0.12, 0.35 ], "age": 0.1, "P": [
		[ 0.825065, 0.108756, 0.38097 ],
		[ 0.827966, 0.201958, 0.413966 ],
		[ 0.538963, 0.188734, 0.30287 ],
		[ 0.312273, 0.179497, 0.418349 ],
		[ 0.083265, 0.101403, 0.41433 ],
		[ 0.408636, 0.118794, 0.266781 ],
		[ 0.43343, 0.150539, 0.385863 ],
		[ 0.074716, 0.044089, 0.263788 ],
		[ 0.078156, 0.129609, 0.350581 ],
		[ 1.016841, 0.080498, 0.339054 ],
		[ 0.674315, 0.185619, 0.29871 ],
		[ 0.261615, 0.044679, 0.319743 ] ], "n": [
		[ 0.0, 0.343502, -0.939152 ],
		[ 0.0, -0.404583, 0.914501 ],
		[ 0.0, 0.593044, 0.80517 ],
		[ 0.0, -0.320004, -0.947416 ],
		[ 0.0, -0.947735, 0.319058 ],
		[ 0.0, 0.300246, -0.953862 ],
		[ 0.0, 0.091624, 0.995794 ],
		[ 0.0, -0.423632, 0.905834 ],
		[ 0.0, 0.305872, -0.952073 ],
		[ 0.0, -0.999084, -0.042782 ],
		[ 0.0, -0.999259, -0.038496 ],
		[ 0.0, 0.087386, 0.996175 ] ], "col": [
		[ 0.206098, 0.121201, 0.063295 ],
		[ 0.208193, 0.117716, 0.05867 ],
		[ 0.215402, 0.121398, 0.060179 ],
		[ 0.096766, 0.052091, 0.027419 ],
		[ 0.198939, 0.111407, 0.055357 ],
		[ 0.238947, 0.134398, 0.066345 ],
		[ 0.241797, 0.136875, 0.068387 ],
		[ 0.196088, 0.110568, 0.054808 ],
		[ 0.109075, 0.05916, 0.03103 ],
		[ 0.223456, 0.12705, 0.063739 ],
		[ 0.13313, 0.073464, 0.03749 ],
		[ 0.233038, 0.131505, 0.065298 ] ], "nb": [
		[ -0.01422, 0.470727, -0.882164 ],
		[ -0.000545, -0.187768, 0.982213 ],
		[ -0.014981, 0.331808, 0.943228 ],
		[ 0.004806, -0.139965, -0.990145 ],
		[ 0.009882, -0.890916, 0.45406 ],
		[ 0.008481, 0.580594, -0.814149 ],
		[ 0.001376, 0.013672, 0.999906 ],
		[ 0.015984, -0.722189, 0.691511 ],
		[ 0.008254, -0.156957, -0.987571 ],
		[ 0.008019, -0.986148, 0.165673 ],
		[ 0.004407, -0.994766, 0.10208 ],
		[ 0.004753, 0.422603, 0.906303 ] ], "spec": [ 0.078966, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.054498, 0.05, 0.05 ], "axis_v": [ 1.0, 0.0, 0.0 ] },
	{ "axis": 1, "porous": true, "seed": 12345, "org": [ 0.1, -0.05, 0.2 ], "age": 0.6, "P": [
		[ 0.131838, -0.035643, 0.179341 ],
		[ 0.093747, 0.871703, 0.236859 ],
		[ 0.051931, 0.034766, 0.219448 ],
		[ 0.12436, 0.784496, 0.276222 ],
		[ 0.03209, 0.313339, 0.284981 ],
		[ 0.133224, 0.889282, 0.23866 ],
		[ 0.1234, 0.344494, 0.25338 ],
		[ 0.078656, 0.874881, 0.140001 ],
		[ 0.151597, 0.499294, 0.236796 ],
		[ 0.047116, 0.187171, 0.260083 ],
		[ 0.081067, 0.682268, 0.182928 ],
		[ 0.151495, 0.616064, 0.209204 ] ], "n": [
		[ -0.991509, 0.0, 0.13004 ],
		[ 0.965442, 0.0, -0.260617 ],
		[ -0.40932, 0.0, 0.912391 ],
		[ -0.815906, 0.0, 0.578185 ],
		[ 0.999983, 0.0, 0.005776 ],
		[ -0.87622, 0.0, 0.48191 ],
		[ -0.679419, 0.0, -0.733751 ],
		[ 0.91647, 0.0, -0.400103 ],
		[ 0.885839, 0.0, -0.463992 ],
		[ -0.466173, 0.0, 0.884693 ],
		[ 0.997327, 0.0, -0.073073 ],
		[ 0.38222, 0.0, 0.924071 ] ], "col": [
		[ 0.156538, 0.095238, 0.055592 ],
		[ 0.112927, 0.070011, 0.040731 ],
		[ 0.175811, 0.110956, 0.066564 ],
		[ 0.231332, 0.155845, 0.097893 ],
		[ 0.101071, 0.061341, 0.036955 ],
		[ 0.036568, 0.022551, 0.013701 ],
		[ 0.160765, 0.101984, 0.062464 ],
		[ 0.094122, 0.055776, 0.033009 ],
		[ 0.191496, 0.119551, 0.071504 ],
		[ 0.086581, 0.05154, 0.031222 ],
		[ 0.103803, 0.061421, 0.035941 ],
		[ 0.128578, 0.079353, 0.046087 ] ], "nb": [
		[ -0.962907, 0.003358, 0.269813 ],
		[ 0.98498, -0.005494, -0.172583 ],
		[ -0.121067, 0.002184, 0.992642 ],
		[ -0.918339, 0.008527, 0.395703 ],
		[ 0.988263, -0.009729, 0.152449 ],
		[ -0.853894, 0.006858, 0.520402 ],
		[ -0.696618, 0.006448, -0.717413 ],
		[ 0.758663, -0.003775, -0.651473 ],
		[ 0.985946, 0.00033, -0.167062 ],
		[ -0.387701, -0.002755, 0.921781 ],
		[ 0.996658, -0.008508, 0.081244 ],
		[ 0.531918, -0.001981, 0.846794 ] ], "spec": [ 0.05, 0.05, 0.05, 0.149592, 0.05, 0.05, 0.05422, 0.05, 0.05, 0.05, 0.05, 0.05 ], "axis_v": [ 0.0, 1.0, 0.0 ] },
	{ "axis": 2, "porous": false, "seed": 31, "org": [ 0.1, 0.2, -0.03 ], "age": 0.3, "P": [
		[ 0.162979, 0.262007, 0.783088 ],
		[ 0.06175, 0.171879, 0.125318 ],
		[ 0.090861, 0.250755, 0.370097 ],
		[ 0.023477, 0.182541, 0.042566 ],
		[ 0.014055, 0.216256, 0.817446 ],
		[ 0.047312, 0.241044, 0.788566 ],
		[ 0.072635, 0.200235, 0.108064 ],
		[ 0.173995, 0.232974, 0.490599 ],
		[ 0.16736, 0.234104, 0.224955 ],
		[ 0.09663, 0.114568, 0.455704 ],
		[ 0.092181, 0.120332, 0.516376 ],
		[ 0.128863, 0.13934, 0.07495 ] ], "n": [
		[ 0.227167, 0.973856, 0.0 ],
		[ 0.290365, 0.956916, 0.0 ],
		[ 0.953092, 0.302681, 0.0 ],
		[ 0.20524, 0.978712, 0.0 ],
		[ -0.806637, -0.591048, 0.0 ],
		[ 0.752706, -0.658357, 0.0 ],
		[ -0.584357, 0.811497, 0.0 ],
		[ -0.667038, 0.745024, 0.0 ],
		[ -0.865597, 0.500741, 0.0 ],
		[ -0.425797, -0.904819, 0.0 ],
		[ 0.217382, -0.976087, 0.0 ],
		[ 0.930885, -0.365313, 0.0 ] ], "col": [
		[ 0.173972, 0.102601, 0.056527 ],
		[ 0.208559, 0.122563, 0.065665 ],
		[ 0.174411, 0.101263, 0.054272 ],
		[ 0.21101, 0.124757, 0.067497 ],
		[ 0.209646, 0.124065, 0.06728 ],
		[ 0.179056, 0.103954, 0.055468 ],
		[ 0.209629, 0.123235, 0.066053 ],
		[ 0.104157, 0.062784, 0.03706 ],
		[ 0.09903, 0.055652, 0.030758 ],
		[ 0.224389, 0.131273, 0.069753 ],
		[ 0.201811, 0.118397, 0.063389 ],
		[ 0.170458, 0.098443, 0.052819 ] ], "nb": [
		[ 0.219542, 0.975517, 0.012942 ],
		[ 0.300388, 0.953648, 0.017983 ],
		[ 0.984326, 0.174674, 0.024316 ],
		[ -0.07051, 0.996703, 0.04014 ],
		[ -0.927938, -0.372353, 0.016879 ],
		[ 0.893889, -0.448212, 0.008278 ],
		[ -0.372835, 0.927528, -0.026189 ],
		[ -0.644058, 0.764915, 0.009704 ],
		[ -0.956264, 0.292073, -0.015902 ],
		[ -0.276927, -0.960877, 0.005153 ],
		[ 0.099612, -0.99502, 0.003473 ],
		[ 0.999866, -0.006905, 0.014813 ] ], "spec": [ 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.075, 0.05, 0.05, 0.05, 0.05 ], "axis_v": [ 0.0, 0.0, 1.0 ] }
]

var graph : MMGenGraph

func before_all() -> void:
	mm_loader.get_predefined_generators_from_dir(VOXEL_DIR)

func after_each() -> void:
	if graph != null:
		graph.free()
		graph = null

func gpu_available() -> bool:
	return RenderingServer.get_rendering_device() != null

func all_text(source : MMGenBase.ShaderCode) -> String:
	var rv : String = source.defs+source.code+source.get_globals_string()
	for k in source.output_values.keys():
		rv += str(source.output_values[k])
	return rv

# Voxel Inputs wired to Voxel Wood: seed, axis, origin and age
func make_wood(seed_value : int, axis : Vector3, origin : Vector3, age : float, wood_params : Dictionary = {}) -> MMGenBase:
	graph = await mm_loader.create_gen({
		nodes=[
			{ name="In", type="voxel_inputs", parameters={ vox_seed=seed_value, vox_age=age, vox_axis_x=axis.x, vox_axis_y=axis.y, vox_axis_z=axis.z,
					vox_origin_x=origin.x, vox_origin_y=origin.y, vox_origin_z=origin.z } },
			{ name="W", type="voxel_wood", parameters=wood_params }
		],
		connections=[
			{ from="In", from_port=2, to="W", to_port=0 },
			{ from="In", from_port=8, to="W", to_port=2 },
			{ from="In", from_port=9, to="W", to_port=3 },
			{ from="In", from_port=3, to="W", to_port=4 }
		]
	})
	add_child(graph)
	return graph.get_node("W")

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

const BEAM_FUNCTION : String = """vec4 mm_pts(vec2 uv) {
	int idx = int(floor(uv.y*64.0))*64+int(floor(uv.x*64.0));
	float fi = float(idx);
	float r0 = fract(sin(fi*12.9898+1.0)*43758.5453);
	float r1 = fract(sin(fi*78.233+2.0)*43758.5453);
	float r2 = fract(sin(fi*39.425+3.0)*43758.5453);
	int face = int(floor(r0*6.0));
	vec3 v = vec3(r1*80.0, r1*14.0, r2*14.0);
	if (face == 0) {
		v.y = 0.0;
	} else if (face == 1) {
		v.y = 14.0;
	} else if (face == 2) {
		v = vec3(r1*80.0, r2*14.0, 0.0);
	} else if (face == 3) {
		v = vec3(r1*80.0, r2*14.0, 14.0);
	} else if (face == 4) {
		v.x = 0.0;
	} else {
		v.x = 80.0;
	}
	return vec4(v/81.0, 0.0);
}
"""

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

func vec3_array(a : Array) -> PackedVector3Array:
	var rv : PackedVector3Array = PackedVector3Array()
	for v in a:
		rv.append(Vector3(v[0], v[1], v[2]))
	return rv

# ---- headless

func test_node_instantiates() -> void:
	var gen : MMGenBase = await make_wood(0, Vector3(1, 0, 0), Vector3.ZERO, 0.1)
	assert_not_null(gen)
	assert_eq(gen.get_output_defs().size(), 5)
	var names : Array = []
	for o in gen.get_output_defs():
		names.append(o.shortdesc)
	assert_eq(names, [ "Albedo", "Bump", "Roughness", "Spec", "Power" ])
	var inputs : Array = []
	for i in gen.get_input_defs():
		inputs.append(i.name)
	assert_eq(inputs, [ "seed_in", "normal_in", "axis_in", "origin_in", "age_in", "fresh_in", "footprint_in" ])

func test_generated_code() -> void:
	var regex : RegEx = RegEx.new()
	regex.compile(FORBIDDEN)
	for porous in [ true, false ]:
		var gen : MMGenBase = await make_wood(3, Vector3(0, 1, 0), Vector3.ZERO, 0.5, { ring_porous=porous })
		for i in gen.get_output_defs().size():
			var source : MMGenBase.ShaderCode = gen.get_shader_code("vec4(0.0)", i, MMGenContext.new())
			var text : String = all_text(source)
			assert_eq(text.find("$"), -1, "output %d has a $ left" % i)
			assert_null(regex.search(text), "output %d has code outside of the HLSL safe subset" % i)
			assert_string_contains(source.get_globals_string(), "mm_n3_hash_u")
			assert_eq(MMGraphCost.lint_parity(text).size(), 0, "output %d parity: %s" % [ i, str(MMGraphCost.lint_parity(text)) ])
		graph.free()
		graph = null

func test_identifiers_avoid_translated_words() -> void:
	var f : FileAccess = FileAccess.open(VOXEL_DIR+"/voxel_wood.mmg", FileAccess.READ)
	var data : Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var code : String = "\n".join(data.shader_model.instance)
	for m in RegEx.create_from_string("\\b([A-Za-z_]\\w*)\\b").search_all(code):
		var id : String = m.get_string()
		if id in [ "vec3", "vec4", "mix", "atan", "uint" ]:
			continue
		for bad in [ "vec2", "vec3", "vec4", "mat2", "mix", "fract", "atan", "uniform", "sampler2D", "elapsed_time", "texture_" ]:
			assert_eq(id.find(bad), -1, "identifier %s contains %s" % [ id, bad ])

# ---- GPU

func test_matches_voxkit_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	for c in REFERENCE:
		var axis : Vector3 = Vector3(c.axis_v[0], c.axis_v[1], c.axis_v[2])
		var org : Vector3 = Vector3(c.org[0], c.org[1], c.org[2])
		var gen : MMGenBase = await make_wood(c.seed, axis, org, c.age, { ring_porous=c.porous })
		var pf : String = list_function(vec3_array(c.P))
		var albedo : Image = await render_with(gen, 0, pf)
		var bump : Image = await render_with(gen, 1, pf)
		var spec : Image = await render_with(gen, 3, pf)
		assert_not_null(albedo)
		assert_not_null(bump)
		assert_not_null(spec)
		if albedo == null or bump == null or spec == null:
			return
		var worst_col : float = 0.0
		var worst_nb : float = 0.0
		var worst_spec : float = 0.0
		for idx in c.P.size():
			var px : int = idx % 64
			var py : int = idx/64
			var a : Color = albedo.get_pixel(px, py)
			var rc : Array = c.col[idx]
			worst_col = maxf(worst_col, maxf(absf(a.r-rc[0]), maxf(absf(a.g-rc[1]), absf(a.b-rc[2]))))
			var n : Vector3 = Vector3(c.n[idx][0], c.n[idx][1], c.n[idx][2])
			var bc : Color = bump.get_pixel(px, py)
			var g : Vector3 = Vector3(bc.r, bc.g, bc.b)
			var nb : Vector3 = (n-(g-n*g.dot(n))).normalized()
			var rn : Array = c.nb[idx]
			var dn : Vector3 = (nb-Vector3(rn[0], rn[1], rn[2])).abs()
			worst_nb = maxf(worst_nb, maxf(dn.x, maxf(dn.y, dn.z)))
			worst_spec = maxf(worst_spec, absf(spec.get_pixel(px, py).r-c.spec[idx]))
		gdprint("axis %s seed %d: max diff colour %f, bumped normal %f, spec %f" % [ str(axis), c.seed, worst_col, worst_nb, worst_spec ])
		assert_lt(worst_col, 0.005, "colour, seed %d" % c.seed)
		assert_lt(worst_nb, 0.005, "bumped normal, seed %d" % c.seed)
		assert_lt(worst_spec, 0.005, "spec, seed %d" % c.seed)
		graph.free()
		graph = null

func gdprint(text : String) -> void:
	print(text)

func test_beam_mean_colour_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	var pith : Vector3 = Vector3(0.0, 14.0*0.36, 14.0*0.63)/UPM
	var gen : MMGenBase = await make_wood(777, Vector3(1, 0, 0), pith, 0.1)
	var image : Image = await render_with(gen, 0, BEAM_FUNCTION)
	assert_not_null(image)
	if image == null:
		return
	var mean : Vector3 = Vector3.ZERO
	for idx in 2000:
		var c : Color = image.get_pixel(idx % 64, idx/64)
		assert_true(is_finite(c.r) and is_finite(c.g) and is_finite(c.b), "finite")
		assert_true(c.r >= 0.0 and c.r <= 1.0 and c.g >= 0.0 and c.g <= 1.0 and c.b >= 0.0 and c.b <= 1.0, "in [0, 1]: %s" % str(c))
		mean += Vector3(c.r, c.g, c.b)
	mean /= 2000.0
	gdprint("beam mean colour %s" % str(mean))
	assert_lt(absf(mean.x-0.20), 0.05)
	assert_lt(absf(mean.y-0.12), 0.05)
	assert_lt(absf(mean.z-0.07), 0.05)
	for i in [ 1, 2, 3, 4 ]:
		var other : Image = await render_with(gen, i, BEAM_FUNCTION)
		assert_not_null(other, "output %d compiles" % i)
		if other != null:
			var c : Color = other.get_pixel(5, 5)
			assert_true(is_finite(c.r) and is_finite(c.g) and is_finite(c.b), "output %d is finite" % i)
