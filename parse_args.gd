extends Node

func show_error(message : String):
	print(message)

static func name_to_lower(s : String) -> String:
	s = s.strip_edges()
	s = s.to_lower()
	s = s.replace(" ", "_")
	s = s.remove_chars("()/\"")
	return s

func export_files(files, output_dir, target, target_file, image_size, options : Dictionary = {}) -> void:
	var website_materials : Array = []
	# An Array (and not a PackedStringArray) so export_variation can append to it
	var export_list : Array = []
	for f : String in files:
		var basename : String = f.get_file().get_basename()
		var mat_name : String = f.get_file().get_basename()
		var mat_author : String = "unknown"
		var gen = await mm_loader.load_gen(f)
		var from_website : bool = false
		if gen == null and f.begins_with("website:"):
			var asset_index = f.right(-8).to_int()
			basename = "website_"+str(asset_index)
			var http_request : HTTPRequest = HTTPRequest.new()
			add_child(http_request)
			var error : Error
			var data : String
			var json : JSON
			if website_materials.is_empty():
				error = http_request.request(MMPaths.WEBSITE_ADDRESS+"/api/getMaterials")
				if error == OK:
					data = ( await http_request.request_completed )[3].get_string_from_utf8()
					json = JSON.new()
					if json.parse(data) == OK and json.get_data() is Array:
						website_materials = json.get_data()
			for m in website_materials:
				if int(m.id) == asset_index:
					mat_name = m.name
					mat_author = m.author
					break
			error = http_request.request(MMPaths.WEBSITE_ADDRESS+"/api/getMaterial?id="+str(asset_index))
			if error != OK:
				continue
			data = ( await http_request.request_completed )[3].get_string_from_utf8()
			json = JSON.new()
			if json.parse(data) != OK or ! json.data is Dictionary:
				continue
			var parse_result : Dictionary = json.data
			if json.parse(parse_result.json) == OK and json.data is Dictionary:
				gen = await mm_loader.create_gen(json.data)
			else:
				print("Failed to download asset ", asset_index)
				continue
			from_website = true
		if gen != null:
			add_child(gen)
			for e in MMCliTools.apply_overrides(gen, options.get("set", [])):
				show_error("ERROR: %s: %s" % [ f.get_file(), e ])
			await for_each_variation(gen, options, export_variation.bind(gen, f, basename, mat_name, mat_author, output_dir, target, target_file, image_size, from_website, export_list))
			print("Done")
			gen.queue_free()
	if not export_list.is_empty():
		print(",\n".join(PackedStringArray(export_list)))
	get_tree().quit()

func export_variation(suffix : String, gen : MMGenBase, f : String, basename : String, mat_name : String, mat_author : String, output_dir : String, target : String, target_file : String, image_size : int, from_website : bool, export_list : Array) -> void:
	var mat_name_lower = name_to_lower(mat_name)
	var mat_author_lower = name_to_lower(mat_author)
	var gen_stack : Array[MMGenBase] = [gen]
	while gen_stack.size():
		var c : MMGenBase = gen_stack.pop_back()
		gen_stack.append_array(c.get_children())
		if c.has_method("export_material"):
			var best_target : String = target
			if c.has_method("get_export_profiles"):
				if c.get_export_profiles().find(target) == -1:
					var best_similarity : float = 0.0
					for p : String in c.get_export_profiles():
						var similarity : float = p.similarity(target)
						if similarity > best_similarity:
							best_similarity = similarity
							best_target = p
					if best_target == "":
						continue
					print("Using target ", best_target, " (and not ", target, ")")
			var target_file_name : String = target_file
			target_file_name = target_file_name.replace("%f", basename+suffix)
			target_file_name = target_file_name.replace("%N", mat_name)
			target_file_name = target_file_name.replace("%A", mat_author)
			target_file_name = target_file_name.replace("%n", mat_name_lower)
			target_file_name = target_file_name.replace("%a", mat_author_lower)
			var prefix : String = output_dir.path_join(target_file_name)
			if c.has_method("get_export_profiles"):
				print("Exporting Material %s to %s..." % [f.get_file(), prefix])
			else:
				var file_name : String = c.interpret_file_name(c.parameters.suffix, prefix.get_base_dir())
				print("Saving additional export %s" % file_name)
			await c.export_material(prefix, best_target, image_size, true)
			if from_website:
				export_list.append("\""+prefix.get_file()+"\": \""+mat_name+","+mat_author+"\"")

