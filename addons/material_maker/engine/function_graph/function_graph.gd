extends RefCounted
class_name MMFunctionGraph


# Compiles function graphs (a typed JSON IR, described in the Pixel
# Processor node's documentation) to GLSL.
#
# compile() takes:
# - graph: the function graph
# - sample_expressions: one format string per image input, with %s replaced
#   with the UV expression (e.g. "$in(%s)")
# - parameter_expressions: a dictionary that maps parameter names to GLSL
#   expressions (e.g. "$contrast")
# - variables: GLSL expressions for "pos", "size" and "seed", and the prefix
#   of generated function names ("function_prefix")
# and returns { ok, code, value, functions, globals, types, node_errors, errors }:
# - code is a list of GLSL statements and value the vec4 expression of the
#   result (inside a function that has a vec2 uv argument),
# - functions is a list of GLSL function definitions (sub-functions) that
#   must be declared before that code,
# - globals is a list of global GLSL definitions the code requires (each
#   one can be shared by several graphs, so they must be declared once),
# - types maps node ids of the main graph to their types,
# - node_errors maps node ids of the main graph to error messages.


const VERSION : int = 2

const COMPONENTS : Dictionary = { bool=1, int=1, float=1, vec2=2, vec3=3, vec4=4 }
const VECTOR_TYPES : Array[String] = [ "float", "vec2", "vec3", "vec4" ]
const ARG_TYPES : Array[String] = [ "bool", "int", "float", "vec2", "vec3", "vec4" ]
const MAX_LOOP_COUNT : int = 1024

const BINARY_OPS : Dictionary = {
	add="(%s+%s)", sub="(%s-%s)", mul="(%s*%s)", div="(%s/%s)",
	min="min(%s, %s)", max="max(%s, %s)", pow="pow(%s, %s)", mod="mod(%s, %s)",
	atan2="atan(%s, %s)", step="step(%s, %s)"
}
# Binary operations that also accept integers, and their integer form
const INT_BINARY_OPS : Dictionary = {
	add="(%s+%s)", sub="(%s-%s)", mul="(%s*%s)", div="(%s/%s)",
	min="min(%s, %s)", max="max(%s, %s)", mod="mm_fg_mod(%s, %s)"
}
const UNARY_OPS : Dictionary = {
	neg="(-%s)", abs="abs(%s)", floor="floor(%s)", ceil="ceil(%s)",
	fract="fract(%s)", sqrt="sqrt(%s)", sin="sin(%s)", cos="cos(%s)",
	tan="tan(%s)", exp="exp(%s)", log="log(%s)", sign="sign(%s)",
	normalize="normalize(%s)"
}
const INT_UNARY_OPS : Array[String] = [ "neg", "abs", "sign" ]
const COMPARISON_OPS : Dictionary = { lt="<", le="<=", gt=">", ge=">=", eq="==", ne="!=" }

# Integer modulo with the sign of the divisor, like mod() for floats (GLSL's
# % is undefined for negative operands, which breaks wrapping of negative
# coordinates)
const MOD_GLOBAL : String = """int mm_fg_mod(int a, int b) {
	int m = abs(a)%abs(b);
	if (m != 0 && ((a < 0 && b > 0) || (a > 0 && b < 0))) {
		m = abs(b)-m;
	}
	return (b < 0) ? -m : m;
}
"""

# Random numbers from an integer hash (PCG3D, Jarzynski and Olano 2020) of
# the bit patterns of the seed and of the node's seed: unlike sin/cos based
# hashes, it gives the same values on every GPU
const RAND_GLOBAL : String = """float mm_fg_rand(vec2 p, float seed) {
	uvec3 v = uvec3(floatBitsToUint(p+vec2(0.0)), floatBitsToUint(seed+0.0));
	v = v*1664525u+1013904223u;
	v.x += v.y*v.z;
	v.y += v.z*v.x;
	v.z += v.x*v.y;
	v ^= v >> 16u;
	v.x += v.y*v.z;
	v.y += v.z*v.x;
	v.z += v.x*v.y;
	return float(v.x >> 8u)/16777216.0;
}
"""

