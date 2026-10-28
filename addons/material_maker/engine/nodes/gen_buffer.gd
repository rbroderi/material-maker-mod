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

## Named parameters used by the size offset expression (their changes resize
## the buffer)
var size_named_parameters : Array = []
## Dimensions of the buffer in the size uniforms of the shaders that read it
var published_dimensions : Vector2i = Vector2i(-1, -1)

const SIZE_MODE_ABSOLUTE : int = 0
const SIZE_MODE_RELATIVE_TO_OUTPUT : int = 1
const SIZE_MODE_RELATIVE_TO_INPUT : int = 2


func _ready() -> void:
	shader_compute = MMShaderCompute.new()
	if !parameters.has("size"):
		parameters.size = 9
	mm_deps.create_buffer("o%d_tex" % get_instance_id(), self)
	do_update_shader()

func _enter_tree() -> void:
	exiting = false

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
		# Render the buffer if it was invalidated while paused
		mm_deps.buffer_retry("o%d_tex" % get_instance_id())
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
	var parameter_defs : Array = [ { name="size",label="Size", type="size", first=4, last=14, default=4 } ]
	match version:
		VERSION_OLD:
			parameter_defs.push_back({ name="lod", label="Lod", type="float", min=0, max=10.0, step=0.01, default=0 })
		VERSION_COMPLEX:
			parameter_defs.push_back({ name="filter", label="Filter", type="boolean", default=true })
			parameter_defs.push_back({ name="mipmap", label="Mipmap", type="boolean", default=true })
			parameter_defs.push_back({ name="f32", label="32 bits", type="boolean", default=false })
			parameter_defs.push_back({ name="f8", label="8 bits", type="boolean", default=false,
				longdesc="Use an 8 bits buffer to save memory (ignored if 32 bits is set)" })
			parameter_defs.push_back({ name="f16i", label="16 bits integer", type="boolean", default=false,
				longdesc="Store 16 bits integers (as Substance's 16 bits format) instead of 16 bits floats (ignored if 32 bits is set)" })
			parameter_defs.push_back({ name="rg", label="RG", type="boolean", default=false,
				longdesc="Store only the red and green channels of color inputs (blue is 0 and alpha 1 when read)" })
			parameter_defs.push_back({ name="rounding", label="Rounding", type="enum", default=0,
				values=[ { name="GPU", value="gpu" }, { name="Half down", value="half_down" }, { name="Half up", value="half_up" } ],
				longdesc="How values are rounded when they are stored in 8 or 16 bits: as the GPU does (it varies between GPUs: ties are rounded down or up, and some truncate 16 bits floats), or to the nearest step with ties down or up (the same on all GPUs)" })
			parameter_defs.push_back({ name="size_mode", label="Size mode", type="enum", default=0,
				values=[ { name="Absolute", value="absolute" }, { name="Relative to output", value="relative" }, { name="Relative to input", value="input" } ],
				longdesc="Absolute uses the size parameter, relative to output uses the material's size multiplied by 2^offset, relative to input uses the size of the texture the input reads (the nearest buffer or image upstream) multiplied by 2^offset" })
			parameter_defs.push_back({ name="size_offset", label="Size offset", type="float", min=-6.0, max=4.0, step=1.0, default=0.0,
				longdesc="Size relative to the material's or the input's size, as a power of 2 (only used in relative size modes). It can be an expression of the graph's named parameters ($name)." })
			parameter_defs.push_back({ name="aspect", label="Aspect ratio", type="enum", default=0, values=ASPECT_RATIOS,
				longdesc="Width:height of the buffer (the size is its width). Non-square buffers have a different resolution horizontally and vertically, the image is still mapped to the whole UV square" })
	return parameter_defs

## Aspect ratios of non-square buffers and materials (width:height)
const ASPECT_RATIOS : Array[Dictionary] = [
	{ name="1:1", value="1" }, { name="2:1", value="0.5" }, { name="1:2", value="2" },
	{ name="4:1", value="0.25" }, { name="1:4", value="4" }, { name="8:1", value="0.125" }, { name="1:8", value="8" } ]

## Height of an image of a given width with an aspect ratio (index in
## ASPECT_RATIOS)
static func aspect_height(width : int, aspect : int) -> int:
	if aspect <= 0 or aspect >= ASPECT_RATIOS.size():
		return width
	return clampi(roundi(width*float(ASPECT_RATIOS[aspect].value)), 1, 16384)

## Width and height of the buffer, in pixels
func get_buffer_dimensions() -> Vector2i:
	var width : int = 1 << get_buffer_size()
	if version != VERSION_COMPLEX:
		return Vector2i(width, width)
	return Vector2i(width, aspect_height(width, int(get_parameter("aspect"))))

