extends GutTest

## Tests for the #if / #elif / #else / #endif blocks of shaders
## (mm_preprocessor.preprocess_ifs).

var preprocessor : Node

func before_each() -> void:
	preprocessor = load("res://addons/material_maker/engine/preprocessor.gd").new()

func after_each() -> void:
	preprocessor.free()

func process(lines : Array) -> Array:
	var shader : String = "\n".join(PackedStringArray(lines))+"\n"
	return Array(preprocessor.preprocess_ifs(shader).split("\n", false))

func test_if() -> void:
	assert_eq(process([ "a", "#if true", "b", "#else", "c", "#endif", "d" ]), [ "a", "b", "d" ])
	assert_eq(process([ "a", "#if false", "b", "#else", "c", "#endif", "d" ]), [ "a", "c", "d" ])

func test_ifdef_is_left_to_the_shader_compiler() -> void:
	var lines : Array = [ "a", "#ifdef X", "b", "#else", "c", "#endif", "#ifndef Y", "d", "#endif", "e" ]
	assert_eq(process(lines), lines)

func test_if_inside_ifdef() -> void:
	var lines : Array = [ "#ifdef X", "#if false", "a", "#else", "b", "#endif", "#else", "c", "#endif" ]
	assert_eq(process(lines), [ "#ifdef X", "b", "#else", "c", "#endif" ])

func test_ifdef_inside_if() -> void:
	var lines : Array = [ "#if true", "#ifdef X", "a", "#else", "b", "#endif", "#else", "c", "#endif" ]
	assert_eq(process(lines), [ "#ifdef X", "a", "#else", "b", "#endif" ])
	lines[0] = "#if false"
	assert_eq(process(lines), [ "c" ])