# Operations other than the binary, unary and comparison operators above:
# - operands: the keys of the node that reference other nodes (used to find
#   dependencies; vector constructors and calls also have an args array),
# - compile: the method of Compiler that types and compiles the node,
# - globals (optional): global GLSL definitions the operation requires.
const OPERATIONS : Dictionary = {
	"float": { operands=[], compile="compile_float" },
	"int": { operands=[], compile="compile_int" },
	"vec2": { operands=[], compile="compile_vector" },
	"vec3": { operands=[], compile="compile_vector" },
	"vec4": { operands=[], compile="compile_vector" },
	"true": { operands=[], compile="compile_bool" },
	"false": { operands=[], compile="compile_bool" },
	"pos": { operands=[], compile="compile_pos" },
	"size": { operands=[], compile="compile_size" },
	"param": { operands=[], compile="compile_param" },
	"arg": { operands=[], compile="compile_arg" },
	"sample": { operands=[ "uv" ], compile="compile_sample" },
	"to_int": { operands=[ "a" ], compile="compile_to_int" },
	"to_float": { operands=[ "a" ], compile="compile_to_float" },
	"call": { operands=[], compile="compile_call" },
	"loop": { operands=[ "init" ], compile="compile_loop" },
	"dot": { operands=[ "a", "b" ], compile="compile_dot_distance" },
	"distance": { operands=[ "a", "b" ], compile="compile_dot_distance" },
	"length": { operands=[ "a" ], compile="compile_length" },
	"cross": { operands=[ "a", "b" ], compile="compile_cross" },
	"swizzle": { operands=[ "a" ], compile="compile_swizzle" },
	"mix": { operands=[ "a", "b", "t" ], compile="compile_mix_clamp" },
	"clamp": { operands=[ "a", "min", "max" ], compile="compile_mix_clamp" },
	"smoothstep": { operands=[ "e0", "e1", "a" ], compile="compile_mix_clamp" },
	"and": { operands=[ "a", "b" ], compile="compile_logic" },
	"or": { operands=[ "a", "b" ], compile="compile_logic" },
	"not": { operands=[ "a" ], compile="compile_logic" },
	"select": { operands=[ "cond", "a", "b" ], compile="compile_select" },
	"rand": { operands=[ "a" ], compile="compile_rand", globals=[ RAND_GLOBAL ] }
}

static var re_identifier : RegEx = RegEx.create_from_string("^[a-zA-Z][a-zA-Z0-9_]*$")

static func is_identifier(s) -> bool:
	return (s is String or s is StringName) and re_identifier.search(str(s)) != null

## Returns the description of an operation in OPERATIONS, or an empty
## dictionary
static func get_operation(op : String) -> Dictionary:
	return OPERATIONS.get(op, {})

## Replaces whole-word occurrences of word in s (without RegEx.sub, that
## would interpret "$" in the replacement)
static func replace_word(s : String, word : String, replacement : String) -> String:
	var rv : String = ""
	var position : int = 0
	for m in RegEx.create_from_string("\\b%s\\b" % word).search_all(s):
		rv += s.substr(position, m.get_start()-position)+replacement
		position = m.get_end()
	return rv+s.substr(position)


