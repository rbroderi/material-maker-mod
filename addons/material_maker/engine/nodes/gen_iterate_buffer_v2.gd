@tool
extends MMGenBase
class_name MMGenIterateBufferV2


# Iterate buffers with several states: the inputs initialize the states, then
# the loop inputs compute new states from the current ones (the loop outputs)
# a number of times. Each state has its own storage format, and all states
# are rendered by a single compute shader in each iteration (so the loop
# reads the states of the previous iteration). Shaders of the loop can use
# $iteration (0 when initializing the states, then 1 to the iteration count).
#
# Ports: inputs 0..n-1 initialize the states, inputs n..2n-1 are the loop
# inputs. Outputs 0..n-1 are the final states, outputs n..2n-1 the current
# states (connected to the loop).


const MAX_STATES : int = 4
const MAX_ITERATIONS : int = 4096

const SHADER_TEMPLATE : String = """#version 450

layout(local_size_x = @LOCAL_SIZE, local_size_y = 1, local_size_z = 1) in;

@DECLARATIONS

layout(set = 3, binding = 0, std140) restrict buffer MM {
	int mm_chunk_y;
};

const float PI = 3.14159265359;
const float TAU = 2.0*PI;

@COMMON_SHADER_FUNCTIONS

const float seed_variation = 0.0;

@GLOBALS

@DEFINITIONS

void main() {
	float _seed_variation_ = seed_variation;
	vec4 _controlled_variation_ = vec4(0.0);
	vec2 pixel = gl_GlobalInvocationID.xy+vec2(0.5, 0.5+mm_chunk_y);
	vec2 image_size = imageSize(STATE_0);
	vec2 uv = pixel/image_size;
	@CODE
	@OUTPUT_VALUE
}
"""

var exiting : bool = false
var is_paused : bool = false
var is_rendering : bool = false
var current_iteration : int = 0

## Compute shaders that initialize the states and run the loop
var shader_computes : Array[MMShaderCompute] = [ MMShaderCompute.new(), MMShaderCompute.new() ]
## The states' textures
var states : Array[MMTexture] = []
## Whether each state is grayscale
var state_is_greyscale : Array[bool] = []

var buffer_name_init : String
var buffer_name_loop : String
var iteration_param_name : String
var used_named_parameters : Array = []
var published_dimensions : Vector2i = Vector2i(-1, -1)


func _init():
	var genname : String = "o%d" % get_instance_id()
	buffer_name_init = genname+"_v2_init"
	buffer_name_loop = genname+"_v2_loop"
	iteration_param_name = genname+"_iteration"
	for k in MAX_STATES:
		states.append(MMTexture.new())
		state_is_greyscale.append(false)
	mm_deps.create_buffer(buffer_name_init, self)
	mm_deps.create_buffer(buffer_name_loop, self)
	for k in MAX_STATES:
		mm_deps.create_buffer(get_output_buffer_name(k), self)
	set_current_iteration(0)

func _ready() -> void:
	super._ready()
	update_shaders()

func _exit_tree() -> void:
	exiting = true

func get_type() -> String:
	return "iterate_buffer_v2"

func get_type_name() -> String:
	return "Iterate Buffer"

func get_description() -> String:
	return "\n".join([ TranslationServer.translate("Iterate Buffer"),
		TranslationServer.translate("Initializes states (textures) from its inputs, then computes new states from the loop inputs repeatedly") ])

## The dependency of a final state (read by the nodes after the loop)
func get_output_buffer_name(k : int) -> String:
	return "o%d_v2_o%d_tex" % [ get_instance_id(), k ]

## The dependency of a current state (read by the loop)
func get_loop_texture_name(k : int) -> String:
	return "o%d_v2_l%d_tex" % [ get_instance_id(), k ]

func get_state_count() -> int:
	return clampi(int(parameters.get("states", 1)), 1, MAX_STATES)

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

const FORMATS : Array[Dictionary] = [
	{ name="16 bits float", value="16f" }, { name="32 bits float", value="32f" },
	{ name="8 bits", value="8" }, { name="16 bits integer", value="16" } ]

