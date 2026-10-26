extends RefCounted
class_name MMFunctionGraph


# Compiles function graphs (a typed JSON IR, see design/function_graphs.md)
# to GLSL.
#
# compile() takes:
# - graph: the function graph
# - sample_expressions: one format string per image input, with %s replaced
#   with the UV expression (e.g. "$in(%s)")
# - parameter_expressions: a dictionary that maps parameter names to GLSL
#   expressions (e.g. "$contrast")
# - variables: GLSL expressions for "pos", "size" and "seed"
# and returns { ok, code, value, errors }, where code is a list of GLSL
# statements and value the vec4 expression of the result.


const VERSION : int = 1

const COMPONENTS : Dictionary = { bool=1, float=1, vec2=2, vec3=3, vec4=4 }
const VECTOR_TYPES : Array[String] = [ "float", "vec2", "vec3", "vec4" ]

const BINARY_OPS : Dictionary = {
	add="(%s+%s)", sub="(%s-%s)", mul="(%s*%s)", div="(%s/%s)",
	min="min(%s, %s)", max="max(%s, %s)", pow="pow(%s, %s)", mod="mod(%s, %s)",
	atan2="atan(%s, %s)", step="step(%s, %s)"
}
const UNARY_OPS : Dictionary = {
	neg="(-%s)", abs="abs(%s)", floor="floor(%s)", ceil="ceil(%s)",
	fract="fract(%s)", sqrt="sqrt(%s)", sin="sin(%s)", cos="cos(%s)",
	tan="tan(%s)", exp="exp(%s)", log="log(%s)", sign="sign(%s)",
	normalize="normalize(%s)"
}
const COMPARISON_OPS : Dictionary = { lt="<", le="<=", gt=">", ge=">=", eq="==", ne="!=" }

# Operand keys of each operation (used to find dependencies)
const OPERANDS : Dictionary = {
	"sample": [ "uv" ], "dot": [ "a", "b" ], "length": [ "a" ], "distance": [ "a", "b" ],
	"cross": [ "a", "b" ], "swizzle": [ "a" ], "mix": [ "a", "b", "t" ],
	"clamp": [ "a", "min", "max" ], "smoothstep": [ "e0", "e1", "a" ],
	"and": [ "a", "b" ], "or": [ "a", "b" ], "not": [ "a" ], "select": [ "cond", "a", "b" ],
	"rand": [ "a" ]
}


