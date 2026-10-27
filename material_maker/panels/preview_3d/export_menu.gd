extends PanelContainer


const SETTING_GENERATE_MAP_EXPORT_PATH := "3D_generate_map_export_path"
const SETTING_GENERATE_MAP_LAST_TYPE := "3D_generage_map_type"
const SETTING_GENERATE_MAP_RESOLUTION := "3D_generate_map_resolution"
const SETTING_RENDER_SIZE := "3D_render_size"
const SETTING_RENDER_SAMPLES := "3D_render_samples"
const SETTING_RENDER_TRANSPARENT := "3D_render_transparent"
const SETTING_RENDER_THIN_WALLED := "3D_render_thin_walled"
const SETTING_TURNTABLE_FRAMES := "3D_turntable_frames"

@onready var preview3D := owner

@onready var MapExportFile := %MapExportFile
@onready var MapType := %MapType
@onready var MapFileType := %MapFileType
@onready var MapExportFileResultLabel := %MapExportFileResultLabel
@onready var MapResolution := %MapResolution

var render_size : SpinBox
var render_samples : SpinBox
var render_transparent : CheckBox
var render_thin_walled : CheckBox
var render_button : Button
var turntable_frames : SpinBox
var turntable_button : Button


func _ready() -> void:
	add_render_options()

func add_spin_box(parent : Control, label : String, minimum : float, maximum : float, setting : String, default : float) -> SpinBox:
	var l : Label = Label.new()
	l.text = label
	parent.add_child(l)
	var spin_box : SpinBox = SpinBox.new()
	spin_box.min_value = minimum
	spin_box.max_value = maximum
	spin_box.value = mm_globals.get_config_or(setting, default)
	spin_box.value_changed.connect(func(v): mm_globals.set_config(setting, v))
	parent.add_child(spin_box)
	return spin_box

## A check box saved in a setting
func add_check_box(parent : Control, text : String, tooltip : String, setting : String) -> CheckBox:
	var check_box : CheckBox = CheckBox.new()
	check_box.text = text
	check_box.tooltip_text = tooltip
	check_box.button_pressed = mm_globals.get_config_or(setting, false)
	check_box.toggled.connect(func(v): mm_globals.set_config(setting, v))
	parent.add_child(check_box)
	return check_box

## Path traced renders and turntables of the preview
func add_render_options() -> void:
	var box : VBoxContainer = $VBoxContainer
	box.add_child(HSeparator.new())
	var title : Label = Label.new()
	title.text = "Render"
	box.add_child(title)
	var grid : GridContainer = GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	render_size = add_spin_box(grid, "Size", 64, 8192, SETTING_RENDER_SIZE, 1024)
	render_samples = add_spin_box(grid, "Samples", 1, 65536, SETTING_RENDER_SAMPLES, 256)
	render_transparent = add_check_box(box, "Transparent background", "", SETTING_RENDER_TRANSPARENT)
	render_thin_walled = add_check_box(box, "Thin walled", "Transmissive surfaces are thin sheets instead of refractive solids", SETTING_RENDER_THIN_WALLED)
	render_button = Button.new()
	render_button.text = "Path traced render..."
	render_button.tooltip_text = "Renders the object from the current view with a path tracer (PNG or linear EXR)"
	render_button.pressed.connect(_on_render_button_pressed)
	box.add_child(render_button)
	var turntable_grid : GridContainer = GridContainer.new()
	turntable_grid.columns = 2
	box.add_child(turntable_grid)
	turntable_frames = add_spin_box(turntable_grid, "Turntable frames", 2, 720, SETTING_TURNTABLE_FRAMES, 36)
	turntable_button = Button.new()
	turntable_button.text = "Turntable..."
	turntable_button.tooltip_text = "Renders a full turn of the object as a sprite sheet, or a PNG sequence if the file name contains #"
	turntable_button.pressed.connect(_on_turntable_button_pressed)
	box.add_child(turntable_button)

func select_render_file(filters : Array, default_name : String) -> String:
	var dialog := preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
	dialog.min_size = Vector2(500, 500)
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	for f in filters:
		dialog.add_filter(f)
	dialog.current_dir = mm_globals.config.get_value("path", "renders", mm_globals.get_home_directory())
	dialog.current_file = default_name
	var files = await dialog.select_files()
	if files.size() != 1:
		return ""
	mm_globals.config.set_value("path", "renders", files[0].get_base_dir())
	return files[0]

