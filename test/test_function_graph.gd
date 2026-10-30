extends GutTest

const VARIABLES : Dictionary = { pos="uv", size="vec2(512.0)", seed="0.5" }

func compile(nodes : Dictionary, output : String, samples : Array = [ "$in(%s)" ], params : Dictionary = { k="$k" }) -> Dictionary:
	return MMFunctionGraph.compile({ nodes=nodes, output=output }, samples, params, VARIABLES)

func has_error_containing(result : Dictionary, text : String) -> bool:
	for e in result.errors:
		if e.find(text) != -1:
			return true
	return false

func test_sample_and_multiply() -> void:
	var r : Dictionary = compile({
		uv={ op="pos" },
		c={ op="sample", input=0, uv="uv" },
		k={ op="param", name="k" },
		out={ op="mul", a="c", b="k" }
	}, "out")
	assert_true(r.ok, str(r.errors))
	var code : String = "\n".join(r.code)
	assert_string_contains(code, "vec4 fg_1 = $in(fg_0);")
	# The float parameter is broadcast to the vec4 operand type
	assert_string_contains(code, "(fg_1*vec4(fg_2))")
	assert_eq(r.value, "fg_3")

func test_operands_are_ordered_before_use() -> void:
	var r : Dictionary = compile({
		out={ op="add", a="x", b="y" },
		y={ op="float", value=2 },
		x={ op="float", value=1 }
	}, "out")
	assert_true(r.ok, str(r.errors))
	assert_eq(r.code.size(), 3)
	assert_string_contains(r.code[2], "// out")

func test_float_output_is_broadcast_to_rgba() -> void:
	var r : Dictionary = compile({ out={ op="float", value=0.25 } }, "out")
	assert_true(r.ok)
	assert_eq(r.value, "vec4(vec3(fg_0), 1.0)")

func test_vec3_output_gets_alpha() -> void:
	var r : Dictionary = compile({ out={ op="vec3", value=[ 1, 0, 0 ] } }, "out")
	assert_true(r.ok)
	assert_eq(r.value, "vec4(fg_0, 1.0)")

func test_vector_construction_from_parts() -> void:
	var r : Dictionary = compile({
		uv={ op="pos" },
		z={ op="float", value=0.5 },
		out={ op="vec4", args=[ "uv", "z", "z" ] }
	}, "out")
	assert_true(r.ok, str(r.errors))
	assert_string_contains(r.code[2], "vec4(fg_0, fg_1, fg_1)")

func test_wrong_component_count_is_rejected() -> void:
	var r : Dictionary = compile({
		uv={ op="pos" },
		out={ op="vec4", args=[ "uv", "uv", "uv" ] }
	}, "out")
	assert_false(r.ok)
	assert_true(has_error_containing(r, "4 components expected"))

func test_swizzle() -> void:
	var r : Dictionary = compile({
		uv={ op="pos" },
		c={ op="sample", input=0, uv="uv" },
		out={ op="swizzle", a="c", components="bgr" }
	}, "out")
	assert_true(r.ok, str(r.errors))
	assert_string_contains(r.code[2], "vec3 fg_2 = fg_1.bgr;")

func test_invalid_swizzles_are_rejected() -> void:
	var uv : Dictionary = { op="pos" }
	assert_false(compile({ uv=uv, out={ op="swizzle", a="uv", components="xyz" } }, "out").ok)
	assert_false(compile({ uv=uv, out={ op="swizzle", a="uv", components="xg" } }, "out").ok)
	assert_false(compile({ f={ op="float", value=1 }, out={ op="swizzle", a="f", components="x" } }, "out").ok)

func test_incompatible_vector_types_are_rejected() -> void:
	var r : Dictionary = compile({
		uv={ op="pos" },
		v={ op="vec3", value=[ 1, 2, 3 ] },
		out={ op="add", a="uv", b="v" }
	}, "out")
	assert_false(r.ok)
	assert_true(has_error_containing(r, "incompatible types vec2 and vec3"))