class Compiler:
	extends RefCounted

	var nodes : Dictionary
	var output : String
	var sample_expressions : Array
	var parameter_expressions : Dictionary
	var variables : Dictionary
	# Sub-functions: name -> { params, return_type, glsl_name }
	var functions_info : Dictionary = {}
	# Arguments of the function being compiled: name -> { type, glsl_name }
	var args : Dictionary = {}
	var context : String = ""

	var errors : PackedStringArray = PackedStringArray()
	var node_errors : Dictionary = {}
	var order : Array[String] = []
	var types : Dictionary = {}
	var names : Dictionary = {}
	var code : PackedStringArray = PackedStringArray()
	var globals : PackedStringArray = PackedStringArray()

	func error(node_id : String, message : String) -> void:
		if node_id == "":
			errors.append(context+message)
		else:
			errors.append("%s%s: %s" % [ context, node_id, message ])
			node_errors[node_id] = message

	func add_global(definition : String) -> void:
		if not definition in globals:
			globals.append(definition)

	func get_operand_ids(node : Dictionary) -> Array:
		var op : String = node.get("op", "")
		var keys : Array = []
		if BINARY_OPS.has(op) or COMPARISON_OPS.has(op):
			keys = [ "a", "b" ]
		elif UNARY_OPS.has(op):
			keys = [ "a" ]
		else:
			keys = MMFunctionGraph.get_operation(op).get("operands", [])
		var rv : Array = []
		for k in keys:
			rv.append(node.get(k))
		if op in [ "vec2", "vec3", "vec4", "call" ] and node.has("args") and node.args is Array:
			rv.append_array(node.args)
		return rv

	# Depth first traversal from the output, that detects cycles and
	# dangling references and orders nodes so operands come first
	func visit(node_id : String, state : Dictionary) -> void:
		if state.get(node_id, 0) == 2:
			return
		if state.get(node_id, 0) == 1:
			error(node_id, "cycle detected")
			return
		if not nodes.has(node_id) or not nodes[node_id] is Dictionary:
			error(node_id, "node not found")
			return
		state[node_id] = 1
		for operand in get_operand_ids(nodes[node_id]):
			if not operand is String:
				error(node_id, "missing or invalid operand")
			else:
				visit(operand, state)
		state[node_id] = 2
		order.append(node_id)

	func value_of(node_id : String) -> String:
		return names[node_id]

	# Returns the expression of operand converted to type t (only floats
	# are broadcast to vectors)
	func cast(node_id : String, t : String) -> String:
		var operand_type : String = types[node_id]
		if operand_type == t:
			return value_of(node_id)
		return "%s(%s)" % [ t, value_of(node_id) ]

	# Returns the common type of numeric operands, or "" if incompatible.
	# Integers are only accepted if allow_int is true and all operands are
	# integers.
	func common_type(node_id : String, operands : Array, allow_int : bool = false) -> String:
		if allow_int and not operands.is_empty() and operands.all(func(o): return types[o] == "int"):
			return "int"
		var rv : String = "float"
		for o in operands:
			var t : String = types[o]
			if t == "int":
				error(node_id, "operand %s is an int, use to_float to convert it" % o)
				return ""
			if not t in VECTOR_TYPES:
				error(node_id, "operand %s has type %s, a number or vector is expected" % [ o, t ])
				return ""
			if t == "float" or t == rv:
				continue
			if rv != "float":
				error(node_id, "operands have incompatible types %s and %s" % [ rv, t ])
				return ""
			rv = t
		return rv

	func format_float(v) -> String:
		return "%.9f" % float(v)

	func compile_node(node_id : String) -> String:
		var node : Dictionary = nodes[node_id]
		var op : String = node.get("op", "")
		var operands : Array = get_operand_ids(node)
		var operation : Dictionary = MMFunctionGraph.get_operation(op)
		if not operation.is_empty():
			var expression : String = call(operation.compile, node_id, node, op, operands)
			if expression != "":
				for g in operation.get("globals", []):
					add_global(g)
			return expression
		if BINARY_OPS.has(op):
			var t : String = common_type(node_id, operands, INT_BINARY_OPS.has(op))
			if t == "":
				return ""
			types[node_id] = t
			if t == "int":
				if op == "mod":
					add_global(MOD_GLOBAL)
				return INT_BINARY_OPS[op] % [ value_of(node.a), value_of(node.b) ]
			return BINARY_OPS[op] % [ cast(node.a, t), cast(node.b, t) ]
		if UNARY_OPS.has(op):
			if not (types[node.a] in VECTOR_TYPES or (types[node.a] == "int" and op in INT_UNARY_OPS)):
				error(node_id, "a float or vector is expected")
				return ""
			types[node_id] = types[node.a]
			return UNARY_OPS[op] % value_of(node.a)
		if COMPARISON_OPS.has(op):
			if not (types[node.a] in [ "float", "int" ] and types[node.b] == types[node.a]):
				error(node_id, "comparisons require two floats or two ints")
				return ""
			types[node_id] = "bool"
			return "(%s %s %s)" % [ value_of(node.a), COMPARISON_OPS[op], value_of(node.b) ]
		error(node_id, "unknown operation %s" % op)
		return ""


	func compile_float(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		if not (node.get("value") is float or node.get("value") is int):
			error(node_id, "float value expected")
			return ""
		types[node_id] = "float"
		return format_float(node.value)

	func compile_int(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		if not (node.get("value") is float or node.get("value") is int):
			error(node_id, "int value expected")
			return ""
		types[node_id] = "int"
		return "%d" % int(node.value)

	func compile_vector(node_id : String, node : Dictionary, op : String, _operands : Array) -> String:
		var count : int = COMPONENTS[op]
		if node.has("value"):
			if not node.value is Array or node.value.size() != count:
				error(node_id, "%d values expected" % count)
				return ""
			types[node_id] = op
			return "%s(%s)" % [ op, ", ".join(node.value.map(format_float)) ]
		if not node.has("args") or not node.args is Array or node.args.is_empty():
			error(node_id, "value or args expected")
			return ""
		var components : int = 0
		for a in node.args:
			if not types[a] in VECTOR_TYPES:
				error(node_id, "operand %s is not a float or vector" % a)
				return ""
			components += COMPONENTS[types[a]]
		if components != count and not (components == 1 and node.args.size() == 1):
			error(node_id, "%d components expected, %d given" % [ count, components ])
			return ""
		types[node_id] = op
		return "%s(%s)" % [ op, ", ".join(node.args.map(value_of)) ]

	func compile_bool(node_id : String, _node : Dictionary, op : String, _operands : Array) -> String:
		types[node_id] = "bool"
		return op

	func compile_pos(node_id : String, _node : Dictionary, _op : String, _operands : Array) -> String:
		types[node_id] = "vec2"
		return variables.pos

	func compile_size(node_id : String, _node : Dictionary, _op : String, _operands : Array) -> String:
		types[node_id] = "vec2"
		return variables.size

	func compile_param(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		if not parameter_expressions.has(node.get("name", "")):
			error(node_id, "unknown parameter %s" % str(node.get("name")))
			return ""
		types[node_id] = "float"
		return parameter_expressions[node.name]

	func compile_arg(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		if not args.has(node.get("name", "")):
			error(node_id, "unknown argument %s" % str(node.get("name")))
			return ""
		types[node_id] = args[node.name].type
		return args[node.name].glsl_name

	func compile_sample(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		var input = node.get("input")
		if not (input is int or input is float) or int(input) < 0 or int(input) >= sample_expressions.size():
			error(node_id, "invalid input %s" % str(input))
			return ""
		if types[node.uv] != "vec2":
			error(node_id, "uv must be a vec2")
			return ""
		types[node_id] = "vec4"
		return sample_expressions[int(input)] % value_of(node.uv)

	func compile_to_int(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		if types[node.a] != "float":
			error(node_id, "to_int requires a float")
			return ""
		types[node_id] = "int"
		return "int(floor(%s))" % value_of(node.a)

	func compile_to_float(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		if types[node.a] != "int":
			error(node_id, "to_float requires an int")
			return ""
		types[node_id] = "float"
		return "float(%s)" % value_of(node.a)

	func compile_call(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		var info = functions_info.get(node.get("function", ""))
		if info == null:
			error(node_id, "unknown function %s" % str(node.get("function")))
			return ""
		var call_args : Array = node.get("args", [])
		if call_args.size() != info.params.size():
			error(node_id, "%d arguments expected, %d given" % [ info.params.size(), call_args.size() ])
			return ""
		for i in call_args.size():
			if types[call_args[i]] != info.params[i].type:
				error(node_id, "argument %s must be a %s" % [ info.params[i].name, info.params[i].type ])
				return ""
		types[node_id] = info.return_type
		return "%s(%s)" % [ info.glsl_name, ", ".join([ "uv" ]+call_args.map(value_of)) ]

	func compile_loop(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		var info = functions_info.get(node.get("function", ""))
		if info == null:
			error(node_id, "unknown function %s" % str(node.get("function")))
			return ""
		var count = node.get("count")
		if not (count is int or count is float) or int(count) < 0 or int(count) > MAX_LOOP_COUNT:
			error(node_id, "count must be a number between 0 and %d" % MAX_LOOP_COUNT)
			return ""
		var t : String = types[node.init]
		if info.params.size() != 2 or info.params[0].type != t or info.params[1].type != "int" or info.return_type != t:
			error(node_id, "the loop function must take (%s, int) and return %s" % [ t, t ])
			return ""
		# The loop is emitted as statements before the node's value
		var accumulator : String = "fg_loop_%d" % code.size()
		code.append("%s %s = %s;" % [ t, accumulator, value_of(node.init) ])
		code.append("for (int fg_i = 0; fg_i < %d; ++fg_i) { %s = %s(uv, %s, fg_i); }" % [ int(count), accumulator, info.glsl_name, accumulator ])
		types[node_id] = t
		return accumulator

	func compile_dot_distance(node_id : String, node : Dictionary, op : String, operands : Array) -> String:
		var t : String = common_type(node_id, operands)
		if t == "":
			return ""
		types[node_id] = "float"
		return "%s(%s, %s)" % [ op, cast(node.a, t), cast(node.b, t) ]

	func compile_length(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		if not types[node.a] in VECTOR_TYPES:
			error(node_id, "a float or vector is expected")
			return ""
		types[node_id] = "float"
		return "length(%s)" % value_of(node.a)

	func compile_cross(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		if types[node.a] != "vec3" or types[node.b] != "vec3":
			error(node_id, "cross requires two vec3")
			return ""
		types[node_id] = "vec3"
		return "cross(%s, %s)" % [ value_of(node.a), value_of(node.b) ]

	func compile_swizzle(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		var source_type : String = types[node.a]
		var components = node.get("components", "")
		if not components is String or components.length() < 1 or components.length() > 4 or not source_type in [ "vec2", "vec3", "vec4" ]:
			error(node_id, "invalid swizzle")
			return ""
		# Components must all come from the same set (xyzw or rgba)
		var component_set : String = "xyzw" if "xyzw".contains(components[0]) else "rgba"
		for c in components:
			var index : int = component_set.find(c)
			if index == -1 or index >= COMPONENTS[source_type]:
				error(node_id, "invalid component %s for type %s" % [ c, source_type ])
				return ""
		types[node_id] = "float" if components.length() == 1 else "vec%d" % components.length()
		return "%s.%s" % [ value_of(node.a), components ]

	func compile_mix_clamp(node_id : String, _node : Dictionary, op : String, operands : Array) -> String:
		var t : String = common_type(node_id, operands)
		if t == "":
			return ""
		types[node_id] = t
		return "%s(%s)" % [ op, ", ".join(operands.map(func(o): return cast(o, t))) ]

	func compile_logic(node_id : String, node : Dictionary, op : String, operands : Array) -> String:
		for o in operands:
			if types[o] != "bool":
				error(node_id, "boolean operands expected")
				return ""
		types[node_id] = "bool"
		match op:
			"and":
				return "(%s && %s)" % [ value_of(node.a), value_of(node.b) ]
			"or":
				return "(%s || %s)" % [ value_of(node.a), value_of(node.b) ]
		return "(!%s)" % value_of(node.a)

	func compile_select(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		if types[node.cond] != "bool":
			error(node_id, "cond must be a boolean")
			return ""
		var t : String = common_type(node_id, [ node.a, node.b ], true)
		if t == "":
			return ""
		types[node_id] = t
		return "(%s ? %s : %s)" % [ value_of(node.cond), cast(node.a, t), cast(node.b, t) ]

	func compile_rand(node_id : String, node : Dictionary, _op : String, _operands : Array) -> String:
		if types[node.a] != "vec2":
			error(node_id, "rand requires a vec2 seed")
			return ""
		types[node_id] = "float"
		return "mm_fg_rand(%s, %s)" % [ value_of(node.a), variables.seed ]

	# Compiles nodes reachable from output into code, returns false on error
	func compile_body() -> bool:
		var state : Dictionary = {}
		visit(output, state)
		# Graph editors can also have nodes the output does not depend on
		# typed and checked
		if variables.get("compile_all_nodes", false):
			for node_id in nodes.keys():
				visit(node_id, state)
		if not errors.is_empty():
			return false
		for node_id in order:
			var expression : String = compile_node(node_id)
			if expression == "":
				if errors.is_empty():
					error(node_id, "could not be compiled")
				return false
			names[node_id] = "fg_%d" % names.size()
			# Node ids are only kept in comments, without characters that
			# could be mistaken for Material Maker variables or line breaks
			var comment : String = node_id.replace("$", "").replace("\n", " ")
			code.append("%s %s = %s; // %s" % [ types[node_id], names[node_id], expression, comment ])
		return true


# Validates sub-functions and returns them in an order where callees come
# before callers, or reports errors in errors
static func order_functions(functions : Dictionary, errors : PackedStringArray) -> Array:
	var rv : Array = []
	var state : Dictionary = {}
	for name in functions.keys():
		visit_function(name, functions, state, rv, errors)
	return rv

static func visit_function(name : String, functions : Dictionary, state : Dictionary, ordered : Array, errors : PackedStringArray) -> void:
	if state.get(name, 0) == 2:
		return
	if state.get(name, 0) == 1:
		errors.append("function %s: recursion is not supported" % name)
		return
	state[name] = 1
	var f : Dictionary = functions[name]
	if f.get("nodes") is Dictionary:
		for n in f.nodes.values():
			if n is Dictionary and n.get("op", "") in [ "call", "loop" ] and functions.has(n.get("function", "")):
				visit_function(n.function, functions, state, ordered, errors)
	state[name] = 2
	ordered.append(name)

static func compile(graph : Dictionary, sample_expressions : Array, parameter_expressions : Dictionary, variables : Dictionary) -> Dictionary:
	var errors : PackedStringArray = PackedStringArray()
	var functions_info : Dictionary = {}
	var function_definitions : PackedStringArray = PackedStringArray()
	var globals : PackedStringArray = PackedStringArray()
	var prefix : String = variables.get("function_prefix", "fg_function_")
	var functions = graph.get("functions", {})
	if not functions is Dictionary:
		return { ok=false, errors=PackedStringArray([ "functions must be a dictionary" ]), node_errors={}, types={} }
	for name in functions.keys():
		var f = functions[name]
		if not is_identifier(name) or not f is Dictionary or not f.get("params", []) is Array:
			errors.append("function %s: invalid function" % str(name))
			continue
		for p in f.get("params", []):
			if not p is Dictionary or not is_identifier(p.get("name")) or not p.get("type") in ARG_TYPES:
				errors.append("function %s: invalid parameter %s" % [ name, str(p) ])
	var ordered : Array = order_functions(functions, errors) if errors.is_empty() else []
	# Types and errors of sub-functions' nodes (for graph editors)
	var function_types : Dictionary = {}
	var function_node_errors : Dictionary = {}
	# Compile sub-functions, callees first
	for name in ordered:
		var f : Dictionary = functions[name]
		var compiler : Compiler = Compiler.new()
		compiler.context = "function %s: " % name
		compiler.nodes = f.get("nodes", {}) if f.get("nodes") is Dictionary else {}
		compiler.output = f.get("output", "") if f.get("output") is String else ""
		compiler.sample_expressions = sample_expressions
		compiler.parameter_expressions = parameter_expressions
		compiler.variables = variables
		compiler.functions_info = functions_info
		var declarations : PackedStringArray = PackedStringArray([ "vec2 uv" ])
		for p in f.get("params", []):
			compiler.args[p.name] = { type=p.type, glsl_name="fa_"+p.name }
			declarations.append("%s fa_%s" % [ p.type, p.name ])
		var compiled : bool = compiler.compile_body()
		function_types[name] = compiler.types
		function_node_errors[name] = compiler.node_errors
		if not compiled:
			errors.append_array(compiler.errors)
			continue
		var return_type : String = compiler.types[compiler.output]
		var definition : String = "%s %s%s(%s) {\n" % [ return_type, prefix, name, ", ".join(declarations) ]
		for line in compiler.code:
			definition += "\t%s\n" % line
		definition += "\treturn %s;\n}\n" % compiler.value_of(compiler.output)
		function_definitions.append(definition)
		functions_info[name] = { params=f.get("params", []), return_type=return_type, glsl_name=prefix+name }
		for g in compiler.globals:
			if not g in globals:
				globals.append(g)
	# Compile the main graph
	var main : Compiler = Compiler.new()
	main.sample_expressions = sample_expressions
	main.parameter_expressions = parameter_expressions
	main.variables = variables
	main.functions_info = functions_info
	if not graph.has("nodes") or not graph.nodes is Dictionary:
		main.error("", "the graph has no nodes")
	elif not graph.has("output") or not graph.output is String:
		main.error("", "the graph has no output")
	else:
		# The main graph is compiled even if sub-functions have errors, so
		# its types are known
		main.nodes = graph.nodes
		main.output = graph.output
		main.compile_body()
	errors.append_array(main.errors)
	if not errors.is_empty():
		return { ok=false, errors=errors, node_errors=main.node_errors, types=main.types,
			function_types=function_types, function_node_errors=function_node_errors }
	var value : String = main.value_of(graph.output)
	match main.types[graph.output]:
		"float":
			value = "vec4(vec3(%s), 1.0)" % value
		"int":
			value = "vec4(vec3(float(%s)), 1.0)" % value
		"vec2":
			value = "vec4(%s, 0.0, 1.0)" % value
		"vec3":
			value = "vec4(%s, 1.0)" % value
		"bool":
			return { ok=false, errors=PackedStringArray([ "%s: the output cannot be a boolean" % graph.output ]),
				node_errors={ graph.output: "the output cannot be a boolean" }, types=main.types }
	for g in main.globals:
		if not g in globals:
			globals.append(g)
	return { ok=true, code=main.code, value=value, functions=function_definitions, globals=globals, types=main.types, node_errors={}, errors=errors,
		function_types=function_types, function_node_errors=function_node_errors }

# Operations that cannot be used in parameter functions
const NON_EXPRESSION_OPS : Array[String] = [ "pos", "size", "sample", "rand", "call", "loop", "arg" ]

## Compiles a function graph that only uses parameters and constants, and
## whose output is a float, to a single GLSL expression (used for parameter
## functions), returns { ok, expression, errors }
static func compile_expression(graph : Dictionary, parameter_expressions : Dictionary) -> Dictionary:
	var functions = graph.get("functions", {})
	if functions is Dictionary and not functions.is_empty():
		return { ok=false, errors=PackedStringArray([ "functions are not supported in parameter functions" ]) }
	if graph.get("nodes") is Dictionary:
		for n in graph.nodes.values():
			if n is Dictionary and n.get("op", "") in NON_EXPRESSION_OPS:
				return { ok=false, errors=PackedStringArray([ "%s is not supported in parameter functions" % n.op ]) }
	var result : Dictionary = compile(graph, [], parameter_expressions, { pos="uv", size="vec2(1.0)", seed="0.0" })
	if not result.ok:
		return { ok=false, errors=result.errors }
	if result.types[graph.output] != "float":
		return { ok=false, errors=PackedStringArray([ "%s: the output of a parameter function must be a float" % graph.output ]) }
	# Operations that need global definitions (such as integer modulo) can't
	# be written as an expression
	if not result.globals.is_empty():
		return { ok=false, errors=PackedStringArray([ "integer modulo is not supported in parameter functions" ]) }
	# Inline all statements into one expression, operands first
	var re_statement : RegEx = RegEx.create_from_string("^\\w+ (fg_\\d+) = (.*); //")
	var expressions : Dictionary = {}
	var expression : String = ""
	for line in result.code:
		var m : RegExMatch = re_statement.search(line)
		if m == null:
			return { ok=false, errors=PackedStringArray([ "unsupported statement in a parameter function" ]) }
		expression = m.get_string(2)
		for name in expressions.keys():
			var operand : String = expressions[name]
			if not is_primary_expression(operand):
				operand = "(%s)" % operand
			expression = replace_word(expression, name, operand)
		expressions[m.get_string(1)] = expression
	return { ok=true, expression=expressions.values()[-1], errors=PackedStringArray() }

static var re_atom : RegEx = RegEx.create_from_string("^[\\w.$]+$")
static var re_function_name : RegEx = RegEx.create_from_string("^\\w*$")

## Returns true if e can be used as an operand without parentheses: a name,
## a positive number, a function call or an expression in parentheses
static func is_primary_expression(e : String) -> bool:
	if re_atom.search(e) != null:
		return true
	if not e.ends_with(")"):
		return false
	# Find the parenthesis that matches the last one
	var depth : int = 0
	for i in range(e.length()-1, -1, -1):
		if e[i] == ")":
			depth += 1
		elif e[i] == "(":
			depth -= 1
			if depth == 0:
				return re_function_name.search(e.substr(0, i)) != null
	return false
