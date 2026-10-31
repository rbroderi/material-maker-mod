extends GutTest

## Tests for the $if / $elif / $else / $fi blocks of material templates
## (MMGenMaterial.process_conditionals).

var material : MMGenMaterial

func before_each() -> void:
	material = MMGenMaterial.new()
	material.shader_model = {
		inputs = [],
		parameters = [
			{ name = "on", type = "boolean", default = true },
			{ name = "off", type = "boolean", default = false },
			{ name = "amount", type = "float", default = 0.5 },
			{ name = "mode", type = "float", default = 2.0 },
		]
	}

func after_each() -> void:
	material.free()

func process(lines : Array) -> Array:
	var template : String = "\n".join(PackedStringArray(lines))
	return Array(material.process_conditionals(template).split("\n", false))

func test_lines_outside_blocks() -> void:
	assert_eq(process([ "a", "", "b" ]), [ "a", "b" ])
	assert_eq(process([ "a", "$if true", "b", "$fi", "c" ]), [ "a", "b", "c" ])
	assert_eq(process([ "a", "$if false", "b", "$fi", "c" ]), [ "a", "c" ])

func test_parameters() -> void:
	assert_eq(process([ "$if $(param:on)", "a", "$fi" ]), [ "a" ])
	assert_eq(process([ "$if $(param:off)", "a", "$else", "b", "$fi" ]), [ "b" ])
	assert_eq(process([ "$if $(param:amount) > 0.25", "a", "$fi" ]), [ "a" ])
	assert_eq(process([ "$if $(param:on) and $(param:amount) > 0.75", "a", "$fi" ]), [])

func test_else() -> void:
	assert_eq(process([ "$if true", "a", "$else", "b", "$fi", "c" ]), [ "a", "c" ])
	assert_eq(process([ "$if false", "a", "$else", "b", "$fi", "c" ]), [ "b", "c" ])

func test_nested_two_levels() -> void:
	for outer in [ true, false ]:
		for inner in [ true, false ]:
			var expected : Array = [ "begin" ]
			if outer:
				expected.append("o1")
				expected.append("i" if inner else "ie")
				expected.append("o2")
			else:
				expected.append("oe")
			expected.append("end")
			var lines : Array = [
				"begin",
				"$if "+str(outer),
				"o1",
				"$if "+str(inner),
				"i",
				"$else",
				"ie",
				"$fi",
				"o2",
				"$else",
				"oe",
				"$fi",
				"end" ]
			assert_eq(process(lines), expected, "outer=%s inner=%s" % [ outer, inner ])

func test_nested_in_else_branch() -> void:
	var lines : Array = [ "$if $(param:on)", "a", "$else", "$if true", "b", "$else", "c", "$fi", "$fi", "d" ]
	assert_eq(process(lines), [ "a", "d" ])
	lines[0] = "$if $(param:off)"
	assert_eq(process(lines), [ "b", "d" ])

func test_nested_three_levels() -> void:
	for a in [ true, false ]:
		for b in [ true, false ]:
			for c in [ true, false ]:
				var lines : Array = [
					"$if "+str(a),
					"$if "+str(b),
					"$if "+str(c),
					"abc",
					"$else",
					"ab_",
					"$fi",
					"$else",
					"$if "+str(c),
					"a_c",
					"$else",
					"a__",
					"$fi",
					"$fi",
					"$else",
					"$if "+str(b),
					"_b",
					"$else",
					"__",
					"$fi",
					"$fi",
					"after" ]
				var expected : String
				if a:
					if b:
						expected = "abc" if c else "ab_"
					else:
						expected = "a_c" if c else "a__"
				else:
					expected = "_b" if b else "__"
				assert_eq(process(lines), [ expected, "after" ], "a=%s b=%s c=%s" % [ a, b, c ])

func test_conditions_in_skipped_blocks_are_not_evaluated() -> void:
	# An invalid condition inside a skipped block must not change the output
	assert_eq(process([ "$if false", "$if (", "a", "$else", "b", "$fi", "$fi", "c" ]), [ "c" ])

func test_elif() -> void:
	for mode in range(4):
		material.parameters.mode = float(mode)
		var lines : Array = [
			"$if $(param:mode) == 0",
			"zero",
			"$elif $(param:mode) == 1",
			"one",
			"$elif $(param:mode) == 2",
			"two",
			"$else",
			"other",
			"$fi" ]
		assert_eq(process(lines), [ [ "zero", "one", "two", "other" ][mode] ], "mode=%d" % mode)

func test_elif_first_true_branch_wins() -> void:
	assert_eq(process([ "$if false", "a", "$elif true", "b", "$elif true", "c", "$else", "d", "$fi" ]), [ "b" ])
	assert_eq(process([ "$if true", "a", "$elif true", "b", "$fi" ]), [ "a" ])

func test_elif_nested() -> void:
	var lines : Array = [ "$if false", "$elif true", "$if false", "a", "$elif true", "b", "$fi", "$else", "c", "$fi" ]
	assert_eq(process(lines), [ "b" ])
	assert_eq(process([ "$if false", "$if true", "a", "$elif true", "b", "$fi", "$fi" ]), [])

func test_indented_directives() -> void:
	var lines : Array = [
		"$if true",
		"\ta",
		"\t$if false",
		"\t\tb",
		"\t$else",
		"\t\tc",
		"\t$fi",
		"  $if   true  ",
		"    d",
		"  $fi",
		"$fi" ]
	assert_eq(process(lines), [ "\ta", "\t\tc", "    d" ])

func test_carriage_returns() -> void:
	# Templates read from files with CRLF line endings
	assert_eq(process([ "$if false\r", "a\r", "$else\r", "b\r", "$fi\r", "c\r" ]), [ "b\r", "c\r" ])

func test_directive_names_are_whole_words() -> void:
	# Lines that only start like a directive are kept as they are
	assert_eq(process([ "$iffy", "$fixed", "$elsewhere" ]), [ "$iffy", "$fixed", "$elsewhere" ])

func test_unbalanced_blocks() -> void:
	# Missing $fi: the block extends to the end of the template
	assert_eq(process([ "a", "$if false", "b" ]), [ "a" ])
	assert_eq(process([ "a", "$if true", "b" ]), [ "a", "b" ])
	# Unmatched $fi, $else and $elif are reported and ignored
	assert_eq(process([ "a", "$fi", "b" ]), [ "a", "b" ])
	assert_eq(process([ "a", "$else", "b" ]), [ "a", "b" ])
	assert_eq(process([ "a", "$elif false", "b" ]), [ "a", "b" ])
	assert_eq(process([ "$if false", "a", "$fi", "$fi", "b" ]), [ "b" ])

func test_invalid_condition_keeps_block() -> void:
	# A condition that cannot be parsed is reported, and the block is kept
	# (as before), with its $else branch skipped
	assert_eq(process([ "$if (", "a", "$else", "b", "$fi", "c" ]), [ "a", "c" ])
	assert_eq(process([ "$if true", "$if (", "a", "$fi", "b", "$fi", "c" ]), [ "a", "b", "c" ])