const CLI_MODES : Array[String] = [ "--export", "--export-material", "--render", "--bake", "--list-parameters", "--export-mmr", "--rpc", "--help" ]

const HELP : String = """Material Maker command line

  material_maker --export-material [options] <files>   export materials for an engine
  material_maker --render --node <node[:output]> [options] <files>   render a node output
  material_maker --bake [--maps <map,...>] [--high <mesh>] [options] <meshes>   bake mesh maps
  material_maker --list-parameters <files>   list the parameters that can be set
  material_maker --export-mmr [options] <files>   export runtime packages (.mmr)
  material_maker --rpc [--rpc-port <port>]   run a JSON-RPC server without user interface
  material_maker --rpc-port <port>   start the user interface with a JSON-RPC server
  material_maker -- --help   show this help

Options:
  --target <target>          export target (e.g. "Godot/Godot 4 Standard", "MaterialX/Standard Surface")
  -o, --output-dir <dir>     output directory (created if needed)
  --output-file <pattern>    output file name pattern (%f: file name, %n/%N: material name, %a/%A: author)
  --size <size>              image size in pixels
  --set <name>=<value>       set a parameter before rendering (repeatable); name is a remote parameter's
                             name or label, or node/path:parameter
  --seed <n>                 change the seeds of all nodes that are not locked
  --variations <n>           render n variations with different seeds (files are suffixed with _v<i>)
  --format <png|exr>         image format of --render
  --frames <n>               --render renders n animation frames ($time from 0 to the duration) in a sprite sheet
  --duration <seconds>       duration of the animation of --frames (default: 1)
  --columns <n>              columns of the sprite sheet of --frames (default: square sheet)
  --maps <map,...>           maps of --bake (default: ambient_occlusion,curvature,thickness,normal,position,
                             or normal_tangent,height with --high)
  --high <mesh>              high poly mesh for --bake, that adds the normal_tangent, normal_object, height,
                             color, material_id and position maps
  --front <d>, --rear <d>    ray distances in front of and behind the mesh for --high, relative to the
                             diagonal of its bounding box (default: 0.01)
  --cage <mesh>              cage mesh for --high, with the same topology as the baked mesh
  --samples <n>              antialiasing samples for --high (default: 4)
  --show-window              do not minimize the window
  --rpc-port <port>          port of the JSON-RPC server (localhost only, default 7680)
"""

