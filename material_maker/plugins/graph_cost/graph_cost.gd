extends RefCounted


# A static, relative estimate of the cost of the shader code of a graph. It
# is NOT the instruction count of Unreal (or of any driver): it only allows to
# compare two versions of a graph.
#
# The code is split into functions. Each function body is scanned for weighted
# tokens (arithmetic and comparison operators, builtin functions, texture
# lookups), a "for" loop whose bound can be computed multiplies the cost of
# its body by its trip count (the bound may be a constant, a constant of the
# shader, or a parameter of the function whose value is a constant at the
# call site), other loops multiply it by UNKNOWN_TRIP_COUNT and are counted
# in loops_unbounded. A call to a function of the code adds its cost.
# The headers of the loops are not counted.


const UNKNOWN_TRIP_COUNT : int = 4
const TEXTURE_COST : int = 20
const TRANSCENDENTAL_COST : int = 8

## Builtin functions (other than the transcendental ones and the texture
## lookups, see estimate_function_body) and their weight
const BUILTIN_COSTS : Dictionary = {
	floor=2, fract=2, abs=2, min=2, max=2, step=2, sign=2, ceil=2, round=2, trunc=2, mod=3,
	clamp=3, mix=3, dot=3, cross=5, length=5, distance=5, smoothstep=5, normalize=6,
	sqrt=6, inversesqrt=6, reflect=6, refract=8
}
const TRANSCENDENTALS : Array[String] = [ "sin", "cos", "tan", "atan", "asin", "acos", "pow", "exp", "log", "exp2", "log2", "sinh", "cosh", "tanh" ]
const TEXTURE_FUNCTIONS : Array[String] = [ "texture", "textureLod", "texture2D" ]
const KEYWORDS : Array[String] = [ "if", "for", "while", "switch", "return", "else", "do", "break", "continue", "discard" ]

## Helpers that hash with sin(): not bit-exact across compilers and drivers
const SIN_HASH_HELPERS : Array[String] = [ "rand", "rand2", "rand3", "rand31", "rand33" ]
## Tokens that the GLSL to HLSL translation does not handle (see the plan's
## HLSL-safe subset). Matrices, unsigned vectors and one-argument atan() are
## translated.
const UNSAFE_TOKENS : Array[String] = [
	"bvec2", "bvec3", "bvec4",
	"lessThan", "lessThanEqual", "greaterThan", "greaterThanEqual", "equal", "notEqual",
	"dFdx", "dFdy", "fwidth", "texelFetch", "textureSize"
]

static var re_identifier : RegEx = RegEx.create_from_string("[A-Za-z_]\\w*")
static var re_function_header : RegEx = RegEx.create_from_string("^[\\w\\s]*?\\b(\\w+)\\s*\\(([^)]*)\\)\\s*$")
static var re_define : RegEx = RegEx.create_from_string("^\\s*#\\s*define\\s+(\\w+)\\s+(.+?)\\s*$")
static var re_const : RegEx = RegEx.create_from_string("^\\s*const\\s+(?:int|uint|float)\\s+(\\w+)\\s*=\\s*([^;]+);")


## Estimates the cost of GLSL code: { instructions, texture_samples,
## functions, loops_unbounded, by_function }. entry is the function whose cost
## is reported (by default, the sum of the functions that no function calls).
## constants gives the value of the other identifiers (such as uniforms).
static func estimate_glsl(code : String, entry : String = "", constants : Dictionary = {}) -> Dictionary:
	var ctx : Dictionary = { functions={}, constants=constants.duplicate(), memo={}, stack=[] }
	parse_code(code, ctx)
	var functions : Dictionary = ctx.functions
	var rv : Dictionary = { instructions=0, texture_samples=0, functions=functions.size(), loops_unbounded=0, by_function={} }
	var roots : Array = []
	if entry != "":
		if not functions.has(entry):
			rv.error = "function '%s' not found" % entry
			return rv
		roots.append(entry)
	else:
		roots = find_roots(functions)
	var total : Dictionary = { c=0, t=0, u=0 }
	for r in roots:
		var cost : Dictionary = function_cost(r, {}, ctx)
		total.c += cost.c
		total.t += cost.t
		total.u += cost.u
	rv.instructions = total.c
	rv.texture_samples = total.t
	rv.loops_unbounded = total.u
	# The cost of each function, when its parameters are not known
	for f in functions.keys():
		var unknown : Dictionary = {}
		for p in functions[f].params:
			unknown[p] = null
		rv.by_function[f] = function_cost(f, unknown, ctx).c
	return rv