class Compiler:
	extends RefCounted

	var graph : Dictionary
	var nodes : Dictionary
	var sample_expressions : Array
	var parameter_expressions : Dictionary
	var variables : Dictionary

	var errors : PackedStringArray = PackedStringArray()
	var order : Array[String] = []
	var types : Dictionary = {}
	var names : Dictionary = {}
	var code : PackedStringArray = PackedStringArray()

	func error(node_id : String, message : String) -> void:
		if node_id == "":
			errors.append(message)
		else:
			errors.append("%s: %s" % [ node_id, message ])

	func get_operand_ids(node : Dictionary) -> Array:
		var op : String = node.get("op", "")
		var keys : Array = []
		if BINARY_OPS.has(op) or COMPARISON_OPS.has(op):
			keys = [ "a", "b" ]
		elif UNARY_OPS.has(op):
			keys = [ "a" ]
		elif OPERANDS.has(op):
			keys = OPERANDS[op]
		var rv : Array = []
		for k in keys:
			rv.append(node.get(k))
		if op in [ "vec2", "vec3", "vec4" ] and node.has("args"):
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

	# Returns the common type of numeric operands, or "" if incompatible
	func common_type(node_id : String, operands : Array) -> String:
		var rv : String = "float"
		for o in operands:
			var t : String = types[o]
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
		match op:
			"float":
				if not (node.get("value") is float or node.get("value") is int):
					error(node_id, "float value expected")
					return ""
				types[node_id] = "float"
				return format_float(node.value)
			"vec2", "vec3", "vec4":
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
						error(node_id, "operand %s is not a number or vector" % a)
						return ""
					components += COMPONENTS[types[a]]
				if components != count and not (components == 1 and node.args.size() == 1):
					error(node_id, "%d components expected, %d given" % [ count, components ])
					return ""
				types[node_id] = op
				return "%s(%s)" % [ op, ", ".join(node.args.map(value_of)) ]
			"true", "false":
				types[node_id] = "bool"
				return op
			"pos":
				types[node_id] = "vec2"
				return variables.pos
			"size":
				types[node_id] = "vec2"
				return variables.size
			"param":
				if not parameter_expressions.has(node.get("name", "")):
					error(node_id, "unknown parameter %s" % str(node.get("name")))
					return ""
				types[node_id] = "float"
				return parameter_expressions[node.name]
			"sample":
				var input = node.get("input")
				if not (input is int or input is float) or int(input) < 0 or int(input) >= sample_expressions.size():
					error(node_id, "invalid input %s" % str(input))
					return ""
				if types[node.uv] != "vec2":
					error(node_id, "uv must be a vec2")
					return ""
				types[node_id] = "vec4"
				return sample_expressions[int(input)] % value_of(node.uv)
			"dot", "distance":
				var t : String = common_type(node_id, operands)
				if t == "":
					return ""
				types[node_id] = "float"
				return "%s(%s, %s)" % [ op, cast(node.a, t), cast(node.b, t) ]
			"length":
				if not types[node.a] in VECTOR_TYPES:
					error(node_id, "a number or vector is expected")
					return ""
				types[node_id] = "float"
				return "length(%s)" % value_of(node.a)
			"cross":
				if types[node.a] != "vec3" or types[node.b] != "vec3":
					error(node_id, "cross requires two vec3")
					return ""
				types[node_id] = "vec3"
				return "cross(%s, %s)" % [ value_of(node.a), value_of(node.b) ]
			"swizzle":
				var source_type : String = types[node.a]
				var components = node.get("components", "")
				if not components is String or components.length() < 1 or components.length() > 4 or source_type in [ "bool", "float" ]:
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
			"mix", "clamp", "smoothstep":
				var t : String = common_type(node_id, operands)
				if t == "":
					return ""
				types[node_id] = t
				return "%s(%s)" % [ op, ", ".join(operands.map(func(o): return cast(o, t))) ]
			"and", "or", "not":
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
			"select":
				if types[node.cond] != "bool":
					error(node_id, "cond must be a boolean")
					return ""
				var t : String = common_type(node_id, [ node.a, node.b ])
				if t == "":
					return ""
				types[node_id] = t
				return "(%s ? %s : %s)" % [ value_of(node.cond), cast(node.a, t), cast(node.b, t) ]
			"rand":
				if types[node.a] != "vec2":
					error(node_id, "rand requires a vec2 seed")
					return ""
				types[node_id] = "float"
				return "rand(%s+vec2(%s))" % [ value_of(node.a), variables.seed ]
		if BINARY_OPS.has(op):
			var t : String = common_type(node_id, operands)
			if t == "":
				return ""
			types[node_id] = t
			return BINARY_OPS[op] % [ cast(node.a, t), cast(node.b, t) ]
		if UNARY_OPS.has(op):
			if not types[node.a] in VECTOR_TYPES:
				error(node_id, "a number or vector is expected")
				return ""
			types[node_id] = types[node.a]
			return UNARY_OPS[op] % value_of(node.a)
		if COMPARISON_OPS.has(op):
			if types[node.a] != "float" or types[node.b] != "float":
				error(node_id, "comparisons require float operands")
				return ""
			types[node_id] = "bool"
			return "(%s %s %s)" % [ value_of(node.a), COMPARISON_OPS[op], value_of(node.b) ]
		error(node_id, "unknown operation %s" % op)
		return ""

	func run() -> Dictionary:
		if not graph.has("nodes") or not graph.nodes is Dictionary:
			error("", "the graph has no nodes")
		elif not graph.has("output") or not graph.output is String:
			error("", "the graph has no output")
		else:
			nodes = graph.nodes
			visit(graph.output, {})
		if errors.is_empty():
			for node_id in order:
				var expression : String = compile_node(node_id)
				if expression == "":
					break
				names[node_id] = "fg_%d" % names.size()
				# Node ids are only kept in comments, without characters that
				# could be mistaken for Material Maker variables or line breaks
				var comment : String = node_id.replace("$", "").replace("\n", " ")
				code.append("%s %s = %s; // %s" % [ types[node_id], names[node_id], expression, comment ])
		if not errors.is_empty():
			return { ok=false, errors=errors }
		var value : String = names[graph.output]
		match types[graph.output]:
			"float":
				value = "vec4(vec3(%s), 1.0)" % value
			"vec2":
				value = "vec4(%s, 0.0, 1.0)" % value
			"vec3":
				value = "vec4(%s, 1.0)" % value
			"bool":
				return { ok=false, errors=PackedStringArray([ "%s: the output cannot be a boolean" % graph.output ]) }
		return { ok=true, code=code, value=value, errors=errors }


static func compile(graph : Dictionary, sample_expressions : Array, parameter_expressions : Dictionary, variables : Dictionary) -> Dictionary:
	var compiler : Compiler = Compiler.new()
	compiler.graph = graph
	compiler.sample_expressions = sample_expressions
	compiler.parameter_expressions = parameter_expressions
	compiler.variables = variables
	return compiler.run()