func get_parameter_defs() -> Array:
	var rv : Array = [
		{ name="states", label="States", type="float", min=1, max=MAX_STATES, step=1, default=1 },
		{ name="size_mode", label="Size mode", type="enum", default=0,
			values=[ { name="Absolute", value="absolute" }, { name="Relative to output", value="relative" }, { name="Relative to input", value="input" } ],
			longdesc="Absolute uses the size parameter, relative to output the material's size multiplied by 2^offset, relative to input the size of the texture the first input reads multiplied by 2^offset" },
		{ name="size", label="Size", type="size", first=4, last=14, default=9 },
		{ name="size_offset", label="Size offset", type="float", min=-6.0, max=4.0, step=1.0, default=0.0,
			longdesc="Size relative to the material's or the input's size, as a power of 2 (an expression of named parameters is accepted)" },
		{ name="iterations", label="Iterations", type="float", min=0, max=64, step=1, default=5,
			longdesc="Number of loop iterations: a number, or an expression of named parameters ($name) and of the states' width in pixels ($pass_size)" },
		{ name="filter", label="Filter", type="boolean", default=true },
		{ name="rounding", label="Rounding", type="enum", default=0,
			values=[ { name="GPU", value="gpu" }, { name="Half down", value="half_down" }, { name="Half up", value="half_up" } ],
			longdesc="How states are rounded when they are stored: as the GPU does (it varies between GPUs), or to the nearest step with ties down or up (the same on all GPUs)" },
	]
	for k in get_state_count():
		rv.append({ name="format_%d" % k, label="State %d format" % (k+1), type="enum", default=0, values=FORMATS })
		rv.append({ name="rg_%d" % k, label="State %d RG" % (k+1), type="boolean", default=false,
			longdesc="Store only the red and green channels of the state (if it is not grayscale)" })
	return rv

func get_input_defs() -> Array:
	var rv : Array = []
	for k in get_state_count():
		rv.append({ name="in%d" % k, label="Init %d" % (k+1), type="rgba" })
	for k in get_state_count():
		rv.append({ name="loop_in%d" % k, label="Loop %d" % (k+1), type="rgba" })
	return rv

func get_output_defs(_show_hidden : bool = false) -> Array:
	var rv : Array = []
	for k in get_state_count():
		rv.append({ name="out%d" % k, type="rgba" })
	for k in get_state_count():
		rv.append({ name="loop%d" % k, type="rgba" })
	return rv

func follow_input(input_index : int) -> Array:
	var n : int = get_state_count()
	if input_index >= n:
		# As in Iterate Buffer: the loop inputs only lead to the final states
		# (connecting the current states to the loop is not a cycle)
		return [ OutputPort.new(self, input_index-n) ]
	return super.follow_input(input_index)

func source_changed(_input_port_index : int) -> void:
	update_shaders()

func all_sources_changed() -> void:
	update_shaders()

## Moves connections when the number of states changes
func reconnect_for_state_count(old_count : int, new_count : int) -> void:
	var parent = get_parent()
	if parent == null or not parent.has_method("reconnect_inputs"):
		return
	var inputs_changes : Dictionary = {}
	for i in parent.get_connected_inputs(self):
		var k : int = int(i) % old_count
		var is_loop : bool = int(i) >= old_count
		inputs_changes[i] = -1 if k >= new_count else (k+new_count if is_loop else k)
	var outputs_changes : Dictionary = {}
	for i in parent.get_connected_outputs(self):
		var k : int = int(i) % old_count
		var is_loop : bool = int(i) >= old_count
		outputs_changes[i] = -1 if k >= new_count else (k+new_count if is_loop else k)
	parent.reconnect_inputs(self, inputs_changes)
	parent.reconnect_outputs(self, outputs_changes)

