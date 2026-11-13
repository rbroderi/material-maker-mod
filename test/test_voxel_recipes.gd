extends GutTest

# Tests of the recipe nodes: Voxel Palette Pick, Weathering, Char, Wetness and Paint (design/zcity_plan.md, WP14)

const MMGraphCost = preload("res://material_maker/plugins/graph_cost/graph_cost.gd")
const FORBIDDEN : String = "\\b(mat[234]|uvec[234]|bvec[234]|lessThan|greaterThan|dFdx|dFdy|fwidth|texelFetch|textureSize)\\b"
const VOXEL_DIR : String = "res://material_maker/plugins/voxel/nodes"
const TARGET : String = "Unreal/Unreal Engine 5 Voxel"
const TARGET_DIR : String = "res://material_maker/plugins/voxel/export_targets"
const OUT_DIR : String = "user://voxel_recipes_test"
const TYPES : Array = [ "voxel_palette_pick", "voxel_weathering", "voxel_char", "voxel_wetness", "voxel_paint" ]
const PALETTE : Array = [ [ 150, 80, 60 ], [ 168, 92, 64 ], [ 120, 70, 56 ], [ 84, 64, 64 ], [ 176, 134, 94 ] ]

# Values computed with ZCity/Tools/voxkit (noise.py hash3/fbm and the brick() palette and aged branch, the paint branch of wood()).
# Palette: colours and the two hash values per id. Weathering and paint: positions in metres, linear colours.
const REFERENCE : Dictionary = {
	"palette": [
		{ "seed": 5, "ids": [ 3, 40, 77, 114, 151, 188, 225, 262, 299, 336, 373, 410, 447, 484, 521, 558, 595, 632, 669, 706, 743, 780, 817, 854 ], "col": [
		[ 0.158165, 0.088917, 0.063474 ],
		[ 0.186374, 0.104196, 0.068427 ],
		[ 0.316084, 0.083655, 0.045966 ],
		[ 0.331660, 0.093563, 0.047822 ],
		[ 0.309114, 0.081497, 0.045476 ],
		[ 0.157920, 0.088784, 0.063431 ],
		[ 0.384081, 0.105340, 0.050838 ],
		[ 0.307178, 0.080898, 0.045340 ],
		[ 0.381538, 0.104769, 0.050692 ],
		[ 0.157416, 0.058187, 0.043141 ],
		[ 0.318603, 0.084435, 0.046143 ],
		[ 0.368173, 0.101766, 0.049923 ],
		[ 0.370829, 0.102363, 0.050076 ],
		[ 0.324725, 0.086330, 0.046573 ],
		[ 0.333860, 0.089158, 0.047215 ],
		[ 0.341818, 0.095845, 0.048407 ],
		[ 0.171670, 0.059621, 0.041456 ],
		[ 0.168122, 0.059264, 0.041875 ],
		[ 0.329800, 0.087901, 0.046929 ],
		[ 0.321798, 0.085424, 0.046367 ],
		[ 0.333178, 0.088946, 0.047167 ],
		[ 0.362680, 0.100532, 0.049607 ],
		[ 0.337669, 0.094913, 0.048168 ],
		[ 0.330301, 0.088056, 0.046965 ] ], "h1": [ 0.919054, 0.919472, 0.128881, 0.525499, 0.032865, 0.922928, 0.552732, 0.078558, 0.501275, 0.804436, 0.055447, 0.430320, 0.423632, 0.125790, 0.091372, 0.507486, 0.735211, 0.719491, 0.058181, 0.082287, 0.007329, 0.561003, 0.623458, 0.189860 ], "h2": [ 0.574820, 0.808099, 0.366181, 0.840127, 0.136177, 0.572793, 0.105046, 0.072283, 0.140712, 0.876018, 0.449292, 0.328120, 0.290875, 0.651315, 0.952736, 0.697695, 0.465332, 0.567546, 0.818765, 0.554731, 0.930234, 0.405148, 0.755872, 0.835299 ] },
		{ "seed": 123456, "ids": [ 3, 40, 77, 114, 151, 188, 225, 262, 299, 336, 373, 410, 447, 484, 521, 558, 595, 632, 669, 706, 743, 780, 817, 854 ], "col": [
		[ 0.183579, 0.060819, 0.040048 ],
		[ 0.174858, 0.059942, 0.041079 ],
		[ 0.173771, 0.059833, 0.041207 ],
		[ 0.187391, 0.061203, 0.039597 ],
		[ 0.320676, 0.085077, 0.046288 ],
		[ 0.352526, 0.098250, 0.049023 ],
		[ 0.370379, 0.102262, 0.050050 ],
		[ 0.402903, 0.200128, 0.095784 ],
		[ 0.334436, 0.089336, 0.047255 ],
		[ 0.334392, 0.089322, 0.047252 ],
		[ 0.324240, 0.086180, 0.046539 ],
		[ 0.349116, 0.097484, 0.048827 ],
		[ 0.162646, 0.058713, 0.042522 ],
		[ 0.150020, 0.084506, 0.062044 ],
		[ 0.167830, 0.059235, 0.041910 ],
		[ 0.326493, 0.086877, 0.046697 ],
		[ 0.151109, 0.085096, 0.062235 ],
		[ 0.416316, 0.216554, 0.102715 ],
		[ 0.157740, 0.058220, 0.043102 ],
		[ 0.353415, 0.098450, 0.049074 ],
		[ 0.349036, 0.097466, 0.048822 ],
		[ 0.188076, 0.105117, 0.068726 ],
		[ 0.167904, 0.059242, 0.041901 ],
		[ 0.325696, 0.086631, 0.046641 ] ], "h1": [ 0.797947, 0.693825, 0.851716, 0.732793, 0.210866, 0.490055, 0.545438, 0.967372, 0.286642, 0.090044, 0.030034, 0.545744, 0.711930, 0.909510, 0.776528, 0.126880, 0.899734, 0.973727, 0.815814, 0.602374, 0.425208, 0.864373, 0.700726, 0.206776 ], "h2": [ 0.122218, 0.373481, 0.404812, 0.012394, 0.517707, 0.547538, 0.297186, 0.691261, 0.971757, 0.970280, 0.635306, 0.595359, 0.725336, 0.507463, 0.575977, 0.709648, 0.516469, 0.394563, 0.866694, 0.535066, 0.596482, 0.822170, 0.573851, 0.683358 ] } ],
	"weather": [
		{ "seed": 4242, "age": 0.800000, "up": 0.250000, "fr": 0.000000, "P": [
		[ -1.114289, -0.002166, 0.304495 ],
		[ -1.413933, -1.056222, 1.284633 ],
		[ -1.288738, -1.110678, 1.344985 ],
		[ 0.365651, -0.393021, 0.034170 ],
		[ 0.488529, -0.674074, -1.086096 ],
		[ 0.864119, 0.511082, 0.037147 ],
		[ 0.950209, 0.147226, 1.442741 ],
		[ -0.886472, 0.161191, -0.049126 ],
		[ -0.440175, 0.274786, -0.794096 ],
		[ 0.906608, 1.102001, -1.113721 ],
		[ -0.098780, -0.668565, -1.250649 ],
		[ 1.187833, -0.210154, -1.056926 ],
		[ 0.520087, -0.893352, 1.204293 ],
		[ -0.848555, -1.400776, -0.897693 ],
		[ -0.462756, -0.093276, 1.218403 ],
		[ 0.592083, -0.482038, -1.449368 ] ], "col": [
		[ 0.393320, 0.388533, 0.385155 ],
		[ 0.389362, 0.382586, 0.376585 ],
		[ 0.396305, 0.391113, 0.387035 ],
		[ 0.401048, 0.396743, 0.393706 ],
		[ 0.399433, 0.395028, 0.391919 ],
		[ 0.401431, 0.397150, 0.394130 ],
		[ 0.372477, 0.366389, 0.362093 ],
		[ 0.401155, 0.396857, 0.393824 ],
		[ 0.387994, 0.382875, 0.379262 ],
		[ 0.367681, 0.361294, 0.356786 ],
		[ 0.390891, 0.385952, 0.382467 ],
		[ 0.374869, 0.368931, 0.364740 ],
		[ 0.402736, 0.398536, 0.395573 ],
		[ 0.374260, 0.368283, 0.364065 ],
		[ 0.374527, 0.368567, 0.364361 ],
		[ 0.401549, 0.397276, 0.394261 ] ] },
		{ "seed": 99, "age": 1.000000, "up": 0.000000, "fr": 0.300000, "P": [
		[ -1.020529, 1.489308, -0.120852 ],
		[ 0.573120, -1.335996, -1.397849 ],
		[ 1.037670, 0.263646, -0.573871 ],
		[ -0.547870, -1.232288, -0.981991 ],
		[ -1.426242, 1.017375, -0.101090 ],
		[ -1.118391, 0.717741, -0.913042 ],
		[ -1.314239, 0.295176, 1.187273 ],
		[ -1.419170, 0.915408, -0.929490 ],
		[ -1.221296, -1.446114, -0.621075 ],
		[ 0.681335, -0.020463, 1.058760 ],
		[ -0.848366, -0.554452, -0.725577 ],
		[ 1.434903, 1.323018, -0.477941 ],
		[ -0.191995, -0.557041, 0.739527 ],
		[ -1.379961, -1.297683, -0.287887 ],
		[ -0.764718, 1.035675, 0.725421 ],
		[ 0.137382, 0.484427, 0.576837 ] ], "col": [
		[ 0.337466, 0.329504, 0.323886 ],
		[ 0.353071, 0.346073, 0.341128 ],
		[ 0.339660, 0.331835, 0.326313 ],
		[ 0.394813, 0.390432, 0.387340 ],
		[ 0.371917, 0.366106, 0.362005 ],
		[ 0.371050, 0.365185, 0.361047 ],
		[ 0.369511, 0.363550, 0.359343 ],
		[ 0.347895, 0.340584, 0.335426 ],
		[ 0.337253, 0.329278, 0.323650 ],
		[ 0.375974, 0.370416, 0.366494 ],
		[ 0.343153, 0.335547, 0.330179 ],
		[ 0.335759, 0.327691, 0.321998 ],
		[ 0.381913, 0.376726, 0.373066 ],
		[ 0.383571, 0.378487, 0.374900 ],
		[ 0.387485, 0.382639, 0.379214 ],
		[ 0.381148, 0.375913, 0.372219 ] ] } ],
	"paint": [
		{ "seed": 7, "mask": 0.800000, "P": [
		[ 0.843164, 1.282508, -1.050794 ],
		[ 0.378390, -1.069136, -0.170607 ],
		[ 0.858854, 1.184093, 0.777684 ],
		[ -1.393775, -0.421764, -1.010830 ],
		[ 1.496407, -1.067954, -0.767057 ],
		[ -0.428341, -1.317340, 1.111155 ],
		[ 0.409084, -1.020755, -0.005194 ],
		[ -1.263991, 0.332939, -0.805010 ],
		[ -1.384083, -1.154287, 0.165788 ],
		[ 0.410942, -0.525598, 0.430357 ],
		[ -0.443802, -1.108023, -0.554369 ],
		[ -0.314195, 1.237917, -1.153019 ],
		[ -1.241508, 0.184506, 1.390178 ],
		[ 1.221765, 0.600732, -1.299748 ],
		[ 0.919204, 0.550124, -1.068209 ],
		[ -0.105169, -1.352032, 0.905628 ] ], "col": [
		[ 0.545849, 0.497478, 0.410297 ],
		[ 0.574901, 0.523378, 0.430516 ],
		[ 0.576310, 0.524635, 0.431497 ],
		[ 0.570145, 0.519138, 0.427206 ],
		[ 0.575320, 0.523752, 0.430808 ],
		[ 0.549341, 0.500591, 0.412727 ],
		[ 0.563848, 0.513524, 0.422823 ],
		[ 0.543066, 0.494997, 0.408360 ],
		[ 0.552507, 0.503414, 0.414931 ],
		[ 0.553809, 0.504575, 0.415837 ],
		[ 0.562367, 0.512204, 0.421793 ],
		[ 0.553804, 0.504570, 0.415833 ],
		[ 0.552719, 0.503602, 0.415078 ],
		[ 0.550881, 0.501964, 0.413799 ],
		[ 0.562358, 0.512196, 0.421787 ],
		[ 0.561028, 0.511010, 0.420861 ] ], "rough": 0.380000, "w": 0.800000 },
		{ "seed": 31, "mask": 0.300000, "P": [
		[ 0.655903, 0.913884, 0.781247 ],
		[ -0.698227, 0.869222, -0.752488 ],
		[ -1.086314, -0.328830, -0.006479 ],
		[ -0.642534, 0.317349, 0.307511 ],
		[ -0.780547, 0.367702, -0.428241 ],
		[ 0.704069, -0.628746, 0.896380 ],
		[ -0.254669, 0.159721, 0.520039 ],
		[ 0.055132, -0.727146, 1.438145 ],
		[ -1.211834, -0.525229, 0.147337 ],
		[ -1.413899, -1.035261, 0.897793 ],
		[ 0.851443, 0.410899, 1.205399 ],
		[ 0.766570, -0.603647, 0.434600 ],
		[ -0.479753, 0.749533, -0.345619 ],
		[ -1.040270, 1.129370, 0.571216 ],
		[ 0.734036, 0.178794, 0.848825 ],
		[ -0.156380, 0.197379, -1.312309 ] ], "col": [
		[ 0.524456, 0.505529, 0.471416 ],
		[ 0.522781, 0.504035, 0.470250 ],
		[ 0.530447, 0.510870, 0.475586 ],
		[ 0.521664, 0.503040, 0.469473 ],
		[ 0.522654, 0.503923, 0.470162 ],
		[ 0.529347, 0.509890, 0.474820 ],
		[ 0.528113, 0.508789, 0.473961 ],
		[ 0.520614, 0.502104, 0.468742 ],
		[ 0.517696, 0.499503, 0.466711 ],
		[ 0.520118, 0.501661, 0.468397 ],
		[ 0.524351, 0.505435, 0.471343 ],
		[ 0.521497, 0.502891, 0.469357 ],
		[ 0.525881, 0.506800, 0.472408 ],
		[ 0.522813, 0.504064, 0.470272 ],
		[ 0.528167, 0.508838, 0.473999 ],
		[ 0.526433, 0.507291, 0.472791 ] ], "rough": 0.455000, "w": 0.300000 } ],
}