## Returns the material's output size (as log2), or -1 if there is none
func get_output_size() -> int:
	var material : Node = find_material()
	if material != null and material.parameters.has("size"):
		return int(material.parameters.size)
	return -1

## The width of the texture an output reads: that of the nearest buffer or
## texture (image...) upstream, following the first input of other nodes,
## or -1 if there is none
static func find_texture_width(port : OutputPort, depth : int = 0) -> int:
	if port == null or depth > 256:
		return -1
	var generator : MMGenBase = port.generator
	if generator.has_method("get_buffer_dimensions"):
		return generator.get_buffer_dimensions().x
	if generator is MMGenTexture and generator.texture.texture_size.x > 0:
		return generator.texture.texture_size.x
	if generator is MMGenGraph:
		var outputs : Node = generator.get_node_or_null("gen_outputs")
		return find_texture_width(outputs.get_source(port.output_index) if outputs != null else null, depth+1)
	if generator.name == "gen_inputs" and generator.get_parent() is MMGenBase:
		return find_texture_width(generator.get_parent().get_source(port.output_index), depth+1)
	if generator.get_input_defs().is_empty():
		return -1
	return find_texture_width(generator.get_source(0), depth+1)

## The size offset (an expression of named parameters, or a number)
func get_size_offset() -> int:
	var offset : Dictionary = calculate_float_parameter("size_offset")
	size_named_parameters = offset.get("used_named_parameters", [])
	return roundi(offset.get("value", 0.0))

## Returns the buffer's size (as log2), that depends on its size mode
func get_buffer_size() -> int:
	if version == VERSION_COMPLEX:
		match int(get_parameter("size_mode")):
			SIZE_MODE_RELATIVE_TO_OUTPUT:
				var output_size : int = get_output_size()
				if output_size >= 0:
					return clamp(output_size+get_size_offset(), 0, 14)
			SIZE_MODE_RELATIVE_TO_INPUT:
				var input_width : int = find_texture_width(get_source(0))
				if input_width <= 0:
					# Inputs that do not read a texture are rendered at the material's size
					var output_size : int = get_output_size()
					input_width = (1 << output_size) if output_size >= 0 else (1 << int(get_parameter("size")))
				return clamp(roundi(log(float(input_width))/log(2.0))+get_size_offset(), 0, 14)
	return int(get_parameter("size"))

## The storage format of the buffer (MMPipeline.STORAGE_*)
func get_storage() -> int:
	if version != VERSION_COMPLEX:
		return MMPipeline.STORAGE_16F
	if get_parameter("f32"):
		return MMPipeline.STORAGE_32F
	if get_parameter("f16i"):
		return MMPipeline.STORAGE_16
	if get_parameter("f8"):
		return MMPipeline.STORAGE_8
	return MMPipeline.STORAGE_16F

## The number of channels of the buffer's texture
func get_channel_count() -> int:
	if is_greyscale:
		return 1
	return 2 if version == VERSION_COMPLEX and get_parameter("rg") else 4

## The storage format that is really used (8 and 16 bits integer formats
## fall back to 16 bits floats if the GPU does not support them)
func get_effective_storage() -> int:
	return MMPipeline.get_effective_storage(get_channel_count(), get_storage())

## Returns false for parameters that are ignored with the current settings
## (so the node can grey them out)
func is_parameter_used(n : String) -> bool:
	if version != VERSION_COMPLEX:
		return true
	match n:
		"size":
			return int(get_parameter("size_mode")) == SIZE_MODE_ABSOLUTE
		"size_offset":
			return int(get_parameter("size_mode")) != SIZE_MODE_ABSOLUTE
		"f8":
			return not get_parameter("f32") and not get_parameter("f16i")
		"f16i":
			return not get_parameter("f32")
		"rounding":
			return get_storage() == MMPipeline.STORAGE_8 or get_storage() == MMPipeline.STORAGE_16
	return true

## The size and format of the buffer, shown under the node
func get_badge() -> String:
	var storage : int = get_storage()
	var effective_storage : int = get_effective_storage()
	var format : String = [ "16F", "32F", "8 bits", "16 bits" ][effective_storage]
	var note : String = ""
	if effective_storage != storage:
		note = " (%s unsupported)" % [ "16F", "32F", "8 bits", "16 bits" ][storage]
	var dimensions : Vector2i = get_buffer_dimensions()
	var size_text : String = "%d px" % dimensions.x if dimensions.x == dimensions.y else "%dx%d px" % [ dimensions.x, dimensions.y ]
	var channels : String = [ "", "gray", "RG", "", "RGBA" ][get_channel_count()]
	return "%s  %s %s%s" % [ size_text, format, channels, note ]

