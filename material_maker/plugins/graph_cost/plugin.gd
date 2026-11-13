extends MMPlugin


# A relative estimate of the shader cost of nodes and materials (see
# graph_cost.gd): the Plugins > Show shader cost menu item, the --graph-cost
# command line mode and the graph_cost RPC method.


const GraphCost = preload("graph_cost.gd")


func _enable(api : MMPlugins.API) -> void:
	api.add_menu_item("Show shader cost", show_cost_in_ui)
	api.add_cli_mode("--graph-cost", cost_mode, "material_maker --graph-cost [--node <node[:output]>] <files>   print the estimated shader cost (a relative estimate, not Unreal's instruction count) of a node or of the material as JSON, one line per file")
	api.add_rpc_method("graph_cost", cost_rpc)

## The cost of a node output (spec "node[:output]") or, if it is empty, of
## the material of the graph
func get_cost(graph : MMGenBase, spec : String) -> Dictionary:
	if spec == "":
		var material : MMGenBase = MMCliTools.find_material_node(graph)
		if material == null:
			return { error="the graph has no material node, use --node" }
		return GraphCost.estimate_material(material)
	var resolved : Dictionary = MMCliTools.resolve_node_output(graph, spec)
	if resolved.has("error"):
		return resolved
	return GraphCost.estimate_output(resolved.generator, resolved.output)

func show_cost_in_ui() -> void:
	var graph_edit = mm_globals.main_window.get_current_graph_edit()
	if graph_edit == null:
		return
	var cost : Dictionary = get_cost(graph_edit.generator, "")
	if cost.has("error"):
		mm_globals.set_tip_text(cost.error, 5)
		return
	mm_globals.set_tip_text("Material: ~%d instructions, %d texture samples" % [ cost.instructions, cost.texture_samples ], 5)

## material_maker --graph-cost [--node <node[:output]>] <files>
func cost_mode(cli : Node, files : Array, options : Dictionary) -> void:
	await cli.process_graph_files(cli.expand_files(files), options, func(_suffix : String, gen : MMGenBase, f : String, variation_options : Dictionary):
		var cost : Dictionary = get_cost(gen, variation_options.node)
		if cost.has("error"):
			cli.show_error("ERROR: %s: %s" % [ f.get_file(), cost.error ])
			return
		cost.file = f
		print(JSON.stringify(cost)))

## RPC: { node?, output? } -> { instructions, texture_samples, ... }
func cost_rpc(params : Dictionary, rpc : Node):
	var graph : MMGenGraph = await rpc.get_graph()
	var spec : String = ""
	if params.has("node"):
		if not rpc.require(params, [ "node" ]):
			return null
		spec = params.node+":"+str(int(params.get("output", 0)))
	var cost : Dictionary = get_cost(graph, spec)
	if cost.has("error"):
		return rpc.fail(cost.error)
	return cost
