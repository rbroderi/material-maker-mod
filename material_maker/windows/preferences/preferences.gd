extends Window

var config : ConfigFile

signal config_changed()

func _ready() -> void:
	add_color_management_tab()

## OpenColorIO settings (used when the mm_ocio extension is built)
func add_color_management_tab() -> void:
	var scroll : ScrollContainer = ScrollContainer.new()
	scroll.name = "Color"
	var vbox : VBoxContainer = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)
	if not MMColorManagement.is_available():
		var note : Label = Label.new()
		note.text = "These settings need the OpenColorIO extension (see native/ocio)"
		vbox.add_child(note)
	for o in [ [ "OCIO config (empty: built-in ACES studio config)", "ocio_config" ],
			[ "Working color space", "ocio_working_space" ],
			[ "Color space of exported color maps (empty: no conversion)", "ocio_export_space" ] ]:
		var hbox : HBoxContainer = HBoxContainer.new()
		var label : Label = Label.new()
		label.text = o[0]
		hbox.add_child(label)
		var edit : StringOption = StringOption.new()
		edit.config_variable = o[1]
		edit.custom_minimum_size = Vector2(260, 0)
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL | Control.SIZE_SHRINK_END
		hbox.add_child(edit)
		vbox.add_child(hbox)
	%TabContainer.add_child(scroll)
	for t in find_children("*", "Tree", true, false):
		if t.has_method("update_tree"):
			t.update_tree()

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
