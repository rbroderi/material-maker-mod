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

var volume_section : VBoxContainer
var volume_resolution : OptionButton
var volume_format : OptionButton

const VOLUME_RESOLUTIONS : Array[int] = [ 32, 64, 128, 256 ]
const VOLUME_FORMATS : Array = [ [ "OpenVDB (.vdb)", "vdb" ], [ "3D DDS (.dds)", "dds" ], [ "KTX2 (.ktx2)", "ktx2" ] ]

func _ready() -> void:
	for val in export_settings.values():
		val = val.replace("$SUFFIX", owner.config_var_suffix)

	owner.generator_changed.connect(update)
	add_volume_section()

## Export of 3D textures and SDFs as volumes (see MMVolumeExport)
func add_volume_section() -> void:
	volume_section = VBoxContainer.new()
	volume_section.visible = false
	var label : Label = Label.new()
	label.text = "Volume (3D texture or SDF)"
	volume_section.add_child(label)
	var hbox : HBoxContainer = HBoxContainer.new()
	volume_section.add_child(hbox)
	volume_resolution = OptionButton.new()
	volume_resolution.tooltip_text = "The number of voxels in each direction"
	for r in VOLUME_RESOLUTIONS:
		volume_resolution.add_item("%d³" % r)
	volume_resolution.selected = 2
	hbox.add_child(volume_resolution)
	volume_format = OptionButton.new()
	for f in VOLUME_FORMATS:
		volume_format.add_item(f[0])
	hbox.add_child(volume_format)
	var button : Button = Button.new()
	button.text = "Export volume..."
	button.tooltip_text = "Samples the 3D output in a [-0.5, 0.5]³ box and saves it as a volume"
	button.pressed.connect(_on_volume_pressed)
	volume_section.add_child(button)
	get_node("VBox").add_child(volume_section)

func _on_volume_pressed() -> void:
	if owner.generator == null:
		return
	var extension : String = VOLUME_FORMATS[volume_format.selected][1]
	var file_dialog := preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	file_dialog.title = "Export volume"
	file_dialog.add_filter("*.%s; %s" % [ extension, VOLUME_FORMATS[volume_format.selected][0] ])
	file_dialog.current_dir = mm_globals.config.get_value("path", "save_preview", mm_globals.get_home_directory())
	var files = await file_dialog.select_files()
	if files.size() == 0:
		return
	var path : String = files[0]
	if path.get_extension().to_lower() != extension:
		path += "."+extension
	export_notification("Exporting...")
	var error : String = await MMVolumeExport.export_volume(owner.generator, owner.output, path, VOLUME_RESOLUTIONS[volume_resolution.selected])
	export_notification("Exported to "+path if error == "" else "Error: "+error)


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
		%FileType.selected = mm_globals.get_config(export_settings.extension)

	export_notification("")

	size = Vector2()


func update() -> void:
	additional_ids["$node"] = mm_globals.get_node_title_from_gen(owner.generator)
	if volume_section != null:
		volume_section.visible = owner.generator != null and MMVolumeExport.is_volume_output(owner.generator, owner.output)

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
	match %FileType.selected:
		0: extension += ".png"
		1: extension += ".exr"
	
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
