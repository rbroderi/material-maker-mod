@tool
extends MMGenTexture
class_name MMGenBuffer


# Texture generator buffers, that render their input in a specific resolution and
# provide the result as output.
# This is useful when using generators that sample their inputs several times


const VERSION_OLD     : int = 0
const VERSION_SIMPLE  : int = 1
const VERSION_COMPLEX : int = 2


var version : int = VERSION_OLD
var exiting : bool = false

var shader_compute : MMShaderCompute
var is_greyscale : bool = false

var is_paused : bool = false


func _ready() -> void:
	shader_compute = MMShaderCompute.new()
	if !parameters.has("size"):
		parameters.size = 9
	mm_deps.create_buffer("o%d_tex" % get_instance_id(), self)
	do_update_shader()

func _exit_tree() -> void:
	exiting = true

func get_type() -> String:
	return "buffer"

func get_type_name() -> String:
	return "Buffer"

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

func get_description() -> String:
	var desc_list : PackedStringArray = PackedStringArray()
	desc_list.push_back(TranslationServer.translate("Buffer"))
	desc_list.push_back(TranslationServer.translate("Samples input into a texture of a given resolution"))
	return "\n".join(desc_list)

func get_parameter_defs() -> Array:
	var parameter_defs : Array = [ { name="size",label="Size", type="size", first=4, last=13, default=4 } ]
	match version:
		VERSION_OLD:
			parameter_defs.push_back({ name="lod", label="Lod", type="float", min=0, max=10.0, step=0.01, default=0 })
		VERSION_COMPLEX:
			parameter_defs.push_back({ name="filter", label="Filter", type="boolean", default=true })
			parameter_defs.push_back({ name="mipmap", label="Mipmap", type="boolean", default=true })
			parameter_defs.push_back({ name="f32", label="32 bits", type="boolean", default=false })
			parameter_defs.push_back({ name="f8", label="8 bits", type="boolean", default=false,
				longdesc="Use an 8 bits buffer to save memory (ignored if 32 bits is set)" })
			parameter_defs.push_back({ name="size_mode", label="Size mode", type="enum", default=0,
				values=[ { name="Absolute", value="absolute" }, { name="Relative to output", value="relative" } ],
				longdesc="Absolute uses the size parameter, relative to output uses the material's size multiplied by 2^offset" })
			parameter_defs.push_back({ name="size_offset", label="Size offset", type="float", min=-6.0, max=4.0, step=1.0, default=0.0,
				longdesc="Size relative to the material's size, as a power of 2 (only used in relative size mode)" })
	return parameter_defs

## Returns the material's output size (as log2), or -1 if there is none
func get_output_size() -> int:
	var root : Node = self
	while root.get_parent() is MMGenBase:
		root = root.get_parent()
	for c in root.get_children():
		if c is MMGenMaterial:
			return c.get_output_size()
	return -1

## Returns the buffer's size (as log2), that depends on its size mode
func get_buffer_size() -> int:
	if version == VERSION_COMPLEX and get_parameter("size_mode") == 1:
		var output_size : int = get_output_size()
		if output_size >= 0:
			var size_def : Dictionary = get_parameter_def("size")
			return clampi(output_size+int(get_parameter("size_offset")), size_def.first, size_def.last)
	return int(get_parameter("size"))

## Returns true if the buffer is stored as 8 bits (if the GPU does not
## support 8 bits storage, 16 bits floats are used instead)
func is_8_bits_effective() -> bool:
	if version != VERSION_COMPLEX or not get_parameter("f8") or get_parameter("f32"):
		return false
	return MMPipeline.is_output_texture_type_supported(MMPipeline.TEXTURE_TYPE_R8 if is_greyscale else MMPipeline.TEXTURE_TYPE_RGBA8)

## Returns false for parameters that are ignored with the current settings
## (so the node can grey them out)
func is_parameter_used(n : String) -> bool:
	if version != VERSION_COMPLEX:
		return true
	match n:
		"size":
			return get_parameter("size_mode") != 1
		"size_offset":
			return get_parameter("size_mode") == 1
		"f8":
			return not get_parameter("f32")
	return true

## The size and format of the buffer, shown under the node
func get_badge() -> String:
	var format : String = "16F"
	var note : String = ""
	if version == VERSION_COMPLEX:
		if get_parameter("f32"):
			format = "32F"
		elif get_parameter("f8"):
			if is_8_bits_effective():
				format = "8 bits"
			else:
				note = " (8 bits unsupported)"
	return "%d px  %s %s%s" % [ 1 << get_buffer_size(), format, "gray" if is_greyscale else "RGBA", note ]

## Keywords of node types and input names that need more than 8 bits of precision
const NORMAL_KEYWORDS : Array[String] = [ "normal" ]
const HEIGHT_KEYWORDS : Array[String] = [ "height", "depth", "occlusion", "curvature" ]

## A warning when an 8 bits buffer feeds a node that computes normals or uses
## heights, since 256 levels show as steps there. Colors and masks are fine.
func get_precision_warning() -> String:
	if not is_8_bits_effective():
		return ""
	var parent : Node = get_parent()
	if not parent is MMGenGraph:
		return ""
	match find_precision_sensitive_target(parent, name, 0, 8):
		"normal":
			return "8 bits: loses normal precision"
		"height":
			return "8 bits: loses height precision"
	return ""

