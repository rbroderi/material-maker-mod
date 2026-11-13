extends MMPlugin


# The --voxel-master command line mode (see voxel_master.gd).


const VoxelMaster = preload("voxel_master.gd")


func _enable(api : MMPlugins.API) -> void:
	api.add_cli_mode("--voxel-master", master_mode, "material_maker --voxel-master --master-config <config.json> -o <dir> <files>   combine the voxel recipes of the graphs in one Unreal Engine 5 master material (<name>.shader, <name>.py, <name>.master.json)", {
		"--master-config": { key="master_config", type=TYPE_STRING, help="--voxel-master: JSON file with name, ids (graph file name to integer id), id_source, inputs (sources of Seed, Age, Upkeep, Fresh, Char, Wet, Axis, Origin, Footprint) and position_scale" } })

## material_maker --voxel-master --master-config <json> -o <dir> <files>
func master_mode(cli : Node, files : Array, options : Dictionary) -> int:
	if not options.has("master_config"):
		cli.show_error("ERROR: --voxel-master requires --master-config <config.json>")
		return 1
	var text : String = FileAccess.get_file_as_string(options.master_config)
	var json : JSON = JSON.new()
	if text == "" or json.parse(text) != OK or not json.data is Dictionary:
		cli.show_error("ERROR: cannot read the configuration %s (a JSON object)" % options.master_config)
		return 1
	var config : Dictionary = json.data
	var graphs : Array = []
	var failed : bool = false
	for f : String in cli.expand_files(files):
		var gen : MMGenBase = await cli.load_graph(f, options)
		if gen == null:
			failed = true
			continue
		graphs.append({ graph=gen, file=f })
	var output_dir : String = options.output_dir
	var errors : Array[String] = []
	if not failed:
		errors = await VoxelMaster.generate(graphs, config, output_dir)
	for e in errors:
		cli.show_error("ERROR: "+e)
	for g in graphs:
		g.graph.queue_free()
	if failed or not errors.is_empty():
		return 1
	var name : String = VoxelMaster.complete_config(config).name
	for ext in [ "shader", "py", "master.json" ]:
		print("Exported %s" % output_dir.path_join("%s.%s" % [ name, ext ]))
	print("Done")
	return 0