## Keywords of node types and input names that need more than 8 bits of precision
const NORMAL_KEYWORDS : Array[String] = [ "normal" ]
const HEIGHT_KEYWORDS : Array[String] = [ "height", "depth", "occlusion", "curvature" ]

## A warning when an 8 bits buffer feeds a node that computes normals or uses
## heights (directly or through reroutes and groups), since 256 levels show as
## steps there. Colors and masks are fine, even if they are grayscale.
func get_precision_warning() -> String:
	if version != VERSION_COMPLEX or get_effective_storage() != MMPipeline.STORAGE_8:
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
	if version == VERSION_COMPLEX and get_parameter("size_mode") != SIZE_MODE_ABSOLUTE:
		update_buffer_size()

## Updates the size uniforms of the shaders that read the buffer
func publish_dimensions(dimensions : Vector2i) -> void:
	if dimensions == published_dimensions:
		return
	published_dimensions = dimensions
	mm_deps.dependency_update("o%d_tex_size" % get_instance_id(), float(dimensions.x))
	mm_deps.dependency_update("o%d_tex_size_y" % get_instance_id(), float(dimensions.y))

func update_buffer_size() -> void:
	if is_inside_tree():
		var dimensions : Vector2i = get_buffer_dimensions()
		published_dimensions = Vector2i(-1, -1)
		publish_dimensions(dimensions)
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
	if n in [ "size", "size_mode", "size_offset", "aspect" ]:
		update_buffer_size()
	elif n in [ "f32", "f8", "f16i", "rg", "rounding" ] and is_inside_tree():
		update_shader()

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
	var rg : bool = false
	var rounding : int = MMPipeline.ROUNDING_GPU
	if version == VERSION_COMPLEX:
		rg = get_parameter("rg")
		rounding = int(get_parameter("rounding"))
	var shader_status : bool = await shader_compute.set_shader_from_shadercode_storage(source, get_storage(), rg, rounding)
	if shader_status:
		var new_is_greyscale = shader_compute.is_greyscale()
		if new_is_greyscale != is_greyscale:
			is_greyscale = new_is_greyscale
			notify_output_change(0)
			if version == VERSION_OLD:
				notify_output_change(1)
		await mm_deps.buffer_create_compute_material("o%d_tex" % get_instance_id(), shader_compute)
		# Named parameters of the size offset resize the buffer
		get_buffer_size()
		for p in size_named_parameters:
			mm_deps.buffer_add_dependency("o%d_tex" % get_instance_id(), p)
		mm_deps.update()
	else:
		print("buffer is invalid")

func on_dep_update_value(buffer_name, parameter_name, value) -> bool:
	if parameter_name in size_named_parameters:
		# The buffer is resized (and rendered again)
		return false
	if value != null:
		shader_compute.set_parameter(parameter_name, value)
	return false

func on_dep_update_buffer(buffer_name : String) -> bool:
	if is_paused:
		return false
	# Relative sizes depend on inputs that are rendered first
	var dimensions : Vector2i = get_buffer_dimensions()
	publish_dimensions(dimensions)
	var status = await shader_compute.render(texture, dimensions.x, dimensions.y)
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

## Frees the buffer's texture (it is rendered again when needed, see mm_deps)
func release_buffer(buffer_name : String) -> bool:
	if is_paused or buffer_name != "o%d_tex" % get_instance_id():
		return false
	texture.release(buffer_name)
	return true

func get_adjusted_uv(uv : String) -> String:
	if version == VERSION_COMPLEX and not get_parameter("filter"):
		var genname = "o"+str(get_instance_id())
		var size : String = "vec2(%s_tex_size, %s_tex_size_y)" % [ genname, genname ]
		return "((floor(fract(%s) * %s)+vec2(0.5))/%s)" % [ uv, size, size ]
	else:
		return "fract(%s)" % uv

## When true (while exporting fully procedural shaders), buffers generate the
## code of their input instead of reading their texture
static var inline_buffers : bool = false

func _get_shader_code(uv : String, output_index : int, context : MMGenContext) -> ShaderCode:
	if inline_buffers:
		var source : OutputPort = get_source(0)
		if source != null:
			return source.generator.get_shader_code(uv, source.output_index, context)
	var genname = "o"+str(get_instance_id())
	var shader_code = _get_shader_code_lod(uv, output_index, context, is_greyscale, -1.0 if output_index == 0 else parameters.lod)
	var dimensions : Vector2i = get_buffer_dimensions()
	shader_code.add_uniform("%s_tex_size" % genname, "float", float(dimensions.x))
	shader_code.add_uniform("%s_tex_size_y" % genname, "float", float(dimensions.y))
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
