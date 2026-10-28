@tool
extends MMGenTexture
class_name MMGenGpuReduction


# Base class of nodes that reduce their input with a GPU pass (that
# accumulates results in an int array with atomics) and use the results on
# the CPU (see MMGenAnalysis and MMGenStatistics).
#
# Subclasses define the hooks below: the compute shader template and its
# replacements, the results array and what is done with the results.


var exiting : bool = false
var shader_compute : MMShaderCompute
var is_paused : bool = false


func _ready() -> void:
	shader_compute = MMShaderCompute.new()
	if !parameters.has("size"):
		parameters.size = 10
	mm_deps.create_buffer(get_buffer_name(), self)
	do_update_shader()

func _enter_tree() -> void:
	exiting = false

func _exit_tree() -> void:
	exiting = true

# Hooks

## The suffix of the buffer's name (o<id>_<suffix>, saved graphs depend on it)
func get_buffer_suffix() -> String:
	return "tex"

## The name of the image size uniform in the shader template
func get_template_size_name() -> String:
	return "mm_analysis_size"

## The compute shader template (with @ placeholders replaced by
## get_template_replacements())
func get_template_path() -> String:
	return ""

func get_template_replacements() -> Dictionary:
	return {}

## The type of the input
func get_input_type() -> String:
	return "rgba"

## The largest size parameter (2^last pixels) and its description
func get_size_parameter_def() -> Dictionary:
	return { name="size", label="Size", type="size", first=4, last=12, default=10, longdesc="The resolution at which the input is analyzed" }

## Adapts the input's shader code to the template (connected is false when
## source is the default shader code)
func prepare_source(_source : ShaderCode, _connected : bool) -> void:
	pass

## The name and the initial values of the results array
func get_results_name() -> String:
	return "mm_results"

func get_initial_results() -> PackedInt32Array:
	return PackedInt32Array()

## Uses the results of a render of size x size pixels, returns the value of
## the buffer's dependency (null on error)
func use_results(_results : PackedInt32Array, _size : int):
	return null

# Shared implementation

func get_buffer_name() -> String:
	return "o%d_%s" % [ get_instance_id(), get_buffer_suffix() ]

func get_size_parameter_name() -> String:
	return "%s_size" % get_buffer_name()

func get_image_size() -> int:
	return int(pow(2, get_parameter("size")))

func set_paused(v : bool) -> void:
	if v == is_paused:
		return
	is_paused = v
	if ! v:
		# Render the buffer if it was invalidated while paused
		mm_deps.buffer_retry(get_buffer_name())
		mm_deps.update()

func get_buffers(flags : int = BUFFERS_ALL) -> Array:
	if ( is_paused and flags == BUFFERS_RUNNING ) or ( ! is_paused and flags == BUFFERS_PAUSED ):
		return []
	return [ self ]

func get_parameter_defs() -> Array:
	return [ get_size_parameter_def() ]

func get_input_defs() -> Array:
	return [ { name="in", type=get_input_type() } ]

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
	var connected : bool = source != null and source.output_type != ""
	if not connected:
		source = get_default_generated_shader()
	prepare_source(source, connected)
	var shader_template : String = load(get_template_path()).text
	var replacements : Dictionary = get_template_replacements()
	for r in replacements.keys():
		shader_template = shader_template.replace(r, replacements[r])
	shader_template = shader_template.replace(get_template_size_name(), get_size_parameter_name())
	var output_textures : Array[Dictionary] = []
	var extra_parameters : Array[Dictionary] = [
		{ name="elapsed_time", type="float", value=0.0 },
		{ name=get_size_parameter_name(), type="float", value=float(get_image_size()) }
	]
	var extra_output_parameters : Array[Dictionary] = [ { name=get_results_name(), type="int", array_size=get_initial_results().size() } ]
	if await shader_compute.compute_shader.set_shader_from_shadercode_ext(shader_template, source, output_textures, extra_parameters, false, extra_output_parameters):
		await mm_deps.buffer_create_compute_material(get_buffer_name(), shader_compute)
		mm_deps.update()
	else:
		push_error("%s shader is invalid" % get_type_name())

func on_dep_update_value(_buffer_name, parameter_name, value) -> bool:
	if value != null:
		shader_compute.set_parameter(parameter_name, value)
	return false

func on_dep_update_buffer(buffer_name : String) -> bool:
	if is_paused:
		return false
	var size : int = get_image_size()
	var output_parameters_values : Dictionary = { get_results_name(): get_initial_results() }
	var textures : Array[MMTexture] = []
	var status : bool = await shader_compute.compute_shader.render_ext(textures, Vector2i(size, size), output_parameters_values)
	if not status or not output_parameters_values.has(get_results_name()):
		push_error("Failed to update %s" % get_type_name())
		return false
	rendering_time = shader_compute.get_render_time()
	rendering_time_updated.emit(rendering_time)
	var value = use_results(output_parameters_values[get_results_name()], size)
	if value == null:
		return false
	mm_deps.dependency_update(buffer_name, value, true)
	return true

func _serialize(data : Dictionary) -> Dictionary:
	data.type = get_type()
	return data
