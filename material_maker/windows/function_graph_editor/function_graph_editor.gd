extends MMToolWindow
class_name MMFunctionGraphEditor


# Visual editor for function graphs (the IR compiled by MMFunctionGraph,
# described in the Pixel Processor node's documentation).
#
# The function graph IR is the editor's model: every change is applied to it,
# and the graph view is rebuilt from it after structural changes. Modes:
# - "pixel": pixel processors (inputs, parameters, sub-functions),
# - "value": value processors (same, without the pixel position and size),
# - "expression": parameter functions (named parameters and constants only,
#   compiled to a single expression).


signal graph_applied(graph : Dictionary)

# Categories of the "Add node" menu. Operations of MMFunctionGraph that are
# not listed here are shown in an "Other" category.
const OP_CATEGORIES : Dictionary = {
	"Inputs": [ "pos", "size", "param", "arg", "sample", "float", "int", "vec2", "vec3", "vec4", "true", "false" ],
	"Math": [ "add", "sub", "mul", "div", "min", "max", "pow", "mod", "atan2", "step", "neg", "abs", "floor", "ceil", "fract", "sqrt", "sin", "cos", "tan", "exp", "log", "sign" ],
	"Vector": [ "dot", "length", "distance", "cross", "normalize", "swizzle", "mix", "clamp", "smoothstep" ],
	"Logic": [ "lt", "le", "gt", "ge", "eq", "ne", "and", "or", "not", "select" ],
	"Conversion": [ "to_int", "to_float" ],
	"Random": [ "rand" ],
	"Functions": [ "call", "loop" ]
}
const PIXEL_ONLY_OPS : Array[String] = [ "pos", "size" ]
const VECTOR_COMPONENTS : Array[String] = [ "x", "y", "z", "w" ]
const SLOT_COLOR : Color = Color(0.6, 0.7, 0.9)

var graph : Dictionary = {}
var graph_mode : String = "pixel"
# Named parameters that can be used in expression mode
var expression_parameters : Array = []
# "" for the main graph, or the name of the edited sub-function
var scope : String = ""
var compile_types : Dictionary = {}
var compile_node_errors : Dictionary = {}
var errors : PackedStringArray = PackedStringArray()

var graph_edit : GraphEdit

## Undo history: snapshots of the graph (var_to_str keeps value types)
const HISTORY_SIZE : int = 100
var history : PackedStringArray = PackedStringArray()
var history_index : int = -1
var history_timer : Timer
var side_panel : VBoxContainer
var scope_selector : OptionButton
# Controls hidden in expression mode, that has no sub-functions
var function_controls : Array[Control] = []
var add_menu : MenuButton
var status_label : Label
var apply_button : Button
var ok_button : Button


func _init() -> void:
	var vbox : VBoxContainer = create_layout("Function graph", Vector2i(1200, 720), Vector2i(800, 400))
	# Toolbar
	var toolbar : HBoxContainer = HBoxContainer.new()
	vbox.add_child(toolbar)
	scope_selector = OptionButton.new()
	scope_selector.item_selected.connect(on_scope_selected)
	toolbar.add_child(scope_selector)
	var separator : VSeparator = VSeparator.new()
	function_controls = [ scope_selector, add_button(toolbar, "Add function", add_function), add_button(toolbar, "Remove function", remove_function), separator ]
	toolbar.add_child(separator)
	add_menu = MenuButton.new()
	add_menu.text = "Add node"
	add_menu.flat = false
	toolbar.add_child(add_menu)
	add_button(toolbar, "Set output", set_selected_as_output)
	add_button(toolbar, "Delete", delete_selected)
	add_button(toolbar, "Edit JSON", edit_json)
	toolbar.add_child(VSeparator.new())
	add_button(toolbar, "Undo", undo).tooltip_text = "Undo (Ctrl+Z)"
	add_button(toolbar, "Redo", redo).tooltip_text = "Redo (Ctrl+Y or Ctrl+Shift+Z)"
	status_label = Label.new()
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.clip_text = true
	toolbar.add_child(status_label)
	# Graph and side panel
	var split : HSplitContainer = HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(split)
	graph_edit = GraphEdit.new()
	graph_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	graph_edit.size_flags_stretch_ratio = 3.0
	graph_edit.right_disconnects = true
	graph_edit.connection_request.connect(on_connection_request)
	graph_edit.disconnection_request.connect(on_disconnection_request)
	graph_edit.delete_nodes_request.connect(on_delete_nodes_request)
	graph_edit.end_node_move.connect(store_positions)
	split.add_child(graph_edit)
	var scroll : ScrollContainer = ScrollContainer.new()
	scroll.custom_minimum_size.x = 420
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(scroll)
	side_panel = VBoxContainer.new()
	side_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(side_panel)
	# Buttons
	var buttons : HBoxContainer = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	vbox.add_child(buttons)
	apply_button = add_button(buttons, "Apply", apply)
	ok_button = add_button(buttons, "OK", on_ok_pressed)
	add_button(buttons, "Cancel", queue_free)
	# Edits that don't rebuild the view (e.g. typing in fields) are recorded
	# periodically, so they are grouped in a single undo step
	history_timer = Timer.new()
	history_timer.wait_time = 0.5
	history_timer.timeout.connect(record_state)
	add_child(history_timer)