func test_select_and_comparison() -> void:
	var r : Dictionary = compile({
		uv={ op="pos" },
		x={ op="swizzle", a="uv", components="x" },
		half={ op="float", value=0.5 },
		cond={ op="gt", a="x", b="half" },
		red={ op="vec3", value=[ 1, 0, 0 ] },
		out={ op="select", cond="cond", a="red", b="half" }
	}, "out")
	assert_true(r.ok, str(r.errors))
	assert_string_contains("\n".join(r.code), "(fg_3 ? fg_4 : vec3(fg_2))")

func test_select_requires_boolean_condition() -> void:
	var r : Dictionary = compile({
		f={ op="float", value=1 },
		out={ op="select", cond="f", a="f", b="f" }
	}, "out")
	assert_false(r.ok)
	assert_true(has_error_containing(r, "cond must be a boolean"))

func test_cycles_are_detected() -> void:
	var r : Dictionary = compile({
		a={ op="add", a="b", b="b" },
		b={ op="neg", a="a" }
	}, "a")
	assert_false(r.ok)
	assert_true(has_error_containing(r, "cycle detected"))

func test_dangling_references_are_detected() -> void:
	var r : Dictionary = compile({ out={ op="abs", a="missing" } }, "out")
	assert_false(r.ok)
	assert_true(has_error_containing(r, "missing: node not found"))

func test_unknown_operations_are_rejected() -> void:
	var r : Dictionary = compile({ out={ op="teleport" } }, "out")
	assert_false(r.ok)
	assert_true(has_error_containing(r, "unknown operation teleport"))

func test_invalid_input_index_is_rejected() -> void:
	var r : Dictionary = compile({ uv={ op="pos" }, out={ op="sample", input=3, uv="uv" } }, "out")
	assert_false(r.ok)
	assert_true(has_error_containing(r, "invalid input 3"))

func test_unknown_parameter_is_rejected() -> void:
	var r : Dictionary = compile({ out={ op="param", name="nope" } }, "out")
	assert_false(r.ok)
	assert_true(has_error_containing(r, "unknown parameter nope"))

func test_boolean_output_is_rejected() -> void:
	var r : Dictionary = compile({ out={ op="true" } }, "out")
	assert_false(r.ok)

func test_rand_uses_seed_and_integer_hash() -> void:
	var r : Dictionary = compile({ uv={ op="pos" }, out={ op="rand", a="uv" } }, "out")
	assert_true(r.ok, str(r.errors))
	assert_string_contains(r.code[1], "mm_fg_rand(fg_0, 0.5)")
	assert_eq(r.globals, PackedStringArray([ MMFunctionGraph.RAND_GLOBAL ]))
	assert_string_contains(r.globals[0], "floatBitsToUint")

func test_globals_are_declared_once() -> void:
	var r : Dictionary = compile({
		uv={ op="pos" },
		a={ op="rand", a="uv" },
		half={ op="float", value=0.5 },
		uv2={ op="mul", a="uv", b="half" },
		b={ op="rand", a="uv2" },
		out={ op="add", a="a", b="b" }
	}, "out")
	assert_true(r.ok, str(r.errors))
	assert_eq(r.globals.size(), 1)

func test_graphs_without_globals() -> void:
	var r : Dictionary = compile({ uv={ op="pos" }, out={ op="length", a="uv" } }, "out")
	assert_true(r.ok, str(r.errors))
	assert_true(r.globals.is_empty())

func test_node_ids_are_sanitized_in_comments() -> void:
	var r : Dictionary = compile({ "$evil": { op="float", value=1 } }, "$evil")
	assert_true(r.ok, str(r.errors))
	assert_eq(r.code[0].find("$"), -1)

