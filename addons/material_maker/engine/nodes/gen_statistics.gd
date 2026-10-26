@tool
extends MMGenBase
class_name MMGenStatistics


# Statistics nodes compute the minimum, maximum and mean value of each channel
# of their input on the GPU, and provide them as outputs that are constant over
# the whole image.
# The results are stored in a vec4[3] uniform named after the node's buffer,
# so shaders that use them wait for the statistics to be computed.


const RESULT_SIZE : int = 16 # min[4], max[4], sum low words[4], sum high words[4]

var exiting : bool = false

var shader_compute : MMShaderCompute
var is_paused : bool = false

var stats : PackedColorArray = PackedColorArray([ Color(0.0, 0.0, 0.0, 0.0), Color(1.0, 1.0, 1.0, 1.0), Color(0.5, 0.5, 0.5, 0.5) ])


func _ready() -> void:
	shader_compute = MMShaderCompute.new()
	if !parameters.has("size"):
		parameters.size = 10
	mm_deps.create_buffer(get_buffer_name(), self)
	do_update_shader()

func _exit_tree() -> void:
	exiting = true

func get_type() -> String:
	return "statistics"

func get_type_name() -> String:
	return "Statistics"

func get_description() -> String:
	var desc_list : PackedStringArray = PackedStringArray()
	desc_list.push_back(TranslationServer.translate("Statistics"))
	desc_list.push_back(TranslationServer.translate("Computes the minimum, maximum and mean value of its input"))
	return "\n".join(desc_list)

func get_buffer_name() -> String:
	return "o%d_stats" % get_instance_id()

func get_size_parameter_name() -> String:
	return "o%d_stats_size" % get_instance_id()

func get_image_size() -> int:
	return int(pow(2, get_parameter("size")))

func set_paused(v : bool) -> void:
	if v == is_paused:
		return
	is_paused = v
	if ! v:
		mm_deps.update()

func get_buffers(flags : int = BUFFERS_ALL) -> Array:
	if ( is_paused and flags == BUFFERS_RUNNING ) or ( ! is_paused and flags == BUFFERS_PAUSED ):
		return []
	return [ self ]

func get_parameter_defs() -> Array:
	return [
		{ name="size", label="Size", type="size", first=4, last=14, default=10,
			longdesc="The resolution at which the input is sampled" }
	]

func get_input_defs() -> Array:
	return [ { name="in", type="rgba" } ]

func get_output_defs(_show_hidden : bool = false) -> Array:
	return [
		{ type="rgba", shortdesc="Min", longdesc="The minimum value of each channel" },
		{ type="rgba", shortdesc="Max", longdesc="The maximum value of each channel" },
		{ type="rgba", shortdesc="Mean", longdesc="The mean value of each channel" }
	]

func source_changed(_input_port_index : int) -> void:
	update_shader()

func all_sources_changed() -> void:
	update_shader()

func set_parameter(n : String, v) -> void:
	if is_inside_tree() and n == "size":
		mm_deps.dependency_update(get_size_parameter_name(), float(pow(2, v)))
	super.set_parameter(n, v)

var updating_shader : bool = false
func update_shader() -> void:
	if ! updating_shader:
		updating_shader = true
		do_update_shader.call_deferred()

func do_update_shader() -> void:
	if ! is_instance_valid(self) or exiting:
		return
	if not is_node_ready():
		await ready
	updating_shader = false
	var context : MMGenContext = MMGenContext.new()
	var source : ShaderCode
	var source_output : OutputPort = get_source(0)
	if source_output != null:
		source = source_output.generator.get_shader_code("uv", source_output.output_index, context)
	if source == null or source.output_type == "":
		source = get_default_generated_shader()
	var shader_template : String = load("res://addons/material_maker/engine/nodes/statistics_compute.tres").text
	var output_textures : Array[Dictionary] = []
	var extra_parameters : Array[Dictionary] = [
		{ name="elapsed_time", type="float", value=0.0 },
		{ name=get_size_parameter_name(), type="float", value=float(get_image_size()) }
	]
	var extra_output_parameters : Array[Dictionary] = [ { name="mm_stats", type="int", array_size=RESULT_SIZE } ]
	shader_template = shader_template.replace("mm_stats_size", get_size_parameter_name())
	var shader_status : bool = await shader_compute.compute_shader.set_shader_from_shadercode_ext(shader_template, source, output_textures, extra_parameters, false, extra_output_parameters)
	if shader_status:
		await mm_deps.buffer_create_compute_material(get_buffer_name(), shader_compute)
		mm_deps.update()
	else:
		print("statistics shader is invalid")

func on_dep_update_value(_buffer_name, parameter_name, value) -> bool:
	if value != null:
		shader_compute.set_parameter(parameter_name, value)
	return false

func on_dep_update_buffer(buffer_name : String) -> bool:
	if is_paused:
		return false
	var size : int = get_image_size()
	var initial_values : PackedInt32Array = PackedInt32Array()
	initial_values.resize(RESULT_SIZE)
	for c in 4:
		initial_values[c] = 0x7FFFFFFF
		initial_values[4+c] = -0x80000000
	var output_parameters_values : Dictionary = { mm_stats=initial_values }
	var textures : Array[MMTexture] = []
	var status : bool = await shader_compute.compute_shader.render_ext(textures, Vector2i(size, size), output_parameters_values)
	if not status or not output_parameters_values.has("mm_stats"):
		print("Failed to update statistics")
		return false
	rendering_time = shader_compute.get_render_time()
	rendering_time_updated.emit(rendering_time)
	stats = decode_results(output_parameters_values.mm_stats, size*size)
	mm_deps.dependency_update(buffer_name, stats, true)
	return true

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

func _serialize(data: Dictionary) -> Dictionary:
	data.type = get_type()
	return data
