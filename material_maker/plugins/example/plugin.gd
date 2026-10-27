extends MMPlugin


# An example plugin (see MMPlugins and the user manual)


func _enable(api : MMPlugins.API) -> void:
	api.add_menu_item("Example: count nodes", count_nodes_in_ui)
	api.add_rpc_method("example_node_count", rpc_node_count)
	api.add_command("example_list_nodes", list_nodes)
	api.add_export_hook(on_exported)

func count_nodes_in_ui() -> void:
	var graph_edit = mm_globals.main_window.get_current_graph_edit()
	if graph_edit != null:
		mm_globals.set_tip_text("%d nodes" % graph_edit.generator.get_child_count(), 3)

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

## Writes the list of exported files' prefix and target next to the export
func on_exported(_material : MMGenBase, prefix : String, target : String) -> void:
	var file : FileAccess = FileAccess.open(prefix+".exported.txt", FileAccess.WRITE)
	if file != null:
		file.store_string("%s exported for %s\n" % [ prefix.get_file(), target ])
