@tool
extends MMGenShader
class_name MMGenPixelProcessor


# Pixel processors compute each pixel with a function graph (see
# MMFunctionGraph). The function graph is compiled to a shader model, so
# everything else (parameters, previews, exports...) is handled by
# MMGenShader. Only the function graph is serialized.


const DEFAULT_FUNCTION_GRAPH : Dictionary = {
	version=1,
	inputs=[ { name="in", label="Input" } ],
	parameters=[ { name="amount", label="Amount", min=0.0, max=1.0, step=0.01, default=1.0 } ],
	nodes={
		pos={ op="pos" },
		color={ op="sample", input=0, uv="pos" },
		inverted={ op="sub", a="one", b="color" },
		one={ op="float", value=1.0 },
		amount={ op="param", name="amount" },
		mixed={ op="mix", a="color", b="inverted", t="amount" },
		rgb={ op="swizzle", a="mixed", components="rgb" },
		alpha={ op="swizzle", a="color", components="a" },
		out={ op="vec4", args=[ "rgb", "alpha" ] }
	},
	output="out"
}

const RESERVED_NAMES : Array[String] = [ "uv", "seed", "name", "time", "node_id", "size", "name_uv" ]

var function_graph : Dictionary = {}
# Global GLSL definitions required by the compiled function graph
var function_graph_globals : PackedStringArray = PackedStringArray()


func _init() -> void:
	set_function_graph(DEFAULT_FUNCTION_GRAPH.duplicate(true))

func get_type() -> String:
	return "pixel_processor"

func get_type_name() -> String:
	return "Pixel Processor"

static func is_valid_name(n) -> bool:
	if not n is String or n == "" or n in RESERVED_NAMES:
		return false
	var regex : RegEx = RegEx.create_from_string("^[a-zA-Z][a-zA-Z0-9_]*$")
	return regex.search(n) != null

## Returns true if the graph or one of its sub-functions uses op
static func uses_op(graph : Dictionary, op : String) -> bool:
	var node_lists : Array = [ graph.get("nodes") ]
	if graph.get("functions") is Dictionary:
		for f in graph.functions.values():
			if f is Dictionary:
				node_lists.append(f.get("nodes"))
	for nodes in node_lists:
		if nodes is Dictionary:
			for n in nodes.values():
				if n is Dictionary and n.get("op", "") == op:
					return true
	return false

## Builds the shader model for a function graph, returns { model, globals, errors }
static func build_shader_model(graph : Dictionary) -> Dictionary:
	var errors : PackedStringArray = PackedStringArray()
	var used_names : Dictionary = {}
	var inputs = graph.get("inputs", [])
	var parameters = graph.get("parameters", [])
	if not inputs is Array or not parameters is Array:
		return { errors=PackedStringArray([ "inputs and parameters must be arrays" ]) }
	var model_inputs : Array = []
	var sample_expressions : Array = []
	for i in inputs:
		if not i is Dictionary or not is_valid_name(i.get("name")) or used_names.has(i.name):
			errors.append("invalid or duplicate input name %s" % str(i.get("name") if i is Dictionary else i))
			continue
		used_names[i.name] = true
		model_inputs.append({ name=i.name, label=i.get("label", i.name), shortdesc=i.get("label", i.name), type="rgba", function=true, default="vec4(0.0)" })
		sample_expressions.append("$"+i.name+"(%s)")
	var model_parameters : Array = []
	var parameter_expressions : Dictionary = {}
	for p in parameters:
		if not p is Dictionary or not is_valid_name(p.get("name")) or used_names.has(p.name):
			errors.append("invalid or duplicate parameter name %s" % str(p.get("name") if p is Dictionary else p))
			continue
		used_names[p.name] = true
		model_parameters.append({ name=p.name, label=p.get("label", p.name), type="float", control="None",
			min=float(p.get("min", 0.0)), max=float(p.get("max", 1.0)), step=float(p.get("step", 0.01)), default=float(p.get("default", 0.0)) })
		parameter_expressions[p.name] = "$"+p.name
	if uses_op(graph, "size"):
		model_parameters.append({ name="size", label="Size", type="size", first=4, last=13, default=10 })
	if not errors.is_empty():
		return { errors=errors }
	var variables : Dictionary = { pos="uv", size="vec2($size)", seed="$seed", function_prefix="$(name)_fn_" }
	var result : Dictionary = MMFunctionGraph.compile(graph, sample_expressions, parameter_expressions, variables)
	if not result.ok:
		# Graphs that cannot be compiled (e.g. that need a plugin that is not
		# enabled) get a model with their inputs and parameters, that outputs
		# black, so loading and saving them keeps them unchanged
		var invalid_model : Dictionary = { name="Pixel Processor", shortdesc="Pixel Processor", code="",
			instance="vec4 $(name)_pp(vec2 uv) {\n\treturn vec4(0.0, 0.0, 0.0, 1.0);\n}\n",
			inputs=model_inputs, parameters=model_parameters,
			outputs=[ { rgba="$(name)_pp($uv)", type="rgba", shortdesc="Output", longdesc="The function graph is invalid" } ] }
		return { errors=result.errors, invalid_model=invalid_model }
	var instance : String = "\n".join(result.functions)+"vec4 $(name)_pp(vec2 uv) {\n"
	for line in result.code:
		instance += "\t%s\n" % line
	instance += "\treturn %s;\n}\n" % result.value
	var model : Dictionary = {
		name="Pixel Processor",
		shortdesc="Pixel Processor",
		longdesc="Computes each pixel with a function graph",
		code="",
		instance=instance,
		inputs=model_inputs,
		parameters=model_parameters,
		outputs=[ { rgba="$(name)_pp($uv)", type="rgba", shortdesc="Output", longdesc="The result of the function graph" } ]
	}
	return { model=model, globals=result.globals, errors=errors }

