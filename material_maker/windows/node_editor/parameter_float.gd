extends HBoxContainer

const CONTROLS = [ "None", "P1.x", "P1.y", "P1.a", "P1.r", "P2.x", "P2.y", "P2.a", "P2.r", "P3.x", "P3.y", "Rect1.x", "Rect1.y", "Radius1.r", "Radius1.a", "Radius11.r", "Radius11.a", "Scale1.x", "Scale1.y", "Angle1.a", "Angle2.a" ]

# The variables the parameter's expression can use (expression_variables),
# that are only defined in the node's JSON, are kept when editing
var expression_variables : Array = []

func _ready() -> void:
	$Control.clear()
	for c in CONTROLS:
		$Control.add_item(c)

func get_model_data() -> Dictionary:
	var data = {
		min = $Min.value,
		max = $Max.value,
		step = $Step.value,
		default = $Default.value,
		control = $Control.get_item_text($Control.selected)
	}
	# The default value can be an expression
	var default_value = $Default.get_value()
	if default_value is String:
		data.default = default_value
	if not expression_variables.is_empty():
		data.expression_variables = expression_variables.duplicate()
	return data

func set_model_data(data) -> void:
	expression_variables = data.get("expression_variables", []).duplicate()
	if data.has("min"):
		$Min.value = data.min
		$Default.min_value = data.min
	if data.has("max"):
		$Max.value = data.max
		$Default.max_value = data.max
	if data.has("step"):
		$Step.value = data.step
		$Default.step = data.step
	if data.has("default"):
		$Default.set_value(data.default)
	if data.has("control"):
		$Control.selected = 0
		for i in range($Control.get_item_count()):
			if data.control == $Control.get_item_text(i):
				$Control.selected = i
				break


func _on_Min_value_changed(v : float) -> void:
	$Default.min_value = v

func _on_Max_value_changed(v : float) -> void:
	$Default.max_value = v

func _on_Step_value_changed(v : float) -> void:
	$Default.step = v
