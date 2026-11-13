extends GutTest

# Tests of the 3D Buffer node (design/zcity_plan.md, WP9)

const NODE_TYPES : Array[String] = [ "tex3d_to_atlas", "tex3d_from_atlas", "tex3d_buffer" ]
const FORBIDDEN : String = "\\b(mat[234]|uvec[234]|lessThan|dFdx|texelFetch|textureSize)\\b"

# Random points in [-1, 2)^3 (the volume is periodic, so this also tests the wrapping)
const RANDOM_POINTS : String = """vec4 mm_pts(vec2 uv) {
	float idx = floor(uv.y*64.0)*64.0+floor(uv.x*64.0);
	vec3 r = fract(sin(vec3(idx*12.9898+1.0, idx*78.233+2.0, idx*37.719+3.0))*43758.5453);
	return vec4(r*3.0-vec3(1.0), 0.0);
}
"""

# Slice centre, texel centre points of the 128x128x256 layout (1 metre extent)
const CENTER_POINTS : String = """vec4 mm_pts(vec2 uv) {
	float idx = floor(uv.y*64.0)*64.0+floor(uv.x*64.0);
	float i = mod(idx*2.0, 128.0);
	float j = mod(floor(idx/64.0)*3.0, 128.0);
	float k = mod(idx*5.0, 256.0);
	return vec4((i+0.5)/128.0, (j+0.5)/128.0, (k+0.5)/256.0, 0.0);
}
"""

var graph : MMGenGraph

func after_each() -> void:
	if graph != null:
		graph.free()
		graph = null

func make_graph(nodes : Array, connections : Array = []) -> void:
	graph = await mm_loader.create_gen({ nodes=nodes, connections=connections })
	add_child(graph)

func buffer_graph(buffer_parameters : Dictionary = {}, noise_parameters : Dictionary = {}) -> void:
	var noise : Dictionary = { scale_x=4, scale_y=4, scale_z=4, period=4, seed_offset=3 }
	noise.merge(noise_parameters, true)
	await make_graph([
		{ name="noise", type="tex3d_noise_value", parameters=noise },
		{ name="buf", type="tex3d_buffer", parameters=buffer_parameters } ],
		[ { from="noise", from_port=0, to="buf", to_port=0 } ])

func spread(image : Image) -> float:
	var low : float = 1e9
	var high : float = -1e9
	for idx in 4096:
		var v : float = image.get_pixel(idx % 64, idx/64).r
		low = minf(low, v)
		high = maxf(high, v)
	return high-low

func gpu_available() -> bool:
	return RenderingServer.get_rendering_device() != null

func uniform_types(source : MMGenBase.ShaderCode) -> Array:
	var rv : Array = []
	for u in source.uniforms:
		rv.append(u.type)
	return rv

func all_text(source : MMGenBase.ShaderCode) -> String:
	return source.defs+source.code+source.get_globals_string()

# Renders the first output of a generator at the points of a point function (64x64 pixels)
func render_points(gen : MMGenBase, points : String) -> Image:
	# Buffers used by the output must be rendered first
	gen.get_shader_code("vec4(0.0)", 0, MMGenContext.new())
	await MMCliTools.wait_for_renders(gen.get_tree())
	var source : MMGenBase.ShaderCode = gen.get_shader_code("mm_pts(uv)", 0, MMGenContext.new())
	source.defs = points+source.defs
	source.output_values = { rgba="vec4(%s, 1.0)" % source.output_values["tex3d"] }
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

# ---- headless

func test_nodes_instantiate() -> void:
	for t in NODE_TYPES:
		await make_graph([ { name="n", type=t } ])
		var gen : MMGenBase = graph.get_node("n")
		assert_not_null(gen, t)
		if gen != null:
			assert_eq(gen.get_output_defs().size(), 1, t)
		graph.free()
		graph = null

func test_buffer_graph_structure() -> void:
	await buffer_graph()
	var gen : MMGenBase = graph.get_node("buf")
	assert_eq(gen.get_input_defs().size(), 1)
	assert_eq(gen.get_input_defs()[0].type, "tex3d")
	assert_eq(gen.get_output_defs()[0].type, "tex3d")
	var names : Array = []
	for d in gen.get_parameter_defs():
		names.append(d.name)
	assert_eq(names, [ "layout", "extent", "mode" ])
	assert_true(gen.get_node("atlas_buffer") is MMGenBuffer)
	assert_eq(int(gen.get_node("atlas_buffer").get_parameter("size")), 11)