## The cost of the code of the output of a generator
static func estimate_output(generator : MMGenBase, output_index : int) -> Dictionary:
	var outputs : Array = generator.get_output_defs(true)
	if output_index < 0 or output_index >= outputs.size():
		return { error="node '%s' has no output %d" % [ generator.name, output_index ] }
	var type : String = outputs[output_index].get("type", "")
	var uv : String = "vec2(0.0)"
	if type.begins_with("tex3d"):
		uv = "vec4(0.0)"
	elif type.begins_with("sdf3d"):
		uv = "vec3(0.0)"
	var source : MMGenBase.ShaderCode = generator.get_shader_code(uv, output_index, MMGenContext.new())
	var value : String = source.output_values.get(source.output_type, "")
	# Only the declarations that the output calls: a node can carry several versions of
	# a function (the Hash parameter of the 3D noises), and the lint must judge the one in use
	var globals : String = source.get_globals_string(source.defs+source.code+value)
	var body : String = source.defs+"\nfloat mm_entry() {\n"+source.code+"\n"+value+";\n}\n"
	var code : String = globals+"\n"+body
	var constants : Dictionary = {}
	for u in source.uniforms:
		if u.value is float or u.value is int:
			constants[u.name] = u.value
	var rv : Dictionary = estimate_glsl(code, "mm_entry", constants)
	# get_globals_string keeps a declaration when its name is a substring of the code, so
	# blend_dissolve_exact also brings blend_dissolve: lint only what the entry really calls
	rv.parity_warnings = Array(lint_parity(reachable_code(globals, body)))
	return rv

## The declarations of globals that body calls (directly or through other declarations),
## followed by body. Names are matched as whole identifiers.
static func reachable_code(globals : String, body : String) -> String:
	var declarations : Array[String] = MMGenBase.split_glsl(globals)
	var names : PackedStringArray = PackedStringArray()
	var identifiers : Array = []
	for d in declarations:
		names.append(MMGenBase.get_glsl_declaration_name(d))
		var ids : Dictionary = {}
		for m in re_identifier.search_all(d):
			ids[m.get_string()] = true
		identifiers.append(ids)
	var used : Dictionary = {}
	for m in re_identifier.search_all(MMGenBase.remove_comments(body)):
		used[m.get_string()] = true
	var kept : Array[bool] = []
	kept.resize(declarations.size())
	kept.fill(false)
	var changed : bool = true
	while changed:
		changed = false
		for i in declarations.size():
			if kept[i]:
				continue
			if names[i] == "" or used.has(names[i]):
				kept[i] = true
				changed = true
				used.merge(identifiers[i])
	var rv : String = ""
	for i in declarations.size():
		if kept[i]:
			rv += declarations[i]+"\n"
	return rv+"\n"+body

## The cost of a material: the sum of the costs of the sources of its inputs
static func estimate_material(material : MMGenBase) -> Dictionary:
	var rv : Dictionary = { instructions=0, texture_samples=0, functions=0, loops_unbounded=0, by_function={}, by_input={}, parity_warnings=[] }
	var done : Array[String] = []
	var inputs : Array = material.get_input_defs()
	for i in inputs.size():
		var source : MMGenBase.OutputPort = material.get_source(i)
		if source == null:
			continue
		var key : String = "%s:%d" % [ source.generator.name, source.output_index ]
		if key in done:
			continue
		done.append(key)
		var cost : Dictionary = estimate_output(source.generator, source.output_index)
		if cost.has("error"):
			continue
		rv.instructions += cost.instructions
		rv.texture_samples += cost.texture_samples
		rv.functions += cost.functions
		rv.loops_unbounded += cost.loops_unbounded
		rv.by_input[inputs[i].get("name", str(i))] = cost.instructions
		for f in cost.by_function.keys():
			rv.by_function[f] = cost.by_function[f]
		for w in cost.parity_warnings:
			if not w in rv.parity_warnings:
				rv.parity_warnings.append(w)
	return rv

