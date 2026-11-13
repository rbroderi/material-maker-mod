extends RefCounted

## Translation of the GLSL matrix products to HLSL (a step of
## MMGenMaterial.process_option_hlsl_base, run on code whose types are already
## translated).
##
## HLSL matrices are the transposes of the GLSL ones, as cross compilers do: each
## GLSL column is an HLSL row (see the tofloatNxN constructors of hlsl_defs.tmpl).
## So m[i] is the same column in both languages, transpose, inverse and
## determinant commute, and every GLSL product that involves a matrix becomes a
## mul() with swapped operands:
##   a*b    ->  mul(b, a)       (M*v -> mul(v, M), v*M -> mul(M, v), M1*M2 -> mul(M2, M1))
##   a *= b ->  a = mul(b, a)
## A scalar times a matrix stays a *.
##
## The matrix (and scalar) operands are found from the matrix constructors, the
## identifiers declared with a matrix (or scalar) type in their scope (local and
## global variables, function parameters, uniforms, also from the declarations
## of the shader), the calls of functions that return a matrix (or a scalar),
## transpose()/inverse() of a matrix, indexing, swizzles and parenthesized
## expressions. A * is left associative and binds tighter than + and -.

const MARK_M : String = "__mmM__"
const MARK_A : String = "__mmA__"
const MARK_S : String = "__mmS__"

const W : int = 0
const ID : int = 1
const NUM : int = 2
const OP : int = 3

const KEYWORDS : Array = [ "return", "else", "case", "default", "do", "if", "while", "for", "switch",
	"break", "continue", "discard", "in", "out", "inout", "const", "uniform", "static", "highp",
	"mediump", "lowp", "precision", "flat", "smooth", "noperspective", "varying", "attribute",
	"inline", "struct", "typedef" ]
const MATRIX_TYPES : Array = [ "mat2", "mat3", "mat4", "float2x2", "float3x3", "float4x4" ]
const SCALAR_TYPES : Array = [ "float", "int", "uint", "bool", "half", "double" ]
const MATRIX_FUNCTIONS : Array = [ "tofloat2x2", "tofloat3x3", "tofloat4x4", "float2x2", "float3x3", "float4x4", "mat2", "mat3", "mat4" ]
const SCALAR_FUNCTIONS : Array = [ "float", "int", "uint", "bool", "dot", "length", "distance", "determinant" ]
const SAME_TYPE_FUNCTIONS : Array = [ "transpose", "inverse", "hlsl_inverse" ]
const DECLARATION_ENDS : Array = [ "=", ";", ",", ")", "[", "(" ]

static var re_token : RegEx = RegEx.create_from_string("//[^\\n]*|/\\*[\\s\\S]*?\\*/|#[^\\n]*|\\s+|[A-Za-z_]\\w*|(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][+-]?\\d+)?\\w*|[*/+\\-=!<>&|^%]=|&&|\\|\\||\\+\\+|--|<<|>>|.")
static var re_matrix : RegEx = RegEx.create_from_string("\\b(?:mat[234]|(?:to)?float[234]x[234])\\b")
static var re_matrix_names : RegEx = RegEx.create_from_string("\\b(?:mat[234]|float[234]x[234])\\s+(\\w+)")

## Translates the matrix products of code (HLSL types, GLSL products).
## declarations is the code (GLSL or HLSL) that declares the global variables and
## functions code uses ("" when code contains its own declarations).
static func translate(code : String, declarations : String = "") -> String:
	var needed : bool = re_matrix.search(code) != null
	if not needed:
		for m in re_matrix_names.search_all(declarations):
			if RegEx.create_from_string("\\b"+m.strings[1]+"\\b").search(code) != null:
				needed = true
				break
	if not needed:
		return code
	var functions : Dictionary = {}
	var globals : Dictionary = {}
	if declarations != "":
		var d : Array = tokenize(declarations)
		globals = scan(d[0], d[1], {}, functions, false).globals
	var t : Array = tokenize(code)
	var kinds : PackedByteArray = t[1]
	var texts : PackedStringArray = scan(t[0], kinds, globals, functions, true).texts
	var matching : PackedInt32Array = match_brackets(texts, kinds)
	if matching.is_empty():
		return code
	var rv : Array = rewrite_level(texts, kinds, matching, 0, texts.size())
	return rv[0].replace(MARK_M, "").replace(MARK_A, "").replace(MARK_S, "")