## Starts editing a function graph. In expression mode, parameters are the
## names that param nodes can use.
func edit(g : Dictionary, m : String, window_title : String = "", parameters : Array = []) -> void:
	graph_mode = m
	expression_parameters = parameters
	set_graph(g)
	if window_title != "":
		title = window_title
	scope = ""
	for c in function_controls:
		c.visible = graph_mode != "expression"
	rebuild_add_menu()
	# The first state of the history is recorded when the view is built,
	# with the positions of the nodes
	history.clear()
	history_index = -1
	rebuild_all()
	history_timer.start()
	popup_centered()

## Sets the edited graph (a copy of g, with the keys the editor needs)
func set_graph(g : Dictionary) -> void:
	graph = g.duplicate(true)
	if not graph.get("nodes") is Dictionary:
		graph.nodes = {}
	if not graph.get("output") is String:
		graph.output = ""
	if graph_mode != "expression":
		for k in [ "inputs", "parameters" ]:
			if not graph.get(k) is Array:
				graph[k] = []

#
# Undo/redo
#

## Adds the current graph to the history if it changed
func record_state() -> void:
	var state : String = var_to_str(graph)
	if history_index >= 0 and history[history_index] == state:
		return
	history.resize(history_index+1)
	history.append(state)
	if history.size() > HISTORY_SIZE:
		history.remove_at(0)
	history_index = history.size()-1

func undo() -> void:
	store_positions()
	record_state()
	if history_index > 0:
		history_index -= 1
		restore_state()

func redo() -> void:
	record_state()
	if history_index < history.size()-1:
		history_index += 1
		restore_state()

func restore_state() -> void:
	graph = str_to_var(history[history_index])
	if scope != "" and not get_functions().has(scope):
		scope = ""
	rebuild_all()

func _input(event : InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and event.is_command_or_control_pressed()):
		return
	# Text fields have their own undo
	var focus : Control = gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if event.keycode == KEY_Z and not event.shift_pressed:
		undo()
		set_input_as_handled()
	elif event.keycode == KEY_Y or (event.keycode == KEY_Z and event.shift_pressed):
		redo()
		set_input_as_handled()

func get_graph() -> Dictionary:
	store_positions()
	return graph.duplicate(true)

func apply() -> void:
	if errors.is_empty():
		graph_applied.emit(get_graph())

func on_ok_pressed() -> void:
	apply()
	queue_free()

#
# Model helpers
#

func get_functions() -> Dictionary:
	if not graph.get("functions") is Dictionary:
		graph.functions = {}
	return graph.functions

func scope_data() -> Dictionary:
	return graph if scope == "" else get_functions()[scope]

func scope_nodes() -> Dictionary:
	var data : Dictionary = scope_data()
	if not data.get("nodes") is Dictionary:
		data.nodes = {}
	return data.nodes

static func is_hidden(node_id : String) -> bool:
	return node_id.contains("__c")

static func vector_size(op : String) -> int:
	return int(op.right(1)) if op in [ "vec2", "vec3", "vec4" ] else 0

