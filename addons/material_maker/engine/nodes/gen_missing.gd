@tool
extends MMGenBase
class_name MMGenMissing


# Placeholder for nodes whose type is unknown (e.g. a node type of a plugin
# that is not installed or not enabled). It keeps the node's data and
# connections and saves them unchanged, and outputs magenta.


## The node's data, as loaded
var data : Dictionary = {}
var input_count : int = 0
var output_count : int = 1


func get_type() -> String:
	return data.get("type", "missing")

func get_type_name() -> String:
	return "Missing: %s" % get_type()

func get_description() -> String:
	return "This node's type (%s) is unknown: a plugin may be missing or disabled. It is kept as is when the graph is saved." % get_type()

## Sets the port counts from the connections of the graph that contains the
## node (the node's definition, that would give them, is missing)
func set_port_counts(connections : Array) -> void:
	for c in connections:
		if c.get("to") == name:
			input_count = max(input_count, int(c.to_port)+1)
		if c.get("from") == name:
			output_count = max(output_count, int(c.from_port)+1)

func get_input_defs() -> Array:
	var rv : Array = []
	for i in input_count:
		rv.append({ name="in%d" % i, label="", type="rgba" })
	return rv

func get_output_defs(_show_hidden : bool = false) -> Array:
	var rv : Array = []
	for i in output_count:
		rv.append({ type="rgba" })
	return rv

func _get_shader_code(_uv : String, _output_index : int, _context : MMGenContext) -> ShaderCode:
	var rv : ShaderCode = ShaderCode.new()
	rv.output_type = "rgba"
	rv.output_values.rgba = "vec4(1.0, 0.0, 1.0, 1.0)"
	return rv

func serialize() -> Dictionary:
	var rv : Dictionary = data.duplicate(true)
	rv.name = name
	rv.node_position = { x=position.x, y=position.y }
	return rv

func deserialize(new_data : Dictionary) -> void:
	data = new_data.duplicate(true)
	if data.has("name"):
		name = data.name
	if data.has("node_position"):
		position = Vector2(data.node_position.x, data.node_position.y)