var graph : MMGenGraph

func before_all() -> void:
	mm_loader.get_predefined_generators_from_dir(VOXEL_DIR)
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

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

# A graph with a Voxel Inputs node In, a Decompose node Dec fed by the position, and the node N under test
func build(type : String, vox : Dictionary, connections : Array, params : Dictionary = {}) -> MMGenBase:
	var all_connections : Array = [ { from="In", from_port=0, to="Dec", to_port=0 } ]
	all_connections.append_array(connections)
	graph = await mm_loader.create_gen({
		nodes=[
			{ name="In", type="voxel_inputs", parameters=vox },
			{ name="Dec", type="tex3d_decompose" },
			{ name="N", type=type, parameters=params }
		],
		connections=all_connections
	})
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

const IDS_FUNCTION : String = """vec4 mm_pts(vec2 uv) {
	int idx = int(floor(uv.y*64.0))*64+int(floor(uv.x*64.0));
	if (idx > 999) {
		idx = 999;
	}
	return vec4(float(idx), 0.0, 0.0, 0.0);
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

func ids_array(ids : Array) -> PackedVector3Array:
	var rv : PackedVector3Array = PackedVector3Array()
	for v in ids:
		rv.append(Vector3(v, 0, 0))
	return rv

func color_diff(c : Color, r : Array) -> float:
	return maxf(absf(c.r-r[0]), maxf(absf(c.g-r[1]), absf(c.b-r[2])))

func srgb_to_linear(v : float) -> float:
	var c : float = v/255.0
	return c/12.92 if c <= 0.04045 else pow((c+0.055)/1.055, 2.4)

func palette_colour(k : int) -> Vector3:
	return Vector3(srgb_to_linear(PALETTE[k][0]), srgb_to_linear(PALETTE[k][1]), srgb_to_linear(PALETTE[k][2]))

# ---- headless

func test_nodes_instantiate() -> void:
	var expected : Dictionary = {
		voxel_palette_pick = [ [ "id_in", "seed_in" ], [ "Colour", "H1", "H2", "H3" ] ],
		voxel_weathering = [ [ "albedo_in", "height_in", "seed_in", "age_in", "upkeep_in", "fresh_in" ], [ "Albedo", "Roughness delta", "Bump scale" ] ],
		voxel_char = [ [ "albedo_in", "roughness_in", "char_in", "seed_in" ], [ "Albedo", "Roughness", "Height", "Emission" ] ],
		voxel_wetness = [ [ "albedo_in", "roughness_in", "wet_in", "normal_in" ], [ "Albedo", "Roughness" ] ],
		voxel_paint = [ [ "albedo_in", "roughness_in", "bump_in", "mask_in", "seed_in" ], [ "Albedo", "Roughness", "Bump" ] ]
	}
	for type in TYPES:
		var gen : MMGenBase = await build(type, {}, [])
		assert_not_null(gen, type)
		var inputs : Array = []
		for i in gen.get_input_defs():
			inputs.append(i.name)
		assert_eq(inputs, expected[type][0], type)
		var outputs : Array = []
		for o in gen.get_output_defs():
			outputs.append(o.shortdesc)
		assert_eq(outputs, expected[type][1], type)
		graph.free()
		graph = null

func test_generated_code() -> void:
	var regex : RegEx = RegEx.new()
	regex.compile(FORBIDDEN)
	for type in TYPES:
		var gen : MMGenBase = await build(type, {}, [])
		for i in gen.get_output_defs().size():
			var source : MMGenBase.ShaderCode = gen.get_shader_code("vec4(0.0)", i, MMGenContext.new())
			var text : String = all_text(source)
			assert_eq(text.find("$"), -1, "%s output %d has a $ left" % [ type, i ])
			assert_null(regex.search(text), "%s output %d has code outside of the HLSL safe subset" % [ type, i ])
			assert_string_contains(source.get_globals_string(), "mm_n3_hash_u")
			assert_eq(MMGraphCost.lint_parity(text).size(), 0, "%s output %d parity: %s" % [ type, i, str(MMGraphCost.lint_parity(text)) ])
		graph.free()
		graph = null

func test_identifiers_avoid_translated_words() -> void:
	for type in TYPES:
		var f : FileAccess = FileAccess.open(VOXEL_DIR+"/"+type+".mmg", FileAccess.READ)
		var data : Dictionary = JSON.parse_string(f.get_as_text())
		f.close()
		var code : String = "\n".join(data.shader_model.instance)
		for m in RegEx.create_from_string("\\b([A-Za-z_]\\w*)\\b").search_all(code):
			var id : String = m.get_string()
			if id in [ "vec3", "vec4", "mix", "atan", "uint" ]:
				continue
			for bad in [ "vec2", "vec3", "vec4", "mat2", "mix", "fract", "atan", "uniform", "sampler2D", "elapsed_time", "texture_" ]:
				assert_eq(id.find(bad), -1, "%s: identifier %s contains %s" % [ type, id, bad ])

# A graph that uses all five nodes, exported with the Unreal voxel target and compiled by dxc
func test_all_five_export_and_compile() -> void:
	MMPlugins.load_export_targets(TARGET_DIR)
	graph = await mm_loader.create_gen({
		nodes=[
			{ name="Material", type="material_voxel" },
			{ name="In", type="voxel_inputs" },
			{ name="Dec", type="tex3d_decompose" },
			{ name="Pick", type="voxel_palette_pick" },
			{ name="Weather", type="voxel_weathering" },
			{ name="Paint", type="voxel_paint" },
			{ name="Char", type="voxel_char", parameters={ ember=2.0 } },
			{ name="Wet", type="voxel_wetness" }
		],
		connections=[
			{ from="In", from_port=0, to="Dec", to_port=0 },
			{ from="Dec", from_port=0, to="Pick", to_port=0 },
			{ from="In", from_port=2, to="Pick", to_port=1 },
			{ from="Pick", from_port=0, to="Weather", to_port=0 },
			{ from="Dec", from_port=1, to="Weather", to_port=1 },
			{ from="In", from_port=2, to="Weather", to_port=2 },
			{ from="In", from_port=3, to="Weather", to_port=3 },
			{ from="In", from_port=4, to="Weather", to_port=4 },
			{ from="In", from_port=5, to="Weather", to_port=5 },
			{ from="Weather", from_port=0, to="Paint", to_port=0 },
			{ from="Dec", from_port=2, to="Paint", to_port=3 },
			{ from="In", from_port=2, to="Paint", to_port=4 },
			{ from="Paint", from_port=0, to="Char", to_port=0 },
			{ from="Paint", from_port=1, to="Char", to_port=1 },
			{ from="In", from_port=6, to="Char", to_port=2 },
			{ from="In", from_port=2, to="Char", to_port=3 },
			{ from="Char", from_port=0, to="Wet", to_port=0 },
			{ from="Char", from_port=1, to="Wet", to_port=1 },
			{ from="In", from_port=7, to="Wet", to_port=2 },
			{ from="In", from_port=1, to="Wet", to_port=3 },
			{ from="Wet", from_port=0, to="Material", to_port=0 },
			{ from="Wet", from_port=1, to="Material", to_port=2 },
			{ from="Char", from_port=3, to="Material", to_port=3 },
			{ from="Paint", from_port=2, to="Material", to_port=6 }
		]
	})
	add_child(graph)
	var material : MMGenMaterial = graph.get_node("Material")
	assert_true(material.get_export_profiles().has(TARGET), "target registered")
	var prefix : String = ProjectSettings.globalize_path(OUT_DIR).path_join("all5")
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
	var path : String = OUT_DIR.path_join("all5.hlsl")
	var f : FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(MMTestHlsl.wrap_custom_node(shader, inputs, outputs))
	f.close()
	for hv in [ "2018", "2021" ]:
		var r : Dictionary = MMTestHlsl.compile_hlsl(path, "ps_6_0", "main", hv)
		assert_true(r.ok, "-HV %s: %s" % [ hv, r.output ])

# ---- GPU

func test_palette_matches_voxkit_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	for c in REFERENCE.palette:
		var gen : MMGenBase = await build("voxel_palette_pick", { vox_seed=c.seed },
				[ { from="Dec", from_port=0, to="N", to_port=0 }, { from="In", from_port=2, to="N", to_port=1 } ])
		var pf : String = list_function(ids_array(c.ids))
		var colour : Image = await render_with(gen, 0, pf)
		var h1 : Image = await render_with(gen, 1, pf)
		var h2 : Image = await render_with(gen, 2, pf)
		assert_not_null(colour)
		assert_not_null(h1)
		assert_not_null(h2)
		if colour == null or h1 == null or h2 == null:
			return
		var worst_col : float = 0.0
		var worst_h : float = 0.0
		for idx in c.ids.size():
			worst_col = maxf(worst_col, color_diff(colour.get_pixel(idx % 64, idx/64), c.col[idx]))
			worst_h = maxf(worst_h, maxf(absf(h1.get_pixel(idx % 64, idx/64).r-c.h1[idx]), absf(h2.get_pixel(idx % 64, idx/64).r-c.h2[idx])))
		print("palette seed %d: max diff colour %f, hashes %f" % [ c.seed, worst_col, worst_h ])
		assert_lt(worst_col, 0.002, "colour, seed %d" % c.seed)
		assert_lt(worst_h, 0.0001, "hash values, seed %d" % c.seed)
		graph.free()
		graph = null

func test_palette_distribution_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	var gen : MMGenBase = await build("voxel_palette_pick", { vox_seed=77 },
			[ { from="Dec", from_port=0, to="N", to_port=0 }, { from="In", from_port=2, to="N", to_port=1 } ])
	var colour : Image = await render_with(gen, 0, IDS_FUNCTION)
	var h1 : Image = await render_with(gen, 1, IDS_FUNCTION)
	assert_not_null(colour)
	assert_not_null(h1)
	if colour == null or h1 == null:
		return
	var worst : float = 0.0
	var counts : Array = [ 0, 0, 0, 0, 0 ]
	for idx in 1000:
		var c : Color = colour.get_pixel(idx % 64, idx/64)
		var v : Vector3 = Vector3(c.r, c.g, c.b)
		# distance to the nearest segment between two adjacent palette colours
		var best : float = 1.0e9
		for k in 5:
			var a : Vector3 = palette_colour(k)
			var b : Vector3 = palette_colour((k+1) % 5)
			var ab : Vector3 = b-a
			var t : float = clampf((v-a).dot(ab)/ab.length_squared(), 0.0, 1.0)
			best = minf(best, (a+ab*t-v).length())
		worst = maxf(worst, best)
		var h : float = h1.get_pixel(idx % 64, idx/64).r
		var k : int = 0
		for t in [ 0.40, 0.66, 0.86, 0.93 ]:
			if h > t:
				k += 1
		counts[k] += 1
	print("palette: worst distance to a segment %f, counts %s" % [ worst, str(counts) ])
	assert_lt(worst, 0.002, "every colour lies on a segment between adjacent palette colours")
	var expected : Array = [ 0.40, 0.26, 0.20, 0.07, 0.07 ]
	for k in 5:
		assert_lt(absf(counts[k]/1000.0-expected[k]), 0.05, "frequency of colour %d: %d" % [ k, counts[k] ])

func test_weathering_matches_voxkit_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	for c in REFERENCE.weather:
		var gen : MMGenBase = await build("voxel_weathering", { vox_seed=c.seed, vox_age=c.age, vox_upkeep=c.up, vox_fresh=c.fr },
				[ { from="In", from_port=2, to="N", to_port=2 }, { from="In", from_port=3, to="N", to_port=3 },
				{ from="In", from_port=4, to="N", to_port=4 }, { from="In", from_port=5, to="N", to_port=5 } ])
		var image : Image = await render_with(gen, 0, list_function(vec3_array(c.P)))
		assert_not_null(image)
		if image == null:
			return
		var worst : float = 0.0
		for idx in c.P.size():
			worst = maxf(worst, color_diff(image.get_pixel(idx % 64, idx/64), c.col[idx]))
		print("weathering seed %d: max diff colour %f" % [ c.seed, worst ])
		assert_lt(worst, 0.002, "colour, seed %d" % c.seed)
		graph.free()
		graph = null

func test_weathering_fresh_is_identity_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	var points : PackedVector3Array = vec3_array(REFERENCE.weather[0].P)
	var gen : MMGenBase = await build("voxel_weathering", { vox_seed=5, vox_age=0.9, vox_upkeep=0.0, vox_fresh=1.0 },
			[ { from="In", from_port=0, to="N", to_port=0 }, { from="Dec", from_port=1, to="N", to_port=1 },
			{ from="In", from_port=2, to="N", to_port=2 }, { from="In", from_port=3, to="N", to_port=3 },
			{ from="In", from_port=4, to="N", to_port=4 }, { from="In", from_port=5, to="N", to_port=5 } ])
	var image : Image = await render_with(gen, 0, list_function(points))
	assert_not_null(image)
	if image == null:
		return
	for idx in points.size():
		var c : Color = image.get_pixel(idx % 64, idx/64)
		var p : Vector3 = points[idx]
		assert_almost_eq(Vector3(c.r, c.g, c.b), p, Vector3(1e-6, 1e-6, 1e-6), "albedo equals the input at point %d" % idx)
	# and with age the albedo does change
	graph.get_node("In").set_parameter("vox_fresh", 0.0)
	var aged : Image = await render_with(gen, 0, list_function(points))
	var changed : int = 0
	for idx in points.size():
		var c : Color = aged.get_pixel(idx % 64, idx/64)
		if absf(c.r-points[idx].x) > 0.01:
			changed += 1
	assert_gt(changed, points.size()/2, "weathering changes the albedo when not fresh")

func test_wetness_dry_is_identity_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	var points : PackedVector3Array = vec3_array(REFERENCE.weather[0].P)
	var conns : Array = [ { from="In", from_port=0, to="N", to_port=0 }, { from="Dec", from_port=1, to="N", to_port=1 },
			{ from="In", from_port=7, to="N", to_port=2 } ]
	var gen : MMGenBase = await build("voxel_wetness", { vox_wet=0.0 }, conns)
	var albedo : Image = await render_with(gen, 0, list_function(points))
	var rough : Image = await render_with(gen, 1, list_function(points))
	assert_not_null(albedo)
	assert_not_null(rough)
	if albedo == null or rough == null:
		return
	for idx in points.size():
		var c : Color = albedo.get_pixel(idx % 64, idx/64)
		assert_almost_eq(Vector3(c.r, c.g, c.b), points[idx], Vector3(1e-6, 1e-6, 1e-6), "albedo at point %d" % idx)
		assert_almost_eq(rough.get_pixel(idx % 64, idx/64).r, points[idx].y, 1e-6, "roughness at point %d" % idx)
	# fully wet: darker and smoother
	graph.get_node("In").set_parameter("vox_wet", 1.0)
	albedo = await render_with(gen, 0, list_function(points))
	rough = await render_with(gen, 1, list_function(points))
	for idx in points.size():
		var c : Color = albedo.get_pixel(idx % 64, idx/64)
		assert_almost_eq(c.r, points[idx].x*0.55, 1e-5, "wet albedo at point %d" % idx)
		assert_lte(rough.get_pixel(idx % 64, idx/64).r, minf(points[idx].y, 0.15)+1e-6, "wet roughness at point %d" % idx)

func test_char_zero_is_identity_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	var points : PackedVector3Array = vec3_array(REFERENCE.weather[1].P)
	var conns : Array = [ { from="In", from_port=0, to="N", to_port=0 }, { from="Dec", from_port=1, to="N", to_port=1 },
			{ from="In", from_port=6, to="N", to_port=2 }, { from="In", from_port=2, to="N", to_port=3 } ]
	var gen : MMGenBase = await build("voxel_char", { vox_char=0.0, vox_seed=9 }, conns, { ember=3.0 })
	var pf : String = list_function(points)
	var albedo : Image = await render_with(gen, 0, pf)
	var rough : Image = await render_with(gen, 1, pf)
	var height : Image = await render_with(gen, 2, pf)
	var emission : Image = await render_with(gen, 3, pf)
	if albedo == null or rough == null or height == null or emission == null:
		fail_test("render failed")
		return
	for idx in points.size():
		var c : Color = albedo.get_pixel(idx % 64, idx/64)
		assert_almost_eq(Vector3(c.r, c.g, c.b), points[idx], Vector3(1e-6, 1e-6, 1e-6), "albedo at point %d" % idx)
		assert_almost_eq(rough.get_pixel(idx % 64, idx/64).r, points[idx].y, 1e-6, "roughness at point %d" % idx)
		assert_almost_eq(emission.get_pixel(idx % 64, idx/64).r, 0.0, 1e-6, "no emission at point %d" % idx)
		assert_almost_eq(height.get_pixel(idx % 64, idx/64).r, 0.5, 1e-6, "flat height at point %d" % idx)
	# fully charred: black, rough, cracked and glowing in the cracks
	graph.get_node("In").set_parameter("vox_char", 1.0)
	albedo = await render_with(gen, 0, pf)
	rough = await render_with(gen, 1, pf)
	height = await render_with(gen, 2, pf)
	emission = await render_with(gen, 3, pf)
	var low : float = 1.0
	var high : float = 0.0
	var glow : float = 0.0
	for idx in points.size():
		assert_lt(albedo.get_pixel(idx % 64, idx/64).r, 0.03, "charcoal at point %d" % idx)
		assert_almost_eq(rough.get_pixel(idx % 64, idx/64).r, 0.9, 1e-6)
		var h : float = height.get_pixel(idx % 64, idx/64).r
		low = minf(low, h)
		high = maxf(high, h)
		glow = maxf(glow, emission.get_pixel(idx % 64, idx/64).r)
	print("char: height %f..%f, glow %f" % [ low, high, glow ])
	assert_true(low >= 0.0 and high <= 1.0 and high > low, "crack height varies")
	assert_gt(glow, 0.0, "embers glow in the cracks")

func test_paint_matches_voxkit_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	for c in REFERENCE.paint:
		var gen : MMGenBase = await build("voxel_paint", { vox_seed=c.seed, vox_wet=c.mask },
				[ { from="In", from_port=0, to="N", to_port=2 }, { from="In", from_port=7, to="N", to_port=3 },
				{ from="In", from_port=2, to="N", to_port=4 } ])
		var points : PackedVector3Array = vec3_array(c.P)
		var pf : String = list_function(points)
		var albedo : Image = await render_with(gen, 0, pf)
		var rough : Image = await render_with(gen, 1, pf)
		var bump : Image = await render_with(gen, 2, pf)
		if albedo == null or rough == null or bump == null:
			fail_test("render failed")
			return
		var worst : float = 0.0
		var worst_r : float = 0.0
		var worst_b : float = 0.0
		for idx in points.size():
			worst = maxf(worst, color_diff(albedo.get_pixel(idx % 64, idx/64), c.col[idx]))
			worst_r = maxf(worst_r, absf(rough.get_pixel(idx % 64, idx/64).r-c.rough))
			var b : Color = bump.get_pixel(idx % 64, idx/64)
			var expected : Vector3 = points[idx]*(1.0+(0.375-1.0)*c.w)
			var d : Vector3 = (Vector3(b.r, b.g, b.b)-expected).abs()
			worst_b = maxf(worst_b, maxf(d.x, maxf(d.y, d.z)))
		print("paint seed %d: max diff colour %f, roughness %f, bump %f" % [ c.seed, worst, worst_r, worst_b ])
		assert_lt(worst, 0.002, "colour, seed %d" % c.seed)
		assert_lt(worst_r, 0.0001, "roughness, seed %d" % c.seed)
		assert_lt(worst_b, 0.0001, "bump, seed %d" % c.seed)
		graph.free()
		graph = null