## Returns the names of the input slots of a node
func get_slot_keys(node : Dictionary) -> Array:
	var op : String = node.get("op", "")
	if vector_size(op) > 0:
		return VECTOR_COMPONENTS.slice(0, vector_size(op))
	if op == "call":
		var f = get_functions().get(node.get("function", ""))
		return f.params.map(func(p): return p.name) if f is Dictionary else []
	if MMFunctionGraph.BINARY_OPS.has(op) or MMFunctionGraph.COMPARISON_OPS.has(op):
		return [ "a", "b" ]
	if MMFunctionGraph.UNARY_OPS.has(op):
		return [ "a" ]
	return MMFunctionGraph.get_operation(op).get("operands", [])

## Returns the slots of a vector constructor, each one either
## { node=id } or { value=float }
func get_vector_slots(node_id : String) -> Array:
	var nodes : Dictionary = scope_nodes()
	var node : Dictionary = nodes[node_id]
	var count : int = vector_size(node.op)
	var rv : Array = []
	if node.get("value") is Array:
		for v in node.value:
			rv.append({ value=float(v) })
	elif node.get("args") is Array:
		for a in node.args:
			if a is String and is_hidden(a) and nodes.has(a):
				rv.append({ value=float(nodes[a].get("value", 0.0)) })
			else:
				rv.append({ node=a })
	while rv.size() < count:
		rv.append({ value=0.0 })
	return rv.slice(0, count)

## Writes the slots of a vector constructor: constants only produce a vector
## constant, otherwise unconnected slots become hidden float constants (only
## as many as the connected operands' components leave room for)
func set_vector_slots(node_id : String, slots : Array) -> void:
	var nodes : Dictionary = scope_nodes()
	var node : Dictionary = nodes[node_id]
	for k in nodes.keys():
		if k.begins_with(node_id+"__c"):
			nodes.erase(k)
	node.erase("value")
	node.erase("args")
	if slots.all(func(s): return s.has("value")):
		node.value = slots.map(func(s): return s.value)
		return
	var components : int = 0
	for s in slots:
		if s.has("node"):
			components += MMFunctionGraph.COMPONENTS.get(compile_types.get(s.node, "float"), 1)
	var free_components : int = vector_size(node.op)-components
	var args : Array = []
	for i in slots.size():
		if slots[i].has("node"):
			args.append(slots[i].node)
		elif free_components > 0:
			var constant_id : String = "%s__c%d" % [ node_id, i ]
			nodes[constant_id] = { op="float", value=slots[i].value }
			args.append(constant_id)
			free_components -= 1
	node.args = args

## Sets the operand of a node's input slot (operand is a node id or null)
func set_operand(node_id : String, slot : int, operand) -> void:
	var node : Dictionary = scope_nodes()[node_id]
	if vector_size(node.op) > 0:
		var slots : Array = get_vector_slots(node_id)
		slots[slot] = { node=operand } if operand != null else { value=0.0 }
		set_vector_slots(node_id, slots)
	elif node.op == "call":
		var args : Array = node.get("args", [])
		while args.size() < get_slot_keys(node).size():
			args.append(null)
		args[slot] = operand
		node.args = args
	else:
		var key : String = get_slot_keys(node)[slot]
		if operand == null:
			node.erase(key)
		else:
			node[key] = operand

func get_operand(node_id : String, slot : int):
	var node : Dictionary = scope_nodes()[node_id]
	if vector_size(node.op) > 0:
		var s : Dictionary = get_vector_slots(node_id)[slot]
		return s.get("node")
	if node.op == "call":
		var args : Array = node.get("args", [])
		return args[slot] if slot < args.size() else null
	return node.get(get_slot_keys(node)[slot])

func new_node(op : String) -> Dictionary:
	var node : Dictionary = { op=op }
	match op:
		"float", "int":
			node.value = 0
		"vec2", "vec3", "vec4":
			node.value = []
			for i in vector_size(op):
				node.value.append(0.0)
		"param":
			var names : Array = get_parameter_names()
			node.name = names[0] if not names.is_empty() else ""
		"arg":
			var params : Array = scope_data().get("params", [])
			node.name = params[0].name if not params.is_empty() else ""
		"sample":
			node.input = 0
		"swizzle":
			node.components = "x"
		"call", "loop":
			var names : Array = get_functions().keys()
			node.function = names[0] if not names.is_empty() else ""
			if op == "loop":
				node.count = 4
	return node

