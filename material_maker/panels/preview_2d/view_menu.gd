extends PanelContainer

const GUIDES_GRID := 3

var ocio_view : OptionButton = null
var channel : OptionButton = null
var pixel_values : CheckBox = null
var compare : CheckBox = null

func _ready() -> void:
	add_inspection_controls()
	# OCIO display/view transforms, when OpenColorIO support is built
	if not MMColorManagement.is_available():
		return
	var label : Label = Label.new()
	label.text = "View transform (OCIO)"
	ocio_view = MMColorManagement.create_view_picker(owner.view_transform, func(view : String): owner.view_transform = view)
	var vbox : Node = %PostProcessing.get_parent()
	vbox.add_child(label)
	vbox.move_child(label, %PostProcessing.get_index()+1)
	vbox.add_child(ocio_view)
	vbox.move_child(ocio_view, label.get_index()+1)

## Channel isolation, pixel values and comparison with a snapshot
func add_inspection_controls() -> void:
	var vbox : Node = %PostProcessing.get_parent()
	var label : Label = Label.new()
	label.text = "Channel"
	vbox.add_child(label)
	channel = OptionButton.new()
	for c in owner.CHANNEL_OPTIONS:
		channel.add_item(c)
	channel.item_selected.connect(func(i : int): owner.channel = i)
	vbox.add_child(channel)
	pixel_values = CheckBox.new()
	pixel_values.text = "Show pixel values"
	pixel_values.tooltip_text = "Shows the values of the pixel under the mouse"
	pixel_values.toggled.connect(func(b : bool): owner.show_pixel_values = b)
	vbox.add_child(pixel_values)
	var hbox : HBoxContainer = HBoxContainer.new()
	vbox.add_child(hbox)
	var snapshot : Button = Button.new()
	snapshot.text = "Snapshot"
	snapshot.tooltip_text = "Keeps the current image, to compare it with later changes or with another node"
	snapshot.pressed.connect(func():
		await owner.take_snapshot()
		compare.disabled = owner.snapshot == null
		compare.set_pressed_no_signal(owner.compare_enabled))
	hbox.add_child(snapshot)
	compare = CheckBox.new()
	compare.text = "Compare"
	compare.tooltip_text = "Shows the snapshot left of a split that can be dragged"
	compare.disabled = true
	compare.toggled.connect(func(b : bool): owner.compare_enabled = b)
	hbox.add_child(compare)

func _open() -> void:
	channel.selected = owner.channel
	pixel_values.set_pressed_no_signal(owner.show_pixel_values)
	compare.disabled = owner.snapshot == null
	compare.set_pressed_no_signal(owner.compare_enabled)
	%ViewMode.selected = owner.view_mode
	%PostProcessing.selected = owner.view_filter
	if ocio_view != null:
		MMColorManagement.select_view(ocio_view, owner.view_transform)

	%Guides.selected = owner.get_node("Guides").style
	%CustomGridSize.visible = %Guides.selected == GUIDES_GRID
	%CustomGridSize.value = owner.get_node("Guides").grid_size
	#%CustomGridSizeLabel.visible = %Guides.selected == GUIDES_GRID

	%GuidesColor.color = owner.get_node("Guides").color
	
	%CheckerSize.selected = owner.checker_size
	%CheckerBrightness.selected = owner.checker_brightness

	size = Vector2()


func _on_view_mode_item_selected(index: int) -> void:
	owner.view_mode = index


func _on_post_processing_item_selected(index: int) -> void:
	owner.view_filter = index


func _on_guides_item_selected(index: int) -> void:
	%CustomGridSize.visible = index == GUIDES_GRID
	if index == GUIDES_GRID:
		%CustomGridSize.value = owner.get_node("Guides").grid_size
	owner.get_node("Guides").style = index
	size = Vector2()

func _on_guides_color_color_changed(color: Color) -> void:
	owner.get_node("Guides").color = color

func _on_custom_grid_size_value_changed(value: Variant) -> void:
	owner.get_node("Guides").grid_size = value


func _on_checker_size_item_selected(index: int) -> void:
	owner.checker_size = index


func _on_checker_brightness_item_selected(index: int) -> void:
	owner.checker_brightness = index