func set_parameter(n : String, v) -> void:
	if n == "states" and is_inside_tree():
		var old_count : int = get_state_count()
		var new_count : int = clampi(int(v), 1, MAX_STATES)
		if old_count != new_count:
			reconnect_for_state_count(old_count, new_count)
	super.set_parameter(n, v)
	if n == "states":
		emit_signal("parameter_changed", "__update_all__", null)
	if is_inside_tree():
		if n in [ "size", "size_mode", "size_offset" ]:
			publish_dimensions(get_buffer_dimensions())
		if n == "states" or n == "rounding" or n.begins_with("format_") or n.begins_with("rg_"):
			update_shaders()
		set_current_iteration(0)
		mm_deps.buffer_invalidate(buffer_name_init)

## Evaluates a parameter that can be an expression of named parameters and
## of $pass_size
func evaluate_expression(n : String, default : float) -> float:
	var value = get_parameter(n)
	if value is float or value is int:
		return float(value)
	if not value is String:
		return default
	value = value.replace("$pass_size", str(get_buffer_dimensions().x))
	var parent : Node = get_parent()
	if parent != null and parent.has_method("get_named_parameters"):
		var named_parameters : Dictionary = parent.get_named_parameters()
		for np in named_parameters.keys():
			if value.find("$"+np) != -1:
				if not named_parameters[np].id in used_named_parameters:
					used_named_parameters.append(named_parameters[np].id)
				value = value.replace("$"+np, str(named_parameters[np].value))
	var expression : Expression = Expression.new()
	if expression.parse(value, []) != OK:
		return default
	var result = expression.execute()
	return float(result) if (result is float or result is int) else default

func get_iterations() -> int:
	return clampi(roundi(evaluate_expression("iterations", 1.0)), 0, MAX_ITERATIONS)

## Width and height of the states, in pixels
func get_buffer_dimensions() -> Vector2i:
	var size : int = int(get_parameter("size"))
	match int(get_parameter("size_mode")):
		MMGenBuffer.SIZE_MODE_RELATIVE_TO_OUTPUT:
			var material : Node = find_material()
			if material != null and material.parameters.has("size"):
				size = int(material.parameters.size)+roundi(evaluate_expression("size_offset", 0.0))
		MMGenBuffer.SIZE_MODE_RELATIVE_TO_INPUT:
			var width : int = MMGenBuffer.find_texture_width(get_source(0))
			if width > 0:
				size = roundi(log(float(width))/log(2.0))+roundi(evaluate_expression("size_offset", 0.0))
	size = clampi(size, 0, 14)
	return Vector2i(1 << size, 1 << size)

func publish_dimensions(dimensions : Vector2i) -> void:
	if dimensions == published_dimensions:
		return
	published_dimensions = dimensions
	mm_deps.dependency_update("o%d_v2_size" % get_instance_id(), float(dimensions.x))

var require_shaders_update : bool = false

func update_shaders() -> void:
	if ! require_shaders_update:
		require_shaders_update = true
		do_update_shaders.call_deferred()

## Generates the code of the inputs of the states (the initialization inputs
## or the loop inputs) in a single shader
func generate_shader_code(first_input : int, context : MMGenContext) -> Dictionary:
	var rv : ShaderCode = ShaderCode.new()
	var stores : String = ""
	var greyscale : Array[bool] = []
	for k in get_state_count():
		var source_output : OutputPort = get_source(first_input+k)
		var source : ShaderCode
		if source_output != null:
			source = source_output.generator.get_shader_code("uv", source_output.output_index, context)
		if source == null or source.output_type == "":
			source = get_default_generated_shader()
		greyscale.append(source.output_type == "f")
		rv.add_globals(source.globals)
		rv.add_uniforms(source.uniforms)
		rv.defs += source.defs
		rv.code += source.code
		var rounding : String = MMPipeline.get_store_rounding_code(int(get_parameter("rounding")), get_state_storage(k))
		stores += "\t{\n\t\tvec4 outColor = %s;\n\t\t%s\n\t\timageStore(STATE_%d, ivec2(pixel), outColor);\n\t}\n" % [ source.output_values.rgba, rounding, k ]
	rv.output_type = "rgba"
	rv.output_values.rgba = stores
	return { code=rv, greyscale=greyscale }