func get_parameter_names() -> Array:
	if graph_mode == "expression":
		return expression_parameters
	return graph.get("parameters", []).map(func(p): return p.get("name", ""))

#
# View
#

func rebuild_all() -> void:
	rebuild_scope_selector()
	rebuild_panel()
	rebuild_view()

func rebuild_scope_selector() -> void:
	scope_selector.clear()
	scope_selector.add_item("Main graph")
	for f in get_functions().keys():
		scope_selector.add_item("Function: %s" % f)
		if f == scope:
			scope_selector.select(scope_selector.item_count-1)
	if scope == "":
		scope_selector.select(0)

## Returns the operations the compiler supports, by category
static func get_op_categories() -> Dictionary:
	var supported : Array = MMFunctionGraph.BINARY_OPS.keys()+MMFunctionGraph.UNARY_OPS.keys()+MMFunctionGraph.COMPARISON_OPS.keys()+MMFunctionGraph.OPERATIONS.keys()
	var rv : Dictionary = {}
	var listed : Array = []
	for category in OP_CATEGORIES.keys():
		rv[category] = OP_CATEGORIES[category].filter(func(op): return op in supported)
		listed.append_array(OP_CATEGORIES[category])
	var other : Array = supported.filter(func(op): return not op in listed)
	if not other.is_empty():
		other.sort()
		rv["Other"] = other
	return rv

func rebuild_add_menu() -> void:
	var popup : PopupMenu = add_menu.get_popup()
	popup.clear()
	for c in popup.get_children():
		c.queue_free()
	var categories : Dictionary = get_op_categories()
	for category in categories.keys():
		var submenu : PopupMenu = PopupMenu.new()
		submenu.name = category
		for op in categories[category]:
			if graph_mode == "value" and op in PIXEL_ONLY_OPS:
				continue
			if graph_mode == "expression" and op in MMFunctionGraph.NON_EXPRESSION_OPS:
				continue
			submenu.add_item(op)
		if submenu.item_count == 0:
			submenu.free()
			continue
		submenu.index_pressed.connect(func(i : int): add_node(submenu.get_item_text(i)))
		popup.add_child(submenu)
		popup.add_submenu_node_item(category, submenu)

# Rebuilds are deferred, since they free the controls whose signals request
# them
var view_rebuild_scheduled : bool = false
var panel_rebuild_scheduled : bool = false

func rebuild_view() -> void:
	if not view_rebuild_scheduled:
		view_rebuild_scheduled = true
		do_rebuild_view.call_deferred()

func rebuild_panel() -> void:
	if not panel_rebuild_scheduled:
		panel_rebuild_scheduled = true
		do_rebuild_panel.call_deferred()

func do_rebuild_view() -> void:
	view_rebuild_scheduled = false
	graph_edit.clear_connections()
	for c in graph_edit.get_children():
		if c is GraphNode:
			graph_edit.remove_child(c)
			c.free()
	var nodes : Dictionary = scope_nodes()
	var layout : Dictionary = compute_layout()
	for node_id in nodes.keys():
		if is_hidden(node_id) or not nodes[node_id] is Dictionary:
			continue
		var graph_node : GraphNode = create_graph_node(node_id, nodes[node_id])
		if nodes[node_id].get("pos") is Array and nodes[node_id].pos.size() == 2:
			graph_node.position_offset = Vector2(nodes[node_id].pos[0], nodes[node_id].pos[1])
		else:
			graph_node.position_offset = layout.get(node_id, Vector2.ZERO)
		graph_edit.add_child(graph_node)
	for node_id in nodes.keys():
		if is_hidden(node_id) or not nodes[node_id] is Dictionary:
			continue
		for slot in get_slot_keys(nodes[node_id]).size():
			var operand = get_operand(node_id, slot)
			if operand is String and graph_edit.has_node(NodePath(operand)):
				graph_edit.connect_node(operand, 0, node_id, slot)
	# Rebuilds follow discrete edits (adding, deleting, connecting nodes...).
	# The positions computed for nodes that had none are stored first, or
	# the next undo would only forget them.
	store_positions()
	record_state()
	update_status()

