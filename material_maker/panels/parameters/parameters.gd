extends ScrollContainer

@onready var parameters : GridContainer = $Parameters

const GENERIC = preload("res://material_maker/nodes/generic/generic.gd")

var controls : Dictionary = {}
var generator = null
var ignore_parameter_change = ""

func _ready():
	set_generator(generator)

func set_generator(g):
	if g != generator:
		if is_instance_valid(generator) and generator.is_connected("parameter_changed", Callable(self, "on_parameter_changed")):
			generator.disconnect("parameter_changed", Callable(self, "on_parameter_changed"))
		generator = g
		if generator != null:
			generator.connect("parameter_changed", Callable(self, "on_parameter_changed"))
	if parameters:
		for c in parameters.get_children():
			parameters.remove_child(c)
			c.free()
	controls = {}
	var group : String = ""
	var group_controls : Array = []
	if generator != null:
		var parameter_labels = {}
		for p in generator.get_parameter_defs():
			if p.has("label"):
				parameter_labels[p.label] = p
		for p in generator.get_parameter_defs():
			if p.has("label"):
				if p.label.left(6) == "Paint " and parameter_labels.has(p.label.right(-6)):
					continue
				elif parameter_labels.has("Paint "+p.label):
					var paint_parameter = parameter_labels["Paint "+p.label]
					var channel_control = GENERIC.create_parameter_control(paint_parameter, false)
					channel_control.name = paint_parameter.name
					if channel_control is CheckBox:
						channel_control.text = p.label
					parameters.add_child(channel_control)
					controls[paint_parameter.name] = channel_control
				else:
					var label_text : String = p.label
					# "Group::Label" parameters are shown under a collapsible header
					var parameter_group : String = ""
					if label_text.contains("::"):
						parameter_group = label_text.left(label_text.rfind("::"))
						label_text = label_text.get_slice("::", label_text.get_slice_count("::")-1)
					if parameter_group != group:
						group = parameter_group
						group_controls = []
						if group != "":
							add_group_header(group, group_controls)
					var label : Label = Label.new()
					label.text = label_text
					label.size_flags_horizontal = SIZE_EXPAND_FILL
					parameters.add_child(label)
					group_controls.append(label)
			else:
				p.add_child(Control.new())
			var control = GENERIC.create_parameter_control(p, false)
			control.name = p.name
			control.size_flags_horizontal = SIZE_FILL
			parameters.add_child(control)
			controls[p.name] = control
			group_controls.append(control)
		GENERIC.initialize_controls_from_generator(controls, generator, self)
	set_size(get_size()-Vector2(1.0, 1.0))
	set_size(get_size())

## Adds a header that shows or hides the controls of a group
func add_group_header(group_name : String, group_controls : Array) -> void:
	var header : Button = Button.new()
	header.text = "\u25bc "+group_name
	header.flat = true
	header.toggle_mode = true
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.toggled.connect(func(collapsed : bool):
		header.text = ("\u25b6 " if collapsed else "\u25bc ")+group_name
		for c in group_controls:
			c.visible = not collapsed)
	parameters.add_child(header)
	parameters.add_child(Control.new())

func on_parameter_changed(p : String, v) -> void:
	if ignore_parameter_change == p:
		return
	if p == "__update_all__":
		set_generator(generator)
	else:
		GENERIC.update_control_from_parameter(controls, p, v)

func _on_text_changed(new_text, variable : String) -> void:
	ignore_parameter_change = variable
	generator.set_parameter(variable, new_text)
	ignore_parameter_change = ""

func _on_value_changed(new_value, variable : String) -> void:
	ignore_parameter_change = variable
	generator.set_parameter(variable, new_value)
	ignore_parameter_change = ""

func _on_float_value_changed(new_value, _merge_undo : bool = false, variable : String = "") -> void:
	ignore_parameter_change = variable
	generator.set_parameter(variable, new_value)
	ignore_parameter_change = ""

func _on_color_changed(new_color, _old_value, variable : String) -> void:
	ignore_parameter_change = variable
	generator.set_parameter(variable, new_color)
	ignore_parameter_change = ""

func _on_file_changed(new_file, variable : String) -> void:
	ignore_parameter_change = variable
	generator.set_parameter(variable, new_file)
	ignore_parameter_change = ""

func _on_gradient_changed(new_gradient, variable : String) -> void:
	ignore_parameter_change = variable
	generator.set_parameter(variable, new_gradient.duplicate())
	ignore_parameter_change = ""
