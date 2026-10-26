extends PanelContainer

const GUIDES_GRID := 3

var ocio_view : OptionButton = null

func _ready() -> void:
	# OCIO display/view transforms, when OpenColorIO support is built
	if not MMColorManagement.is_available():
		return
	var label : Label = Label.new()
	label.text = "View transform (OCIO)"
	ocio_view = OptionButton.new()
	ocio_view.add_item("None")
	for v in MMColorManagement.get_views():
		ocio_view.add_item(v)
	ocio_view.item_selected.connect(func(i : int): owner.view_transform = "" if i == 0 else ocio_view.get_item_text(i))
	var vbox : Node = %PostProcessing.get_parent()
	vbox.add_child(label)
	vbox.move_child(label, %PostProcessing.get_index()+1)
	vbox.add_child(ocio_view)
	vbox.move_child(ocio_view, label.get_index()+1)

func _open() -> void:
	%ViewMode.selected = owner.view_mode
	%PostProcessing.selected = owner.view_filter
	if ocio_view != null:
		ocio_view.selected = 0
		for i in ocio_view.item_count:
			if ocio_view.get_item_text(i) == owner.view_transform:
				ocio_view.selected = i

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
