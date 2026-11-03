extends MMPlugin


# Exports runtime packages (.mmr, see runtime_exporter.gd): from the File
# menu, with the --export-mmr command line mode and the export_mmr RPC method.


const RuntimeExporter = preload("runtime_exporter.gd")


func _enable(api : MMPlugins.API) -> void:
	api.add_menu_item("Export runtime package (.mmr)...", export_from_menu, "File", "Export material")
	# (the mode is also listed in plugin.cfg's cli_modes)
	api.add_cli_mode("--export-mmr", export_mode, "material_maker --export-mmr [options] <files>   export runtime packages (<file>.mmr; --size 0 uses the Material node's size)")
	api.add_rpc_method("export_mmr", export_rpc)

## Exports the runtime package of a graph, whose outputs are size x size
## pixels (the material's size when size is 0), returns the errors
static func export_package(graph : MMGenGraph, path : String, size : int = 0) -> PackedStringArray:
	return await RuntimeExporter.new().do_export(graph, path, size)

func export_from_menu() -> void:
	var graph_edit : MMGraphEdit = mm_globals.main_window.get_current_graph_edit()
	if graph_edit == null:
		return
	var dialog := preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
	dialog.min_size = Vector2(500, 500)
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.add_filter("*.mmr; Material Maker runtime package")
	var files = await dialog.select_files()
	if files.size() != 1:
		return
	var path : String = files[0] if files[0].get_extension() == "mmr" else files[0]+".mmr"
	mm_globals.set_tip_text("Exporting %s..." % path.get_file())
	await MMCliTools.wait_for_renders(mm_globals.main_window.get_tree())
	var errors : PackedStringArray = await export_package(MMCliTools.get_top_graph(graph_edit.generator), path)
	if errors.is_empty():
		mm_globals.set_tip_text("Exported %s" % path.get_file(), 5)
	else:
		mm_globals.main_window.accept_dialog("Runtime package export failed:\n"+"\n".join(errors))

## material_maker --export-mmr [options] <files> (with --size, --set, --seed
## and --variations, see process_graph_files)
func export_mode(cli : Node, files : Array[String], options : Dictionary) -> void:
	await cli.process_graph_files(cli.expand_files(files), options, export_variation.bind(cli))

func export_variation(suffix : String, graph : MMGenBase, file : String, options : Dictionary, cli : Node) -> void:
	await MMCliTools.wait_for_renders(graph.get_tree())
	var file_name : String = options.output_dir.path_join(file.get_file().get_basename()+suffix+".mmr")
	var errors : PackedStringArray = await export_package(graph, file_name, options.size)
	for e in errors:
		cli.show_error("ERROR: %s: %s" % [ file.get_file(), e ])
	if errors.is_empty():
		print("Exported %s" % file_name)

## RPC: { path, size } -> the package's path (size 0, the default, is the
## material's size)
func export_rpc(params : Dictionary, rpc : Node):
	if not rpc.require(params, [ "path" ]):
		return null
	var size : int = rpc.get_int(params, "size", 0)
	if rpc.method_error != "":
		return null
	if size < 0:
		return rpc.fail("incorrect size %d" % size)
	var top : MMGenGraph = MMCliTools.get_top_graph(await rpc.get_graph())
	DirAccess.make_dir_recursive_absolute(params.path.get_base_dir())
	await MMCliTools.wait_for_renders(rpc.get_tree())
	var errors : PackedStringArray = await export_package(top, params.path, size)
	return rpc.fail(", ".join(errors)) if not errors.is_empty() else params.path