## Places nodes in columns by dependency depth (used for nodes that have no
## stored position)
func compute_layout() -> Dictionary:
	var nodes : Dictionary = scope_nodes()
	var depths : Dictionary = {}
	for i in nodes.size():
		var changed : bool = false
		for node_id in nodes.keys():
			if is_hidden(node_id) or not nodes[node_id] is Dictionary:
				continue
			var depth : int = 0
			for slot in get_slot_keys(nodes[node_id]).size():
				var operand = get_operand(node_id, slot)
				if operand is String and depths.has(operand):
					depth = max(depth, depths[operand]+1)
			if depths.get(node_id, -1) != depth:
				depths[node_id] = depth
				changed = true
		if not changed:
			break
	var rows : Dictionary = {}
	var rv : Dictionary = {}
	for node_id in depths.keys():
		var row : int = rows.get(depths[node_id], 0)
		rows[depths[node_id]] = row+1
		rv[node_id] = Vector2(30+240*depths[node_id], 30+150*row)
	return rv

func create_graph_node(node_id : String, node : Dictionary) -> GraphNode:
	var graph_node : GraphNode = GraphNode.new()
	graph_node.name = node_id
	graph_node.title = node_id
	var keys : Array = get_slot_keys(node)
	var vector_slots : Array = get_vector_slots(node_id) if vector_size(node.op) > 0 else []
	for i in keys.size():
		var row : HBoxContainer = HBoxContainer.new()
		var label : Label = Label.new()
		label.text = keys[i]
		row.add_child(label)
		if not vector_slots.is_empty() and vector_slots[i].has("value"):
			row.add_child(create_float_field(vector_slots[i].value, func(v : float): set_vector_constant(node_id, i, v)))
		graph_node.add_child(row)
		graph_node.set_slot(i, true, 0, SLOT_COLOR, i == 0, 0, SLOT_COLOR)
	if keys.is_empty():
		var label : Label = Label.new()
		label.text = node.op
		graph_node.add_child(label)
		graph_node.set_slot(0, false, 0, SLOT_COLOR, true, 0, SLOT_COLOR)
	add_settings(graph_node, node_id, node)
	return graph_node

func create_float_field(value : float, callback : Callable, step : float = 0.001) -> SpinBox:
	var field : SpinBox = SpinBox.new()
	field.allow_greater = true
	field.allow_lesser = true
	field.step = step
	field.custom_minimum_size.x = 90
	field.value = value
	field.value_changed.connect(callback)
	return field

func create_option_field(values : Array, current : String, callback : Callable) -> OptionButton:
	var field : OptionButton = OptionButton.new()
	for v in values:
		field.add_item(str(v))
		if str(v) == current:
			field.select(field.item_count-1)
	field.item_selected.connect(func(i : int): callback.call(field.get_item_text(i)))
	return field

# Adds the fields that edit a node's settings (constants, names...)
func add_settings(graph_node : GraphNode, node_id : String, node : Dictionary) -> void:
	var field : Control = null
	match node.op:
		"float":
			field = create_float_field(float(node.get("value", 0.0)), func(v : float): set_setting(node_id, "value", v))
		"int":
			field = create_float_field(float(node.get("value", 0)), func(v : float): set_setting(node_id, "value", int(v)), 1.0)
		"param":
			field = create_option_field(get_parameter_names(), node.get("name", ""), func(v : String): set_setting(node_id, "name", v))
		"arg":
			field = create_option_field(scope_data().get("params", []).map(func(p): return p.name), node.get("name", ""), func(v : String): set_setting(node_id, "name", v))
		"sample":
			var names : Array = graph.get("inputs", []).map(func(i): return i.get("name", ""))
			var current : String = names[int(node.get("input", 0))] if int(node.get("input", 0)) < names.size() else ""
			field = create_option_field(names, current, func(v : String): set_setting(node_id, "input", names.find(v)))
		"swizzle":
			var line_edit : LineEdit = LineEdit.new()
			line_edit.text = node.get("components", "")
			line_edit.text_changed.connect(func(v : String): set_setting(node_id, "components", v))
			field = line_edit
		"call", "loop":
			var functions : Array = get_functions().keys().filter(func(f): return f != scope)
			field = create_option_field(functions, node.get("function", ""), func(v : String): set_setting(node_id, "function", v, node.op == "call"))
	if field != null:
		graph_node.add_child(field)
	if node.op == "loop":
		graph_node.add_child(create_float_field(float(node.get("count", 4)), func(v : float): set_setting(node_id, "count", int(v)), 1.0))

