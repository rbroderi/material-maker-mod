extends MMPlugin


# Adds the sd_rand operation to function graphs (Pixel and Value Processors):
# Substance-compatible random numbers, implemented from the behavioral
# specification in sbsar2ptex's docs/random-generator.md (see README.md).
#
# Each evaluation owns a 32 bits state:
# - pixel processors start from a Jenkins one-at-a-time hash of the seed and
#   of the bit patterns of the pixel center position,
# - value processors start from the seed,
# and each sd_rand call advances it with an LCG, then uses bits 1-23 as the
# mantissa of a number in [0, 1), multiplied by the amplitude.


const OP_NAME : String = "sd_rand"
const PIXEL_LCG : String = "1228363579u+51137u" # 0x4937573B, 0xC7C1
const VALUE_LCG : String = "2147001325u+715136305u" # 0x7FF8A3ED, 0x2AA01D31
const STATE_DECLARATION : String = "uint fg_rng = "
const INIT_GLOBAL : String = """uint mm_sd_rand_init(uint seed, vec2 pos) {
	uint h = seed;
	h += h << 10u;
	h ^= h >> 6u;
	h += floatBitsToUint(pos.x);
	h += h << 10u;
	h ^= h >> 6u;
	h += floatBitsToUint(pos.y);
	h += h << 10u;
	h ^= h >> 6u;
	h += h << 3u;
	h ^= h >> 11u;
	h += h << 15u;
	return h;
}
"""

var plugin_id : String = ""


func _enable(api : MMPlugins.API) -> void:
	plugin_id = api.plugin_id
	api.add_function_graph_op(OP_NAME, [ "a" ], compile_sd_rand)

func _disable() -> void:
	MMFunctionGraph.remove_plugin_operations(plugin_id)

## The uint seed of the random state: the "sd_seed" variable if the caller
## gives one, the graph's integer random_seed if it has one (e.g. graphs
## translated from Substance), or the node's seed
static func get_seed(compiler : MMFunctionGraph.Compiler) -> String:
	if compiler.variables.has("sd_seed"):
		return compiler.variables.sd_seed
	var random_seed = compiler.graph.get("random_seed")
	if random_seed is int or random_seed is float:
		return "%du" % (int(random_seed) & 0xFFFFFFFF)
	return "uint(fract(%s)*16777216.0)" % compiler.variables.get("seed", "0.0")

## sd_rand(a): every call advances the random state, in dependency order
static func compile_sd_rand(compiler : MMFunctionGraph.Compiler, node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
	if compiler.types[node.a] != "float":
		compiler.error(node_id, "sd_rand requires a float amplitude")
		return ""
	if not compiler.args.is_empty() or compiler.context != "":
		compiler.error(node_id, "sd_rand is not supported in sub-functions")
		return ""
	var value_mode : bool = compiler.variables.get("mode", "pixel") == "value"
	# The state is declared before the first call
	if not Array(compiler.code).any(func(line : String): return line.begins_with(STATE_DECLARATION)):
		if value_mode:
			compiler.code.append(STATE_DECLARATION+"%s;" % get_seed(compiler))
		else:
			compiler.add_global(INIT_GLOBAL)
			compiler.code.append(STATE_DECLARATION+"mm_sd_rand_init(%s, uv);" % get_seed(compiler))
	compiler.code.append("fg_rng = fg_rng*%s;" % (VALUE_LCG if value_mode else PIXEL_LCG))
	compiler.types[node_id] = "float"
	return "((uintBitsToFloat(1065353216u | ((fg_rng >> 1u) & 8388607u))-1.0)*%s)" % compiler.value_of(node.a)