## Warnings about the code that cannot be translated to HLSL, or whose results
## depend on the compiler (hashes made with sin)
static func lint_parity(code : String) -> PackedStringArray:
	var rv : PackedStringArray = PackedStringArray()
	code = MMGenBase.remove_comments(code)
	var compact : String = code.replace(" ", "").replace("\t", "").replace("\n", "").replace("\r", "")
	var names : Dictionary = {}
	for m in re_identifier.search_all(code):
		names[m.get_string()] = true
	for h in SIN_HASH_HELPERS:
		if names.has(h):
			rv.append("'%s' hashes with sin(): its values differ between compilers and drivers" % h)
	if compact.contains("sin(dot("):
		rv.append("'sin(dot(' hash: its values differ between compilers and drivers")
	for t in UNSAFE_TOKENS:
		if names.has(t):
			rv.append("'%s' is not in the HLSL-safe subset" % t)
	return rv


# Parsing

static func parse_code(code : String, ctx : Dictionary) -> void:
	var lines : PackedStringArray = PackedStringArray()
	for l in code.split("\n"):
		if l.strip_edges().begins_with("#"):
			var m : RegExMatch = re_define.search(l)
			if m != null:
				var v = eval_const(m.get_string(2), {}, ctx)
				if v != null:
					ctx.constants[m.get_string(1)] = v
			continue
		lines.append(l)
	for d in MMGenBase.split_glsl("\n".join(lines)):
		var brace : int = d.find("{")
		if brace == -1:
			var m : RegExMatch = re_const.search(d)
			if m != null:
				var v = eval_const(m.get_string(2), {}, ctx)
				if v != null:
					ctx.constants[m.get_string(1)] = v
			continue
		var header : String = d.left(brace).replace("\n", " ").replace("\r", " ").strip_edges()
		if header.begins_with("struct"):
			continue
		var m : RegExMatch = re_function_header.search(header)
		if m == null:
			continue
		var params : Array[String] = []
		for p in m.get_string(2).split(","):
			var words : PackedStringArray = p.strip_edges().split(" ", false)
			if words.size() >= 2:
				var n : String = words[words.size()-1]
				params.append(n.left(n.find("[")) if n.contains("[") else n)
		ctx.functions[m.get_string(1)] = { params=params, body=d.substr(brace+1, d.rfind("}")-brace-1) }

## The functions that no other function of the code calls
static func find_roots(functions : Dictionary) -> Array:
	var called : Dictionary = {}
	for f in functions.keys():
		for m in re_identifier.search_all(functions[f].body):
			if functions.has(m.get_string()) and m.get_string() != f:
				called[m.get_string()] = true
	var roots : Array = []
	for f in functions.keys():
		if not called.has(f):
			roots.append(f)
	return roots

static func find_closing(s : String, open : int) -> int:
	var op : String = s[open]
	var cp : String = { "(": ")", "{": "}", "[": "]" }[op]
	var level : int = 0
	for i in range(open, s.length()):
		if s[i] == op:
			level += 1
		elif s[i] == cp:
			level -= 1
			if level == 0:
				return i
	return -1

static func split_top_level(s : String, separator : String) -> Array[String]:
	var rv : Array[String] = []
	var level : int = 0
	var start : int = 0
	for i in s.length():
		var c : String = s[i]
		if c in "([{":
			level += 1
		elif c in ")]}":
			level -= 1
		elif c == separator and level == 0:
			rv.append(s.substr(start, i-start))
			start = i+1
	rv.append(s.substr(start))
	return rv


# Constant expressions

## The value of an expression made of numbers, int() and float() conversions,
## and the identifiers of env (or of the constants of the code), or null
static func eval_const(expression : String, env : Dictionary, ctx : Dictionary):
	expression = expression.strip_edges()
	if expression == "":
		return null
	var names : PackedStringArray = PackedStringArray()
	var values : Array = []
	for m in re_identifier.search_all(expression):
		var n : String = m.get_string()
		if n in names or n in ["int", "float", "uint", "min", "max", "floor", "ceil", "abs", "clamp"]:
			continue
		var v = env[n] if env.has(n) else ctx.constants.get(n)
		if v == null:
			return null
		names.append(n)
		values.append(v)
	# Literals such as 4u, 1.0f or 4.
	var cleaned : String = expression
	var re_suffix : RegEx = RegEx.create_from_string("(\\d)[uUfF]\\b")
	cleaned = re_suffix.sub(cleaned, "$1", true)
	cleaned = RegEx.create_from_string("(\\d)\\.(?!\\d)").sub(cleaned, "$1.0", true)
	var e : Expression = Expression.new()
	if e.parse(cleaned, names) != OK:
		return null
	var result = e.execute(values, null, false)
	if e.has_execute_failed() or not (result is float or result is int):
		return null
	return result


# Costs

