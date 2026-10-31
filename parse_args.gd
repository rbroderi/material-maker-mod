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
			apply_graph_options(gen, f, options)
			await for_each_variation(gen, options, export_variation.bind(gen, f, basename, mat_name, mat_author, output_dir, target, target_file, image_size, from_website, export_list))
			print("Done")
			gen.queue_free()
	if not export_list.is_empty():
		print(",\n".join(PackedStringArray(export_list)))
	get_tree().quit()

## Exports the materials of a graph (called for each variation, with the
## suffix of its files)
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
			if suffix != "" and not target_file_name.contains("%f"):
				# Variations must not overwrite each other
				target_file_name += suffix
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

const CLI_MODES : Array[String] = [ "--export", "--export-material", "--render", "--bake", "--list-parameters", "--help" ]

## Options that set a value: option -> { key, type (TYPE_BOOL for flags),
## minimum }
const VALUE_OPTIONS : Dictionary = {
	# -t is also Godot's --always-on-top, so it only works after "--"
	"-t": { key="target", type=TYPE_STRING }, "--target": { key="target", type=TYPE_STRING },
	"-o": { key="output_dir", type=TYPE_STRING }, "--output-dir": { key="output_dir", type=TYPE_STRING },
	"--output-file": { key="output_file", type=TYPE_STRING },
	"--seed": { key="seed", type=TYPE_INT },
	"--variations": { key="variations", type=TYPE_INT, minimum=1 },
	"--format": { key="format", type=TYPE_STRING },
	"--node": { key="node", type=TYPE_STRING },
	"--show-window": { key="show_window", type=TYPE_BOOL },
}

## Image formats of --render
const RENDER_FORMATS : Array[String] = [ "png", "exr", "jpg", "webp" ]

const HELP : String = """Material Maker command line

  material_maker --export-material [options] <files>   export materials for an engine
  material_maker --render --node <node[:output]> [options] <files>   render a node output
  material_maker --bake [--maps <map,...>] [options] <meshes>   bake mesh maps
  material_maker --list-parameters <files>   list the parameters that can be set
  material_maker -- --help   show this help

Options (they can also be given after "--"):
  --target <target>          export target (e.g. "Godot/Godot 4 Standard", "Unity/HDRP")
  -o, --output-dir <dir>     output directory (created if needed)
  --output-file <pattern>    output file name pattern (%f: file name, %n/%N: material name, %a/%A: author)
  --size <size>              image size in pixels (default: 2048; with --export-material, 0 uses
                             the Material node's size)
  --set <name>=<value>       set a parameter before rendering (repeatable); name is a remote parameter's
                             name or label, or node/path:parameter
  --seed <n>                 change the seeds of all nodes that are not locked
  --variations <n>           render n variations with different seeds (files are suffixed with _v<i>)
  --node <node[:output]>     node output of --render (outputs are numbered from 0)
  --format <format>          image format of --render (png, exr, jpg or webp)
  --maps <map,...>           maps of --bake (default: ambient_occlusion,curvature,thickness,normal,position)
  --show-window              do not minimize the window
"""

func _ready():
	RenderingServer.set_default_clear_color(Color.BLACK)
	# Arguments after "--" are also accepted (Godot handles some options,
	# such as --help and -t, itself)
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
		await get_tree().process_frame
		get_tree().change_scene_to_packed(scene)
		return
	if mode == "--help":
		print(HELP)
		get_tree().quit()
		return
	var options : Dictionary = parse_options(args)
	if options.is_empty():
		get_tree().quit(1)
		return
	# Rendering needs a window (the GPU is not available in headless mode),
	# but it does not need to be visible
	if DisplayServer.get_name() != "headless" and not options.get("show_window", false):
		get_window().mode = Window.MODE_MINIMIZED
	var dir : DirAccess = DirAccess.open(".")
	print("Current dir: ", dir.get_current_dir())
	if options.output_dir == "":
		options.output_dir = dir.get_current_dir()
	if ! dir.dir_exists(options.output_dir):
		dir.make_dir_recursive(options.output_dir)
	print("Output dir: ", options.output_dir)
	var files : Array[String] = options.files
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