## Sets the function graph, returns the list of errors (empty on success)
func set_function_graph(graph : Dictionary) -> PackedStringArray:
	var result : Dictionary = build_shader_model(graph)
	if not result.errors.is_empty():
		return result.errors
	function_graph = graph
	function_graph_globals = result.globals
	set_shader_model(result.model)
	return PackedStringArray()

func _get_shader_code(uv : String, output_index : int, context : MMGenContext) -> ShaderCode:
	var rv : ShaderCode = super._get_shader_code(uv, output_index, context)
	# Global definitions are added one by one, so those that are used by
	# several pixel processors are only declared once
	for g in function_graph_globals:
		rv.add_global(g, "%s (Pixel Processor)" % get_hier_name())
	return rv

func _serialize(data : Dictionary) -> Dictionary:
	data.function_graph = function_graph
	return data

func _deserialize(data : Dictionary) -> void:
	if data.has("function_graph") and data.function_graph is Dictionary:
		var errors : PackedStringArray = set_function_graph(data.function_graph)
		if not errors.is_empty():
			push_error("Invalid function graph in %s: %s" % [ name, ", ".join(errors) ])
			var result : Dictionary = build_shader_model(data.function_graph)
			if result.has("invalid_model"):
				function_graph = data.function_graph
				function_graph_globals = PackedStringArray()
				set_shader_model(result.invalid_model)

## Edits the function graph as JSON
func edit(node, _tab : String = "") -> void:
	var dialog : AcceptDialog = AcceptDialog.new()
	dialog.title = tr("Function graph") + " - " + name
	dialog.dialog_hide_on_ok = false
	dialog.add_cancel_button(tr("Cancel"))
	var vbox : VBoxContainer = VBoxContainer.new()
	var text_edit : TextEdit = TextEdit.new()
	text_edit.custom_minimum_size = Vector2(640, 520)
	text_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text_edit.text = JSON.stringify(function_graph, "\t", false)
	vbox.add_child(text_edit)
	var errors_label : Label = Label.new()
	errors_label.custom_minimum_size.x = 640
	errors_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	errors_label.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
	vbox.add_child(errors_label)
	dialog.add_child(vbox)
	dialog.confirmed.connect(self.on_edit_confirmed.bind(node, dialog, text_edit, errors_label))
	dialog.visibility_changed.connect(func():
		if not dialog.visible:
			dialog.queue_free())
	mm_globals.main_window.add_dialog(dialog)
	dialog.content_scale_factor = mm_globals.ui_scale_factor()
	dialog.popup_centered()

func on_edit_confirmed(node, dialog : AcceptDialog, text_edit : TextEdit, errors_label : Label) -> void:
	var json : JSON = JSON.new()
	if json.parse(text_edit.text) != OK:
		errors_label.text = "line %d: %s" % [ json.get_error_line(), json.get_error_message() ]
		return
	if not json.data is Dictionary:
		errors_label.text = tr("The function graph must be a JSON object")
		return
	var result : Dictionary = build_shader_model(json.data)
	if not result.errors.is_empty():
		errors_label.text = "\n".join(result.errors)
		return
	function_graph = json.data
	function_graph_globals = result.globals
	node.update_shader_generator(result.model)
	node.finalize_generator_update()
	dialog.hide()
