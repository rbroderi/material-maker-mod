extends GutTest


# Tests of the sd_rand plugin. The plugin is enabled before each test and
# disabled after it.


const PLUGIN_SCRIPT : String = "res://material_maker/plugins/sd_rand/plugin.gd"
const VARIABLES : Dictionary = { pos="uv", size="vec2(512.0)", seed="0.5" }

var plugin : MMPlugin = null


func enable_plugin() -> void:
	plugin = load(PLUGIN_SCRIPT).new()
	var api : MMPlugins.API = MMPlugins.API.new()
	api.plugin_id = "sd_rand"
	api.plugin_path = PLUGIN_SCRIPT.get_base_dir()
	plugin._enable(api)

func disable_plugin() -> void:
	if plugin != null:
		plugin._disable()
		plugin = null

func before_each() -> void:
	enable_plugin()

func after_each() -> void:
	disable_plugin()

func compile(nodes : Dictionary, output : String, variables : Dictionary = VARIABLES, extra : Dictionary = {}) -> Dictionary:
	var graph : Dictionary = { nodes=nodes, output=output }
	graph.merge(extra)
	return MMFunctionGraph.compile(graph, [], {}, variables)

func test_pixel_mode() -> void:
	var r : Dictionary = compile({ one={ op="float", value=1 }, a={ op="sd_rand", a="one" }, b={ op="sd_rand", a="one" }, out={ op="add", a="a", b="b" } }, "out")
	assert_true(r.ok, str(r.errors))
	var code : String = "\n".join(r.code)
	# The state is initialized once, from the node's seed, and advanced by each call
	assert_eq(code.count("uint fg_rng = mm_sd_rand_init(uint(fract(0.5)*16777216.0), uv);"), 1)
	assert_eq(code.count("fg_rng = fg_rng*1228363579u+51137u;"), 2)
	assert_eq(r.globals.size(), 1)
	assert_string_contains(r.globals[0], "uint mm_sd_rand_init(uint seed, vec2 pos)")

func test_value_mode() -> void:
	var variables : Dictionary = VARIABLES.duplicate()
	variables.mode = "value"
	variables.sd_seed = "5u"
	var r : Dictionary = compile({ one={ op="float", value=1 }, out={ op="sd_rand", a="one" } }, "out", variables)
	assert_true(r.ok, str(r.errors))
	assert_string_contains("\n".join(r.code), "uint fg_rng = 5u;")
	assert_string_contains("\n".join(r.code), "2147001325u+715136305u")
	assert_eq(r.globals.size(), 0)

func test_graph_random_seed() -> void:
	var r : Dictionary = compile({ one={ op="float", value=1 }, out={ op="sd_rand", a="one" } }, "out", VARIABLES, { random_seed=4294967297 })
	assert_true(r.ok, str(r.errors))
	assert_string_contains("\n".join(r.code), "uint fg_rng = mm_sd_rand_init(1u, uv);")

func test_amplitude_must_be_a_float() -> void:
	var r : Dictionary = compile({ v={ op="vec2", value=[ 1, 1 ] }, out={ op="sd_rand", a="v" } }, "out")
	assert_false(r.ok)
	assert_eq(r.node_errors.get("out"), "sd_rand requires a float amplitude")

func test_not_in_sub_functions() -> void:
	var graph : Dictionary = {
		functions={ f={ params=[], nodes={ one={ op="float", value=1 }, out={ op="sd_rand", a="one" } }, output="out" } },
		nodes={ out={ op="call", function="f", args=[] } },
		output="out"
	}
	var r : Dictionary = MMFunctionGraph.compile(graph, [], {}, VARIABLES)
	assert_false(r.ok)
	assert_true(Array(r.errors).any(func(e : String): return e.contains("sd_rand is not supported in sub-functions")), str(r.errors))

func test_operand_is_a_dependency() -> void:
	# The amplitude is compiled before sd_rand even if it is declared after it
	var r : Dictionary = compile({ out={ op="sd_rand", a="zamp" }, zamp={ op="float", value=0.5 } }, "out")
	assert_true(r.ok, str(r.errors))

func test_enable_and_disable() -> void:
	assert_true("sd_rand" in MMFunctionGraph.get_operation_names())
	var nodes : Dictionary = { one={ op="float", value=1 }, out={ op="sd_rand", a="one" } }
	assert_true(compile(nodes, "out").ok)
	disable_plugin()
	assert_false("sd_rand" in MMFunctionGraph.get_operation_names())
	var r : Dictionary = compile(nodes, "out")
	assert_false(r.ok)
	assert_string_contains(str(r.node_errors.get("out")), "unknown operation sd_rand")
	# Pixel Processors that use it show the error
	var model : Dictionary = MMGenPixelProcessor.build_shader_model({ inputs=[], parameters=[], nodes=nodes, output="out" })
	assert_true(Array(model.errors).any(func(e : String): return e.contains("unknown operation sd_rand")), str(model.errors))
	enable_plugin()
	assert_true(compile(nodes, "out").ok)