func test_pixel_processor_default_graph_builds() -> void:
	var r : Dictionary = MMGenPixelProcessor.build_shader_model(MMGenPixelProcessor.DEFAULT_FUNCTION_GRAPH.duplicate(true))
	assert_true(r.errors.is_empty(), str(r.errors))
	assert_eq(r.model.inputs.size(), 1)
	assert_true(r.model.inputs[0].function)
	assert_eq(r.model.parameters[0].name, "amount")
	assert_string_contains(r.model.instance, "vec4 $(name)_pp(vec2 uv) {")
	assert_string_contains(r.model.instance, "$in(fg_0)")

func test_pixel_processor_adds_size_parameter_when_used() -> void:
	var graph : Dictionary = { inputs=[], parameters=[], nodes={ s={ op="size" }, out={ op="swizzle", a="s", components="x" } }, output="out" }
	var r : Dictionary = MMGenPixelProcessor.build_shader_model(graph)
	assert_true(r.errors.is_empty(), str(r.errors))
	assert_eq(r.model.parameters[-1].name, "size")
	assert_string_contains(r.model.instance, "vec2($size)")

func test_pixel_processor_rejects_bad_names() -> void:
	var graph : Dictionary = { inputs=[ { name="uv" }, { name="a" } ], parameters=[ { name="a" } ], nodes={ out={ op="float", value=1 } }, output="out" }
	var r : Dictionary = MMGenPixelProcessor.build_shader_model(graph)
	assert_eq(r.errors.size(), 2, str(r.errors))

# IR v2: integers, sub-functions, loops, Substance-compatible rand,
# parameter functions

func test_integers() -> void:
	var r : Dictionary = compile({
		a={ op="int", value=7 },
		b={ op="int", value=2 },
		m={ op="mod", a="a", b="b" },
		f={ op="to_float", a="m" },
		out={ op="mul", a="f", b="half" },
		half={ op="float", value=0.5 }
	}, "out")
	assert_true(r.ok, str(r.errors))
	var code : String = "\n".join(r.code)
	# Integer modulo wraps negative values like mod() (GLSL's % does not)
	assert_string_contains(code, "int fg_2 = mm_fg_mod(fg_0, fg_1);")
	assert_string_contains(code, "float fg_3 = float(fg_2);")
	assert_eq(r.globals, PackedStringArray([ MMFunctionGraph.MOD_GLOBAL ]))

func test_float_modulo_needs_no_global() -> void:
	var r : Dictionary = compile({ a={ op="float", value=7 }, b={ op="float", value=2 }, out={ op="mod", a="a", b="b" } }, "out")
	assert_true(r.ok, str(r.errors))
	assert_string_contains(r.code[2], "mod(fg_0, fg_1)")
	assert_true(r.globals.is_empty())

func test_mixing_int_and_float_is_rejected() -> void:
	var r : Dictionary = compile({ a={ op="int", value=1 }, b={ op="float", value=1 }, out={ op="add", a="a", b="b" } }, "out")
	assert_false(r.ok)
	assert_true(has_error_containing(r, "use to_float"))
	assert_true(r.node_errors.has("out"))

func test_int_output_is_converted() -> void:
	var r : Dictionary = compile({ out={ op="int", value=3 } }, "out")
	assert_true(r.ok)
	assert_eq(r.value, "vec4(vec3(float(fg_0)), 1.0)")

func test_sub_function_call() -> void:
	var graph : Dictionary = {
		functions={
			brighten={ params=[ { name="c", type="vec4" }, { name="k", type="float" } ],
				nodes={ c={ op="arg", name="c" }, k={ op="arg", name="k" }, out={ op="mul", a="c", b="k" } }, output="out" }
		},
		nodes={ uv={ op="pos" }, c={ op="sample", input=0, uv="uv" }, k={ op="float", value=2 }, out={ op="call", function="brighten", args=[ "c", "k" ] } },
		output="out"
	}
	var r : Dictionary = MMFunctionGraph.compile(graph, [ "$in(%s)" ], {}, VARIABLES)
	assert_true(r.ok, str(r.errors))
	assert_eq(r.functions.size(), 1)
	assert_string_contains(r.functions[0], "vec4 fg_function_brighten(vec2 uv, vec4 fa_c, float fa_k) {")
	assert_string_contains("\n".join(r.code), "fg_function_brighten(uv, fg_1, fg_2)")

