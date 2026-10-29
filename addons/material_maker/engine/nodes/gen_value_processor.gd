@tool
extends MMGenPixelProcessor
class_name MMGenValueProcessor


# Value processors compute a single value with a function graph (see
# design/function_graphs.md). The graph is compiled like a pixel processor's,
# but is rendered once into a 1x1 buffer, so the node's output is constant
# over the image and the graph is not evaluated for each pixel.


const DEFAULT_VALUE_FUNCTION_GRAPH : Dictionary = {
	version=2,
	inputs=[ { name="in", label="Input" } ],
	parameters=[ { name="x", label="X", min=0.0, max=1.0, step=0.01, default=0.5 }, { name="y", label="Y", min=0.0, max=1.0, step=0.01, default=0.5 } ],
	nodes={
		x={ op="param", name="x" },
		y={ op="param", name="y" },
		position={ op="vec2", args=[ "x", "y" ] },
		out={ op="sample", input=0, uv="position" }
	},
	output="out"
}

# Raw output of the function graph, sampled by the value buffer
const RAW_OUTPUT : int = 1


# The buffer that renders the raw output of its value processor (its parent).
# It is not part of the graph and is never serialized.
class ValueBuffer:
	extends MMGenBuffer

	func _init() -> void:
		version = VERSION_SIMPLE
		parameters.size = 0

	func get_type_name() -> String:
		return "Value Buffer"

	func get_source(_input_index : int) -> OutputPort:
		return OutputPort.new(get_parent(), RAW_OUTPUT)

	func get_targets(_output_index : int) -> Array:
		return []

	func notify_output_change(_output_index : int) -> void:
		# The value processor's output is this buffer's output
		var processor = get_parent()
		if processor != null:
			processor.notify_output_change(0)


var value_buffer : ValueBuffer = null


func _init() -> void:
	set_function_graph(DEFAULT_VALUE_FUNCTION_GRAPH.duplicate(true))

func _ready() -> void:
	super._ready()
	value_buffer = ValueBuffer.new()
	value_buffer.name = "value_buffer"
	add_child(value_buffer)

func get_type() -> String:
	return "value_processor"

func get_type_name() -> String:
	return "Value Processor"

func get_mode() -> String:
	return "value"

func get_buffers(flags : int = BUFFERS_ALL) -> Array:
	var rv : Array = super.get_buffers(flags)
	if value_buffer != null:
		rv.append_array(value_buffer.get_buffers(flags))
	return rv

func set_shader_model(data : Dictionary) -> void:
	super.set_shader_model(data)
	# The value buffer renders this node's raw output, that just changed
	if value_buffer != null:
		value_buffer.update_shader()

func source_changed(input_index : int) -> void:
	if value_buffer != null:
		value_buffer.update_shader()
	super.source_changed(input_index)

func _get_shader_code(uv : String, output_index : int, context : MMGenContext) -> ShaderCode:
	if output_index == RAW_OUTPUT or value_buffer == null:
		return super._get_shader_code(uv, 0, context)
	# The output is the value buffer's single pixel
	return value_buffer.get_shader_code("vec2(0.5)", 0, context)
