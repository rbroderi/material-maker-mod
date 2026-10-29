extends MMPlugin


# An example plugin (see MMPlugins and the user manual)


func _enable(api : MMPlugins.API) -> void:
	api.add_menu_item("Example: count nodes", count_nodes_in_ui)
	api.add_import_format("stripes", "Example stripes", import_stripes)
	api.add_rpc_method("example_node_count", rpc_node_count)
	api.add_command("example_list_nodes", list_nodes)
	# (the mode is also listed in plugin.cfg's cli_modes)
	api.add_cli_mode("--example-thumbnails", thumbnails_mode,
		"material_maker --example-thumbnails [--example-size <size>] [options] <files>   render the albedo of materials to <file>_thumbnail.png",
		{ "--example-size": { key="example_size", type=TYPE_INT, minimum=1, help="size of --example-thumbnails images (default: 256)" } })
	api.add_export_menu_section(func(export_menu : Control) -> Control: return RenderSpecSection.new(export_menu))
	api.add_export_hook(on_exported)

func count_nodes_in_ui() -> void:
	var graph_edit = mm_globals.main_window.get_current_graph_edit()
	if graph_edit != null:
		mm_globals.set_tip_text("%d nodes" % graph_edit.generator.get_child_count(), 3)

## Imports .stripes files (lines such as "count=12") as a material whose
## albedo is the Example Stripes node
func import_stripes(path : String) -> Dictionary:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var count : float = 8.0
	var warnings : Array[String] = []
	for line in file.get_as_text().split("\n", false):
		var key_value : PackedStringArray = line.strip_edges().split("=")
		if key_value.size() == 2 and key_value[0].strip_edges() == "count" and key_value[1].strip_edges().is_valid_float():
			count = clamp(key_value[1].to_float(), 1.0, 32.0)
		elif line.strip_edges() != "":
			warnings.append("ignored line '%s'" % line.strip_edges())
	return {
		name=path.get_file().get_basename(), type="graph", node_position={ x=0, y=0 },
		nodes=[
			{ name="Material", type="material", node_position={ x=0, y=0 }, parameters={} },
			{ name="stripes", type="example_stripes", node_position={ x=-300, y=0 }, parameters={ count=count } } ],
		connections=[ { from="stripes", from_port=0, to="Material", to_port=0 } ],
		warnings=warnings }

## RPC: the number of nodes of the current graph
func rpc_node_count(_params : Dictionary):
	var graph_edit = mm_globals.main_window.get_current_graph_edit() if mm_globals.main_window != null else null
	if graph_edit != null:
		return graph_edit.generator.get_child_count()
	# Without user interface, the RPC server's graph
	var rpc_server = Engine.get_main_loop().root.get_node_or_null("RpcServer")
	return (await rpc_server.get_graph()).get_child_count() if rpc_server != null else -1

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

## material_maker --example-thumbnails: renders the albedo of each material
## (with --set, --seed and --variations, see process_graph_files)
func thumbnails_mode(cli : Node, files : Array[String], options : Dictionary) -> void:
	await cli.process_graph_files(cli.expand_files(files), options, render_thumbnail)

func render_thumbnail(suffix : String, graph : MMGenBase, file : String, options : Dictionary) -> void:
	var material : MMGenBase = MMCliTools.find_material_node(graph)
	if material == null:
		print("%s has no material node" % file.get_file())
		return
	var file_name : String = options.output_dir.path_join("%s_thumbnail%s.png" % [ file.get_file().get_basename(), suffix ])
	await MMCliTools.wait_for_renders(graph.get_tree())
	var error : String = await MMCliTools.render_node(graph, str(material.name)+":0", options.get("example_size", 256), file_name)
	print("ERROR: "+error if error != "" else "Rendered "+file_name)

## Writes the list of exported files' prefix and target next to the export
func on_exported(_material : MMGenBase, prefix : String, target : String) -> void:
	var file : FileAccess = FileAccess.open(prefix+".exported.txt", FileAccess.WRITE)
	if file != null:
		file.store_string("%s exported for %s\n" % [ prefix.get_file(), target ])

## A section of the 2D preview's export menu that shows (and copies) the
## command line options that render the previewed output
class RenderSpecSection:
	extends HBoxContainer

	var export_menu : Control
	var options : LineEdit = LineEdit.new()

	func _init(menu : Control) -> void:
		export_menu = menu
		var label : Label = Label.new()
		label.text = "Command line:"
		add_child(label)
		options.editable = false
		options.size_flags_horizontal = SIZE_EXPAND_FILL
		options.custom_minimum_size.x = 200
		add_child(options)
		var copy : Button = Button.new()
		copy.text = "Copy"
		copy.pressed.connect(on_copy)
		add_child(copy)
		update(export_menu.get_generator(), export_menu.get_output())

	func update(generator : MMGenBase, output : int) -> void:
		# Only nodes of graphs have a command line name
		visible = is_instance_valid(generator) and generator.get_parent() is MMGenGraph
		if visible:
			var top : MMGenGraph = MMCliTools.get_top_graph(generator.get_parent())
			options.text = "--render --node %s:%d" % [ str(top.get_path_to(generator)), output ]

	func on_copy() -> void:
		DisplayServer.clipboard_set(options.text)
		export_menu.export_notification("Copied to the clipboard")
