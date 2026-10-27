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
			parameter_defs.push_back({ name="size_mode", label="Size mode", type="enum", default=0,
				values=[ { name="Absolute", value="absolute" }, { name="Relative to output", value="relative" } ],
				longdesc="Absolute uses the size parameter, relative to output uses the material's size multiplied by 2^offset" })
			parameter_defs.push_back({ name="size_offset", label="Size offset", type="float", min=-6.0, max=4.0, step=1.0, default=0.0,
				longdesc="Size relative to the material's size, as a power of 2 (only used in relative size mode)" })
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
	var root : Node = self
	while root.get_parent() is MMGenBase:
		root = root.get_parent()
	for c in root.get_children():
		if c is MMGenMaterial and c.parameters.has("size"):
			return int(c.parameters.size)
	return -1

## Returns the buffer's size (as log2), that depends on its size mode
func get_buffer_size() -> int:
	if version == VERSION_COMPLEX and get_parameter("size_mode") == 1:
		var output_size : int = get_output_size()
		if output_size >= 0:
			return clamp(output_size+int(get_parameter("size_offset")), 0, 14)
	return int(get_parameter("size"))

## The size and format of the buffer, shown under the node
func get_badge() -> String:
	var format : String = "16F"
	if version == VERSION_COMPLEX:
		if get_parameter("f32"):
			format = "32F"
		elif get_parameter("f8"):
			format = "8 bits"
	var dimensions : Vector2i = get_buffer_dimensions()
	var size_text : String = "%d px" % dimensions.x if dimensions.x == dimensions.y else "%dx%d px" % [ dimensions.x, dimensions.y ]
	return "%s  %s %s" % [ size_text, format, "gray" if is_greyscale else "RGBA" ]

## A warning when an 8 bits buffer stores data that needs more precision:
## grayscale data (usually heights or masks used as heights), or data used
## to compute normals or heights
func get_precision_warning() -> String:
	if version != VERSION_COMPLEX or get_parameter("f32") or not get_parameter("f8"):
		return ""
	if is_greyscale:
		return "8 bits: loses height precision"
	var parent = get_parent()
	if parent is MMGenGraph:
		for c in parent.connections:
			if c.from != name or not parent.has_node(NodePath(c.to)):
				continue
			var consumer = parent.get_node(NodePath(c.to))
			var input_defs : Array = consumer.get_input_defs()
			var input_name : String = ""
			if c.to_port < input_defs.size():
				input_name = (input_defs[c.to_port].get("name", "")+" "+input_defs[c.to_port].get("shortdesc", "")).to_lower()
			# Library nodes are identified by their model (e.g. normal_map2), others by their type
			var consumer_type : String = (consumer.model if consumer.model is String else consumer.get_type())+" "+consumer.get_type_name()
			if consumer_type.to_lower().contains("normal") or input_name.contains("height") or input_name.contains("normal"):
				return "8 bits: loses normal precision"
	return ""

## Called when the material's size changes
func on_output_size_changed() -> void:
	if version == VERSION_COMPLEX and get_parameter("size_mode") == 1:
		update_buffer_size()

func update_buffer_size() -> void:
	if is_inside_tree():
		var dimensions : Vector2i = get_buffer_dimensions()
		mm_deps.dependency_update("o%d_tex_size" % get_instance_id(), float(dimensions.x))
		mm_deps.dependency_update("o%d_tex_size_y" % get_instance_id(), float(dimensions.y))
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
	elif n == "f8" and is_inside_tree():
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
	var dimensions : Vector2i = get_buffer_dimensions()
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
