extends GutTest

# Tests the cost model used by automatic buffers (MMGenShader.should_auto_buffer)

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
	shader.set_shader_model(model.duplicate(true))
	autofree(shader)
	return shader

const BLUR_MODEL : Dictionary = {
	name="blur",
	inputs=[ { name="in", type="rgba", function=true, default="vec4(0.0)" } ],
	outputs=[ { rgba="$(name_uv)_blur", type="rgba" } ],
	code="vec4 $(name_uv)_blur = vec4(0.0); for (int i = 0; i < 25; ++i) { $(name_uv)_blur += $in($uv+vec2(float(i))); }",
	parameters=[], instance=""
}

## A node whose code costs about cost units
func make_expensive_model(cost : int) -> Dictionary:
	return {
		name="expensive",
		inputs=[],
		outputs=[ { rgba="vec4(%s1.0%s)" % [ "sin(".repeat(cost), ")".repeat(cost) ], type="rgba" } ],
		parameters=[], code="", instance=""
	}

func add_to_graph(graph : MMGenGraph, generator : MMGenBase, generator_name : String) -> MMGenBase:
	generator.name = generator_name
	graph.add_generator(generator)
	return generator

func test_loop_estimates() -> void:
	assert_eq(MMGenShader.estimate_loop_iterations("return 1.0;"), 1.0)
	assert_eq(MMGenShader.estimate_loop_iterations("for (int i = 0; i < 8; ++i) {}"), 8.0)
	assert_eq(MMGenShader.estimate_loop_iterations("for (float i = -2.0; i <= 2.0; i += 1.0) {}"), 5.0)
	# Loops with bounds that are not constant use the default estimate
	assert_eq(MMGenShader.estimate_loop_iterations("for (int i = 0; i < $count; ++i) {}"), MMGenShader.DEFAULT_LOOP_ITERATIONS)

func test_cost_model_counts_samples() -> void:
	var shader : MMGenShader = make_shader({
		inputs=[ { name="in", type="rgba", function=true, default="vec4(0.0)" }, { name="mask", type="f", default="1.0" }, { name="in2", type="f", default="1.0" } ],
		outputs=[ { rgba="$in($uv)*$mask($uv)+$in($uv*2.0)*$in2($uv)", type="rgba" } ],
		parameters=[], code="", instance=""
	})
	var model : Dictionary = shader.get_cost_model()
	# $in2 is not counted as a sample of $in
	assert_eq(model.samples, [ 2.0, 1.0, 1.0 ] as Array[float])
	assert_gt(model.cost, 1.0)

func test_function_inputs_in_loops_are_sampled_per_iteration() -> void:
	var shader : MMGenShader = make_shader(BLUR_MODEL)
	assert_eq(shader.get_cost_model().samples[0], 25.0)

func test_decisions() -> void:
	var shader : MMGenShader = make_shader({
		inputs=[ { name="in", type="rgba", function=true, default="vec4(0.0)" }, { name="sdf", type="sdf2d", default="0.0" } ],
		outputs=[ { rgba="$in($uv)", type="rgba" } ],
		parameters=[], code="", instance=""
	})
	# Sampling an expensive source many times is buffered
	assert_true(shader.should_auto_buffer(0, 1000.0, 8.0))
	# Sampling it once is not, unless it exceeds the shader budget
	assert_false(shader.should_auto_buffer(0, 1000.0, 1.0))
	assert_true(shader.should_auto_buffer(0, 5000.0, 1.0))
	# Cheap sources are never buffered
	assert_false(shader.should_auto_buffer(0, 3.0, 8.0))
	# Only image inputs can be buffered
	assert_false(shader.should_auto_buffer(1, 100000.0, 8.0))
	# Automatic buffers can be disabled
	mm_globals.set_config("auto_buffer", false)
	assert_false(shader.should_auto_buffer(0, 1000.0, 8.0))

func test_inputs_read_through_attributes_or_variations_are_not_buffered() -> void:
	var shader : MMGenShader = make_shader({
		inputs=[ { name="in", type="rgba", function=true, default="vec4(0.0)" }, { name="tiles", type="rgba", function=true, default="vec4(0.0)" } ],
		outputs=[ { rgba="textureLod($in.texture, $uv, 2.0)+$in($uv)+$tiles.variation($uv, 0.5)", type="rgba" } ],
		parameters=[], code="", instance=""
	})
	assert_true(shader.uses_input_attributes(0))
	assert_true(shader.input_uses_variations(1))
	assert_false(shader.should_auto_buffer(0, 100000.0, 64.0))
	assert_false(shader.should_auto_buffer(1, 100000.0, 64.0))

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