func _on_render_button_pressed() -> void:
	var file_name : String = await select_render_file([ "*.png; PNG image File", "*.exr; EXR image File" ], "render.png")
	if file_name == "":
		return
	var size_value : int = int(render_size.value)
	render_button.disabled = true
	var error : String = await preview3D.render_path_traced(file_name, Vector2i(size_value, size_value), int(render_samples.value), render_transparent.button_pressed,
		func(done, total): render_button.text = "Rendering %d/%d" % [ done, total ], render_thin_walled.button_pressed)
	render_button.text = "Path traced render..."
	render_button.disabled = false
	if error != "":
		mm_globals.set_tip_text(error, 5)

func _on_turntable_button_pressed() -> void:
	var file_name : String = await select_render_file([ "*.png; PNG image File" ], "turntable.png")
	if file_name == "":
		return
	var size_value : int = int(render_size.value)
	turntable_button.disabled = true
	var images : Array[Image] = await preview3D.render_turntable(int(turntable_frames.value), Vector2i(size_value, size_value))
	var error : String = preview3D.save_turntable(images, file_name)
	turntable_button.disabled = false
	if error != "":
		mm_globals.set_tip_text(error, 5)


func _open() -> void:
	if mm_globals.has_config(SETTING_GENERATE_MAP_EXPORT_PATH):
		MapExportFile.text = mm_globals.get_config(SETTING_GENERATE_MAP_EXPORT_PATH)
	update_generate_map_file_label()

	if mm_globals.has_config(SETTING_GENERATE_MAP_LAST_TYPE):
		MapType.select(mm_globals.get_config(SETTING_GENERATE_MAP_LAST_TYPE))

	if mm_globals.has_config(SETTING_GENERATE_MAP_RESOLUTION):
		MapResolution.select(mm_globals.get_config(SETTING_GENERATE_MAP_RESOLUTION))


func _on_map_type_item_selected(index: int) -> void:
	mm_globals.set_config(SETTING_GENERATE_MAP_LAST_TYPE, index)
	update_generate_map_file_label()


func _on_generate_map_button_pressed() -> void:
	var file_name: String = MapExportFileResultLabel.text

	var extension := ""
	match MapFileType.selected:
		0: extension += ".png"
		1: extension += ".exr"

	var dialog := preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
	dialog.min_size = Vector2(500, 500)
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.add_filter("*.png; PNG image File")
	dialog.add_filter("*.exr; EXR image File")
	dialog.current_dir = get_node("/MainWindow").mm_globals.config.get_value("path", "maps", mm_globals.get_home_directory())

	dialog.current_file = file_name.get_basename()+extension

	var files = await dialog.select_files()
	if files.size() != 1:
		return

	var resolution: int = 256 << MapResolution.selected

	match MapType.selected:
		0: preview3D.do_generate_map(files[0], "position", resolution)
		1: preview3D.do_generate_map(files[0], "normal", resolution)
		2: preview3D.do_generate_map(files[0], "curvature", resolution)
		3: preview3D.do_generate_map(files[0], "ambient_occlusion", resolution)
		4: preview3D.do_generate_map(files[0], "thickness", resolution)


func _on_map_export_file_text_changed(new_text: String) -> void:
	mm_globals.set_config(SETTING_GENERATE_MAP_EXPORT_PATH, new_text)
	update_generate_map_file_label()


func _on_map_resolution_item_selected(index: int) -> void:
	mm_globals.set_config(SETTING_GENERATE_MAP_RESOLUTION, index)
	update_generate_map_file_label()


func update_generate_map_file_label() -> void:
	var file_result := interpret_map_file_name(MapExportFile.text)
	MapExportFileResultLabel.text = file_result
	MapExportFileResultLabel.tooltip_text = file_result
	MapExportFileResultLabel.visible = not MapExportFile.text.is_empty() and MapExportFile.text.count("$") != file_result.count("$")
	size = Vector2()


func interpret_map_file_name(file_name: String, path:="") -> String:
	var additional_ids : Dictionary[String, String] = {"$type": MapType.get_item_text(MapType.selected).to_snake_case()}

	var extension := ""
	match MapFileType.selected:
		0: extension += ".png"
		1: extension += ".exr"
	
	var resolution : String = str(256 << MapResolution.selected)
	
	var graph_node : MMGenBase = get_node("/root/MainWindow").get_current_graph_edit().generator
	
	return MMLoader.interpret_file_name(file_name, path, extension, graph_node, additional_ids, resolution)

func _on_map_file_type_item_selected(_index: int) -> void:
	update_generate_map_file_label()
