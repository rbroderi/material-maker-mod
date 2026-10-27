extends MMPlugin


# Exports runtime packages (.mmr, see runtime_exporter.gd): from the File
# menu, with the --export-mmr command line mode and the export_mmr RPC method.


const RuntimeExporter = preload("runtime_exporter.gd")


func _enable(api : MMPlugins.API) -> void:
	api.add_menu_item("Export runtime package (.mmr)...", export_from_menu, "File", "Export material")
	api.add_cli_mode("--export-mmr", export_mode, "material_maker --export-mmr [options] <files>   export runtime packages (.mmr)")
	api.add_rpc_method("export_mmr", export_rpc)

## Exports the runtime package of a graph, whose outputs are size x size
## pixels (or size x height when height is not 0, the material's size when
## size is 0), returns the errors
static func export_package(graph : MMGenGraph, path : String, size : int = 0, height : int = 0) -> PackedStringArray:
	return await RuntimeExporter.new().do_export(graph, path, size, height)

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

## material_maker --export-mmr [options] <files> (the material's size is used
## unless --size is given)
func export_mode(cli : Node, files : Array, options : Dictionary) -> void:
	await cli.process_graph_files(cli.expand_files(files), options, func(suffix : String, gen : MMGenBase, f : String, variation_options : Dictionary):
		await MMCliTools.wait_for_renders(cli.get_tree())
		var file_name : String = variation_options.output_dir.path_join(f.get_file().get_basename()+suffix+".mmr")
		var size : int = variation_options.size if variation_options.get("size_given", false) else 0
		for e in await export_package(gen, file_name, size, cli.output_height):
			cli.show_error("ERROR: %s: %s" % [ f.get_file(), e ])
		print("Exported %s" % file_name))

## RPC: { path, size, height } -> the package's path (size 0 is the material's
## size)
func export_rpc(params : Dictionary, rpc : Node):
	if not rpc.require(params, [ "path" ]):
		return null
	var top : MMGenGraph = MMCliTools.get_top_graph(await rpc.get_graph())
	DirAccess.make_dir_recursive_absolute(params.path.get_base_dir())
	await MMCliTools.wait_for_renders(rpc.get_tree())
	var errors : PackedStringArray = await export_package(top, params.path, int(params.get("size", 0)), int(params.get("height", 0)))
	return rpc.fail(", ".join(errors)) if not errors.is_empty() else params.path