func get_state_storage(k : int) -> int:
	return [ MMPipeline.STORAGE_16F, MMPipeline.STORAGE_32F, MMPipeline.STORAGE_8, MMPipeline.STORAGE_16 ][clampi(int(get_parameter("format_%d" % k)), 0, 3)]

func do_update_shaders() -> void:
	require_shaders_update = false
	if not is_inside_tree():
		return
	var n : int = get_state_count()
	var greyscale : Array[bool] = []
	for pass_index in 2:
		var context : MMGenContext = MMGenContext.new()
		context.iteration_variable = iteration_param_name
		var generated : Dictionary = generate_shader_code(pass_index*n, context)
		if pass_index == 0:
			greyscale = generated.greyscale
		var output_textures : Array[Dictionary] = []
		for k in n:
			var channels : int = 1 if greyscale[k] else (2 if get_parameter("rg_%d" % k) else 4)
			output_textures.append({ name="STATE_%d" % k, type=MMPipeline.get_texture_type(channels, get_state_storage(k)) })
		var extra_parameters : Array[Dictionary] = [ { name="elapsed_time", type="float", value=0.0 } ]
		var shader_compute : MMShaderCompute = shader_computes[pass_index]
		await shader_compute.compute_shader.set_shader_from_shadercode_ext(SHADER_TEMPLATE, generated.code, output_textures, extra_parameters)
		var buffer_name : String = [ buffer_name_init, buffer_name_loop ][pass_index]
		await mm_deps.buffer_create_compute_material(buffer_name, shader_compute)
		mm_deps.buffer_invalidate(buffer_name)
	# Named parameters of the iteration count and size restart the iterations
	used_named_parameters = []
	get_iterations()
	get_buffer_dimensions()
	for p in used_named_parameters:
		mm_deps.buffer_add_dependency(buffer_name_init, p)
	for k in n:
		if greyscale[k] != state_is_greyscale[k]:
			state_is_greyscale[k] = greyscale[k]
			notify_output_change(k)
			notify_output_change(n+k)
	set_current_iteration(0)

func on_dep_update_value(buffer_name, parameter_name, value) -> bool:
	var loop_textures : Array = []
	for k in get_state_count():
		loop_textures.append(get_loop_texture_name(k))
	if not parameter_name in loop_textures and parameter_name != iteration_param_name:
		set_current_iteration(0)
	if value != null:
		if buffer_name == buffer_name_init:
			shader_computes[0].set_parameter(parameter_name, value)
		elif buffer_name == buffer_name_loop:
			shader_computes[1].set_parameter(parameter_name, value)
	return false

func on_dep_buffer_invalidated(buffer_name : String):
	if not exiting and (buffer_name == buffer_name_init or buffer_name == buffer_name_loop):
		invalidate_outputs()

