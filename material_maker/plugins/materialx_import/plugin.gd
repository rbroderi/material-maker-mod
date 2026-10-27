extends MMPlugin


# Imports MaterialX materials (.mtlx) as Material Maker graphs (see
# materialx_import.gd): as a format of File/Load, with its own menu item, and
# with a command that converts them to .ptex files.


const MaterialXImporter = preload("materialx_import.gd")


func _enable(api : MMPlugins.API) -> void:
	api.add_import_format("mtlx", "MaterialX material", import_mtlx)
	api.add_menu_item("Import MaterialX material...", import_from_menu, "File", "Load material from website")
	api.add_command("materialx_import", import_command)

## The graph of a MaterialX file (see MaterialXImporter.do_import())
static func import_mtlx(path : String) -> Dictionary:
	return MaterialXImporter.new().do_import(path, "")

func import_from_menu() -> void:
	var dialog := preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
	dialog.min_size = Vector2(500, 500)
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	dialog.add_filter("*.mtlx; MaterialX material")
	dialog.current_dir = mm_globals.config.get_value("path", "project", mm_globals.get_home_directory())
	var files = await dialog.select_files()
	if files.size() > 0:
		mm_globals.main_window.do_load_projects(files)

## material_maker --plugin materialx_import <file.mtlx> [output.ptex]
func import_command(arguments : PackedStringArray) -> int:
	if arguments.is_empty():
		print("usage: --plugin materialx_import <file.mtlx> [output.ptex]")
		return 1
	var output : String = arguments[1] if arguments.size() > 1 else arguments[0].get_basename()+".ptex"
	var imported : Dictionary = import_mtlx(arguments[0])
	if imported.is_empty():
		print("ERROR: cannot import ", arguments[0])
		return 1
	for w in imported.get("warnings", []):
		print("warning: ", w)
	imported.erase("warnings")
	# The graph is created and serialized as when it is saved
	var graph : MMGenBase = await mm_loader.create_gen(imported)
	if graph == null:
		print("ERROR: cannot create the graph of ", arguments[0])
		return 1
	mm_loader.current_project_path = output.get_base_dir()
	var data : Dictionary = graph.serialize()
	mm_loader.current_project_path = ""
	graph.free()
	var file : FileAccess = FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		print("ERROR: cannot write ", output)
		return 1
	file.store_string(JSON.stringify(data, "\t", true))
	print("Wrote ", output)
	return 0