func _ready():
	RenderingServer.set_default_clear_color(Color.BLACK)
	# Arguments after "--" are also accepted (Godot handles --help itself)
	var args : PackedStringArray = OS.get_cmdline_args()+OS.get_cmdline_user_args()
	var mode : String = ""
	for m in CLI_MODES:
		if m in args:
			mode = m
			break
	if mode == "":
		var no_logo : bool = ( args.find("--no-splash") != -1 )
		var scene : PackedScene
		if no_logo:
			scene = load("res://material_maker/main_window.tscn")
		else:
			scene = load("res://splash_screen/splash_screen.tscn")
		var rpc_port : int = args.find("--rpc-port")
		if rpc_port != -1 and rpc_port+1 < args.size():
			start_rpc_server(int(args[rpc_port+1]))
		await get_tree().process_frame
		get_tree().change_scene_to_packed(scene)
		return
	if mode == "--help":
		print(HELP)
		get_tree().quit()
		return
	# Rendering needs a window (the GPU is not available in headless mode),
	# but it does not need to be visible
	if not "--show-window" in args:
		get_window().mode = Window.MODE_MINIMIZED
	var dir : DirAccess = DirAccess.open(".")
	print("Current dir: ", dir.get_current_dir())
	var options : Dictionary = {
		target="Godot/Godot 4 Standard", output_dir=dir.get_current_dir(), output_file="%f",
		size=2048, set=[], variations=1, format="png", node="", maps=MMCliTools.DEFAULT_BAKE_MAPS
	}
	var files : Array[String] = []
	var i = 0
	while i < args.size():
		var arg : String = args[i]
		var value : String = args[i+1] if i+1 < args.size() else ""
		match arg:
			# -t is also Godot's --always-on-top, so it only works after "--"
			"-t", "--target":
				options.target = value
				i += 1
			"-o", "--output-dir":
				options.output_dir = value
				i += 1
			"--output-file":
				options.output_file = value
				i += 1
			"--size":
				options.size = int(value)
				if options.size <= 0:
					show_error("ERROR: incorrect size "+value)
					get_tree().quit(1)
					return
				i += 1
			"--set":
				options.set.append(value)
				i += 1
			"--seed":
				options.seed = int(value)
				i += 1
			"--variations":
				options.variations = max(1, int(value))
				i += 1
			"--format":
				options.format = value
				i += 1
			"--node":
				options.node = value
				i += 1
			"--high", "--cage":
				options[arg.substr(2)] = value
				i += 1
			"--front", "--rear":
				options[arg.substr(2)] = float(value)
				i += 1
			"--samples":
				options.samples = max(1, int(value))
				i += 1
			"--frames":
				options.frames = max(1, int(value))
				i += 1
			"--duration":
				options.duration = float(value)
				i += 1
			"--columns":
				options.columns = int(value)
				i += 1
			"--maps":
				options.maps = Array(value.split(",", false))
				i += 1
			"--show-window":
				pass
			"--rpc-port":
				options.rpc_port = int(value)
				i += 1
			_:
				if not arg in CLI_MODES:
					files.push_back(arg)
		i += 1
	if ! dir.dir_exists(options.output_dir):
		dir.make_dir_recursive(options.output_dir)
	print("Output dir: ", options.output_dir)
	match mode:
		"--export", "--export-material":
			print("Exporting...")
			await export_files(expand_files(files), options.output_dir, options.target, options.output_file, options.size, options)
		"--render":
			await render_files(expand_files(files), options)
		"--bake":
			await bake_files(files, options)
		"--list-parameters":
			await list_parameters(expand_files(files))
		"--export-mmr":
			await export_mmr_files(expand_files(files), options)
		"--rpc":
			if start_rpc_server(options.get("rpc_port", MMRpcServer.DEFAULT_PORT)) != OK:
				get_tree().quit(1)
			elif not files.is_empty():
				await get_tree().process_frame
				await rpc_server.api_load({ path=files[0] })

var rpc_server : MMRpcServer = null

## Starts the JSON-RPC server, as a child of the root so it survives scene changes
func start_rpc_server(port : int) -> Error:
	rpc_server = MMRpcServer.new()
	rpc_server.name = "RpcServer"
	get_tree().root.add_child.call_deferred(rpc_server)
	return rpc_server.start(port)

func expand_files(files : Array[String]) -> Array:
	var expanded_files = []
	for f : String in files:
		var basedir : String = f.get_base_dir()
		if basedir == "":
			basedir = "."
		var basename : String = f.get_file()
		if basename.find("*") != -1:
			basename = basename.replace("*", ".*")
			var dir : DirAccess = DirAccess.open(basedir)
			if dir != null:
				var regex : RegEx = RegEx.new()
				regex.compile("^"+basename+"$")
				dir.list_dir_begin() # TODOGODOT4 fill missing arguments https://github.com/godotengine/godot/pull/40547
				var file_name = dir.get_next()
				while file_name != "":
					if regex.search(file_name) and file_name.get_extension() == "ptex":
						expanded_files.push_back(basedir+"/"+file_name)
					file_name = dir.get_next()
		elif f.begins_with("website:"):
			for m : String in f.right(-8).split(","):
				var index_range : PackedStringArray = m.split("-")
				match index_range.size():
					1:
						if m.is_valid_int():
							expanded_files.push_back("website:"+m)
					2:
						if index_range[0].is_valid_int() and index_range[1].is_valid_int():
							for mi in range(index_range[0].to_int(), index_range[1].to_int()+1):
								expanded_files.push_back("website:"+str(mi))
		else:
			expanded_files.push_back(f)
	return expanded_files

