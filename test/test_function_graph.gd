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

func test_rand_uses_seed() -> void:
	var r : Dictionary = compile({ uv={ op="pos" }, out={ op="rand", a="uv" } }, "out")
	assert_true(r.ok, str(r.errors))
	assert_string_contains(r.code[1], "rand(fg_0+vec2(0.5))")

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
