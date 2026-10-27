extends MMPlugin


# Imports X-Rite AxF materials with the axf2ptex converter (python/axf2ptex.py),
# that writes Material Maker graphs and their textures next to the AxF file
# (or in an output directory). Needs Python 3 with numpy and h5py.


func _enable(api : MMPlugins.API) -> void:
	api.add_menu_item("Import AxF material...", import_from_menu)
	api.add_command("axf_import", import_command)
	api.add_rpc_method("import_axf", import_rpc)

## The converter: in the source tree, or in the python directory of a build
static func find_converter() -> String:
	for directory in [ ProjectSettings.globalize_path("res://python"), MMPaths.get_resource_dir().path_join("python") ]:
		var path : String = directory.path_join("axf2ptex.py")
		if FileAccess.file_exists(path):
			return path
	return ""

static func python_command() -> String:
	var python : String = OS.get_environment("MATERIAL_MAKER_PYTHON")
	if python != "":
		return python
	return "python" if OS.get_name() == "Windows" else "python3"

## Converts an AxF file without blocking (the converter runs in its own
## process), returns { files } (the written graphs, and warnings) or { error }
static func convert_axf(axf_path : String, output_dir : String = "") -> Dictionary:
	var converter : String = find_converter()
	if converter == "":
		return { error="the AxF converter (python/axf2ptex.py) was not found" }
	var report_path : String = OS.get_cache_dir().path_join("mm_axf_import_%d.json" % Time.get_ticks_usec())
	var arguments : PackedStringArray = PackedStringArray([ converter, axf_path, "--report", report_path ])
	if output_dir != "":
		arguments.append_array([ "-o", output_dir ])
	var pid : int = OS.create_process(python_command(), arguments)
	if pid <= 0:
		return { error="cannot run %s (set MATERIAL_MAKER_PYTHON to a Python 3 with numpy and h5py)" % python_command() }
	while OS.is_process_running(pid):
		await Engine.get_main_loop().process_frame
	var report = JSON.parse_string(FileAccess.get_file_as_string(report_path)) if FileAccess.file_exists(report_path) else null
	DirAccess.remove_absolute(report_path)
	if not report is Dictionary:
		return { error="the AxF converter failed (exit code %d)" % OS.get_process_exit_code(pid) }
	if not report.errors.is_empty() or report.files.is_empty():
		return { error="
".join(report.errors) if not report.errors.is_empty() else "nothing was imported" }
	return { files=PackedStringArray(report.files), warnings=PackedStringArray(report.warnings) }

func import_from_menu() -> void:
	var dialog := preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
	dialog.min_size = Vector2(500, 500)
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.add_filter("*.axf; X-Rite AxF material")
	var files = await dialog.select_files()
	if files.size() != 1:
		return
	mm_globals.set_tip_text("Importing %s..." % files[0].get_file())
	var result : Dictionary = await convert_axf(files[0])
	if result.has("error"):
		mm_globals.main_window.accept_dialog("AxF import failed:\n"+result.error)
		return
	for f in result.files:
		# The PBR approximations of car paints are written but not opened
		if not f.ends_with("_pbr.ptex"):
			await mm_globals.main_window.do_load_material(f)
	mm_globals.set_tip_text("Imported %s" % ", ".join(Array(result.files).map(func(f): return f.get_file())), 5)

## material_maker --plugin axf_import <file.axf> [output directory]
func import_command(arguments : PackedStringArray) -> int:
	if arguments.is_empty():
		print("usage: --plugin axf_import <file.axf> [output directory]")
		return 1
	var result : Dictionary = await convert_axf(arguments[0], arguments[1] if arguments.size() > 1 else "")
	if result.has("error"):
		print("ERROR: ", result.error)
		return 1
	for w in result.warnings:
		print("warning: ", w)
	for f in result.files:
		print("Wrote ", f)
	return 0

## RPC: { path, output } -> the written graphs
func import_rpc(params : Dictionary):
	if not params.has("path"):
		return { error="missing path" }
	var result : Dictionary = await convert_axf(params.path, params.get("output", ""))
	return result.get("files", result)