## Loads a graph, adds it to the tree and applies parameter overrides
func load_graph(f : String, options : Dictionary) -> MMGenBase:
	var gen = await mm_loader.load_gen(f)
	if gen == null:
		show_error("ERROR: cannot load %s" % f)
		return null
	add_child(gen)
	for e in MMCliTools.apply_overrides(gen, options.get("set", [])):
		show_error("ERROR: %s: %s" % [ f.get_file(), e ])
	return gen

## Calls callable once per variation, after changing the seeds, with the
## suffix of the variation's files
func for_each_variation(gen : MMGenBase, options : Dictionary, callable : Callable) -> void:
	var variations : int = options.get("variations", 1)
	for v in variations:
		# Seeds are offset relatively to the previous variation
		if v == 0 and options.has("seed"):
			MMCliTools.reseed(gen, options.seed)
		elif v > 0:
			MMCliTools.reseed(gen, 1)
		await callable.call("_v%d" % v if variations > 1 else "")

func render_variation(suffix : String, gen : MMGenBase, f : String, options : Dictionary) -> void:
	await MMCliTools.wait_for_renders(get_tree())
	var node_name : String = options.node.replace("/", "_").replace(":", "_")
	var file_name : String = options.output_dir.path_join("%s_%s%s.%s" % [ f.get_file().get_basename(), node_name, suffix, options.format ])
	var error : String
	if options.get("frames", 1) > 1:
		error = await MMCliTools.render_flipbook(gen, options.node, options.size, options.frames, options.get("duration", 1.0), options.get("columns", 0), file_name)
	else:
		error = await MMCliTools.render_node(gen, options.node, options.size, file_name)
	if error != "":
		show_error("ERROR: %s: %s" % [ f.get_file(), error ])
	else:
		print("Rendered %s" % file_name)

func render_files(files : Array, options : Dictionary) -> void:
	if options.node == "":
		show_error("ERROR: --render requires --node <node[:output]>")
		get_tree().quit(1)
		return
	for f : String in files:
		var gen : MMGenBase = await load_graph(f, options)
		if gen == null:
			continue
		await for_each_variation(gen, options, render_variation.bind(gen, f, options))
		gen.queue_free()
	print("Done")
	get_tree().quit()

func bake_files(files : Array[String], options : Dictionary) -> void:
	if options.has("high") and options.maps == MMCliTools.DEFAULT_BAKE_MAPS:
		options.maps = MMCliTools.DEFAULT_HIGH_POLY_MAPS
	for f in files:
		var prefix : String = options.output_dir.path_join(f.get_file().get_basename())
		for e in await MMCliTools.bake(f, options.maps, options.size, prefix, options):
			show_error("ERROR: %s: %s" % [ f.get_file(), e ])
	print("Done")
	get_tree().quit()

func export_mmr_variation(suffix : String, gen : MMGenBase, f : String, options : Dictionary) -> void:
	await MMCliTools.wait_for_renders(get_tree())
	var file_name : String = options.output_dir.path_join(f.get_file().get_basename()+suffix+".mmr")
	# The material's size is used unless --size is given
	var size : int = options.size if "--size" in OS.get_cmdline_args()+OS.get_cmdline_user_args() else 0
	for e in await MMRuntimeExporter.export_package(gen, file_name, size):
		show_error("ERROR: %s: %s" % [ f.get_file(), e ])
	print("Exported %s" % file_name)

func export_mmr_files(files : Array, options : Dictionary) -> void:
	for f : String in files:
		var gen : MMGenBase = await load_graph(f, options)
		if gen == null:
			continue
		await for_each_variation(gen, options, export_mmr_variation.bind(gen, f, options))
		gen.queue_free()
	print("Done")
	get_tree().quit()

func list_parameters(files : Array) -> void:
	for f : String in files:
		var gen : MMGenBase = await load_graph(f, {})
		if gen == null:
			continue
		print("Parameters of %s:" % f)
		for l in MMCliTools.list_parameters(gen):
			print("  "+l)
		gen.queue_free()
	get_tree().quit()