func set_setting(node_id : String, key : String, value, rebuild : bool = false) -> void:
	scope_nodes()[node_id][key] = value
	if rebuild:
		store_positions()
		rebuild_view()
	else:
		update_status()

func set_vector_constant(node_id : String, slot : int, value : float) -> void:
	var slots : Array = get_vector_slots(node_id)
	slots[slot] = { value=value }
	set_vector_slots(node_id, slots)
	update_status()

## Compiles the graph, and shows types and errors
func update_status() -> void:
	var sample_expressions : Array = graph.get("inputs", []).map(func(i): return "$in%d(%%s)" % graph.get("inputs", []).find(i))
	var parameter_expressions : Dictionary = {}
	for p in get_parameter_names():
		parameter_expressions[p] = "$"+p
	# All nodes are compiled (not only those the output depends on) to show their types
	var variables : Dictionary = { pos="uv", size="vec2(1.0)", seed="0.0", compile_all_nodes=true }
	var result : Dictionary = MMFunctionGraph.compile(graph, sample_expressions, parameter_expressions, variables)
	if scope == "":
		compile_types = result.get("types", {})
		compile_node_errors = result.get("node_errors", {})
	else:
		compile_types = result.get("function_types", {}).get(scope, {})
		compile_node_errors = result.get("function_node_errors", {}).get(scope, {})
	var expression : String = ""
	if graph_mode == "expression":
		var expression_result : Dictionary = MMFunctionGraph.compile_expression(graph, parameter_expressions)
		errors = expression_result.errors
		expression = expression_result.get("expression", "")
	else:
		errors = MMGenPixelProcessor.build_shader_model(graph, graph_mode).errors
	var output : String = scope_data().get("output", "")
	for c in graph_edit.get_children():
		if not c is GraphNode:
			continue
		var node_id : String = c.name
		var node : Dictionary = scope_nodes().get(node_id, {})
		var text : String = "%s: %s" % [ node_id, node.get("op", "") ]
		if compile_types.has(node_id):
			text += " (%s)" % compile_types[node_id]
		if node_id == output:
			text += "  [output]"
		c.title = text
		if compile_node_errors.has(node_id):
			c.self_modulate = Color(1.0, 0.45, 0.45)
			c.tooltip_text = compile_node_errors[node_id]
		else:
			c.self_modulate = Color(0.6, 1.0, 0.6) if node_id == output else Color.WHITE
			c.tooltip_text = ""
	if errors.is_empty():
		status_label.text = "OK: %s" % expression if expression != "" else "OK"
	else:
		status_label.text = "%d error(s): %s" % [ errors.size(), errors[0] ]
	status_label.tooltip_text = "\n".join(errors) if not errors.is_empty() else expression
	apply_button.disabled = not errors.is_empty()
	ok_button.disabled = not errors.is_empty()

func store_positions() -> void:
	for c in graph_edit.get_children():
		if c is GraphNode and scope_nodes().has(String(c.name)):
			scope_nodes()[String(c.name)].pos = [ c.position_offset.x, c.position_offset.y ]

#
# Graph editing
#

func on_connection_request(from_node : StringName, _from_port : int, to_node : StringName, to_port : int) -> void:
	if from_node == to_node:
		return
	store_positions()
	set_operand(String(to_node), to_port, String(from_node))
	rebuild_view()

func on_disconnection_request(_from_node : StringName, _from_port : int, to_node : StringName, to_port : int) -> void:
	store_positions()
	set_operand(String(to_node), to_port, null)
	rebuild_view()

func on_delete_nodes_request(node_names : Array) -> void:
	delete_nodes(node_names.map(func(n): return String(n)))

func delete_selected() -> void:
	var selected : Array = []
	for c in graph_edit.get_children():
		if c is GraphNode and c.selected:
			selected.append(String(c.name))
	delete_nodes(selected)