func on_dep_update_buffer(buffer_name : String) -> bool:
	if is_paused:
		return false
	if buffer_name != buffer_name_init and buffer_name != buffer_name_loop:
		# Final states are updated when the iterations are done (unused
		# states are updated immediately)
		if buffer_name.ends_with("_tex") and int(buffer_name.get_slice("_v2_o", 1).to_int()) >= get_state_count():
			await get_tree().process_frame
			mm_deps.dependency_update(buffer_name, null, true)
		return true
	if is_rendering:
		return true
	is_rendering = true
	if buffer_name == buffer_name_init and current_iteration != 0:
		set_current_iteration(0)
	var first_iteration : bool = ( current_iteration == 0 )
	var shader_compute : MMShaderCompute = shader_computes[0] if first_iteration else shader_computes[1]
	var iterations : int = get_iterations()
	if current_iteration > iterations:
		await get_tree().process_frame
		mm_deps.dependency_update(buffer_name, null, true)
		is_rendering = false
		return true
	var check_current_iteration : int = current_iteration
	var dimensions : Vector2i = get_buffer_dimensions()
	publish_dimensions(dimensions)
	var textures : Array[MMTexture] = states.slice(0, get_state_count())
	var status : bool = await shader_compute.compute_shader.render_ext(textures, dimensions)
	is_rendering = false
	if not status:
		print("Error while rendering %s" % buffer_name)
		return false
	if first_iteration:
		rendering_time = 0
	rendering_time += shader_compute.get_render_time()
	rendering_time_updated.emit(rendering_time)
	if check_current_iteration != current_iteration:
		mm_deps.dependency_update(buffer_name, null, true)
		return true
	set_current_iteration(current_iteration+1)
	var rendered_buffer : String = buffer_name_init if first_iteration else buffer_name_loop
	mm_deps.dependency_update(rendered_buffer, null, true)
	if buffer_name != rendered_buffer:
		mm_deps.dependency_update(buffer_name, null, true)
	var loop_reads_states : bool = false
	for k in get_state_count():
		if mm_deps.dependencies.get(get_loop_texture_name(k), []).has(buffer_name_loop):
			loop_reads_states = true
	if current_iteration > iterations or (not first_iteration and not loop_reads_states):
		# Done (a loop that does not read the states would give the same result)
		set_current_iteration(iterations+1)
		for k in get_state_count():
			mm_deps.dependency_update(get_output_buffer_name(k), states[k], true)
	else:
		for k in get_state_count():
			mm_deps.dependency_update(get_loop_texture_name(k), states[k], true)
		if not loop_reads_states:
			mm_deps.buffer_invalidate(buffer_name_loop)
	return status

func set_current_iteration(i : int) -> void:
	if i == current_iteration:
		return
	current_iteration = i
	mm_deps.dependency_update(iteration_param_name, current_iteration, true)
	if current_iteration == 0:
		invalidate_outputs()

## Invalidates the final states (that are created after the other buffers)
func invalidate_outputs() -> void:
	for k in MAX_STATES:
		if mm_deps.buffers.has(get_output_buffer_name(k)):
			mm_deps.buffer_invalidate(get_output_buffer_name(k))

func get_adjusted_uv(uv : String) -> String:
	if not get_parameter("filter"):
		var size : String = "o%d_v2_size" % get_instance_id()
		return "((floor(fract(%s) * %s)+vec2(0.5))/%s)" % [ uv, size, size ]
	return "fract(%s)" % uv

func _get_shader_code(uv : String, output_index : int, context : MMGenContext) -> ShaderCode:
	var genname : String = "o%d" % get_instance_id()
	var n : int = get_state_count()
	var k : int = output_index % n
	var texture_name : String = get_loop_texture_name(k) if output_index >= n else get_output_buffer_name(k)
	var is_greyscale : bool = state_is_greyscale[k]
	var rv : ShaderCode = ShaderCode.new()
	rv.output_type = "f" if is_greyscale else "rgba"
	var variant_index : int = context.get_variant(self, uv+","+str(output_index))
	if variant_index == -1:
		variant_index = context.get_variant(self, uv+","+str(output_index))
		rv.add_uniform(texture_name, "sampler2D", states[k])
		rv.code = "%s %s_%d_%d = textureLod(%s, %s, 0.0)%s;\n" % [ "float" if is_greyscale else "vec4", genname, output_index, variant_index, texture_name, get_adjusted_uv(uv), ".r" if is_greyscale else "" ]
	rv.add_uniform("%s_v2_size" % genname, "float", float(get_buffer_dimensions().x))
	rv.output_values[rv.output_type] = "%s_%d_%d" % [ genname, output_index, variant_index ]
	return rv

func get_output_attributes(output_index : int) -> Dictionary:
	var n : int = get_state_count()
	var attributes : Dictionary = {}
	var k : int = output_index % n
	attributes.texture = get_loop_texture_name(k) if output_index >= n else get_output_buffer_name(k)
	attributes.texture_size = "o%d_v2_size" % get_instance_id()
	if output_index >= n:
		attributes.iteration = iteration_param_name
	return attributes

func _serialize(data: Dictionary) -> Dictionary:
	data.type = get_type()
	return data
