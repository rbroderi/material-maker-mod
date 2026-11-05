class_name MMGraphImage
extends MMGraphNodeGeneric

## The OpenColorIO color space picker that replaces the text field of the
## ocio_space parameter (when OpenColorIO support is built)
var ocio_space_picker : OptionButton = null

func _ready() -> void:
	super._ready()
	add_to_group(MMColorManagement.UPDATE_GROUP)

func initialize_properties() -> void:
	ocio_space_picker = null
	if MMColorManagement.is_available() and controls.has("ocio_space") and controls.ocio_space is LineEdit:
		# The color space is selected in the config's list instead of typed
		var line_edit : LineEdit = controls.ocio_space
		controls.erase("ocio_space")
		ocio_space_picker = OptionButton.new()
		ocio_space_picker.fit_to_longest_item = false
		ocio_space_picker.clip_text = true
		ocio_space_picker.custom_minimum_size = Vector2(80, 0)
		ocio_space_picker.size_flags_horizontal = line_edit.size_flags_horizontal
		ocio_space_picker.add_theme_font_size_override("font_size", 13)
		line_edit.name = "ocio_space_text"
		line_edit.add_sibling(ocio_space_picker)
		ocio_space_picker.name = "ocio_space"
		line_edit.get_parent().remove_child(line_edit)
		line_edit.queue_free()
		update_ocio_space_picker()
		ocio_space_picker.item_selected.connect(_on_ocio_space_selected)
	super.initialize_properties()

func update_ocio_space_picker() -> void:
	if ocio_space_picker != null and generator != null:
		MMColorManagement.fill_color_space_picker(ocio_space_picker, generator.get_parameter("ocio_space"))

func _on_ocio_space_selected(_index : int) -> void:
	var color_space : String = MMColorManagement.get_picker_color_space(ocio_space_picker)
	ocio_space_picker.tooltip_text = color_space
	set_generator_parameter("ocio_space", color_space)

## Lists the color spaces of the new config
func on_color_management_changed() -> void:
	update_ocio_space_picker()

func on_parameter_changed(p : String, v) -> void:
	super.on_parameter_changed(p, v)
	if p == "filter":
		var image_edit : ImagePickerButton = controls["image"]
		image_edit.set_filter(v)
	elif p == "ocio_space" and ignore_parameter_change != p:
		update_ocio_space_picker()
