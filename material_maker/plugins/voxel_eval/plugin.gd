extends MMPlugin


# Evaluates graph outputs at arbitrary points (see voxel_eval.gd) from the
# command line (--evaluate-points) and from the RPC server (evaluate_points),
# exchanging NumPy .npy files with Python (python/material_maker_client/voxel.py).


const VoxelEval = preload("voxel_eval.gd")


func _enable(api : MMPlugins.API) -> void:
	api.add_cli_mode("--evaluate-points", evaluate_mode, "material_maker --evaluate-points --points <p.npy> [--normals <n.npy>] [--fresh <f.npy>] [--node <node[:output]>] [--set <name>=<value>] [--voxel-params <json>] [-o dir] <files>   evaluate a node output (default: the Voxel Material) at points", {
		"--points": { key="points", type=TYPE_STRING, help="--evaluate-points: .npy file of float32 points, shape (N, 3), in metres" },
		"--normals": { key="normals", type=TYPE_STRING, help="--evaluate-points: .npy file of float32 unit normals, shape (N, 3) (default: zero, unknown)" },
		"--fresh": { key="fresh", type=TYPE_STRING, help="--evaluate-points: .npy file of float32 fresh values, shape (N) (default: 0)" },
		"--voxel-params": { key="voxel_params", type=TYPE_STRING, help="--evaluate-points: JSON object (or the path of a JSON file) that sets parameters: seed, age, upkeep, fresh, char, wet, footprint, axis and origin (arrays of 3) set every Voxel Inputs node" } })
	api.add_rpc_method("evaluate_points", evaluate_rpc)

## material_maker --evaluate-points --points p.npy [options] <files>
## Writes <input>_<node>.npy (N, 4) with --node, else <input>_base_color.npy,
## _orm, _emission, _normal and _opacity
func evaluate_mode(cli : Node, files : Array, options : Dictionary) -> void:
	if not options.has("points"):
		cli.show_error("ERROR: --evaluate-points requires --points <file.npy>")
		cli.get_tree().quit(1)
		return
	var voxel_params : Dictionary = {}
	if options.has("voxel_params"):
		var text : String = options.voxel_params.strip_edges()
		if not text.begins_with("{"):
			text = FileAccess.get_file_as_string(text)
		var json : JSON = JSON.new()
		if json.parse(text) != OK or not json.data is Dictionary:
			cli.show_error("ERROR: --voxel-params must be a JSON object or the path of a file that contains one")
			cli.get_tree().quit(1)
			return
		voxel_params = json.data
	await cli.process_graph_files(cli.expand_files(files), options, func(suffix : String, gen : MMGenBase, f : String, variation_options : Dictionary):
		var output : String = variation_options.output_dir.path_join(f.get_file().get_basename())
		if variation_options.node != "":
			output += "_"+MMCliTools.spec_to_file_part(variation_options.node)
		output += suffix
		var result : Dictionary = await VoxelEval.evaluate_files(gen, variation_options.points, variation_options.get("normals", ""), variation_options.get("fresh", ""), variation_options.node, voxel_params, output)
		if result.has("error"):
			cli.show_error("ERROR: %s: %s" % [ f.get_file(), result.error ])
			return
		for file_name in result.files:
			print("Exported %s" % file_name))

## RPC: { points, output, normals?, fresh?, node?, params? } -> the files
## written. points, normals and fresh are paths of .npy files; with node
## ("name[:output]") output is the path of an (N, 4) file, else it is a prefix
## of the files <prefix>_base_color.npy, _orm, _emission, _normal and _opacity.
func evaluate_rpc(params : Dictionary, rpc : Node):
	if not rpc.require(params, [ "points", "output" ]):
		return null
	for k in [ "normals", "fresh", "node" ]:
		if params.has(k) and not params[k] is String:
			return rpc.fail("parameter '%s' must be a string" % k)
	if params.has("params") and not params.params is Dictionary:
		return rpc.fail("parameter 'params' must be an object")
	var graph : MMGenGraph = await rpc.get_graph()
	await MMCliTools.wait_for_renders(rpc.get_tree())
	var result : Dictionary = await VoxelEval.evaluate_files(graph, params.points, params.get("normals", ""), params.get("fresh", ""), params.get("node", ""), params.get("params", {}), params.output)
	if result.has("error"):
		return rpc.fail(result.error)
	return result.files
