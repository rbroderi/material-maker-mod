extends GutTest

const MMGraphCost = preload("res://material_maker/plugins/graph_cost/graph_cost.gd")

func make_graph(node : Dictionary) -> MMGenBase:
	var graph : MMGenBase = await mm_loader.create_gen({
		nodes=[ node, { name="Material", type="material", parameters={ size=10 } } ],
		connections=[]
	})
	add_child_autofree(graph)
	return graph

func test_loop_calling_function_of_known_weight() -> void:
	# w(): 2 multiplications and 1 addition (3), a call to sin (8), a call to
	# floor (2) = 13. The loop has 4 iterations, and each iteration adds 1
	# (the addition of the argument) to the cost of w().
	var code : String = """
	float w(float x) {
		float a = x*x*x;
		return a + sin(a) + floor(a);
	}
	float f(float x) {
		float r = 0.0;
		for (int i = 0; i < 4; ++i) {
			r += w(x+1.0);
		}
		return r;
	}
	"""
	var r : Dictionary = MMGraphCost.estimate_glsl(code, "f")
	# w = 2 (x*x*x) + 1 (a + sin) + 8 (sin) + 1 (+ floor) + 2 (floor) = 14
	assert_eq(r.by_function.w, 14)
	# Per iteration: r += (1), x+1.0 (1), w (14) = 16
	assert_eq(r.instructions, 64)
	assert_eq(r.loops_unbounded, 0)
	assert_eq(r.texture_samples, 0)

func test_unknown_bound_and_textures() -> void:
	var code : String = """
	vec4 g(sampler2D s, vec2 uv, int n) {
		vec4 c = vec4(0.0);
		for (int i = 0; i < n; ++i) { c += texture(s, uv); }
		return c;
	}
	"""
	var r : Dictionary = MMGraphCost.estimate_glsl(code, "g")
	assert_eq(r.loops_unbounded, 1)
	assert_eq(r.texture_samples, 4)
	assert_eq(r.instructions, 4*(20+1))

func test_loop_bound_from_call_site_argument() -> void:
	var code : String = """
	float h(int n) { float s = 0.0; for (int i = 0; i < n; i++) { s += 1.0; } return s; }
	float a() { return h(3); }
	float b() { return h(6); }
	"""
	assert_eq(MMGraphCost.estimate_glsl(code, "a").instructions, 3)
	assert_eq(MMGraphCost.estimate_glsl(code, "b").instructions, 6)

func test_perlin_iterations_increase_cost() -> void:
	var low : MMGenBase = await make_graph({ name="perlin", type="perlin", parameters={ iterations=3 } })
	var high : MMGenBase = await make_graph({ name="perlin", type="perlin", parameters={ iterations=6 } })
	var cost_low : Dictionary = MMGraphCost.estimate_output(low.get_node("perlin"), 0)
	var cost_high : Dictionary = MMGraphCost.estimate_output(high.get_node("perlin"), 0)
	assert_gt(cost_low.instructions, 0)
	assert_gt(cost_high.instructions, cost_low.instructions)
	assert_eq(cost_high.loops_unbounded, 0)

func test_lint_flags_sin_hash_nodes_only() -> void:
	var fbm : MMGenBase = await make_graph({ name="n", type="tex3d_fbm" })
	var warnings : Array = MMGraphCost.estimate_output(fbm.get_node("n"), 0).parity_warnings
	assert_gt(warnings.size(), 0, "tex3d_fbm hashes with sin")
	var plain : MMGenBase = await make_graph({ name="n", type="uniform" })
	var plain_cost : Dictionary = MMGraphCost.estimate_output(plain.get_node("n"), 0)
	assert_eq(plain_cost.parity_warnings.size(), 0)

func test_lint_unsafe_tokens() -> void:
	assert_eq(MMGraphCost.lint_parity("float f(float x) { return atan(x); }").size(), 1)
	assert_eq(MMGraphCost.lint_parity("float f(float x, float y) { return atan(x, y); }").size(), 0)
	assert_eq(MMGraphCost.lint_parity("void f() { mat3 m; }").size(), 1)
	assert_eq(MMGraphCost.lint_parity("float f(vec2 p) { return fract(sin(dot(p, vec2(1.0)))*4.0); }").size(), 1)

func test_material_cost() -> void:
	var graph : MMGenBase = await mm_loader.create_gen({
		nodes=[
			{ name="perlin", type="perlin", parameters={ iterations=3 } },
			{ name="Material", type="material", parameters={ size=10 } },
		],
		connections=[ { from="perlin", from_port=0, to="Material", to_port=0 } ]
	})
	add_child_autofree(graph)
	var r : Dictionary = MMGraphCost.estimate_material(graph.get_node("Material"))
	assert_gt(r.instructions, 0)
