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
		[ 0.199, 0.111034, 0.070644 ],
		[ 0.317209, 0.084003, 0.046045 ],
		[ 0.329916, 0.093171, 0.047722 ],
		[ 0.30669, 0.080747, 0.045306 ],
		[ 0.325573, 0.092195, 0.047472 ],
		[ 0.179133, 0.060372, 0.040573 ],
		[ 0.313518, 0.082861, 0.045786 ],
		[ 0.42999, 0.233298, 0.109781 ],
		[ 0.324007, 0.086108, 0.046522 ],
		[ 0.153908, 0.057834, 0.043555 ],
		[ 0.185134, 0.060976, 0.039864 ],
		[ 0.183562, 0.102672, 0.067933 ],
		[ 0.318574, 0.084426, 0.046141 ],
		[ 0.319578, 0.084737, 0.046211 ],
		[ 0.325485, 0.086565, 0.046626 ],
		[ 0.391301, 0.106962, 0.051254 ],
		[ 0.324424, 0.086237, 0.046552 ],
		[ 0.323374, 0.085912, 0.046478 ],
		[ 0.183384, 0.0608, 0.040071 ],
		[ 0.397475, 0.193481, 0.092979 ],
		[ 0.108552, 0.062046, 0.054763 ],
		[ 0.359375, 0.099789, 0.049417 ],
		[ 0.14949, 0.084218, 0.061951 ],
		[ 0.393651, 0.188798, 0.091003 ] ], "h1": [ 0.876079, 0.059603, 0.62252, 0.320085, 0.638071, 0.716123, 0.076709, 0.941728, 0.217577, 0.662735, 0.706131, 0.897991, 0.140831, 0.040845, 0.152573, 0.639229, 0.241027, 0.353676, 0.7646, 0.961859, 0.910241, 0.49393, 0.874048, 0.952743 ], "h2": [ 0.912511, 0.403298, 0.864596, 0.056174, 0.925489, 0.250304, 0.281501, 0.09211, 0.627613, 0.977104, 0.077421, 0.784841, 0.448347, 0.481479, 0.676381, 0.003801, 0.641378, 0.606726, 0.127836, 0.811325, 0.164535, 0.451495, 0.503076, 0.895904 ] },
		{ "seed": 123456, "ids": [ 3, 40, 77, 114, 151, 188, 225, 262, 299, 336, 373, 410, 447, 484, 521, 558, 595, 632, 669, 706, 743, 780, 817, 854 ], "col": [
		[ 0.091515, 0.052818, 0.051771 ],
		[ 0.335175, 0.089565, 0.047307 ],
		[ 0.181628, 0.101625, 0.067594 ],
		[ 0.341292, 0.095727, 0.048377 ],
		[ 0.319347, 0.084665, 0.046195 ],
		[ 0.310274, 0.081856, 0.045558 ],
		[ 0.386978, 0.105991, 0.051005 ],
		[ 0.319215, 0.084624, 0.046186 ],
		[ 0.177866, 0.060245, 0.040723 ],
		[ 0.306262, 0.080614, 0.045276 ],
		[ 0.314326, 0.083111, 0.045842 ],
		[ 0.174693, 0.059925, 0.041098 ],
		[ 0.331039, 0.088284, 0.047017 ],
		[ 0.323346, 0.085903, 0.046476 ],
		[ 0.324566, 0.086281, 0.046562 ],
		[ 0.381404, 0.104739, 0.050684 ],
		[ 0.185065, 0.060969, 0.039872 ],
		[ 0.331758, 0.088507, 0.047067 ],
		[ 0.315764, 0.083556, 0.045943 ],
		[ 0.32076, 0.085102, 0.046294 ],
		[ 0.317947, 0.084232, 0.046097 ],
		[ 0.331689, 0.088486, 0.047062 ],
		[ 0.171925, 0.059647, 0.041425 ],
		[ 0.305875, 0.080495, 0.045249 ] ], "h1": [ 0.900162, 0.0812, 0.895426, 0.444935, 0.328101, 0.193341, 0.628091, 0.381613, 0.713972, 0.063355, 0.256609, 0.741445, 0.105209, 0.363063, 0.302977, 0.478134, 0.754707, 0.194813, 0.365125, 0.200825, 0.376859, 0.183212, 0.733448, 0.244798 ], "h2": [ 0.023643, 0.996131, 0.768845, 0.705063, 0.473851, 0.174456, 0.064433, 0.469481, 0.28682, 0.042045, 0.308153, 0.378232, 0.859648, 0.605784, 0.646049, 0.142587, 0.079389, 0.883366, 0.355594, 0.520476, 0.427635, 0.881094, 0.457987, 0.029292 ] } ],
	"weather": [
		{ "seed": 4242, "age": 0.8, "up": 0.25, "fr": 0.0, "P": [
		[ -1.114289, -0.002166, 0.304495 ],
		[ -1.413933, -1.056222, 1.284633 ],
		[ -1.288738, -1.110678, 1.344985 ],
		[ 0.365651, -0.393021, 0.03417 ],
		[ 0.488529, -0.674074, -1.086096 ],
		[ 0.864119, 0.511082, 0.037147 ],
		[ 0.950209, 0.147226, 1.442741 ],
		[ -0.886472, 0.161191, -0.049126 ],
		[ -0.440175, 0.274786, -0.794096 ],
		[ 0.906608, 1.102001, -1.113721 ],
		[ -0.09878, -0.668565, -1.250649 ],
		[ 1.187833, -0.210154, -1.056926 ],
		[ 0.520087, -0.893352, 1.204293 ],
		[ -0.848555, -1.400776, -0.897693 ],
		[ -0.462756, -0.093276, 1.218403 ],
		[ 0.592083, -0.482038, -1.449368 ] ], "col": [
		[ 0.373585, 0.367566, 0.363318 ],
		[ 0.395345, 0.390685, 0.387396 ],
		[ 0.383144, 0.377721, 0.373895 ],
		[ 0.384794, 0.379475, 0.375721 ],
		[ 0.384124, 0.378763, 0.37498 ],
		[ 0.372524, 0.366438, 0.362144 ],
		[ 0.374707, 0.368758, 0.36456 ],
		[ 0.384372, 0.377834, 0.372386 ],
		[ 0.368117, 0.361757, 0.357269 ],
		[ 0.387548, 0.382401, 0.378768 ],
		[ 0.355158, 0.347989, 0.34293 ],
		[ 0.378005, 0.372262, 0.368209 ],
		[ 0.399321, 0.394909, 0.391795 ],
		[ 0.401913, 0.396997, 0.393061 ],
		[ 0.39452, 0.389759, 0.386365 ],
		[ 0.352797, 0.34548, 0.340317 ] ] },
		{ "seed": 99, "age": 1.0, "up": 0.0, "fr": 0.3, "P": [
		[ -1.020529, 1.489308, -0.120852 ],
		[ 0.57312, -1.335996, -1.397849 ],
		[ 1.03767, 0.263646, -0.573871 ],
		[ -0.54787, -1.232288, -0.981991 ],
		[ -1.426242, 1.017375, -0.10109 ],
		[ -1.118391, 0.717741, -0.913042 ],
		[ -1.314239, 0.295176, 1.187273 ],
		[ -1.41917, 0.915408, -0.92949 ],
		[ -1.221296, -1.446114, -0.621075 ],
		[ 0.681335, -0.020463, 1.05876 ],
		[ -0.848366, -0.554452, -0.725577 ],
		[ 1.434903, 1.323018, -0.477941 ],
		[ -0.191995, -0.557041, 0.739527 ],
		[ -1.379961, -1.297683, -0.287887 ],
		[ -0.764718, 1.035675, 0.725421 ],
		[ 0.137382, 0.484427, 0.576837 ] ], "col": [
		[ 0.352203, 0.345161, 0.340192 ],
		[ 0.366999, 0.360881, 0.356563 ],
		[ 0.380986, 0.375741, 0.37204 ],
		[ 0.387199, 0.382342, 0.378915 ],
		[ 0.347924, 0.340615, 0.335458 ],
		[ 0.349285, 0.342062, 0.336964 ],
		[ 0.35701, 0.350269, 0.345511 ],
		[ 0.344371, 0.33684, 0.331526 ],
		[ 0.381215, 0.373953, 0.367404 ],
		[ 0.369903, 0.363966, 0.359777 ],
		[ 0.363633, 0.357305, 0.35284 ],
		[ 0.343365, 0.335721, 0.33029 ],
		[ 0.37254, 0.366768, 0.362695 ],
		[ 0.377876, 0.372437, 0.368599 ],
		[ 0.339402, 0.331562, 0.326029 ],
		[ 0.364592, 0.358324, 0.3539 ] ] } ],
	"paint": [
		{ "seed": 7, "mask": 0.8, "P": [
		[ 0.843164, 1.282508, -1.050794 ],
		[ 0.37839, -1.069136, -0.170607 ],
		[ 0.858854, 1.184093, 0.777684 ],
		[ -1.393775, -0.421764, -1.01083 ],
		[ 1.496407, -1.067954, -0.767057 ],
		[ -0.428341, -1.31734, 1.111155 ],
		[ 0.409084, -1.020755, -0.005194 ],
		[ -1.263991, 0.332939, -0.80501 ],
		[ -1.384083, -1.154287, 0.165788 ],
		[ 0.410942, -0.525598, 0.430357 ],
		[ -0.443802, -1.108023, -0.554369 ],
		[ -0.314195, 1.237917, -1.153019 ],
		[ -1.241508, 0.184506, 1.390178 ],
		[ 1.221765, 0.600732, -1.299748 ],
		[ 0.919204, 0.550124, -1.068209 ],
		[ -0.105169, -1.352032, 0.905628 ] ], "col": [
		[ 0.548174, 0.499551, 0.411915 ],
		[ 0.557711, 0.508053, 0.418553 ],
		[ 0.553904, 0.50466, 0.415903 ],
		[ 0.572287, 0.521048, 0.428697 ],
		[ 0.553294, 0.504116, 0.415479 ],
		[ 0.566324, 0.515732, 0.424547 ],
		[ 0.578947, 0.526985, 0.433332 ],
		[ 0.553135, 0.503974, 0.415368 ],
		[ 0.586628, 0.533833, 0.438678 ],
		[ 0.564115, 0.513763, 0.42301 ],
		[ 0.560856, 0.510857, 0.420741 ],
		[ 0.560378, 0.510431, 0.420409 ],
		[ 0.557988, 0.5083, 0.418745 ],
		[ 0.565032, 0.51458, 0.423648 ],
		[ 0.579653, 0.527615, 0.433823 ],
		[ 0.545073, 0.496786, 0.409757 ] ], "rough": 0.38, "w": 0.8 },
		{ "seed": 31, "mask": 0.3, "P": [
		[ 0.655903, 0.913884, 0.781247 ],
		[ -0.698227, 0.869222, -0.752488 ],
		[ -1.086314, -0.32883, -0.006479 ],
		[ -0.642534, 0.317349, 0.307511 ],
		[ -0.780547, 0.367702, -0.428241 ],
		[ 0.704069, -0.628746, 0.89638 ],
		[ -0.254669, 0.159721, 0.520039 ],
		[ 0.055132, -0.727146, 1.438145 ],
		[ -1.211834, -0.525229, 0.147337 ],
		[ -1.413899, -1.035261, 0.897793 ],
		[ 0.851443, 0.410899, 1.205399 ],
		[ 0.76657, -0.603647, 0.4346 ],
		[ -0.479753, 0.749533, -0.345619 ],
		[ -1.04027, 1.12937, 0.571216 ],
		[ 0.734036, 0.178794, 0.848825 ],
		[ -0.15638, 0.197379, -1.312309 ] ], "col": [
		[ 0.524271, 0.505364, 0.471287 ],
		[ 0.525957, 0.506867, 0.47246 ],
		[ 0.522501, 0.503786, 0.470055 ],
		[ 0.528828, 0.509427, 0.474459 ],
		[ 0.519372, 0.500997, 0.467878 ],
		[ 0.525523, 0.50648, 0.472158 ],
		[ 0.528822, 0.509421, 0.474454 ],
		[ 0.523226, 0.504432, 0.47056 ],
		[ 0.526464, 0.507319, 0.472813 ],
		[ 0.514807, 0.496926, 0.4647 ],
		[ 0.530762, 0.511151, 0.475805 ],
		[ 0.521435, 0.502835, 0.469313 ],
		[ 0.523793, 0.504938, 0.470955 ],
		[ 0.523725, 0.504878, 0.470907 ],
		[ 0.525363, 0.506337, 0.472047 ],
		[ 0.526243, 0.507122, 0.47266 ] ], "rough": 0.455, "w": 0.3 } ]
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
