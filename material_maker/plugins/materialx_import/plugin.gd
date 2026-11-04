extends MMPlugin


# Imports MaterialX materials (.mtlx) as Material Maker graphs (see
# materialx_import.gd): as a format of File/Load (and drag and drop), with its
# own menu item, and with a command that converts them to .ptex files.


const MaterialXImporter = preload("materialx_import.gd")


func _enable(api : MMPlugins.API) -> void:
	api.add_import_format("mtlx", "MaterialX material", import_mtlx)
	api.add_menu_item("Import MaterialX material...", import_from_menu, "File", "Load material from website")
	api.add_command("materialx_import", import_command)

## The graph of a MaterialX file (see MaterialXImporter.do_import()), and its
## warnings
static func import_mtlx(path : String) -> Dictionary:
	var importer = MaterialXImporter.new()
	var imported : Dictionary = importer.do_import(path, "")
	var message : String = ""
	if imported.is_empty():
		push_error("MaterialX import: %s" % importer.error)
		message = importer.error
	elif not imported.warnings.is_empty():
		message = "; ".join(imported.warnings)
	if message != "" and mm_globals.main_window != null:
		mm_globals.set_tip_text("MaterialX import of %s: %s" % [ path.get_file(), message ], 10)
	return imported

func import_from_menu() -> void:
	var dialog := preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
	dialog.min_size = Vector2(500, 500)
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	dialog.add_filter("*.mtlx;MaterialX material")
	dialog.current_dir = mm_globals.config.get_value("path", "project", mm_globals.get_home_directory())
	var files = await dialog.select_files()
	if files.size() > 0:
		mm_globals.main_window.do_load_projects(files)

## material_maker --plugin materialx_import <file.mtlx> [output.ptex]
func import_command(arguments : PackedStringArray) -> int:
	if arguments.is_empty() or arguments.size() > 2:
		print("usage: --plugin materialx_import <file.mtlx> [output.ptex]")
		return 1
	var input : String = arguments[0]
	var output : String = arguments[1] if arguments.size() > 1 else input.get_basename()+".ptex"
	if not FileAccess.file_exists(input):
		print("ERROR: %s was not found" % input)
		return 1
	var importer = MaterialXImporter.new()
	var imported : Dictionary = importer.do_import(input, "")
	if imported.is_empty():
		print("ERROR: cannot import %s: %s" % [ input, importer.error ])
		return 1
	for w in imported.warnings:
		print("warning: ", w)
	imported.erase("warnings")
	# The graph is created and serialized as when it is saved
	var graph : MMGenBase = await mm_loader.create_gen(imported)
	if graph == null:
		print("ERROR: cannot create the graph of ", input)
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
