extends PanelContainer

const GUIDES_GRID := 3

## OpenColorIO display/view transforms (null without OpenColorIO support)
var view_transform_picker : OptionButton = null

func _ready() -> void:
	if not MMColorManagement.is_available():
		return
	var label : Label = Label.new()
	label.text = "View transform"
	label.tooltip_text = "OpenColorIO display/view transform, applied to the preview only"
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.theme_type_variation = "MM_PanelMenuSubPanelLabel"
	view_transform_picker = MMColorManagement.create_view_picker(owner.view_transform, func(view : String):
		owner.view_transform = view
		view_transform_picker.tooltip_text = view)
	# View names are long ("display / view"), they are clipped and shown in the tooltip
	view_transform_picker.theme_type_variation = "MM_NodeOptionEdit"
	view_transform_picker.get_popup().theme_type_variation = "MM_NodeOptionEditPopup"
	view_transform_picker.fit_to_longest_item = false
	view_transform_picker.clip_text = true
	view_transform_picker.custom_minimum_size.x = 160
	var vbox : Node = %PostProcessing.get_parent()
	vbox.add_child(label)
	vbox.move_child(label, %PostProcessing.get_index()+1)
	vbox.add_child(view_transform_picker)
	vbox.move_child(view_transform_picker, label.get_index()+1)

func _open() -> void:
	%ViewMode.selected = owner.view_mode
	%PostProcessing.selected = owner.view_filter

	%Guides.selected = owner.get_node("Guides").style
	%CustomGridSize.visible = %Guides.selected == GUIDES_GRID
	%CustomGridSize.value = owner.get_node("Guides").grid_size
	#%CustomGridSizeLabel.visible = %Guides.selected == GUIDES_GRID

	%GuidesColor.color = owner.get_node("Guides").color
	
	%CheckerSize.selected = owner.checker_size
	%CheckerBrightness.selected = owner.checker_brightness
	if view_transform_picker != null:
		# The views of the current config
		MMColorManagement.fill_view_picker(view_transform_picker, owner.view_transform)
		view_transform_picker.tooltip_text = owner.view_transform

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
