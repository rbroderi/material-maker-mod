extends MMPlugin


# An example plugin (see MMPlugins and the user manual)


func _enable(api : MMPlugins.API) -> void:
	api.add_menu_item("Example: count nodes", count_nodes_in_ui)
	api.add_command("example_list_nodes", list_nodes)
	api.add_export_hook(on_exported)
	api.add_image_format("pnm", "Netpbm image file", save_pnm)

func count_nodes_in_ui() -> void:
	var graph_edit = mm_globals.main_window.get_current_graph_edit()
	if graph_edit != null:
		mm_globals.set_tip_text("%d nodes" % graph_edit.generator.get_child_count(), 3)

## material_maker --plugin example_list_nodes <file.ptex>: prints the node types
func list_nodes(arguments : PackedStringArray) -> int:
	if arguments.is_empty():
		print("usage: --plugin example_list_nodes <file.ptex>")
		return 1
	var data = mm_loader.string_to_dict_tree(FileAccess.get_file_as_string(arguments[0]))
	if not data is Dictionary or not data.has("nodes"):
		print("cannot read ", arguments[0])
		return 1
	for n in data.nodes:
		print("%s: %s" % [ n.name, n.type ])
	return 0

## Writes the list of exported files' prefix and target next to the export
func on_exported(_material : MMGenBase, prefix : String, target : String) -> void:
	var file : FileAccess = FileAccess.open(prefix+".exported.txt", FileAccess.WRITE)
	if file != null:
		file.store_string("%s exported for %s\n" % [ prefix.get_file(), target ])

## Saves an image as a Netpbm file: grayscale (P5) or RGB (P6), with 8 or 16
## bits per component (the "grayscale" and "bits" options of export targets)
func save_pnm(image : Image, file_name : String, options : Dictionary) -> Error:
	var grayscale : bool = options.get("grayscale", false)
	var bits : int = int(options.get("bits", 8))
	var max_value : int = 65535 if bits == 16 else 255
	var converted : Image = image.duplicate()
	if bits == 16:
		converted.convert(Image.FORMAT_RF if grayscale else Image.FORMAT_RGBF)
	else:
		converted.convert(Image.FORMAT_R8 if grayscale else Image.FORMAT_RGB8)
	var file : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string("%s\n%d %d\n%d\n" % [ "P5" if grayscale else "P6", image.get_width(), image.get_height(), max_value ])
	if bits == 16:
		file.big_endian = true
		for v in converted.get_data().to_float32_array():
			file.store_16(clampi(roundi(v*max_value), 0, max_value))
	else:
		file.store_buffer(converted.get_data())
	return OK