func test_layout_configurations() -> void:
	await buffer_graph()
	var gen : MMGenBase = graph.get_node("buf")
	var expected_sizes : Array = [ 9, 10, 11, 12 ]
	for i in 4:
		gen.set_parameter("layout", i)
		assert_eq(int(gen.get_node("atlas_buffer").get_parameter("size")), expected_sizes[i], "buffer size of layout %d" % i)
		assert_eq(int(gen.get_node("to_atlas").get_parameter("layout")), i)
		assert_eq(int(gen.get_node("from_atlas").get_parameter("layout")), i)
	gen.set_parameter("extent", 2.5)
	assert_eq(gen.get_node("to_atlas").get_parameter("extent"), 2.5)
	assert_eq(gen.get_node("from_atlas").get_parameter("extent"), 2.5)

func test_generated_code_modes() -> void:
	var regex : RegEx = RegEx.new()
	regex.compile(FORBIDDEN)
	await buffer_graph({ mode=0 })
	var gen : MMGenBase = graph.get_node("buf")
	var baked : MMGenBase.ShaderCode = gen.get_shader_code("vec4(0.0)", 0, MMGenContext.new())
	assert_true("sampler2D" in uniform_types(baked), "Baked reads a texture")
	assert_eq(all_text(baked).find("$"), -1)
	assert_null(regex.search(all_text(baked)), "Baked code is in the HLSL safe subset")
	assert_ne(baked.code.find("textureLod("), -1, "Baked samples the atlas")
	gen.set_parameter("mode", 1)
	var direct : MMGenBase.ShaderCode = gen.get_shader_code("vec4(0.0)", 0, MMGenContext.new())
	assert_false("sampler2D" in uniform_types(direct), "Direct has no texture")
	assert_eq(direct.defs.find("texture("), -1)
	assert_eq(direct.code.find("texture("), -1)
	assert_ne(direct.code.find("mm_n3_value"), -1, "Direct evaluates the input")

# ---- GPU

func test_baked_matches_direct_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	await buffer_graph({ layout=2 })
	var buf : MMGenBase = graph.get_node("buf")
	var baked : Image = await render_points(buf, RANDOM_POINTS)
	var direct : Image = await render_points(graph.get_node("noise"), RANDOM_POINTS)
	assert_not_null(baked)
	assert_not_null(direct)
	if baked == null or direct == null:
		return
	var total : float = 0.0
	for idx in 4096:
		total += absf(baked.get_pixel(idx % 64, idx/64).r-direct.get_pixel(idx % 64, idx/64).r)
	gut.p("mean abs difference %f, direct value spread %f" % [ total/4096.0, spread(direct) ])
	assert_gt(spread(direct), 0.2, "the noise is not constant")
	assert_lt(total/4096.0, 0.01, "mean abs difference, 128x128x256, noise scale 4")

func test_exact_at_centres_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	await buffer_graph({ layout=2 })
	var baked : Image = await render_points(graph.get_node("buf"), CENTER_POINTS)
	var direct : Image = await render_points(graph.get_node("noise"), CENTER_POINTS)
	assert_not_null(baked)
	assert_not_null(direct)
	if baked == null or direct == null:
		return
	var max_diff : float = 0.0
	for idx in 4096:
		max_diff = maxf(max_diff, absf(baked.get_pixel(idx % 64, idx/64).r-direct.get_pixel(idx % 64, idx/64).r))
	gut.p("max difference at centres %f, direct value spread %f" % [ max_diff, spread(direct) ])
	assert_gt(spread(direct), 0.2, "the noise is not constant")
	assert_lt(max_diff, 1e-3, "slice-centre, texel-centre points")

func test_other_layouts_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	for layout in [ 0, 1, 3 ]:
		await buffer_graph({ layout=layout }, { scale_x=2, scale_y=2, scale_z=2, period=2 })
		graph.get_node("buf").set_parameter("layout", layout)
		var baked : Image = await render_points(graph.get_node("buf"), RANDOM_POINTS)
		var direct : Image = await render_points(graph.get_node("noise"), RANDOM_POINTS)
		assert_not_null(baked, "layout %d" % layout)
		assert_not_null(direct)
		if baked == null or direct == null:
			return
		var total : float = 0.0
		for idx in 4096:
			total += absf(baked.get_pixel(idx % 64, idx/64).r-direct.get_pixel(idx % 64, idx/64).r)
		assert_lt(total/4096.0, 0.02, "layout %d" % layout)
		graph.free()
		graph = null
