extends MMPlugin


# Writes the parameters of a graph as a JSON schema (see param_schema.gd): the
# --param-schema command line mode and the param_schema RPC method.


const ParamSchema = preload("param_schema.gd")


func _enable(api : MMPlugins.API) -> void:
	api.add_cli_mode("--param-schema", schema_mode, "material_maker --param-schema [-o dir] <files>   write the parameters of each graph as <file>.schema.json (no rendering)")
	api.add_rpc_method("param_schema", schema_rpc)

## material_maker --param-schema [-o dir] <files>
func schema_mode(cli : Node, files : Array, options : Dictionary) -> void:
	await cli.process_graph_files(cli.expand_files(files), options, func(suffix : String, gen : MMGenBase, f : String, variation_options : Dictionary):
		var file_name : String = variation_options.output_dir.path_join("%s%s.schema.json" % [ f.get_file().get_basename(), suffix ])
		var file : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
		if file == null:
			cli.show_error("ERROR: %s: cannot write %s" % [ f.get_file(), file_name ])
			return
		file.store_string(ParamSchema.to_json(ParamSchema.build(gen)))
		file.close()
		print("Exported %s" % file_name))

## RPC: {} -> the schema of the current graph
func schema_rpc(_params : Dictionary, rpc : Node):
	return ParamSchema.build(await rpc.get_graph())
