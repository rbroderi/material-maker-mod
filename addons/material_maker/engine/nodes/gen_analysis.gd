@tool
extends MMGenGpuReduction
class_name MMGenAnalysis


# Base class of nodes that analyze their input with a GPU pass (that
# accumulates results in an int array with atomics), process the results on
# the CPU, and provide the result as a small texture (see the Histogram and
# Fill to Index nodes).
#
# Subclasses define get_input_type(), get_result_size(), get_analysis_code()
# (GLSL that reads "value", the input as a vec4, "pixel" and "image_size",
# and writes to mm_out.mm_results) and process_results().


func get_template_path() -> String:
	return "res://addons/material_maker/engine/nodes/analysis_compute.tres"

func get_template_replacements() -> Dictionary:
	return { "@ANALYSIS": get_analysis_code() }

## Number of ints in the results array
func get_result_size() -> int:
	return 0

## Initial values of the results array (zeros by default)
func get_initial_results() -> PackedInt32Array:
	var rv : PackedInt32Array = PackedInt32Array()
	rv.resize(get_result_size())
	return rv

func get_analysis_code() -> String:
	return ""

## Converts the results to the image used as output texture
func process_results(_results : PackedInt32Array, _size : int) -> Image:
	return null

## The template reads the input as a vec4
func prepare_source(source : ShaderCode, connected : bool) -> void:
	if not connected:
		source.output_values[get_input_type()] = "vec4(0.0)" if get_input_type() != "f" else "0.0"
	var value : String = source.output_values.get(get_input_type(), source.output_values.get("rgba", "vec4(0.0)"))
	source.output_values.rgba = "vec4(%s)" % value if get_input_type() != "fill" else value

func use_results(results : PackedInt32Array, size : int):
	var image : Image = process_results(results, size)
	if image == null:
		return null
	texture.set_texture(ImageTexture.create_from_image(image))
	return texture