func test_call_argument_types_are_checked() -> void:
	var graph : Dictionary = {
		functions={ f={ params=[ { name="x", type="vec2" } ], nodes={ out={ op="arg", name="x" } }, output="out" } },
		nodes={ k={ op="float", value=2 }, out={ op="call", function="f", args=[ "k" ] } },
		output="out"
	}
	var r : Dictionary = MMFunctionGraph.compile(graph, [], {}, VARIABLES)
	assert_false(r.ok)
	assert_true(has_error_containing(r, "argument x must be a vec2"))

func test_recursion_is_rejected() -> void:
	var graph : Dictionary = {
		functions={ f={ params=[ { name="x", type="float" } ], nodes={ x={ op="arg", name="x" }, out={ op="call", function="f", args=[ "x" ] } }, output="out" } },
		nodes={ k={ op="float", value=2 }, out={ op="call", function="f", args=[ "k" ] } },
		output="out"
	}
	var r : Dictionary = MMFunctionGraph.compile(graph, [], {}, VARIABLES)
	assert_false(r.ok)
	assert_true(has_error_containing(r, "recursion is not supported"))

func test_loop() -> void:
	var graph : Dictionary = {
		functions={ step={ params=[ { name="acc", type="float" }, { name="i", type="int" } ],
			nodes={ acc={ op="arg", name="acc" }, i={ op="arg", name="i" }, f={ op="to_float", a="i" }, out={ op="add", a="acc", b="f" } }, output="out" } },
		nodes={ zero={ op="float", value=0 }, out={ op="loop", function="step", count=4, init="zero" } },
		output="out"
	}
	var r : Dictionary = MMFunctionGraph.compile(graph, [], {}, VARIABLES)
	assert_true(r.ok, str(r.errors))
	var code : String = "\n".join(r.code)
	assert_string_contains(code, "for (int fg_i = 0; fg_i < 4; ++fg_i) { fg_loop_1 = fg_function_step(uv, fg_loop_1, fg_i); }")

func test_loop_signature_is_checked() -> void:
	var graph : Dictionary = {
		functions={ step={ params=[ { name="acc", type="vec2" }, { name="i", type="int" } ], nodes={ out={ op="arg", name="acc" } }, output="out" } },
		nodes={ zero={ op="float", value=0 }, out={ op="loop", function="step", count=4, init="zero" } },
		output="out"
	}
	assert_false(MMFunctionGraph.compile(graph, [], {}, VARIABLES).ok)

func test_sub_function_globals_are_returned() -> void:
	var graph : Dictionary = {
		functions={ noise={ params=[ { name="p", type="vec2" } ], nodes={ p={ op="arg", name="p" }, out={ op="rand", a="p" } }, output="out" } },
		nodes={ uv={ op="pos" }, a={ op="call", function="noise", args=[ "uv" ] }, b={ op="rand", a="uv" }, out={ op="add", a="a", b="b" } },
		output="out"
	}
	var r : Dictionary = MMFunctionGraph.compile(graph, [], {}, VARIABLES)
	assert_true(r.ok, str(r.errors))
	assert_eq(r.globals.size(), 1)
	assert_string_contains(r.functions[0], "mm_fg_rand(fg_0, 0.5)")

func test_pixel_processor_returns_globals() -> void:
	var graph : Dictionary = { inputs=[], parameters=[], nodes={ uv={ op="pos" }, out={ op="rand", a="uv" } }, output="out" }
	var r : Dictionary = MMGenPixelProcessor.build_shader_model(graph)
	assert_true(r.errors.is_empty(), str(r.errors))
	assert_eq(r.globals, PackedStringArray([ MMFunctionGraph.RAND_GLOBAL ]))
	assert_false(r.model.has("global"))
	assert_string_contains(r.model.instance, "mm_fg_rand(fg_0, $seed)")

