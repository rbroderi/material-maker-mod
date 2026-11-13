extends MMPlugin


# Bakes a voxel material to the 2D textures of a mesh (see voxel_mesh_bake.gd)
# from the command line (--bake-voxel-material) and from the RPC server
# (bake_voxel_material).


const VoxelMeshBake = preload("voxel_mesh_bake.gd")


func _enable(api : MMPlugins.API) -> void:
	api.add_cli_mode("--bake-voxel-material", bake_mode, "material_maker --bake-voxel-material --mesh <mesh.obj|glb> [--size 1024] [--unit-scale 1.0] [--set <name>=<value>] [--format png|exr] [-o dir] <files>   bake the Voxel Material of a graph to the textures of a mesh", {
		"--unit-scale": { key="unit_scale", type=TYPE_FLOAT, help="--bake-voxel-material: metres per mesh unit (default: 1)" } })
	api.add_rpc_method("bake_voxel_material", bake_rpc)

## material_maker --bake-voxel-material --mesh <mesh> [options] <files>
## Writes <graph>_<mesh>_basecolor, _orm, _normal_object, _emission and
## _opacity (.png or .exr) in the output directory
func bake_mode(cli : Node, files : Array, options : Dictionary) -> void:
	if not options.has("mesh"):
		cli.show_error("ERROR: --bake-voxel-material requires --mesh <mesh.obj|glb>")
		cli.get_tree().quit(1)
		return
	var format : String = options.get("format", "png")
	if not format in VoxelMeshBake.FORMATS:
		cli.show_error("ERROR: --bake-voxel-material: unknown format %s (formats: %s)" % [ format, ", ".join(VoxelMeshBake.FORMATS) ])
		cli.get_tree().quit(1)
		return
	# (the default size of the command line is 2048, this mode's is 1024)
	var size : int = options.get("size", 1024) if "--size" in OS.get_cmdline_user_args() else VoxelMeshBake.DEFAULT_SIZE
	if size <= 0:
		cli.show_error("ERROR: --bake-voxel-material: incorrect size %d" % size)
		cli.get_tree().quit(1)
		return
	var mesh : Mesh = options.mesh_resource if options.has("mesh_resource") else MMMeshLoader.load_mesh(options.mesh)
	if mesh == null:
		cli.show_error("ERROR: cannot load the mesh %s" % options.mesh)
		cli.get_tree().quit(1)
		return
	await cli.process_graph_files(cli.expand_files(files), options, func(suffix : String, gen : MMGenBase, f : String, variation_options : Dictionary):
		var prefix : String = variation_options.output_dir.path_join("%s_%s%s" % [ f.get_file().get_basename(), options.mesh.get_file().get_basename(), suffix ])
		var result : Dictionary = await VoxelMeshBake.bake(gen, mesh, size, prefix, variation_options.get("unit_scale", 1.0), format)
		if result.has("error"):
			cli.show_error("ERROR: %s: %s" % [ f.get_file(), result.error ])
			return
		for file_name in result.files:
			print("Exported %s" % file_name))

## RPC: { mesh, prefix, size?, unit_scale?, format? } -> the files written
## (<prefix>_basecolor.png, _orm, _normal_object, _emission and _opacity)
func bake_rpc(params : Dictionary, rpc : Node):
	if not rpc.require(params, [ "mesh", "prefix" ]):
		return null
	var format : String = params.get("format", "png")
	if not format in VoxelMeshBake.FORMATS:
		return rpc.fail("unknown format '%s'" % format)
	var mesh : Mesh = MMMeshLoader.load_mesh(params.mesh) if FileAccess.file_exists(params.mesh) else null
	if mesh == null:
		return rpc.fail("cannot load the mesh '%s'" % params.mesh)
	var graph : MMGenGraph = await rpc.get_graph()
	await MMCliTools.wait_for_renders(rpc.get_tree())
	var result : Dictionary = await VoxelMeshBake.bake(graph, mesh, int(params.get("size", VoxelMeshBake.DEFAULT_SIZE)), params.prefix, float(params.get("unit_scale", 1.0)), format)
	if result.has("error"):
		return rpc.fail(result.error)
	return result.files