static func tokenize(code : String) -> Array:
	var texts : PackedStringArray = PackedStringArray()
	var kinds : PackedByteArray = PackedByteArray()
	for m in re_token.search_all(code):
		var s : String = m.get_string()
		texts.append(s)
		var c : int = s.unicode_at(0)
		if s.length() > 1 and (s.begins_with("//") or s.begins_with("/*")):
			kinds.append(W)
		elif c == 35 or c == 32 or c == 9 or c == 10 or c == 13:
			kinds.append(W)
		elif c == 95 or (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
			kinds.append(ID)
		elif (c >= 48 and c <= 57) or (c == 46 and s.length() > 1):
			kinds.append(NUM)
		elif s.strip_edges() == "":
			kinds.append(W)
		else:
			kinds.append(OP)
	return [ texts, kinds ]

static func next_token(kinds : PackedByteArray, i : int) -> int:
	while i < kinds.size() and kinds[i] == W:
		i += 1
	return i

static func type_kind(type : String, is_array : bool) -> String:
	if type in MATRIX_TYPES:
		return "A" if is_array else "M"
	if type in SCALAR_TYPES and not is_array:
		return "S"
	return "U"

static func lookup(scopes : Array, pending : Dictionary, name : String) -> String:
	if pending.has(name):
		return pending[name]
	for i in range(scopes.size()-1, -1, -1):
		if scopes[i].has(name):
			return scopes[i][name]
	return ""

## Finds the declarations (in their scope, braces and the parameters of the
## next block) and the functions that return a matrix or a scalar. When mark is
## true, appends a marker to each identifier that is (or each call that
## returns) a matrix (MARK_M), an array of matrices (MARK_A) or a scalar
## (MARK_S). Returns { globals (the global variables), texts (the marked tokens) }.
static func scan(texts : PackedStringArray, kinds : PackedByteArray, base : Dictionary, functions : Dictionary, mark : bool) -> Dictionary:
	var scopes : Array = [ base.duplicate() ]
	var pending : Dictionary = {}
	var depth : int = 0
	var decl_type : String = ""
	var decl_depth : int = -1
	var comma_decl : bool = false
	var previous : String = ""
	var n : int = texts.size()
	for i in n:
		var k : int = kinds[i]
		if k == W:
			continue
		var t : String = texts[i]
		if k == OP:
			match t:
				"(", "[":
					depth += 1
				")", "]":
					depth -= 1
				"{":
					scopes.append(pending)
					pending = {}
					decl_type = ""
				"}":
					if scopes.size() > 1:
						scopes.pop_back()
					decl_type = ""
				";":
					if depth == 0:
						pending = {}
					if depth <= decl_depth:
						decl_type = ""
				",":
					if decl_type != "" and depth == decl_depth:
						comma_decl = true
		elif k == ID and previous != ".":
			var j : int = next_token(kinds, i+1)
			var after : int = next_token(kinds, j+1) if j < n else n
			if j < n and kinds[j] == ID and after < n and texts[after] in DECLARATION_ENDS and not t in KEYWORDS and not texts[j] in KEYWORDS:
				comma_decl = false
				if texts[after] == "(":
					if depth == 0:
						functions[texts[j]] = type_kind(t, false)
				else:
					var kind : String = type_kind(t, texts[after] == "[")
					if depth > 0:
						pending[texts[j]] = kind
					else:
						scopes.back()[texts[j]] = kind
					decl_type = t
					decl_depth = depth
			else:
				if comma_decl:
					comma_decl = false
					if j < n and texts[j] in [ "=", ";", ",", ")", "[" ]:
						var kind : String = type_kind(decl_type, texts[j] == "[")
						if depth > 0:
							pending[t] = kind
						else:
							scopes.back()[t] = kind
				if mark:
					var kind : String
					if j < n and texts[j] == "(":
						kind = functions.get(t, "")
					else:
						kind = lookup(scopes, pending, t)
					match kind:
						"M":
							texts[i] = t+MARK_M
						"A":
							texts[i] = t+MARK_A
						"S":
							texts[i] = t+MARK_S
		previous = t
	return { globals=scopes[0], texts=texts }

## The index of the matching bracket of each ( and [ (an empty array if they
## do not match)
static func match_brackets(texts : PackedStringArray, kinds : PackedByteArray) -> PackedInt32Array:
	var rv : PackedInt32Array = PackedInt32Array()
	rv.resize(texts.size())
	var stack : Array[int] = []
	for i in texts.size():
		if kinds[i] != OP:
			continue
		match texts[i]:
			"(", "[":
				stack.append(i)
			")", "]":
				if stack.is_empty():
					return PackedInt32Array()
				var o : int = stack.pop_back()
				if (texts[o] == "(") != (texts[i] == ")"):
					return PackedInt32Array()
				rv[o] = i
	if not stack.is_empty():
		return PackedInt32Array()
	return rv

## Rewrites the tokens lo..hi-1 (brackets first, then the products of this
## level). Returns [ text, type ] where type is "M" (matrix), "A" (array of
## matrices), "S" (scalar), "V" (vector) or "U" (unknown).
static func rewrite_level(texts : PackedStringArray, kinds : PackedByteArray, matching : PackedInt32Array, lo : int, hi : int) -> Array:
	var items : Array[Dictionary] = []
	var has_product : bool = false
	var i : int = lo
	while i < hi:
		var t : String = texts[i]
		if kinds[i] == OP and (t == "(" or t == "["):
			var c : int = matching[i]
			var inner : Array = rewrite_level(texts, kinds, matching, i+1, c)
			items.append({ k="g", s=t+inner[0]+texts[c], T=(inner[1] if t == "(" else "U"), br=t })
			i = c+1
			continue
		if kinds[i] == OP and (t == "*" or t == "*="):
			has_product = true
		items.append({ k=[ "w", "id", "num", "op" ][kinds[i]], s=t })
		i += 1
	if has_product:
		process_products(items)
	var text : String = ""
	for it in items:
		text += it.s
	return [ text, expr_type(items, 0, items.size()) ]

static func next_item(items : Array[Dictionary], i : int) -> int:
	while i < items.size() and items[i].k == "w":
		i += 1
	return i

static func previous_item(items : Array[Dictionary], i : int) -> int:
	i -= 1
	while i >= 0 and items[i].k == "w":
		i -= 1
	return i

static func is_op(items : Array[Dictionary], i : int, ops : Array) -> bool:
	return i >= 0 and i < items.size() and items[i].k == "op" and items[i].s in ops

static func is_operand_end(items : Array[Dictionary], i : int) -> bool:
	if i < 0:
		return false
	var it : Dictionary = items[i]
	return it.k in [ "num", "g", "x" ] or (it.k == "id" and not it.s in KEYWORDS)

static func join(items : Array[Dictionary], a : int, b : int) -> String:
	var rv : String = ""
	for i in range(a, b):
		rv += items[i].s
	return rv

static func replace(items : Array[Dictionary], a : int, b : int, item : Dictionary) -> void:
	for i in b-a:
		items.remove_at(a)
	items.insert(a, item)

## The first item of the postfix expression (primary, calls, indexing, member
## accesses) whose last item is q, or -1
static func postfix_start(items : Array[Dictionary], q : int) -> int:
	while q >= 0:
		var it : Dictionary = items[q]
		var p : int = previous_item(items, q)
		if it.k == "g":
			if p >= 0 and ((it.br == "[" and items[p].k in [ "id", "g", "x" ]) or (it.br == "(" and items[p].k == "id" and not items[p].s in KEYWORDS)):
				q = p
				continue
			return q
		elif it.k in [ "id", "num", "x" ]:
			if it.k == "id" and it.s in KEYWORDS:
				return -1
			if is_op(items, p, [ "." ]) and is_operand_end(items, previous_item(items, p)):
				q = previous_item(items, p)
				continue
			return q
		return -1
	return -1

## The first item of the left operand of the * at i: the multiplicative chain
## before it (* and / are left associative), or -1
static func chain_start(items : Array[Dictionary], i : int) -> int:
	var start : int = -1
	var j : int = i
	while true:
		var s : int = postfix_start(items, previous_item(items, j))
		if s < 0:
			break
		var p : int = previous_item(items, s)
		while is_op(items, p, [ "-", "+", "!" ]) and not is_operand_end(items, previous_item(items, p)):
			s = p
			p = previous_item(items, p)
		start = s
		if is_op(items, p, [ "*", "/" ]):
			j = p
			continue
		break
	return start

## The end (exclusive) of the unary expression that starts after i, or -1
static func unary_end(items : Array[Dictionary], i : int) -> int:
	var j : int = next_item(items, i)
	while is_op(items, j, [ "-", "+", "!" ]):
		j = next_item(items, j+1)
	if j >= items.size():
		return -1
	var it : Dictionary = items[j]
	if not (it.k in [ "id", "num", "x" ] or (it.k == "g" and it.br == "(")) or (it.k == "id" and it.s in KEYWORDS):
		return -1
	var end : int = j+1
	var after_name : bool = it.k == "id"
	while true:
		var n : int = next_item(items, end)
		if n >= items.size():
			break
		var nt : Dictionary = items[n]
		if nt.k == "g" and (nt.br == "[" or (nt.br == "(" and after_name)):
			end = n+1
			after_name = false
			continue
		if is_op(items, n, [ "." ]):
			var m : int = next_item(items, n+1)
			if m < items.size() and items[m].k == "id":
				end = m+1
				after_name = true
				continue
		break
	return end

static func call_type(name : String, arguments : Dictionary) -> String:
	if name.ends_with(MARK_M) or name in MATRIX_FUNCTIONS:
		return "M"
	if name.ends_with(MARK_S) or name in SCALAR_FUNCTIONS:
		return "S"
	if name in SAME_TYPE_FUNCTIONS and arguments.T == "M":
		return "M"
	return "U"

static func variable_type(name : String) -> String:
	if name.ends_with(MARK_M):
		return "M"
	if name.ends_with(MARK_A):
		return "A"
	if name.ends_with(MARK_S):
		return "S"
	return "U"

## The type of the unary expression a..b-1
static func unary_type(items : Array[Dictionary], a : int, b : int) -> String:
	var j : int = next_item(items, a)
	while j < b and is_op(items, j, [ "-", "+", "!" ]):
		j = next_item(items, j+1)
	if j >= b:
		return "U"
	var it : Dictionary = items[j]
	var type : String = "U"
	var end : int = j+1
	match it.k:
		"num":
			type = "S"
		"x":
			type = it.T
		"g":
			type = it.T if it.br == "(" else "U"
		"id":
			var n : int = next_item(items, j+1)
			if n < b and items[n].k == "g" and items[n].br == "(":
				type = call_type(it.s, items[n])
				end = n+1
			else:
				type = variable_type(it.s)
		_:
			return "U"
	while true:
		var n : int = next_item(items, end)
		if n >= b:
			break
		var nt : Dictionary = items[n]
		if nt.k == "g" and nt.br == "[":
			type = { "M": "V", "A": "M", "V": "S" }.get(type, "U")
			end = n+1
		elif is_op(items, n, [ "." ]):
			var m : int = next_item(items, n+1)
			if m >= b:
				break
			var member : String = items[m].s
			end = m+1
			var c : int = next_item(items, end)
			if c < b and items[c].k == "g" and items[c].br == "(":
				# A method (length())
				type = "S" if member == "length" else "U"
				end = c+1
			else:
				type = "S" if member.length() == 1 else "U"
		else:
			break
	return type

## The type of a product of factors separated by * and /
static func chain_type(items : Array[Dictionary], a : int, b : int) -> String:
	var any_matrix : bool = false
	var all_scalar : bool = true
	var start : int = a
	for i in range(a, b+1):
		if i == b or is_op(items, i, [ "*", "/" ]):
			var type : String = unary_type(items, start, i)
			any_matrix = any_matrix or type == "M"
			all_scalar = all_scalar and type == "S"
			start = i+1
	return "M" if any_matrix else ("S" if all_scalar else "U")

## The type of the expression a..b-1
static func expr_type(items : Array[Dictionary], a : int, b : int) -> String:
	var question : int = -1
	for i in range(a, b):
		if items[i].k == "op":
			if items[i].s in [ ",", "=", "+=", "-=", "*=", "/=", ";", "{", "}", "<", ">", "<=", ">=", "==", "!=", "&&", "||", "!" ]:
				return "U"
			if items[i].s == "?" and question == -1:
				question = i
	if question != -1:
		for i in range(question+1, b):
			if is_op(items, i, [ ":" ]):
				var t1 : String = expr_type(items, question+1, i)
				var t2 : String = expr_type(items, i+1, b)
				return "M" if t1 == "M" or t2 == "M" else "U"
		return "U"
	var any_matrix : bool = false
	var all_scalar : bool = true
	var start : int = a
	for i in range(a, b+1):
		if i == b or (is_op(items, i, [ "+", "-" ]) and is_operand_end(items, previous_item(items, i)) and previous_item(items, i) >= start):
			if next_item(items, start) < i:
				var type : String = chain_type(items, start, i)
				any_matrix = any_matrix or type == "M"
				all_scalar = all_scalar and type == "S"
			start = i+1
	if any_matrix:
		return "M"
	return "S" if all_scalar and next_item(items, a) < b else "U"

static func process_products(items : Array[Dictionary]) -> void:
	var i : int = 0
	while i < items.size():
		if is_op(items, i, [ "*" ]):
			var a : int = chain_start(items, i)
			var b : int = unary_end(items, i+1)
			if a >= 0 and b >= 0:
				var left : String = chain_type(items, a, i)
				var right : String = unary_type(items, i+1, b)
				if (left == "M" or right == "M") and not (left == "M" and right == "S") and not (left == "S" and right == "M"):
					var text : String = "mul(%s, %s)" % [ join(items, i+1, b).strip_edges(), join(items, a, i).strip_edges() ]
					replace(items, a, b, { k="x", s=text, T=("M" if left == "M" and right == "M" else "V") })
					i = a+1
					continue
		elif is_op(items, i, [ "*=" ]):
			var a : int = postfix_start(items, previous_item(items, i))
			var b : int = i+1
			while b < items.size() and not is_op(items, b, [ ";", ",", "{", "}" ]):
				b += 1
			if a >= 0 and next_item(items, i+1) < b:
				var left : String = unary_type(items, a, i)
				var right : String = expr_type(items, i+1, b)
				if (left == "M" or right == "M") and not (left == "M" and right == "S"):
					var target : String = join(items, a, i).strip_edges()
					var value : String = join(items, i+1, b)
					var trailing : String = value.substr(value.strip_edges(false, true).length())
					var text : String = "%s = mul(%s, %s)%s" % [ target, value.strip_edges(), target, trailing ]
					replace(items, a, b, { k="x", s=text, T="U" })
					i = a+1
					continue
		i += 1