## Parses the options of the command line modes, and returns them with the
## list of input files (options.files), or an empty dictionary (after
## showing an error) if they are not valid
func parse_options(args : PackedStringArray) -> Dictionary:
	var options : Dictionary = {
		target="Godot/Godot 4 Standard", output_dir="", output_file="%f",
		size=2048, set=[], variations=1, format="png", node="", maps=MMCliTools.DEFAULT_BAKE_MAPS
	}
	var files : Array[String] = []
	var i = 0
	while i < args.size():
		var arg : String = args[i]
		# The next argument is not a value if it is another option (so
		# "--node --size 256" is an error, and does not render a node named
		# "--size"). Values starting with a single "-" (e.g. "--seed -5") are
		# accepted, except -t and -o.
		var has_value : bool = i+1 < args.size() and not is_option(args[i+1])
		var value : String = args[i+1] if has_value else ""
		var option : Dictionary = VALUE_OPTIONS.get(arg, {})
		if not option.is_empty():
			if option.type == TYPE_BOOL:
				options[option.key] = true
			else:
				if not has_value:
					show_error("ERROR: missing value for %s" % arg)
					return {}
				if (option.type == TYPE_INT and not value.is_valid_int()) or (option.type == TYPE_FLOAT and not value.is_valid_float()):
					show_error("ERROR: incorrect value for %s: %s" % [ arg, value ])
					return {}
				var converted = type_convert(value, option.type)
				options[option.key] = max(option.minimum, converted) if option.has("minimum") else converted
				i += 1
			i += 1
			continue
		match arg:
			"--size", "--set", "--maps":
				if not has_value:
					show_error("ERROR: missing value for %s" % arg)
					return {}
				match arg:
					"--size":
						options.size = int(value)
						if not value.is_valid_int() or options.size < 0:
							show_error("ERROR: incorrect size "+value)
							return {}
					"--set":
						options.set.append(value)
					"--maps":
						options.maps = Array(value.split(",", false))
				i += 1
			_:
				if arg in CLI_MODES:
					pass
				elif arg.begins_with("-") and arg.length() > 1:
					show_error("ERROR: unknown option %s (see material_maker -- --help)" % arg)
					return {}
				else:
					files.push_back(arg)
		i += 1
	options.files = files
	return options

## True if arg is an option (and not the value of the previous option)
static func is_option(arg : String) -> bool:
	return arg.begins_with("--") or VALUE_OPTIONS.has(arg)

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
	apply_graph_options(gen, f, options)
	return gen

## Applies --set values
func apply_graph_options(gen : MMGenBase, f : String, options : Dictionary) -> void:
	for e in MMCliTools.apply_overrides(gen, options.get("set", [])):
		show_error("ERROR: %s: %s" % [ f.get_file(), e ])

## Loads each graph and calls variation (suffix, gen, f, options) for each of
## its variations, then quits. mode is the option named in the error message
## when --node is required (empty when it is not).
func process_graph_files(files : Array, options : Dictionary, variation : Callable, mode : String = "") -> void:
	if mode != "" and options.node == "":
		show_error("ERROR: %s requires --node <node[:output]>" % mode)
		get_tree().quit(1)
		return
	for f : String in files:
		var gen : MMGenBase = await load_graph(f, options)
		if gen == null:
			continue
		await for_each_variation(gen, options, variation.bind(gen, f, options))
		gen.queue_free()
	print("Done")
	get_tree().quit()

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
	var file_name : String = options.output_dir.path_join("%s_%s%s.%s" % [ f.get_file().get_basename(), MMCliTools.spec_to_file_part(options.node), suffix, options.format ])
	var error : String = await MMCliTools.render_node(gen, options.node, options.size, file_name)
	if error != "":
		show_error("ERROR: %s: %s" % [ f.get_file(), error ])
	else:
		print("Rendered %s" % file_name)

func render_files(files : Array, options : Dictionary) -> void:
	if not options.format in RENDER_FORMATS:
		show_error("ERROR: unknown image format %s (formats: %s)" % [ options.format, ", ".join(RENDER_FORMATS) ])
		get_tree().quit(1)
		return
	if options.size == 0:
		show_error("ERROR: incorrect size 0")
		get_tree().quit(1)
		return
	await process_graph_files(files, options, render_variation, "--render")

func bake_files(files : Array[String], options : Dictionary) -> void:
	if options.size == 0:
		show_error("ERROR: incorrect size 0")
		get_tree().quit(1)
		return
	for f in files:
		var prefix : String = options.output_dir.path_join(f.get_file().get_basename())
		for e in await MMCliTools.bake(f, options.maps, options.size, prefix):
			show_error("ERROR: %s: %s" % [ f.get_file(), e ])
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
