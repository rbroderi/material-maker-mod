extends Window

var config : ConfigFile

signal config_changed()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		queue_free()

func edit_preferences(c : ConfigFile) -> void:
	config = c
	var main_window = mm_globals.main_window
	main_window.add_dialog(self)
	config_changed.connect(main_window.on_config_changed)
	content_scale_factor = mm_globals.ui_scale_factor()
	update_controls(self)
	size *= content_scale_factor
	hide()
	popup_centered(size)

func update_controls(p : Node) -> void:
	for c in p.get_children():
		if c.has_method("init_from_config"):
			c.init_from_config(config)
		update_controls(c)

func update_config(p : Node) -> void:
	for c in p.get_children():
		if c.has_method("update_config"):
			c.update_config(config)
		update_config(c)

func _on_Apply_pressed():
	update_config(self)
	emit_signal("config_changed")

func _on_OK_pressed():
	update_config(self)
	emit_signal("config_changed")
	queue_free()

func _on_Cancel_pressed():
	queue_free()

func _on_InstallLanguage_pressed():
	var dialog = load("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
	dialog.min_size = Vector2(500, 500)
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.add_filter("*.po,*.position,*.csv;Translation file")
	var files = await dialog.select_files()
	if files.size() > 0:
		var locale = load("res://material_maker/locale/locale.gd").new()
		locale.install_translation(files[0])
		update_language_list()

func update_language_list():
	%Language.init_from_locales()
	%Language.init_from_config(config)

func _on_DownloadLanguage_pressed():
	var download_popup = load("res://material_maker/windows/preferences/language_download.tscn").instantiate()
	mm_globals.main_window.add_child(download_popup)
	download_popup.connect("tree_exited", Callable(self, "_on_DownloadLanguage_closed"))

func _on_DownloadLanguage_closed():
	var locale = load("res://material_maker/locale/locale.gd").new()
	locale.read_translations()
	update_language_list()

func _on_ready() -> void:
	%WinTabletDriver.visible = OS.get_name() == "Windows"
	%WinTabletDriverSpacer.visible = OS.get_name() == "Windows"
	add_color_management_tab()
	%Tree.update_tree()

## OpenColorIO settings (when the extension is built)
func add_color_management_tab() -> void:
	var scroll : ScrollContainer = ScrollContainer.new()
	scroll.name = "Color"
	scroll.theme_type_variation = "MM_PreferenceTab"
	var vbox : VBoxContainer = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)
	%TabContainer.add_child(scroll)
	if not MMColorManagement.is_available():
		var note : Label = Label.new()
		note.text = "Color management needs OpenColorIO support (see native/ocio in the source repository)"
		vbox.add_child(note)
		return
	var config_file : LineEdit = load("res://material_maker/windows/preferences/string_option.gd").new()
	config_file.config_variable = "ocio_config"
	config_file.placeholder_text = "Built-in ACES studio config"
	config_file.tooltip_text = "The OpenColorIO config file (empty for the built-in ACES studio config)"
	config_file.custom_minimum_size = Vector2(200, 0)
	config_file.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var browse : Button = Button.new()
	browse.text = "..."
	browse.tooltip_text = "Select an OpenColorIO config file"
	var config_box : HBoxContainer = HBoxContainer.new()
	config_box.custom_minimum_size = Vector2(260, 0)
	config_box.size_flags_horizontal = Control.SIZE_SHRINK_END | Control.SIZE_EXPAND
	config_box.add_child(config_file)
	config_box.add_child(browse)
	add_preference_row(vbox, "OCIO config", config_box)
	var color_space_option : Script = load("res://material_maker/windows/preferences/color_space_option.gd")
	var working_space : OptionButton = color_space_option.new()
	working_space.config_variable = "ocio_working_space"
	working_space.tooltip_text = "The color space of Material Maker's values (sRGB encoded by default)"
	add_preference_row(vbox, "Working color space", working_space)
	var export_space : OptionButton = color_space_option.new()
	export_space.config_variable = "ocio_export_space"
	export_space.none_text = "No conversion"
	add_preference_row(vbox, "Exported color maps", export_space)
	# Items in the order of MMColorManagement.COLOR_DEPTH_*
	var color_depth : OptionButton = EnumOption.new()
	color_depth.config_variable = "ocio_export_color_depth"
	color_depth.add_item("Auto (16 bits if linear)")
	color_depth.add_item("Always 16 bits")
	color_depth.add_item("Always 8 bits")
	color_depth.tooltip_text = "The bit depth of converted PNG color maps: Auto writes 16 bits files for linear color spaces such as ACEScg (8 bits show banding in dark areas) and 8 bits files for the other ones"
	add_preference_row(vbox, "Converted PNG color maps", color_depth)
	# The color spaces of the config being edited
	var update_color_spaces : Callable = func():
		var o = MMColorManagement.get_config_ocio(config_file.text.strip_edges())
		if o == null:
			# A config that cannot be loaded has no color spaces
			o = ClassDB.instantiate("MMOCIO")
		for picker in [ working_space, export_space ]:
			picker.set_color_spaces(picker.get_color_space(), o)
	config_file.text_submitted.connect(func(_t : String): update_color_spaces.call())
	config_file.focus_exited.connect(update_color_spaces)
	browse.pressed.connect(func():
		var dialog = load("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
		dialog.min_size = Vector2(500, 500)
		dialog.access = FileDialog.ACCESS_FILESYSTEM
		dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		dialog.add_filter("*.ocio;OpenColorIO config")
		var files = await dialog.select_files()
		if files.size() > 0:
			config_file.text = files[0]
			update_color_spaces.call())

func add_preference_row(vbox : VBoxContainer, label_text : String, control : Control) -> void:
	var hbox : HBoxContainer = HBoxContainer.new()
	var label : Label = Label.new()
	label.text = label_text
	hbox.add_child(label)
	if control.custom_minimum_size.x == 0:
		control.custom_minimum_size = Vector2(260, 0)
		control.size_flags_horizontal = Control.SIZE_SHRINK_END | Control.SIZE_EXPAND
	hbox.add_child(control)
	vbox.add_child(hbox)