## The cost of a function when its parameters have the values of env (a
## parameter that is not in env, or null in env, is not known): { c, t, u }
static func function_cost(function_name : String, env : Dictionary, ctx : Dictionary) -> Dictionary:
	var key : String = "%s|%s" % [ function_name, str(env) ]
	if ctx.memo.has(key):
		return ctx.memo[key]
	if function_name in ctx.stack or not ctx.functions.has(function_name):
		return { c=0, t=0, u=0 }
	ctx.stack.append(function_name)
	var rv : Dictionary = block_cost(ctx.functions[function_name].body, env, ctx)
	ctx.stack.pop_back()
	ctx.memo[key] = rv
	return rv

static func is_identifier_start(c : String) -> bool:
	return c == "_" or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z")

static func is_digit(c : String) -> bool:
	return c >= "0" and c <= "9"

static func skip_spaces(s : String, i : int) -> int:
	while i < s.length() and s[i] in " \t\r\n":
		i += 1
	return i

## The cost of a sequence of statements
static func block_cost(text : String, env : Dictionary, ctx : Dictionary) -> Dictionary:
	var rv : Dictionary = { c=0, t=0, u=0 }
	var i : int = 0
	var n : int = text.length()
	while i < n:
		var ch : String = text[i]
		if is_identifier_start(ch):
			var start : int = i
			while i < n and (is_identifier_start(text[i]) or is_digit(text[i])):
				i += 1
			var word : String = text.substr(start, i-start)
			var open : int = skip_spaces(text, i)
			var is_call : bool = open < n and text[open] == "("
			if (word == "for" or word == "while") and is_call:
				i = loop_cost(text, word, open, env, ctx, rv)
			elif is_call:
				call_cost(word, text, open, env, ctx, rv)
		elif is_digit(ch) or (ch == "." and i+1 < n and is_digit(text[i+1])):
			# A number (with its exponent, suffix and hexadecimal digits)
			while i < n and (is_identifier_start(text[i]) or is_digit(text[i]) or text[i] == "." or ((text[i] == "+" or text[i] == "-") and text[i-1] in "eE" and not text.substr(maxi(i-6, 0), 6).contains("0x"))):
				i += 1
		elif ch in "+-*/":
			rv.c += 1
			i += 2 if i+1 < n and text[i+1] in "=+-" and (text[i+1] == "=" or text[i+1] == ch) else 1
		elif ch in "<>":
			rv.c += 1
			i += 2 if i+1 < n and (text[i+1] == "=" or text[i+1] == ch) else 1
		elif (ch == "=" or ch == "!") and i+1 < n and text[i+1] == "=":
			rv.c += 1
			i += 2
		else:
			i += 1
	return rv

## Adds the cost of a call to the builtin or user function word, whose
## arguments start at text[open]
static func call_cost(word : String, text : String, open : int, env : Dictionary, ctx : Dictionary, rv : Dictionary) -> void:
	if word in KEYWORDS:
		return
	if word in TEXTURE_FUNCTIONS:
		rv.c += TEXTURE_COST
		rv.t += 1
	elif word in TRANSCENDENTALS:
		rv.c += TRANSCENDENTAL_COST
	elif ctx.functions.has(word):
		var close : int = find_closing(text, open)
		var args : Array[String] = split_top_level(text.substr(open+1, close-open-1) if close != -1 else "", ",")
		var callee_env : Dictionary = {}
		var params : Array = ctx.functions[word].params
		for p in params.size():
			callee_env[params[p]] = eval_const(args[p], env, ctx) if p < args.size() else null
		var cost : Dictionary = function_cost(word, callee_env, ctx)
		rv.c += cost.c
		rv.t += cost.t
		rv.u += cost.u
	elif BUILTIN_COSTS.has(word):
		rv.c += BUILTIN_COSTS[word]

