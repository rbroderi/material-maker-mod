extends Window
class_name MMToolWindow


# Base class of the tool windows built in code (dependencies, library
# instances, function graph editor): a margin, a vertical layout and helpers
# for buttons, spacers and trees.


## Sets the window up and returns the vertical layout of its content
func create_layout(window_title : String, window_size : Vector2i, minimum_size : Vector2i) -> VBoxContainer:
	title = window_title
	size = window_size
	min_size = minimum_size
	close_requested.connect(queue_free)
	var margin : MarginContainer = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in [ "left", "right", "top", "bottom" ]:
		margin.add_theme_constant_override("margin_"+side, 6)
	add_child(margin)
	var vbox : VBoxContainer = VBoxContainer.new()
	margin.add_child(vbox)
	return vbox

static func add_button(parent : Control, text : String, callable : Callable) -> Button:
	var button : Button = Button.new()
	button.text = text
	button.pressed.connect(callable)
	parent.add_child(button)
	return button

## Adds a control that pushes the next ones to the end of a box
static func add_spacer(parent : Control) -> void:
	var spacer : Control = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(spacer)

## A tree of rows (no visible root) with column titles
static func create_tree(titles : Array[String]) -> Tree:
	var tree : Tree = Tree.new()
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.columns = titles.size()
	tree.column_titles_visible = true
	for i in titles.size():
		tree.set_column_title(i, titles[i])
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_ROW
	return tree
