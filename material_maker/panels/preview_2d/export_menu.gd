extends PanelContainer

var export_settings := {
	"path" : "preview$SUFFIX_last_export_path",
	"resolution" : "preview$SUFFIX_last_export_resolution",
	"extension" : "preview$SUFFIX_last_export_extension",
	"file_name" : "preview$SUFFIX_last_export_file_name",
	#"export_type" : "preview$SUFFIX_last_export_type",
	}

const RESOLUTION_CUSTOM := 8

var additional_ids : Dictionary[String, String] = {"$node":"unnamed"}

## Sections added by plugins (see MMPlugins.API.add_export_menu_section)
var plugin_sections : Array[Control] = []
## Extensions of the file types (PNG and EXR, then formats added by plugins)
var file_type_extensions : Array[String] = [ "png", "exr" ]

func _ready() -> void:
	for val in export_settings.values():
		val = val.replace("$SUFFIX", owner.config_var_suffix)

	owner.generator_changed.connect(update)
	for create_section in MMPlugins.export_menu_sections:
		var section = create_section.call(self)
		if section is Control:
			plugin_sections.append(section)
			get_node("VBox").add_child(section)
	for extension in MMPlugins.image_formats.keys():
		file_type_extensions.append(extension)
		%FileType.add_item("."+extension)

## The previewed generator and output, for plugin sections
func get_generator() -> MMGenBase:
	return owner.generator

func get_output() -> int:
	return owner.output


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		%ExportFolderButton.icon = get_theme_icon("folder", "MM_Icons")
		%ExportFileResultLabel.add_theme_color_override("font_color", get_theme_color("font_color", "Label").lerp(Color.ORANGE, 0.5))
		%ExportNotificationLabel.add_theme_color_override("font_color", get_theme_color("font_color", "Label").lerp(get_theme_color("icon_pressed_color", "Button"), 0.5))


func _open() -> void:
	if mm_globals.has_config(export_settings.path):
		%ExportFolder.text = mm_globals.get_config(export_settings.path)

	if mm_globals.has_config(export_settings.file_name):
		%ExportFile.text = mm_globals.get_config(export_settings.file_name)
	%ExportFileResultLabel.text = interpret_file_name(%ExportFile.text)

	if mm_globals.has_config(export_settings.resolution):
		%Resolution.selected = mm_globals.get_config(export_settings.resolution)
	%CustomResolutionSection.visible = %Resolution.selected == RESOLUTION_CUSTOM

	if mm_globals.has_config(export_settings.resolution):
		%Resolution.selected = mm_globals.get_config(export_settings.resolution)

	if mm_globals.has_config(export_settings.extension):
		# Formats of plugins that were disabled are not listed anymore
		var file_type : int = mm_globals.get_config(export_settings.extension)
		%FileType.selected = file_type if file_type < %FileType.item_count else 0

	export_notification("")

	size = Vector2()


func update() -> void:
	additional_ids["$node"] = mm_globals.get_node_title_from_gen(owner.generator)
	for section in plugin_sections:
		if section.has_method("update"):
			section.update(owner.generator, owner.output)

	if not is_visible_in_tree():
		return

	var file_result := interpret_file_name(%ExportFile.text)
	%ExportFileResultLabel.text = file_result
	%ExportFileResultLabel.visible = not %ExportFile.text.is_empty() and %ExportFile.text.count("$") != file_result.count("$")
	size = Vector2()


func _on_export_folder_text_changed(new_text: String) -> void:
	mm_globals.set_config(export_settings.path, new_text)


func _on_export_folder_button_pressed() -> void:
	var file_dialog := preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	#file_dialog.add_filter("*.png; PNG image file")
	#file_dialog.add_filter("*.exr; EXR image file")

	file_dialog.current_dir = mm_globals.get_home_directory()
	
	if %ExportFolder.text:
		file_dialog.current_dir = %ExportFolder.text

	var files = await file_dialog.select_files()

	if files.size() == 1:
		%ExportFolder.text = files[0]
		_on_export_folder_text_changed(files[0])
		%ExportFolder.tooltip_text = files[0]


func _on_export_file_text_changed(new_text: String) -> void:
	mm_globals.set_config(export_settings.file_name, new_text)
	update()


func _on_file_type_item_selected(index: int) -> void:
	mm_globals.set_config(export_settings.extension, index)
	update()


func _on_resolution_item_selected(index: int) -> void:
	mm_globals.set_config(export_settings.resolution, index)
	%CustomResolutionSection.visible = index == RESOLUTION_CUSTOM
	if index != RESOLUTION_CUSTOM:
		%CustomResolutionX.set_value(64 << index)
		%CustomResolutionY.set_value(64 << index)
	update()


func get_export_resolution() -> Vector2i:
		if %Resolution.selected == RESOLUTION_CUSTOM:
			return Vector2i(int(%CustomResolutionX.value), int(%CustomResolutionY.value))
		else:
			var export_size : int = 64 << %Resolution.selected
			return Vector2i(export_size, export_size)


func _on_image_pressed() -> void:
	var path: String = %ExportFolder.text
	var file_name: String = %ExportFile.text

	if file_name:
		file_name = interpret_file_name(file_name, path)

	if path.is_empty():
		var file_dialog := preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
		file_dialog.access = FileDialog.ACCESS_FILESYSTEM

		if not file_name.is_empty():
			file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
			file_dialog.title = 'Save Image "'+file_name+'"'
		else:
			file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
			file_dialog.title = 'Save Image'
			file_dialog.add_filter("*.png; PNG image file")
			file_dialog.add_filter("*.exr; EXR image file")
			for f in MMPlugins.get_image_format_filters():
				file_dialog.add_filter(f)

		file_dialog.current_dir = mm_globals.config.get_value("path", "save_preview", mm_globals.get_home_directory())

		var files = await file_dialog.select_files()

		if files.size() > 0:
			path = files[0]

	if file_name:
		path = path.path_join(file_name)


	if path:
		owner.export_as_image_file(path, get_export_resolution())
		export_notification("Exported to " + path)
		await get_tree().create_timer(0.5).timeout
		update()


func _on_animation_pressed() -> void:
	owner.export_animation()


func _on_taa_render_pressed() -> void:
	owner.export_taa()


func _on_reference_pressed() -> void:
	owner.export_to_reference(get_export_resolution())
	export_notification("Exported to Reference")


func export_notification(text:String) -> void:
	%ExportNotificationLabel.text = text
	%ExportNotificationLabel.visible = not text.is_empty()


func interpret_file_name(file_name: String, path:="") -> String:
	if path.is_empty():
		path = %ExportFolder.text

	if not owner.generator:
		additional_ids["$name"] = "unnamed"

	var extension := ""
	if %FileType.selected >= 0 and %FileType.selected < file_type_extensions.size():
		extension = "."+file_type_extensions[%FileType.selected]
	
	var resolution : String
	if %CustomResolutionSection.visible:
		resolution = "%sx%s" % [ int(%CustomResolutionX.value), int(%CustomResolutionY.value) ]
	else:
		resolution = str(64 << %Resolution.selected)
	
	var graph_node : MMGenBase = get_node("/root/MainWindow").get_current_graph_edit().generator
	
	return MMLoader.interpret_file_name(file_name, path, extension, graph_node, additional_ids, resolution)


func _on_custom_resolution_x_value_changed(value: Variant) -> void:
	update()


func _on_custom_resolution_y_value_changed(value: Variant) -> void:
	update()
