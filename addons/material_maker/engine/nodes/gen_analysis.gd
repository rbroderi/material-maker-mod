@tool
extends MMGenTexture
class_name MMGenAnalysis


# Base class of nodes that analyze their input with a GPU pass (that
# accumulates results in an int array with atomics), process the results on
# the CPU, and provide the result as a small texture (see the Histogram and
# Fill to Index nodes).
#
# Subclasses define get_input_type(), get_result_size(), get_analysis_code()
# (GLSL that reads "value", the input as a vec4, "pixel" and "image_size",
# and writes to mm_out.mm_results) and process_results().


var exiting : bool = false
var shader_compute : MMShaderCompute
var is_paused : bool = false


func _ready() -> void:
	shader_compute = MMShaderCompute.new()
	if !parameters.has("size"):
		parameters.size = 10
	mm_deps.create_buffer(get_buffer_name(), self)
	do_update_shader()

func _exit_tree() -> void:
	exiting = true

func get_buffer_name() -> String:
	return "o%d_tex" % get_instance_id()

func get_size_parameter_name() -> String:
	return "o%d_analysis_size" % get_instance_id()

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
	return [ { name="size", label="Size", type="size", first=4, last=12, default=10, longdesc="The resolution at which the input is analyzed" } ]

func get_input_type() -> String:
	return "rgba"

func get_input_defs() -> Array:
	return [ { name="in", type=get_input_type() } ]

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
		source.output_values[get_input_type()] = "vec4(0.0)" if get_input_type() != "f" else "0.0"
	# The template reads the input as a vec4
	var value : String = source.output_values.get(get_input_type(), source.output_values.get("rgba", "vec4(0.0)"))
	source.output_values.rgba = "vec4(%s)" % value if get_input_type() != "fill" else value
	var shader_template : String = load("res://addons/material_maker/engine/nodes/analysis_compute.tres").text
	shader_template = shader_template.replace("@ANALYSIS", get_analysis_code())
	shader_template = shader_template.replace("mm_analysis_size", get_size_parameter_name())
	var output_textures : Array[Dictionary] = []
	var extra_parameters : Array[Dictionary] = [
		{ name="elapsed_time", type="float", value=0.0 },
		{ name=get_size_parameter_name(), type="float", value=float(get_image_size()) }
	]
	var extra_output_parameters : Array[Dictionary] = [ { name="mm_results", type="int", array_size=get_result_size() } ]
	if await shader_compute.compute_shader.set_shader_from_shadercode_ext(shader_template, source, output_textures, extra_parameters, false, extra_output_parameters):
		await mm_deps.buffer_create_compute_material(get_buffer_name(), shader_compute)
		mm_deps.update()
	else:
		print("analysis shader is invalid")

func on_dep_update_value(_buffer_name, parameter_name, value) -> bool:
	if value != null:
		shader_compute.set_parameter(parameter_name, value)
	return false

func on_dep_update_buffer(buffer_name : String) -> bool:
	if is_paused:
		return false
	var size : int = get_image_size()
	var output_parameters_values : Dictionary = { mm_results=get_initial_results() }
	var textures : Array[MMTexture] = []
	var status : bool = await shader_compute.compute_shader.render_ext(textures, Vector2i(size, size), output_parameters_values)
	if not status or not output_parameters_values.has("mm_results"):
		print("Failed to update analysis")
		return false
	var image : Image = process_results(output_parameters_values.mm_results, size)
	if image == null:
		return false
	texture.set_texture(ImageTexture.create_from_image(image))
	rendering_time = shader_compute.get_render_time()
	rendering_time_updated.emit(rendering_time)
	mm_deps.dependency_update(buffer_name, texture, true)
	return true

func _serialize(data : Dictionary) -> Dictionary:
	data.type = get_type()
	return data