func test_buffer_size_follows_the_nodes_downstream() -> void:
	var graph : MMGenGraph = MMGenGraph.new()
	autofree(graph)
	var blur : MMGenShader = add_to_graph(graph, make_shader(BLUR_MODEL), "blur")
	var sized : MMGenShader = add_to_graph(graph, make_shader({
		inputs=[ { name="in", type="rgba", default="vec4(0.0)" } ],
		outputs=[ { rgba="$in($uv)", type="rgba" } ],
		parameters=[ { name="size", type="size", first=4, last=12, default=11 } ], code="", instance=""
	}), "sized")
	# Without a size parameter downstream, the size set in the preferences is used
	assert_eq(blur.get_auto_buffer_size(), int(mm_globals.get_config("auto_buffer_size")))
	assert_true(graph.connect_children(blur, 0, sized, 0))
	sized.set_parameter("size", 11)
	assert_eq(blur.get_auto_buffer_size(), 11)

func test_graph_decisions_and_pins() -> void:
	var graph : MMGenGraph = MMGenGraph.new()
	autofree(graph)
	var source : MMGenShader = add_to_graph(graph, make_shader(make_expensive_model(200)), "source")
	var blur : MMGenShader = add_to_graph(graph, make_shader(BLUR_MODEL), "blur")
	assert_true(graph.connect_children(source, 0, blur, 0))
	var port : MMGenBase.OutputPort = blur.get_source(0)
	assert_gt(MMGenShader.estimate_cost(port, {}), 200.0)
	# An expensive source sampled 25 times is buffered
	assert_true(blur.is_input_auto_buffered(0, port))
	# The blur's own cost counts the buffered input as texture fetches
	assert_lt(MMGenShader.estimate_cost(MMGenBase.OutputPort.new(blur, 0), {}), 25.0*200.0)
	# Pins override the decision, and are kept with the connection
	graph.set_connection_buffer("blur", 0, "never")
	assert_eq(graph.get_connection_buffer("blur", 0), "never")
	assert_false(blur.is_input_auto_buffered(0, port))
	# "always" works even when automatic buffers are disabled
	mm_globals.set_config("auto_buffer", false)
	graph.set_connection_buffer("blur", 0, "always")
	assert_true(blur.is_input_auto_buffered(0, port))
	graph.set_connection_buffer("blur", 0, "")
	assert_false(blur.is_input_auto_buffered(0, port))
	assert_false(graph.serialize().connections[0].has("buffer"))

func test_cost_of_groups_includes_their_content() -> void:
	var graph : MMGenGraph = MMGenGraph.new()
	autofree(graph)
	var group : MMGenGraph = add_to_graph(graph, MMGenGraph.new(), "group")
	var outputs : MMGenIOs = MMGenIOs.new()
	outputs.ports = [ { name="out", type="rgba" } ]
	add_to_graph(group, outputs, "gen_outputs")
	var source : MMGenShader = add_to_graph(group, make_shader(make_expensive_model(300)), "source")
	assert_true(group.connect_children(source, 0, outputs, 0))
	assert_gt(MMGenShader.estimate_cost(MMGenBase.OutputPort.new(group, 0), {}), 300.0)

func test_pins_are_kept_when_grouping() -> void:
	var graph : MMGenGraph = MMGenGraph.new()
	autofree(graph)
	var source : MMGenShader = add_to_graph(graph, make_shader(make_expensive_model(200)), "source")
	var blur : MMGenShader = add_to_graph(graph, make_shader(BLUR_MODEL), "blur")
	var blur2 : MMGenShader = add_to_graph(graph, make_shader(BLUR_MODEL), "blur2")
	assert_true(graph.connect_children(source, 0, blur, 0))
	assert_true(graph.connect_children(blur, 0, blur2, 0))
	graph.set_connection_buffer("blur", 0, "always")
	graph.set_connection_buffer("blur2", 0, "never")
	# Grouping blur: its input comes from the group's inputs, and its output
	# goes out of the group
	var group : MMGenGraph = graph.create_subgraph([ blur ])
	assert_not_null(group)
	assert_eq(group.get_connection_buffer("blur", 0), "always")
	assert_eq(graph.get_connection_buffer("blur2", 0), "never")
	assert_eq(graph.get_connection_buffer(group.name, 0), "")
	assert_eq(blur.get_buffer_pin(0), "always")
	assert_eq(blur2.get_buffer_pin(0), "never")
	# Pins are saved with the grouped connections
	var data : Dictionary = graph.serialize()
	var pins : Array = []
	for n in data.nodes:
		if n.name == group.name:
			for c in n.connections:
				if c.has("buffer"):
					pins.append("%s.%d:%s" % [ c.to, c.to_port, c.buffer ])
	for c in data.connections:
		if c.has("buffer"):
			pins.append("%s.%d:%s" % [ c.to, c.to_port, c.buffer ])
	pins.sort()
	assert_eq(pins, [ "blur.0:always", "blur2.0:never" ])