## Adds the cost of a for or while loop whose parenthesis starts at text[open]
## to rv, and returns the index after the loop
static func loop_cost(text : String, keyword : String, open : int, env : Dictionary, ctx : Dictionary, rv : Dictionary) -> int:
	var close : int = find_closing(text, open)
	if close == -1:
		return text.length()
	var header : String = text.substr(open+1, close-open-1)
	var i : int = skip_spaces(text, close+1)
	var body : String = ""
	if i < text.length() and text[i] == "{":
		var end : int = find_closing(text, i)
		if end == -1:
			end = text.length()-1
		body = text.substr(i+1, end-i-1)
		i = end+1
	elif i < text.length() and text[i] == ";":
		# The end of a do ... while
		return i+1
	else:
		var end : int = text.find(";", i)
		if end == -1:
			end = text.length()-1
		body = text.substr(i, end-i+1)
		i = end+1
	var trips : int = -1
	if keyword == "for":
		trips = for_trip_count(header, env, ctx)
		var break_trips : int = for_break_count(header, body, env, ctx)
		if break_trips != -1:
			trips = break_trips if trips == -1 else mini(trips, break_trips)
	var body_env : Dictionary = env
	var cost : Dictionary
	if trips == -1:
		trips = UNKNOWN_TRIP_COUNT
		rv.u += 1
	cost = block_cost(body, body_env, ctx)
	rv.c += cost.c*trips
	rv.t += cost.t*trips
	rv.u += cost.u*trips
	return i

## The number of iterations of a for loop that counts up by 1 and whose body
## starts with if (<i> >= X) break; (or <i> > X, or float(<i>) instead of <i>)
## where X has a known value (such as for (int i = 0; i < 10; ++i) { if (i >=
## octaves) break; ... }), or -1
static func for_break_count(header : String, body : String, env : Dictionary, ctx : Dictionary) -> int:
	var parts : Array[String] = split_top_level(header, ";")
	if parts.size() != 3:
		return -1
	var init : RegExMatch = RegEx.create_from_string("(\\w+)\\s*=\\s*(.+)$").search(parts[0].strip_edges())
	if init == null:
		return -1
	var variable : String = init.get_string(1)
	if not parts[2].replace(" ", "") in [ "++"+variable, variable+"++", variable+"+=1" ]:
		return -1
	var start = eval_const(init.get_string(2), env, ctx)
	var re : RegEx = RegEx.create_from_string("^\\s*if\\s*\\(\\s*(?:float\\s*\\(\\s*"+variable+"\\s*\\)|"+variable+")\\s*(>=|>)\\s*(.+?)\\s*\\)\\s*\\{?\\s*break\\s*;")
	var m : RegExMatch = re.search(body)
	if start == null or m == null:
		return -1
	var bound = eval_const(m.get_string(2), env, ctx)
	if bound == null:
		return -1
	var last : float = ceil(float(bound)) if m.get_string(1) == ">=" else floor(float(bound))+1.0
	return maxi(int(last-float(start)), 0)

## The number of iterations of a for loop, from the text between its
## parenthesis, or -1
static func for_trip_count(header : String, env : Dictionary, ctx : Dictionary) -> int:
	var parts : Array[String] = split_top_level(header, ";")
	if parts.size() != 3:
		return -1
	var init : RegExMatch = RegEx.create_from_string("(\\w+)\\s*=\\s*(.+)$").search(parts[0].strip_edges())
	if init == null:
		return -1
	var variable : String = init.get_string(1)
	var start = eval_const(init.get_string(2), env, ctx)
	var condition : RegExMatch = RegEx.create_from_string("^\\s*"+variable+"\\s*(<=|<|>=|>|!=)\\s*(.+?)\\s*$").search(parts[1])
	if start == null or condition == null:
		return -1
	var bound = eval_const(condition.get_string(2), env, ctx)
	if bound == null:
		return -1
	var step : String = parts[2].replace(" ", "")
	var increment : float = 0.0
	if step == "++"+variable or step == variable+"++":
		increment = 1.0
	elif step == "--"+variable or step == variable+"--":
		increment = -1.0
	elif step.begins_with(variable+"+="):
		increment = float(eval_const(step.substr(variable.length()+2), env, ctx) if eval_const(step.substr(variable.length()+2), env, ctx) != null else 0.0)
	elif step.begins_with(variable+"-="):
		increment = -float(eval_const(step.substr(variable.length()+2), env, ctx) if eval_const(step.substr(variable.length()+2), env, ctx) != null else 0.0)
	if increment == 0.0:
		return -1
	var distance : float
	match condition.get_string(1):
		"<":
			distance = float(bound)-float(start)
		"<=":
			distance = float(bound)-float(start)+(1.0 if increment > 0.0 else 0.0)
		">":
			distance = float(start)-float(bound)
		">=":
			distance = float(start)-float(bound)+1.0
		_:
			distance = absf(float(bound)-float(start))
	if (increment > 0.0) != (condition.get_string(1) in ["<", "<=", "!="]) and condition.get_string(1) != "!=":
		return 0
	return maxi(int(ceil(distance/absf(increment))), 0)
