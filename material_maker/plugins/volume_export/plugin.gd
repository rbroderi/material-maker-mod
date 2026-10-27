extends MMPlugin


# Exports 3D textures and SDFs as volumes (see volume_export.gd): from the 2D
# preview's export menu, with the --export-volume command line mode and the
# export_volume RPC method.


const VolumeExport = preload("volume_export.gd")

const RESOLUTIONS : Array[int] = [ 32, 64, 128, 256 ]
const FORMAT_NAMES : Dictionary = { vdb="OpenVDB (.vdb)", dds="3D DDS (.dds)", ktx2="KTX2 (.ktx2)" }


func _enable(api : MMPlugins.API) -> void:
	api.add_export_menu_section(func(export_menu : Control) -> Control: return VolumeSection.new(export_menu))
	api.add_cli_mode("--export-volume", export_mode, "material_maker --export-volume --node <node[:output]> [options] <files>   export a 3D texture or SDF as a volume", {
		"--voxels": { key="resolution", type=TYPE_INT, help="voxels in each direction of --export-volume (default: 128)" },
		"--extent": { key="extent", type=TYPE_FLOAT, help="size of the box sampled by --export-volume (default: 1, the box is centered)" },
		"--texel-format": { key="texel_format", type=TYPE_STRING, help="texel format of --export-volume to dds or ktx2 (%s); --format is vdb, dds or ktx2" % ", ".join(VolumeExport.TEXEL_FORMATS.keys()) } })
	api.add_rpc_method("export_volume", export_rpc)

## The Volume section of the 2D preview's export menu, shown for 3D outputs
class VolumeSection:
	extends VBoxContainer

	var export_menu : Control
	var resolution : OptionButton
	var format : OptionButton

	func _init(menu : Control) -> void:
		export_menu = menu
		visible = false
		var label : Label = Label.new()
		label.text = "Volume (3D texture or SDF)"
		add_child(label)
		var hbox : HBoxContainer = HBoxContainer.new()
		add_child(hbox)
		resolution = OptionButton.new()
		resolution.tooltip_text = "The number of voxels in each direction"
		for r in RESOLUTIONS:
			resolution.add_item("%d³" % r)
		resolution.selected = RESOLUTIONS.find(128)
		hbox.add_child(resolution)
		format = OptionButton.new()
		for f in VolumeExport.FORMATS:
			format.add_item(FORMAT_NAMES[f])
		hbox.add_child(format)
		var button : Button = Button.new()
		button.text = "Export volume..."
		button.tooltip_text = "Samples the 3D output in a [-0.5, 0.5]³ box and saves it as a volume"
		button.pressed.connect(export_volume)
		add_child(button)

	func update(generator : MMGenBase, output_index : int) -> void:
		visible = generator != null and VolumeExport.is_volume_output(generator, output_index)

	func export_volume() -> void:
		var generator : MMGenBase = export_menu.get_generator()
		if generator == null:
			return
		var extension : String = VolumeExport.FORMATS[format.selected]
		var file_dialog := preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
		file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		file_dialog.title = "Export volume"
		file_dialog.add_filter("*.%s; %s" % [ extension, FORMAT_NAMES[extension] ])
		file_dialog.current_dir = mm_globals.config.get_value("path", "save_preview", mm_globals.get_home_directory())
		var files = await file_dialog.select_files()
		if files.size() == 0:
			return
		var path : String = files[0]
		if path.get_extension().to_lower() != extension:
			path += "."+extension
		export_menu.export_notification("Exporting...")
		var error : String = await VolumeExport.export_volume(generator, export_menu.get_output(), path, RESOLUTIONS[resolution.selected])
		export_menu.export_notification("Exported to "+path if error == "" else "Error: "+error)

## material_maker --export-volume --node <node[:output]> [options] <files>
func export_mode(cli : Node, files : Array, options : Dictionary) -> void:
	await cli.process_graph_files(cli.expand_files(files), options, func(suffix : String, gen : MMGenBase, f : String, variation_options : Dictionary):
		await MMCliTools.wait_for_renders(cli.get_tree())
		var resolved : Dictionary = MMCliTools.resolve_node_output(gen, variation_options.node)
		if resolved.has("error"):
			cli.show_error("ERROR: %s: %s" % [ f.get_file(), resolved.error ])
			return
		var extension : String = variation_options.format if variation_options.format in VolumeExport.FORMATS else "vdb"
		var file_name : String = variation_options.output_dir.path_join("%s_%s%s.%s" % [ f.get_file().get_basename(), MMCliTools.spec_to_file_part(variation_options.node), suffix, extension ])
		var error : String = await VolumeExport.export_volume(resolved.generator, resolved.output, file_name, variation_options.get("resolution", 128), variation_options.get("extent", 1.0), variation_options.get("texel_format", ""))
		if error != "":
			cli.show_error("ERROR: %s: %s" % [ f.get_file(), error ])
		else:
			print("Exported %s" % file_name), "--export-volume")

## RPC: { node, path, output, resolution, extent, texel_format } -> the path
func export_rpc(params : Dictionary, rpc : Node):
	if not rpc.require(params, [ "node", "path" ]):
		return null
	var generator : MMGenBase = rpc.get_generator(await rpc.get_graph(), params.node)
	if generator == null:
		return null
	await MMCliTools.wait_for_renders(rpc.get_tree())
	var error : String = await VolumeExport.export_volume(generator, int(params.get("output", 0)), params.path, int(params.get("resolution", 128)), float(params.get("extent", 1.0)), params.get("texel_format", ""))
	return rpc.fail(error) if error != "" else params.path
