@tool
extends MMGenGpuReduction
class_name MMGenStatistics


# Statistics nodes compute the minimum, maximum and mean value of each channel
# of their input on the GPU, and provide them as outputs that are constant over
# the whole image.
# The results are stored in a vec4[3] uniform named after the node's buffer,
# so shaders that use them wait for the statistics to be computed.


const RESULT_SIZE : int = 16 # min[4], max[4], sum low words[4], sum high words[4]

var stats : PackedColorArray = PackedColorArray([ Color(0.0, 0.0, 0.0, 0.0), Color(1.0, 1.0, 1.0, 1.0), Color(0.5, 0.5, 0.5, 0.5) ])


func get_type() -> String:
	return "statistics"

func get_type_name() -> String:
	return "Statistics"

func get_description() -> String:
	var desc_list : PackedStringArray = PackedStringArray()
	desc_list.push_back(TranslationServer.translate("Statistics"))
	desc_list.push_back(TranslationServer.translate("Computes the minimum, maximum and mean value of its input"))
	return "\n".join(desc_list)

func get_buffer_suffix() -> String:
	return "stats"

func get_template_path() -> String:
	return "res://addons/material_maker/engine/nodes/statistics_compute.tres"

func get_template_size_name() -> String:
	return "mm_stats_size"

func get_size_parameter_def() -> Dictionary:
	return { name="size", label="Size", type="size", first=4, last=14, default=10,
		longdesc="The resolution at which the input is sampled" }

func get_output_defs(_show_hidden : bool = false) -> Array:
	return [
		{ type="rgba", shortdesc="Min", longdesc="The minimum value of each channel" },
		{ type="rgba", shortdesc="Max", longdesc="The maximum value of each channel" },
		{ type="rgba", shortdesc="Mean", longdesc="The mean value of each channel" }
	]

func get_results_name() -> String:
	return "mm_stats"

func get_initial_results() -> PackedInt32Array:
	var initial_values : PackedInt32Array = PackedInt32Array()
	initial_values.resize(RESULT_SIZE)
	for c in 4:
		initial_values[c] = 0x7FFFFFFF
		initial_values[4+c] = -0x80000000
	return initial_values

func use_results(results : PackedInt32Array, size : int):
	stats = decode_results(results, size*size)
	return stats

static func ordered_int_to_float(i : int) -> float:
	if i < 0:
		i = i ^ 0x7FFFFFFF
	var bytes : PackedByteArray = PackedByteArray()
	bytes.resize(4)
	bytes.encode_s32(0, i)
	return bytes.decode_float(0)

static func decode_results(results : PackedInt32Array, pixel_count : int) -> PackedColorArray:
	var min_value : Color = Color()
	var max_value : Color = Color()
	var mean_value : Color = Color()
	for c in 4:
		min_value[c] = ordered_int_to_float(results[c])
		max_value[c] = ordered_int_to_float(results[4+c])
		var sum : int = results[12+c]*0x100000000 + (results[8+c] & 0xFFFFFFFF)
		mean_value[c] = float(sum)/65536.0/float(pixel_count)
	return PackedColorArray([ min_value, max_value, mean_value ])

func _get_shader_code(_uv : String, output_index : int, _context : MMGenContext) -> ShaderCode:
	var rv : ShaderCode = ShaderCode.new()
	rv.add_uniform(get_buffer_name(), "vec4", stats, 3)
	rv.output_type = "rgba"
	rv.output_values.rgba = "%s[%d]" % [ get_buffer_name(), output_index ]
	return rv
