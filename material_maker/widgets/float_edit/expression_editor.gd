extends Window

var object : Object = null
var method : String
var extra_parameters : Array = []
var accept_empty : bool = false

@onready var editor = $MarginContainer/VBoxContainer/TextEdit
@onready var parser = load("res://addons/material_maker/parser/glsl_parser.gd").new()

func _ready():
	content_scale_factor = mm_globals.ui_scale_factor()
	min_size = Vector2(300, 100) * content_scale_factor


func edit_parameter(wt : String, value : String, o : Object, m : String, ep : Array = [], ae : bool = false):
	object = o
	method = m
	extra_parameters = ep
	accept_empty = ae
	title = wt
	editor.text = value
	hide()
	popup_centered()
	editor.set_caret_column(editor.text.length())
	editor.grab_focus()
	add_function_graph_button()

# Parameter functions (see design/function_graphs.md): a float parameter's
# expression can be defined by a function graph, that is stored in the
# generator so it can be edited again

## Returns the generator whose float parameter is edited, or null
func find_parameter_generator() -> MMGenBase:
	var node = object
	while node is Node:
		if node.get("generator") is MMGenBase:
			var generator : MMGenBase = node.generator
			if generator.get_parameter_def(object.name).get("type", "") == "float":
				return generator
			return null
		node = node.get_parent()
	return null

## Returns the names the function graph can use, and their expressions
func get_parameter_function_variables(generator : MMGenBase) -> Dictionary:
	var rv : Dictionary = { time="$time" }
	var parent = generator.get_parent()
	if parent != null and parent.has_method("get_named_parameters"):
		for n in parent.get_named_parameters().keys():
			rv[n] = "$"+n
	# Variables the node's shader defines for this parameter's expression
	# (such as the instance index and random values of FX-Map Iterate)
	for v in generator.get_parameter_def(object.name).get("expression_variables", []):
		rv[v] = v
	return rv

func add_function_graph_button() -> void:
	var generator : MMGenBase = find_parameter_generator()
	if generator == null:
		return
	var button : Button = Button.new()
	button.text = "Function graph..."
	button.tooltip_text = "Define this parameter with a function graph"
	button.pressed.connect(edit_function_graph.bind(generator))
	var buttons : HBoxContainer = $MarginContainer/VBoxContainer/HBoxContainer
	buttons.add_child(button)
	buttons.move_child(button, 0)

## Returns true if a stored graph still defines the current expression.
## Graphs saved before compiled expressions had minimal parentheses are
## compared without their parentheses.
static func is_graph_of_expression(graph, variables : Dictionary, current : String) -> bool:
	if not graph is Dictionary:
		return false
	var expression = MMFunctionGraph.compile_expression(graph, variables).get("expression")
	if not expression is String:
		return false
	if expression == current:
		return true
	var strip : Callable = func(e : String) -> String: return e.replace("(", "").replace(")", "").replace(" ", "")
	return strip.call(expression) == strip.call(current)

func edit_function_graph(generator : MMGenBase) -> void:
	var parameter_name : String = object.name
	var variables : Dictionary = get_parameter_function_variables(generator)
	var graph = generator.parameter_functions.get(parameter_name)
	var current : String = editor.text.strip_edges()
	# The stored graph is only used if the parameter was not modified since
	if not is_graph_of_expression(graph, variables, current):
		graph = { nodes={ out={ op="float", value=current.to_float() if current.is_valid_float() else 0.0 } }, output="out" }
	var function_graph_editor = load("res://material_maker/windows/function_graph_editor/function_graph_editor.gd").new()
	mm_globals.main_window.add_dialog(function_graph_editor)
	function_graph_editor.graph_applied.connect(on_function_graph_applied.bind(generator, parameter_name, variables))
	function_graph_editor.edit(graph, "expression", "Parameter function - %s" % parameter_name, variables)

func on_function_graph_applied(graph : Dictionary, generator : MMGenBase, parameter_name : String, variables : Dictionary) -> void:
	var result : Dictionary = MMFunctionGraph.compile_expression(graph, variables)
	if not result.ok or not is_instance_valid(self) or not is_instance_valid(generator):
		return
	editor.text = result.expression
	generator.parameter_functions[parameter_name] = graph
	await check_self_reference_apply()

func check_self_reference_apply() -> bool:
	var value : String = editor.text.replace("\n", "").strip_edges()
	var self_reference := RegEx.new()
	self_reference.compile("\\$\\b%s\\b" % object.name)
	# warns if result expression causes variable to reference itself
	if self_reference.search(value):
		var dialog : AcceptDialog = load("res://material_maker/windows/accept_dialog/accept_dialog.tscn").instantiate()
		var error_text := tr("Expression creates a loop. Remove $%s then try again." % object.name)
		dialog.dialog_text = TranslationServer.translate(error_text)
		add_child(dialog)
		await dialog.ask()
		return false 
	var parameters : Array = [ value ]
	parameters.append_array(extra_parameters)
	object.callv(method, parameters)
	return true

func _on_Apply_pressed():
	if not await check_self_reference_apply():
		return

func _on_OK_pressed():
	if not await check_self_reference_apply():
		return
	queue_free()

func _on_Cancel_pressed():
	queue_free()

func _on_TextEdit_gui_input(event):
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_ENTER:
				_on_OK_pressed()
			KEY_ESCAPE:
				_on_Cancel_pressed()
			_:
				if accept_empty and editor.text == "":
					$MarginContainer/VBoxContainer/HBoxContainer/OK.disabled = false
					$MarginContainer/VBoxContainer/HBoxContainer/Apply.disabled = false
				else:
					var parse_result = parser.parse(editor.text)
					if parse_result.status == "OK" and parse_result.non_terminal == "expression":
						$MarginContainer/VBoxContainer/HBoxContainer/OK.disabled = false
						$MarginContainer/VBoxContainer/HBoxContainer/Apply.disabled = false
					else:
						$MarginContainer/VBoxContainer/HBoxContainer/OK.disabled = true
						$MarginContainer/VBoxContainer/HBoxContainer/Apply.disabled = true