## Follows the connections of an output (through reroutes and groups) and returns
## "normal" or "height" if it feeds an input that needs precision, "" otherwise
func find_precision_sensitive_target(graph : MMGenGraph, gen_name : String, port : int, depth : int) -> String:
	if depth <= 0:
		return ""
	var rv : String = ""
	for target in graph.get_port_targets(gen_name, port):
		var consumer : MMGenBase = target.generator
		var result : String = ""
		if consumer is MMGenReroute:
			result = find_precision_sensitive_target(graph, consumer.name, 0, depth-1)
		elif consumer is MMGenIOs:
			# Output of a group: follow the group's output in its parent graph
			var group : Node = consumer.get_parent()
			if consumer.name == "gen_outputs" and group.get_parent() is MMGenGraph:
				result = find_precision_sensitive_target(group.get_parent(), group.name, target.input_index, depth-1)
		else:
			var input_name : String = ""
			var input_defs : Array = consumer.get_input_defs()
			if target.input_index < input_defs.size():
				input_name = (input_defs[target.input_index].get("name", "")+" "+input_defs[target.input_index].get("shortdesc", "")).to_lower()
			# Library nodes are identified by their model (e.g. normal_map2), others by their type
			var consumer_type : String = ((consumer.model if consumer.model is String else consumer.get_type())+" "+consumer.get_type_name()).to_lower()
			for k in NORMAL_KEYWORDS:
				if consumer_type.contains(k) or input_name.contains(k):
					return "normal"
			for k in HEIGHT_KEYWORDS:
				if consumer_type.contains(k) or input_name.contains(k):
					result = "height"
			if result == "" and consumer is MMGenGraph and consumer.model == null:
				# Group made by the user: follow the input inside it
				result = find_precision_sensitive_target(consumer, "gen_inputs", target.input_index, depth-1)
		if result == "normal":
			return result
		elif result != "":
			rv = result
	return rv

## Called when the material's size changes
func on_output_size_changed() -> void:
	if version == VERSION_COMPLEX and get_parameter("size_mode") == 1:
		update_buffer_size()

func update_buffer_size() -> void:
	if is_inside_tree():
		mm_deps.dependency_update("o%d_tex_size" % get_instance_id(), pow(2, get_buffer_size()))
		# Remote nodes can set the size before the buffer is created
		var buffer_name : String = "o%d_tex" % get_instance_id()
		if mm_deps.buffers.has(buffer_name):
			mm_deps.buffer_invalidate(buffer_name)

func get_input_defs() -> Array:
	return [ { name="in", type="rgba" } ]

func get_output_defs(_show_hidden : bool = false) -> Array:
	if version == VERSION_OLD:
		return [ { type="rgba" }, { type="rgba" } ]
	else:
		return [ { type="rgba" } ]

func source_changed(_input_port_index : int) -> void:
	update_shader()

func all_sources_changed() -> void:
	update_shader()

func set_parameter(n : String, v) -> void:
	super.set_parameter(n, v)
	if n in [ "size", "size_mode", "size_offset" ]:
		update_buffer_size()

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
	else:
		source = get_default_generated_shader()
	var f32 = false
	var f8 = false
	if version == VERSION_COMPLEX:
		f32 = get_parameter("f32")
		f8 = get_parameter("f8")
	var shader_status : bool = await shader_compute.set_shader_from_shadercode(source, f32, f8)
	if shader_status:
		var new_is_greyscale = shader_compute.is_greyscale()
		if new_is_greyscale != is_greyscale:
			is_greyscale = new_is_greyscale
			notify_output_change(0)
			if version == VERSION_OLD:
				notify_output_change(1)
		await mm_deps.buffer_create_compute_material("o%d_tex" % get_instance_id(), shader_compute)
		mm_deps.update()
	else:
		print("buffer is invalid")

func on_dep_update_value(buffer_name, parameter_name, value) -> bool:
	if value != null:
		shader_compute.set_parameter(parameter_name, value)
	return false

func on_dep_update_buffer(buffer_name : String) -> bool:
	if is_paused:
		return false
	var status = await shader_compute.render(texture, pow(2, get_buffer_size()))
	if status:
		rendering_time = shader_compute.get_render_time()
		self.rendering_time_updated.emit(rendering_time)
		mm_deps.dependency_update(buffer_name, texture, true)
		mm_deps.update()
		on_buffer_updated()
	else:
		print("Failed to update buffer")
	return status

func on_buffer_updated():
	pass

func get_adjusted_uv(uv : String) -> String:
	if version == VERSION_COMPLEX and not get_parameter("filter"):
		var genname = "o"+str(get_instance_id())
		return "((floor(fract(%s) * %s_tex_size)+vec2(0.5))/%s_tex_size)" % [ uv, genname, genname ]
	else:
		return "fract(%s)" % uv

func _get_shader_code(uv : String, output_index : int, context : MMGenContext) -> ShaderCode:
	var genname = "o"+str(get_instance_id())
	var shader_code = _get_shader_code_lod(uv, output_index, context, is_greyscale, -1.0 if output_index == 0 else parameters.lod)
	shader_code.add_uniform("%s_tex_size" % genname, "float", pow(2, get_buffer_size()))
	return shader_code

func get_output_attributes(output_index : int) -> Dictionary:
	var attributes : Dictionary = {}
	attributes.texture = "o%d_tex" % get_instance_id()
	attributes.texture_size = "o%d_tex_size" % get_instance_id()
	return attributes

func _serialize(data: Dictionary) -> Dictionary:
	data.type = get_type()
	if version != VERSION_OLD:
		data.version = version
	return data

func _deserialize(data : Dictionary) -> void:
	if data.has("version"):
		version = data.version
	else:
		version = VERSION_OLD
