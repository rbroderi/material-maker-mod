extends GutTest

# Tests the cost model used by automatic buffers (see design/hybrid_evaluator.md)

var saved_config : Dictionary = {}

func before_each() -> void:
	for k in [ "auto_buffer", "auto_buffer_min_gain", "auto_buffer_shader_budget" ]:
		saved_config[k] = mm_globals.get_config(k)
	mm_globals.set_config("auto_buffer", true)
	mm_globals.set_config("auto_buffer_min_gain", 2.0)
	mm_globals.set_config("auto_buffer_shader_budget", 4000.0)

func after_each() -> void:
	for k in saved_config.keys():
		mm_globals.set_config(k, saved_config[k])

func make_shader(model : Dictionary) -> MMGenShader:
	var shader : MMGenShader = MMGenShader.new()
	shader.set_shader_model(model)
	autofree(shader)
	return shader

func test_loop_estimates() -> void:
	assert_eq(MMGenShader.estimate_loop_iterations("return 1.0;"), 1.0)
	assert_eq(MMGenShader.estimate_loop_iterations("for (int i = 0; i < 8; ++i) {}"), 8.0)
	assert_eq(MMGenShader.estimate_loop_iterations("for (float i = -2.0; i <= 2.0; i += 1.0) {}"), 5.0)
	# Loops with bounds that are not constant use the default estimate
	assert_eq(MMGenShader.estimate_loop_iterations("for (int i = 0; i < $count; ++i) {}"), MMGenShader.DEFAULT_LOOP_ITERATIONS)

func test_cost_model_counts_samples() -> void:
	var shader : MMGenShader = make_shader({
		inputs=[ { name="in", type="rgba", function=true, default="vec4(0.0)" }, { name="mask", type="f", default="1.0" } ],
		outputs=[ { rgba="$in($uv)*$mask($uv)+$in($uv*2.0)", type="rgba" } ],
		parameters=[], code="", instance=""
	})
	var model : Dictionary = shader.get_cost_model()
	assert_eq(model.samples, [ 2.0, 1.0 ] as Array[float])
	assert_gt(model.cost, 1.0)

func test_function_inputs_in_loops_are_sampled_per_iteration() -> void:
	var shader : MMGenShader = make_shader({
		inputs=[ { name="in", type="rgba", function=true, default="vec4(0.0)" } ],
		outputs=[ { rgba="$(name)_blur($uv)", type="rgba" } ],
		instance="vec4 $(name)_blur(vec2 uv) { vec4 s = vec4(0.0); for (int i = 0; i < 25; ++i) { s += $in(uv+vec2(float(i))); } return s; }",
		parameters=[], code=""
	})
	assert_eq(shader.get_cost_model().samples[0], 25.0)

func test_decisions() -> void:
	var shader : MMGenShader = make_shader({
		inputs=[ { name="in", type="rgba", function=true, default="vec4(0.0)" }, { name="sdf", type="sdf2d", default="0.0" } ],
		outputs=[ { rgba="$in($uv)", type="rgba" } ],
		parameters=[], code="", instance=""
	})
	# Sampling an expensive source many times is buffered
	assert_true(shader.should_auto_buffer(0, 4000.0, 8.0))
	# Sampling it once is not, unless it exceeds the shader budget
	assert_false(shader.should_auto_buffer(0, 4000.0, 1.0))
	assert_true(shader.should_auto_buffer(0, 5000.0, 1.0))
	# Cheap sources are never buffered
	assert_false(shader.should_auto_buffer(0, 3.0, 8.0))
	# Only image inputs can be buffered
	assert_false(shader.should_auto_buffer(1, 100000.0, 8.0))
	# Automatic buffers can be disabled
	mm_globals.set_config("auto_buffer", false)
	assert_false(shader.should_auto_buffer(0, 1000.0, 8.0))

func test_inputs_read_through_attributes_are_not_buffered() -> void:
	var shader : MMGenShader = make_shader({
		inputs=[ { name="in", type="rgba", function=true, default="vec4(0.0)" } ],
		outputs=[ { rgba="$(name)_blur($uv)", type="rgba" } ],
		instance="vec4 $(name)_blur(vec2 uv) {\nreturn textureLod($in.texture, uv, 2.0)+$in(uv);\n}",
		parameters=[], code=""
	})
	assert_true(shader.uses_input_attributes("in"))
	# $in.texture is the source's own texture, that a buffer would replace
	assert_false(shader.should_auto_buffer(0, 100000.0, 64.0))

func test_size_parameter_sets_buffer_size() -> void:
	var shader : MMGenShader = make_shader({
		inputs=[ { name="in", type="rgba", function=true, default="vec4(0.0)" } ],
		outputs=[ { rgba="$in($uv)", type="rgba" } ],
		parameters=[ { name="size", type="size", first=4, last=12, default=8 } ], code="", instance=""
	})
	shader.set_parameter("size", 9)
	assert_eq(shader.get_auto_buffer_size(), 9)
	var plain : MMGenShader = make_shader({ inputs=[], outputs=[ { rgba="vec4(1.0)", type="rgba" } ], parameters=[], code="", instance="" })
	assert_eq(plain.get_auto_buffer_size(), int(mm_globals.get_config("auto_buffer_size")))