func delete_nodes(node_ids : Array) -> void:
	store_positions()
	var nodes : Dictionary = scope_nodes()
	for node_id in node_ids:
		for k in nodes.keys():
			if k == node_id or k.begins_with(node_id+"__c"):
				nodes.erase(k)
	# Disconnect the deleted nodes
	for node_id in nodes.keys():
		if is_hidden(node_id):
			continue
		for slot in get_slot_keys(nodes[node_id]).size():
			if get_operand(node_id, slot) in node_ids:
				set_operand(node_id, slot, null)
	if scope_data().get("output", "") in node_ids:
		scope_data().output = ""
	rebuild_view()

func add_node(op : String) -> void:
	store_positions()
	var nodes : Dictionary = scope_nodes()
	var index : int = 1
	while nodes.has("%s%d" % [ op, index ]):
		index += 1
	var node_id : String = "%s%d" % [ op, index ]
	var node : Dictionary = new_node(op)
	# New nodes are placed in the middle of the view, shifted so they
	# don't hide each other
	var center : Vector2 = (graph_edit.scroll_offset+0.5*graph_edit.size)/graph_edit.zoom
	added_nodes += 1
	node.pos = [ center.x-80+30*(added_nodes%8), center.y-40+30*(added_nodes%8) ]
	nodes[node_id] = node
	if scope_data().get("output", "") == "":
		scope_data().output = node_id
	rebuild_view()

var added_nodes : int = 0

func set_selected_as_output() -> void:
	for c in graph_edit.get_children():
		if c is GraphNode and c.selected:
			scope_data().output = String(c.name)
			update_status()
			return

#
# Sub-functions
#

func on_scope_selected(index : int) -> void:
	store_positions()
	scope = "" if index == 0 else get_functions().keys()[index-1]
	rebuild_scope_selector()
	rebuild_panel()
	rebuild_view()

func add_function() -> void:
	if graph_mode == "expression":
		return
	var functions : Dictionary = get_functions()
	var index : int = 1
	while functions.has("function%d" % index):
		index += 1
	var function_name : String = "function%d" % index
	functions[function_name] = {
		params=[ { name="acc", type="float" }, { name="i", type="int" } ],
		nodes={ acc={ op="arg", name="acc" } },
		output="acc"
	}
	store_positions()
	scope = function_name
	rebuild_all()

func remove_function() -> void:
	if scope == "":
		return
	get_functions().erase(scope)
	scope = ""
	rebuild_all()

func rename_function(new_name : String) -> void:
	var functions : Dictionary = get_functions()
	if not MMFunctionGraph.is_identifier(new_name) or functions.has(new_name):
		return
	functions[new_name] = functions[scope]
	functions.erase(scope)
	# Update calls and loops in all graphs
	for nodes in [ graph.nodes ]+functions.values().map(func(f): return f.nodes):
		for n in nodes.values():
			if n.get("op", "") in [ "call", "loop" ] and n.get("function", "") == scope:
				n.function = new_name
	scope = new_name
	rebuild_scope_selector()
	update_status()

#
# Side panel: inputs, parameters, function arguments
#

func do_rebuild_panel() -> void:
	panel_rebuild_scheduled = false
	for c in side_panel.get_children():
		side_panel.remove_child(c)
		c.queue_free()
	if graph_mode == "expression":
		add_section_title("Available parameters")
		var label : Label = Label.new()
		label.text = ", ".join(expression_parameters) if not expression_parameters.is_empty() else "(none)"
		label.autowrap_mode = TextServer.AUTOWRAP_WORD
		side_panel.add_child(label)
	elif scope == "":
		add_section_title("Inputs")
		for i in graph.inputs.size():
			add_list_row(graph.inputs, i, [ "name", "label" ], [])
		add_button(side_panel, "+ Input", func(): add_list_item(graph.inputs, { name="in%d" % (graph.inputs.size()+1), label="Input" }))
		add_section_title("Parameters")
		for i in graph.parameters.size():
			add_list_row(graph.parameters, i, [ "name", "label" ], [ "min", "max", "default" ])
		add_button(side_panel, "+ Parameter", func(): add_list_item(graph.parameters, { name="p%d" % (graph.parameters.size()+1), label="Parameter", min=0.0, max=1.0, default=0.5, step=0.01 }))
	else:
		add_section_title("Function name")
		var name_edit : LineEdit = LineEdit.new()
		name_edit.text = scope
		name_edit.text_submitted.connect(rename_function)
		side_panel.add_child(name_edit)
		add_section_title("Arguments")
		var params : Array = scope_data().params
		for i in params.size():
			var row : HBoxContainer = HBoxContainer.new()
			var line_edit : LineEdit = LineEdit.new()
			line_edit.text = params[i].name
			line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			line_edit.text_submitted.connect(func(v : String): rename_argument(i, v))
			row.add_child(line_edit)
			row.add_child(create_option_field(MMFunctionGraph.ARG_TYPES, params[i].type, func(v : String):
				params[i].type = v
				update_status()))
			add_button(row, "x", func():
				params.remove_at(i)
				rebuild_panel()
				rebuild_view())
			side_panel.add_child(row)
		add_button(side_panel, "+ Argument", func():
			params.append({ name="arg%d" % (params.size()+1), type="float" })
			rebuild_panel()
			rebuild_view())