func test_compile_expression_rejects_globals() -> void:
	# Integer modulo needs a global function, that an expression can't declare
	var graph : Dictionary = { nodes={ a={ op="int", value=7 }, b={ op="int", value=3 }, m={ op="mod", a="a", b="b" }, out={ op="to_float", a="m" } }, output="out" }
	assert_false(MMFunctionGraph.compile_expression(graph, {}).ok)

# An operation added by a plugin: twice(a), with a helper global
const TWICE_GLOBAL : String = "float mm_test_twice(float x) { return x*2.0; }\n"

static func compile_twice(compiler : MMFunctionGraph.Compiler, node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
	if compiler.types[node.a] != "float":
		compiler.error(node_id, "twice requires a float")
		return ""
	compiler.types[node_id] = "float"
	return "mm_test_twice(%s)" % compiler.value_of(node.a)

func test_plugin_operations() -> void:
	var api : MMPlugins.API = MMPlugins.API.new()
	api.plugin_id = "test_plugin"
	api.add_function_graph_op("test_twice", [ "a" ], compile_twice, [ TWICE_GLOBAL ])
	# Existing operations cannot be replaced
	assert_false(MMFunctionGraph.add_operation("add", [ "a" ], compile_twice))
	assert_false(MMFunctionGraph.add_operation("rand", [ "a" ], compile_twice))
	assert_false(MMFunctionGraph.add_operation("test_twice", [ "a" ], compile_twice))
	api.add_function_graph_op("add", [ "a" ], compile_twice)
	assert_push_error("cannot add function graph operation add")
	assert_true("test_twice" in MMFunctionGraph.get_operation_names())
	assert_eq(MMFunctionGraph.get_operation("test_twice").operands, [ "a" ])
	assert_true(MMFunctionGraph.is_plugin_operation("test_twice"))
	assert_false(MMFunctionGraph.is_plugin_operation("rand"))
	# Used in the main graph (twice, the second one's operand declared after
	# it) and in a sub-function
	var graph : Dictionary = {
		functions={ f={ params=[ { name="x", type="float" } ], nodes={ x={ op="arg", name="x" }, out={ op="test_twice", a="x" } }, output="out" } },
		nodes={ one={ op="float", value=1 }, a={ op="test_twice", a="one" }, out={ op="test_twice", a="z" }, z={ op="call", function="f", args=[ "a" ] } },
		output="out"
	}
	var r : Dictionary = MMFunctionGraph.compile(graph, [], {}, VARIABLES)
	assert_true(r.ok, str(r.errors))
	assert_eq(r.types.out, "float")
	assert_string_contains("\n".join(r.code), "float fg_1 = mm_test_twice(fg_0); // a")
	assert_string_contains(r.functions[0], "float fg_1 = mm_test_twice(fg_0); // out")
	# The global is added once, although the operation is used 3 times
	assert_eq(r.globals, PackedStringArray([ TWICE_GLOBAL ]))
	# Pixel Processors declare it as a global
	var model : Dictionary = MMGenPixelProcessor.build_shader_model({ inputs=[], parameters=[], nodes=graph.nodes, functions=graph.functions, output="out" })
	assert_true(model.errors.is_empty(), str(model.errors))
	assert_eq(model.globals, PackedStringArray([ TWICE_GLOBAL ]))
	# Errors reported by the operation
	r = compile({ v={ op="vec2", value=[ 1, 1 ] }, out={ op="test_twice", a="v" } }, "out")
	assert_false(r.ok)
	assert_eq(r.node_errors.get("out"), "twice requires a float")
	# Not available in parameter functions
	assert_false(MMFunctionGraph.compile_expression({ nodes={ one={ op="float", value=1 }, out={ op="test_twice", a="one" } }, output="out" }, {}).ok)
	# Unregistered (as when the plugin is not enabled): graphs that use it
	# show an error
	MMFunctionGraph.remove_plugin_operations("test_plugin")
	assert_false("test_twice" in MMFunctionGraph.get_operation_names())
	assert_true(MMFunctionGraph.get_operation("test_twice").is_empty())
	r = MMFunctionGraph.compile(graph, [], {}, VARIABLES)
	assert_false(r.ok)
	assert_true(has_error_containing(r, "unknown operation test_twice"), str(r.errors))
	# Built-in operations are kept
	MMFunctionGraph.remove_plugin_operations()
	assert_false(MMFunctionGraph.get_operation("rand").is_empty())

func test_plugin_registrations_are_cleared() -> void:
	MMFunctionGraph.add_operation("test_twice", [ "a" ], compile_twice, [], "test_plugin")
	MMPlugins.clear_registrations()
	assert_true(MMFunctionGraph.get_operation("test_twice").is_empty())

func test_graph_with_unknown_operation_is_kept() -> void:
	# e.g. a graph that needs a plugin that is not enabled
	var graph : Dictionary = { version=2, inputs=[ { name="src", label="Source" } ], parameters=[ { name="k", label="K", min=0.0, max=1.0, default=0.5 } ],
		nodes={ k={ op="param", name="k" }, out={ op="not_available", a="k" } }, output="out" }
	var pixel_processor : MMGenPixelProcessor = MMGenPixelProcessor.new()
	pixel_processor._deserialize({ function_graph=graph.duplicate(true) })
	assert_push_error("unknown operation not_available")
	assert_eq(pixel_processor.function_graph, graph)
	assert_eq(pixel_processor.get_input_defs().map(func(i): return i.name), [ "src" ])
	assert_true(pixel_processor.get_parameter_defs().any(func(p): return p.name == "k"))
	assert_eq(pixel_processor._serialize({}).function_graph, graph)
	pixel_processor.free()

func test_compile_expression() -> void:
	var graph : Dictionary = { nodes={ s={ op="param", name="speed" }, two={ op="float", value=2 }, out={ op="mul", a="s", b="two" } }, output="out" }
	var r : Dictionary = MMFunctionGraph.compile_expression(graph, { speed="$speed" })
	assert_true(r.ok, str(r.errors))
	assert_eq(r.expression, "($speed*2.000000000)")

func test_compile_expression_parenthesizes_operands() -> void:
	var graph : Dictionary = { nodes={
		s={ op="param", name="speed" }, m={ op="float", value=-1 }, sum={ op="add", a="s", b="m" },
		two={ op="float", value=2 }, prod={ op="mul", a="sum", b="two" }, out={ op="sin", a="prod" } }, output="out" }
	var r : Dictionary = MMFunctionGraph.compile_expression(graph, { speed="$speed" })
	assert_true(r.ok, str(r.errors))
	assert_eq(r.expression, "sin((($speed+(-1.000000000))*2.000000000))")

func test_compile_expression_rejects_pixel_operations() -> void:
	var r : Dictionary = MMFunctionGraph.compile_expression({ nodes={ p={ op="pos" }, out={ op="swizzle", a="p", components="x" } }, output="out" }, {})
	assert_false(r.ok)

func test_compile_expression_requires_a_float_output() -> void:
	var r : Dictionary = MMFunctionGraph.compile_expression({ nodes={ out={ op="vec2", value=[ 1, 2 ] } }, output="out" }, {})
	assert_false(r.ok)
	r = MMFunctionGraph.compile_expression({ nodes={ out={ op="int", value=1 } }, output="out" }, {})
	assert_false(r.ok)

func test_replace_word() -> void:
	assert_eq(MMFunctionGraph.replace_word("fg_1+fg_10*fg_1", "fg_1", "($x)"), "($x)+fg_10*($x)")

func test_value_processor_rejects_position() -> void:
	var graph : Dictionary = { inputs=[], parameters=[], nodes={ p={ op="pos" }, out={ op="swizzle", a="p", components="x" } }, output="out" }
	var r : Dictionary = MMGenPixelProcessor.build_shader_model(graph, "value")
	assert_false(r.errors.is_empty())
