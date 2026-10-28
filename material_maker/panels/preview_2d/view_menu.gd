extends PanelContainer

const GUIDES_GRID := 3

func _open() -> void:
	%ViewMode.selected = owner.view_mode
	%PostProcessing.selected = owner.view_filter
	%Channel.selected = owner.channel
	%PixelValues.set_pressed_no_signal(owner.show_pixel_values)
	update_compare_snapshot()

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


func _on_channel_item_selected(index: int) -> void:
	owner.channel = index


func _on_pixel_values_toggled(toggled_on: bool) -> void:
	owner.show_pixel_values = toggled_on


func _on_take_snapshot_pressed() -> void:
	await owner.take_snapshot()
	update_compare_snapshot()


func _on_compare_snapshot_toggled(toggled_on: bool) -> void:
	owner.compare_enabled = toggled_on


func update_compare_snapshot() -> void:
	%CompareSnapshot.disabled = owner.snapshot == null
	%CompareSnapshot.set_pressed_no_signal(owner.compare_enabled)