func add_section_title(text : String) -> void:
	var label : Label = Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	side_panel.add_child(label)

func add_list_row(list : Array, index : int, text_keys : Array, float_keys : Array) -> void:
	var row : HBoxContainer = HBoxContainer.new()
	for k in text_keys:
		var line_edit : LineEdit = LineEdit.new()
		line_edit.text = str(list[index].get(k, ""))
		line_edit.placeholder_text = k
		line_edit.tooltip_text = k
		line_edit.custom_minimum_size.x = 70
		line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line_edit.text_submitted.connect(func(v : String): set_list_value(list, index, k, v))
		line_edit.focus_exited.connect(func(): set_list_value(list, index, k, line_edit.text))
		row.add_child(line_edit)
	for k in float_keys:
		var field : SpinBox = create_float_field(float(list[index].get(k, 0.0)), set_list_float.bind(list, index, k), 0.01)
		field.custom_minimum_size.x = 60
		field.tooltip_text = k
		row.add_child(field)
	add_button(row, "x", func():
		list.remove_at(index)
		rebuild_panel()
		rebuild_view())
	side_panel.add_child(row)

func set_list_float(v : float, list : Array, index : int, key : String) -> void:
	list[index][key] = v
	update_status()

func set_list_value(list : Array, index : int, key : String, value : String) -> void:
	if index >= list.size() or list[index].get(key, "") == value:
		return
	var old_value : String = list[index].get(key, "")
	list[index][key] = value
	# Keep param nodes pointing to renamed parameters
	if key == "name" and list == graph.get("parameters"):
		for nodes in [ graph.nodes ]+get_functions().values().map(func(f): return f.nodes):
			for n in nodes.values():
				if n.get("op", "") == "param" and n.get("name", "") == old_value:
					n.name = value
	rebuild_view()

func add_list_item(list : Array, item : Dictionary) -> void:
	list.append(item)
	rebuild_panel()
	rebuild_view()

func rename_argument(index : int, new_name : String) -> void:
	var params : Array = scope_data().params
	if not MMFunctionGraph.is_identifier(new_name):
		return
	var old_name : String = params[index].name
	params[index].name = new_name
	for n in scope_nodes().values():
		if n.get("op", "") == "arg" and n.get("name", "") == old_name:
			n.name = new_name
	rebuild_view()

#
# JSON editing (fallback)
#

func edit_json() -> void:
	var dialog : AcceptDialog = AcceptDialog.new()
	dialog.title = "Function graph (JSON)"
	dialog.add_cancel_button("Cancel")
	var text_edit : TextEdit = TextEdit.new()
	text_edit.custom_minimum_size = Vector2(640, 520)
	text_edit.text = JSON.stringify(get_graph(), "\t")
	dialog.add_child(text_edit)
	dialog.confirmed.connect(func():
		var json : JSON = JSON.new()
		if json.parse(text_edit.text) == OK and json.data is Dictionary:
			# Replacing the graph is an undoable step
			record_state()
			set_graph(json.data)
			scope = ""
			rebuild_all()
		else:
			status_label.text = "Invalid JSON: line %d: %s" % [ json.get_error_line(), json.get_error_message() ])
	dialog.visibility_changed.connect(func():
		if not dialog.visible:
			dialog.queue_free())
	add_child(dialog)
	dialog.popup_centered()
