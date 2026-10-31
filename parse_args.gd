extends Node

func show_error(message : String):
	print(message)

static func name_to_lower(s : String) -> String:
	s = s.strip_edges()
	s = s.to_lower()
	s = s.replace(" ", "_")
	s = s.remove_chars("()/\"")
	return s

## Height of non-square outputs (--size widthxheight), or 0
var output_height : int = 0
## Options of --export-material
var export_options : Dictionary = {}
## Exit code of modes that process several graphs (2 when a graph's
## requirements are not met, 1 when a graph is skipped because of another
## error, such as an unknown --preset)
var exit_code : int = 0

## UDIM tiles exported by --export-material (--udim-tiles, or --udim for the
## graph's tiles)
static func get_udim_tiles(material : MMGenMaterial, options : Dictionary) -> PackedInt32Array:
	if options.has("tiles"):
		return options.tiles
	if options.has("udim_tiles"):
		return MMCliTools.parse_udim_tiles(options.udim_tiles)
	if options.get("udim", false):
		return material.get_graph_udim_tiles()
	return PackedInt32Array()

func export_files(files, output_dir, target, target_file, image_size, options : Dictionary = {}) -> void:
	export_options = options
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
		if gen != null and not check_requirements(gen, f, options):
			gen.free()
			get_tree().quit(2)
			return
		if gen != null:
			add_child(gen)
			if not await apply_graph_options(gen, f, options):
				gen.queue_free()
				continue
			await for_each_variation(gen, options, export_variation.bind(gen, f, basename, mat_name, mat_author, output_dir, target, target_file, image_size, from_website, export_list))
			print("Done")
			gen.queue_free()
	if not export_list.is_empty():
		print(",\n".join(PackedStringArray(export_list)))
	print("Peak GPU texture memory: %d MB" % (mm_renderer.peak_texture_memory >> 20))
	print("Shaders: %d compiled, %d from the cache" % [ MMPipeline.shader_cache_misses, MMPipeline.shader_cache_hits ])
	get_tree().quit(exit_code)

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
			if c is MMGenMaterial:
				var tiles : PackedInt32Array = get_udim_tiles(c, export_options)
				if export_options.has("udim_tiles") and tiles.is_empty():
					show_error("ERROR: invalid --udim-tiles %s" % export_options.udim_tiles)
				# Without --size, the Material's size (and aspect ratio) is used.
				# Buffers sized relatively to the Material follow --size (see
				# MMGenMaterial.export_size_override)
				var material_size : int = 0
				if export_options.get("size_given", false):
					material_size = image_size
				await c.export_material(prefix, best_target, material_size, true, output_height, tiles)
			else:
				await c.export_material(prefix, best_target, image_size, true, output_height)
			if from_website:
				export_list.append("\""+prefix.get_file()+"\": \""+mat_name+","+mat_author+"\"")

# Plugins add other modes (see MMPlugins.API.add_cli_mode), e.g. --export-volume
# and --export-mmr
const CLI_MODES : Array[String] = [ "--export", "--export-material", "--render", "--bake", "--list-parameters", "--rpc", "--plugin", "--help" ]

## Options that set a value: option -> { key, type (TYPE_BOOL for flags),
## minimum } (plugin modes add theirs, see MMPlugins.API.add_cli_mode)
const VALUE_OPTIONS : Dictionary = {
	# -t is also Godot's --always-on-top, so it only works after "--"
	"-t": { key="target", type=TYPE_STRING }, "--target": { key="target", type=TYPE_STRING },
	"-o": { key="output_dir", type=TYPE_STRING }, "--output-dir": { key="output_dir", type=TYPE_STRING },
	"--output-file": { key="output_file", type=TYPE_STRING },
	"--seed": { key="seed", type=TYPE_INT },
	"--variations": { key="variations", type=TYPE_INT, minimum=1 },
	"--format": { key="format", type=TYPE_STRING },
	"--node": { key="node", type=TYPE_STRING },
	"--preset": { key="preset", type=TYPE_STRING },
	"--high": { key="high", type=TYPE_STRING },
	"--cage": { key="cage", type=TYPE_STRING },
	"--skew": { key="skew", type=TYPE_STRING },
	"--high-texture": { key="high_texture", type=TYPE_STRING },
	"--match-names": { key="match_names", type=TYPE_BOOL },
	"--udim": { key="udim", type=TYPE_BOOL },
	"--udim-tiles": { key="udim_tiles", type=TYPE_STRING },
	"--mesh": { key="mesh", type=TYPE_STRING },
	"--software-raytracing": { key="software_raytracing", type=TYPE_BOOL },
	"--front": { key="front", type=TYPE_FLOAT },
	"--rear": { key="rear", type=TYPE_FLOAT },
	"--samples": { key="samples", type=TYPE_INT, minimum=1 },
	"--frames": { key="frames", type=TYPE_INT },
	"--duration": { key="duration", type=TYPE_FLOAT },
	"--columns": { key="columns", type=TYPE_INT },
	"--separate-frames": { key="separate_frames", type=TYPE_BOOL },
	"--rpc-port": { key="rpc_port", type=TYPE_INT },
	"--gpu-budget": { key="gpu_budget", type=TYPE_FLOAT, minimum=0.0 },
	"--low-memory": { key="low_memory", type=TYPE_BOOL },
	"--strict": { key="strict", type=TYPE_BOOL },
}

## Image formats of --render (plugins add others)
const RENDER_FORMATS : Array[String] = [ "png", "exr", "jpg", "webp" ]

const HELP : String = """Material Maker command line

  material_maker --export-material [options] <files>   export materials for an engine
  material_maker --render --node <node[:output]> [options] <files>   render a node output
  material_maker --bake [--maps <map,...>] [--high <mesh>] [options] <meshes>   bake mesh maps
  material_maker --list-parameters <files>   list the parameters that can be set
  material_maker --plugin <command> [arguments]   run a command of a plugin
  material_maker --rpc [--rpc-port <port>]   run a JSON-RPC server without user interface
  material_maker --rpc-port <port>   start the user interface with a JSON-RPC server
  material_maker -- --help   show this help

Options (they can also be given after "--"):
  --target <target>          export target (e.g. "Godot/Godot 4 Standard", "MaterialX/Standard Surface")
  -o, --output-dir <dir>     output directory (created if needed)
  --output-file <pattern>    output file name pattern (%f: file name, %n/%N: material name, %a/%A: author)
  --size <size>              image size in pixels, or <width>x<height> for non-square outputs of --render,
                             --export-material and plugin modes (buffers stay square). --export-material
                             uses the Material node's size by default (or with --size 0), and buffers
                             sized relative to the output follow --size (rounded to a power of 2)
  --preset <name>            apply a preset of the graph's parameters (before --set)
  --set <name>=<value>       set a parameter before rendering (repeatable); name is a remote parameter's
                             name or label, or node/path:parameter
  --seed <n>                 change the seeds of all nodes that are not locked
  --variations <n>           render n variations with different seeds (files are suffixed with _v<i>)
  --format <format>          image format of --render (png, exr, jpg or webp), or the format of plugin modes
  --color-space <space>      OCIO color space of exported color maps (albedo, emission), e.g. ACEScg
  --frames <n>               --render renders n animation frames ($time from 0 to the duration) in a sprite sheet
  --duration <seconds>       duration of the animation of --frames (default: 1)
  --columns <n>              columns of the sprite sheet of --frames (default: square sheet)
  --separate-frames          --frames writes one file per frame (suffixed with _<frame>) instead of a sprite sheet
  --maps <map,...>           maps of --bake (default: ambient_occlusion,curvature,thickness,normal,position,
                             or normal_tangent,height with --high)
  --high <mesh>              high poly mesh for --bake, that adds the normal_tangent, normal_object, height,
                             color, material_id, position and texture (with --high-texture) maps
  --front <d>, --rear <d>    ray distances in front of and behind the mesh for --high, relative to the
                             diagonal of its bounding box (default: 0.01)
  --cage <mesh>              cage mesh for --high, with the same topology as the baked mesh
  --samples <n>              antialiasing samples for --high (default: 4)
  --match-names              with --high, rays from each part (object) of a mesh only hit the high poly part
                             with the same name (ignoring _low/_high suffixes)
  --skew <image>             skew map for --high: white bends rays towards the face normal
  --high-texture <image>     texture of the high poly mesh, for the "texture" map of --high
  --udim                     bake each UDIM tile of the mesh's UVs to <mesh>_<map>.<tile>.png, or with
                             --export-material, export each UDIM tile of the graph (of its Mesh Map and
                             High Poly Bake nodes' mesh and its Image nodes' tile files) to <name>.<tile>.png
  --udim-tiles <list>        UDIM tiles of --bake and --export-material (e.g. 1001-1004,1011)
  --mesh <mesh>              mesh of the graph's Mesh Map and High Poly Bake nodes (as the 3D preview's
                             custom mesh), for --export-material and --render
  --software-raytracing      bake --high maps with the software ray caster (by default, hardware
                             ray tracing is used when the GPU supports it)
  --show-window              do not minimize the window
  --rpc-port <port>          port of the JSON-RPC server (localhost only, default 7680)
  --gpu-budget <MB>          GPU memory budget: the least recently used textures are moved to RAM above it
  --strict                   fail when a graph has nodes of unknown types (by default they are kept
                             as magenta placeholders). Graphs that need missing plugins or a newer
                             version (their "requires") always fail.
  --low-memory               free each buffer's texture when all the buffers that read it are rendered
                             (render again when needed): large graphs need much less memory
"""

func _ready():
	RenderingServer.set_default_clear_color(Color.BLACK)
	# Arguments after "--" are also accepted (Godot handles --help itself)
	var args : PackedStringArray = OS.get_cmdline_args()+OS.get_cmdline_user_args()
	if "--plugin" in args:
		# A command of a plugin, with the following arguments (that are not
		# options of Material Maker)
		await run_plugin_command(args)
		return
	var mode : String = ""
	for m in CLI_MODES:
		if m in args:
			mode = m
			break
	if mode == "":
		# Modes of enabled plugins (see MMPlugins.API.add_cli_mode)
		mode = MMPlugins.find_cli_mode(args)
	if mode == "":
		var no_logo : bool = ( args.find("--no-splash") != -1 )
		var scene : PackedScene
		if no_logo:
			scene = load("res://material_maker/main_window.tscn")
		else:
			scene = load("res://splash_screen/splash_screen.tscn")
		# The user interface with a JSON-RPC server
		var rpc_port_index : int = args.find("--rpc-port")
		if rpc_port_index != -1:
			var rpc_port : int = get_rpc_port(args[rpc_port_index+1] if rpc_port_index+1 < args.size() else "")
			if rpc_port != -1:
				start_rpc_server(rpc_port)
		await get_tree().process_frame
		get_tree().change_scene_to_packed(scene)
		return
	if mode == "--help":
		print(get_help())
		get_tree().quit()
		return
	# Godot's headless mode replaces the renderer by a dummy one. Godot builds
	# with Material Maker's headless patch (material_maker/misc/headless.patch)
	# still create local rendering devices (from a Vulkan context without
	# surface); with stock Godot, rendering needs a window, that is minimized
	# (1x1 and transparent, see project.godot: Godot does not allow hiding
	# its main window), so Material Maker runs again without --headless.
	var headless : bool = DisplayServer.get_name() == "headless"
	if headless and mode != "--list-parameters":
		var rd : RenderingDevice = RenderingServer.create_local_rendering_device()
		if rd == null:
			get_tree().quit(run_with_hidden_window())
			return
		rd.free()
	if OS.has_environment(RUN_AGAIN_VARIABLE):
		quit_with_parent_process()
	if not headless and not "--show-window" in args:
		get_window().mode = Window.MODE_MINIMIZED
	# Plugins add nodes, export targets, import formats, RPC methods, and
	# modes with their options
	MMPlugins.load_plugins()
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
		# The next argument is not a value if it is another option (so
		# "--node --size 256" is an error, and does not render a node named
		# "--size"). Values starting with a single "-" (e.g. "--seed -5") are
		# accepted, except -t and -o.
		var has_value : bool = i+1 < args.size() and not is_option(args[i+1])
		var value : String = args[i+1] if has_value else ""
		# (plugin modes add options, see MMPlugins.API.add_cli_mode)
		var option : Dictionary = VALUE_OPTIONS.get(arg, MMPlugins.cli_options.get(arg, {}))
		if not option.is_empty():
			if option.type == TYPE_BOOL:
				options[option.key] = true
			else:
				if not has_value:
					show_error("ERROR: missing value for %s" % arg)
					get_tree().quit(1)
					return
				if (option.type == TYPE_INT and not value.is_valid_int()) or (option.type == TYPE_FLOAT and not value.is_valid_float()):
					show_error("ERROR: incorrect value for %s: %s" % [ arg, value ])
					get_tree().quit(1)
					return
				var converted = type_convert(value, option.type)
				options[option.key] = max(option.minimum, converted) if option.has("minimum") else converted
				i += 1
			i += 1
			continue
		if arg in [ "--size", "--set", "--color-space", "--maps" ] and not has_value:
			show_error("ERROR: missing value for %s" % arg)
			get_tree().quit(1)
			return
		match arg:
			"--size":
				# A size, or width x height (e.g. 2048x1024) for non-square
				# outputs. 0 is the Material node's size with --export-material.
				var dimensions : PackedStringArray = value.to_lower().split("x")
				options.size = int(dimensions[0])
				options.size_given = options.size > 0
				output_height = int(dimensions[1]) if dimensions.size() == 2 else 0
				if not dimensions[0].is_valid_int() or options.size < 0 or dimensions.size() > 2 or (dimensions.size() == 2 and (options.size == 0 or not dimensions[1].is_valid_int() or output_height <= 0)):
					show_error("ERROR: incorrect size "+value)
					get_tree().quit(1)
					return
				i += 1
			"--set":
				options.set.append(value)
				i += 1
			"--color-space":
				MMColorManagement.export_space_override = value
				i += 1
			"--maps":
				options.maps = Array(value.split(",", false))
				i += 1
			"--show-window":
				pass
			_:
				if arg in CLI_MODES or MMPlugins.cli_modes.has(arg):
					pass
				elif arg.begins_with("-") and arg.length() > 1:
					show_error("ERROR: unknown option %s (see material_maker -- --help)" % arg)
					get_tree().quit(1)
					return
				else:
					files.push_back(arg)
		i += 1
	if not check_udim_options(mode, options):
		get_tree().quit(1)
		return
	if options.has("gpu_budget"):
		mm_renderer.gpu_memory_budget_override = options.gpu_budget
	if options.get("low_memory", false):
		mm_deps.release_mode = mm_deps.RELEASE_ALWAYS
	if ! dir.dir_exists(options.output_dir):
		dir.make_dir_recursive(options.output_dir)
	print("Output dir: ", options.output_dir)
	match mode:
		"--export", "--export-material":
			print("Exporting...")
			# (--size 0 uses the Material node's size, as without --size)
			await export_files(expand_files(files), options.output_dir, options.target, options.output_file, options.size if options.size > 0 else 2048, options)
		"--render":
			await render_files(expand_files(files), options)
		"--bake":
			await bake_files(files, options)
		"--list-parameters":
			await list_parameters(expand_files(files))
		"--rpc":
			await run_rpc_server(files, options)
		_:
			# A mode of a plugin, that quits (e.g. with process_graph_files)
			# or returns an exit code
			if MMPlugins.cli_modes.has(mode):
				var exit_code = await MMPlugins.cli_modes[mode].callable.call(self, files, options)
				if exit_code is int:
					get_tree().quit(exit_code)
			else:
				show_error("ERROR: the plugin of %s could not be loaded" % mode)
				get_tree().quit(1)

## Runs the command of a plugin (--plugin <command> [arguments]) and quits
## with its exit code
func run_plugin_command(args : PackedStringArray) -> void:
	# (as in the other command line modes)
	if DisplayServer.get_name() != "headless":
		get_window().mode = Window.MODE_MINIMIZED
	MMPlugins.load_plugins()
	var command_index : int = args.find("--plugin")+1
	var command : String = args[command_index] if command_index < args.size() else ""
	if not MMPlugins.commands.has(command):
		show_error("ERROR: unknown plugin command %s (commands: %s)" % [ command, ", ".join(MMPlugins.commands.keys()) ])
		get_tree().quit(1)
		return
	var command_exit_code = await MMPlugins.commands[command].call(args.slice(command_index+1))
	get_tree().quit(command_exit_code if command_exit_code is int else 0)

## The help, with the modes and options of enabled plugins
func get_help() -> String:
	MMPlugins.load_plugins()
	if MMPlugins.cli_modes.is_empty():
		return HELP
	var lines : PackedStringArray = PackedStringArray([ "Modes of plugins:", "" ])
	for m in MMPlugins.cli_modes.keys():
		lines.append("  "+MMPlugins.cli_modes[m].usage)
	if not MMPlugins.cli_options.is_empty():
		lines.append("")
		lines.append("Options of plugin modes:")
		for o in MMPlugins.cli_options.keys():
			var option : Dictionary = MMPlugins.cli_options[o]
			lines.append("  %-26s %s" % [ o if option.type == TYPE_BOOL else o+" <value>", option.get("help", "") ])
	return HELP+"\n"+"\n".join(lines)

## Set in the environment of the process started by run_with_hidden_window
const RUN_AGAIN_VARIABLE : String = "MATERIAL_MAKER_RUN_WITHOUT_HEADLESS"

const PIPE_CHUNK : int = 4096

## Runs Material Maker again without --headless (its window is minimized in
## command line modes), under xvfb-run on Linux systems without a display,
## relays its output and returns its exit code
func run_with_hidden_window() -> int:
	if OS.has_environment(RUN_AGAIN_VARIABLE):
		# This is already the process run again, still without rendering device
		printerr("ERROR: Material Maker needs a GPU, and cannot create a rendering device")
		return 1
	# Godot's own options (such as --headless and --path) are not in
	# OS.get_cmdline_args()
	var args : PackedStringArray = OS.get_cmdline_args()
	if not OS.has_feature("template"):
		args = PackedStringArray([ "--path", ProjectSettings.globalize_path("res://") ]) + args
	if OS.is_stdout_verbose():
		args.insert(0, "--verbose")
	if not OS.get_cmdline_user_args().is_empty():
		args.append("--")
		args.append_array(OS.get_cmdline_user_args())
	var command : String = OS.get_executable_path()
	var no_display : bool = OS.get_name() in [ "Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD" ] and OS.get_environment("DISPLAY") == "" and OS.get_environment("WAYLAND_DISPLAY") == ""
	if no_display:
		if OS.execute("sh", [ "-c", "command -v xvfb-run" ]) != 0:
			printerr("ERROR: Material Maker needs a GPU, which this Godot build does not provide with --headless,")
			printerr("and there is no display for a hidden window: install xvfb-run, or use a Material Maker")
			printerr("build with headless rendering (see material_maker/misc/headless.patch).")
			return 1
		# Some versions of xvfb-run default to an 8 bits screen
		args = PackedStringArray([ "-a", "-s", "-screen 0 1280x1024x24", command ]) + args
		command = "xvfb-run"
	print("This Godot build cannot render with --headless, running again with a hidden window")
	OS.set_environment(RUN_AGAIN_VARIABLE, "1")
	var process : Dictionary = OS.execute_with_pipe(command, args)
	if process.is_empty():
		printerr("ERROR: cannot run ", command)
		return 1
	var stderr_thread : Thread = Thread.new()
	stderr_thread.start(relay_pipe.bind(process.stderr, true))
	relay_pipe(process.stdio, false)
	stderr_thread.wait_to_finish()
	while OS.is_process_running(process.pid):
		OS.delay_msec(10)
	return OS.get_process_exit_code(process.pid)

## Prints the lines read from a pipe until it is closed
static func relay_pipe(pipe : FileAccess, error : bool) -> void:
	var pending : PackedByteArray = PackedByteArray()
	while true:
		var data : PackedByteArray = pipe.get_buffer(PIPE_CHUNK)
		if data.is_empty():
			break
		pending.append_array(data)
		var end : int = pending.rfind(10)
		if end != -1:
			for line in pending.slice(0, end).get_string_from_utf8().split("\n"):
				if error:
					printerr(line.trim_suffix("\r"))
				else:
					print(line.trim_suffix("\r"))
			pending = pending.slice(end+1)
	if not pending.is_empty():
		if error:
			printerr(pending.get_string_from_utf8())
		else:
			print(pending.get_string_from_utf8())

var stdin_thread : Thread = null

## In the process started by run_with_hidden_window, quits when its parent
## exits (for example when it is killed by a timeout): its standard input is
## a pipe from the parent, that is closed then
func quit_with_parent_process() -> void:
	if OS.get_stdin_type() != OS.STD_HANDLE_PIPE:
		return
	stdin_thread = Thread.new()
	stdin_thread.start(func():
		while OS.read_buffer_from_stdin(PIPE_CHUNK).size() > 0:
			pass
		(func():
			printerr("ERROR: the --headless process exited, quitting")
			get_tree().quit(1)).call_deferred())

## The port of --rpc-port, or -1 (after showing an error) if it is not valid
func get_rpc_port(value : String) -> int:
	if not value.is_valid_int() or int(value) < 1 or int(value) > 65535:
		show_error("ERROR: incorrect value for --rpc-port: %s" % value)
		return -1
	return int(value)

var rpc_server : MMRpcServer = null

## Starts the JSON-RPC server of the user interface, as a child of the root
## so it survives scene changes
func start_rpc_server(port : int) -> Error:
	rpc_server = MMRpcServer.new()
	rpc_server.name = "RpcServer"
	rpc_server.wait_for_main_window = true
	var error : Error = rpc_server.start(port)
	if error == OK:
		get_tree().root.add_child.call_deferred(rpc_server)
	else:
		rpc_server.free()
		rpc_server = null
	return error

## --rpc: runs a JSON-RPC server without user interface (until its quit
## method is called), optionally with a graph
func run_rpc_server(files : Array[String], options : Dictionary) -> void:
	var port : int = get_rpc_port(str(options.rpc_port)) if options.has("rpc_port") else MMRpcServer.DEFAULT_PORT
	if port == -1:
		get_tree().quit(1)
		return
	if files.size() > 1:
		show_error("ERROR: --rpc loads a single file")
		get_tree().quit(1)
		return
	rpc_server = MMRpcServer.new()
	rpc_server.name = "RpcServer"
	get_tree().root.add_child.call_deferred(rpc_server)
	await get_tree().process_frame
	# The graph is loaded before clients can connect
	if not files.is_empty():
		var path : String = files[0] if files[0].is_absolute_path() else DirAccess.open(".").get_current_dir().path_join(files[0])
		await rpc_server.api_load({ path=path })
		if rpc_server.method_error != "":
			show_error("ERROR: "+rpc_server.method_error)
			get_tree().quit(1)
			return
	if rpc_server.start(port) != OK:
		get_tree().quit(1)

## True if arg is an option (and not the value of the previous option)
static func is_option(arg : String) -> bool:
	return arg.begins_with("--") or VALUE_OPTIONS.has(arg) or MMPlugins.cli_options.has(arg)

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
					# (and files of formats imported by plugins)
					if regex.search(file_name) and (file_name.get_extension() == "ptex" or not MMPlugins.get_import_format(file_name).is_empty()):
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
	if not check_requirements(gen, f, options):
		gen.free()
		return null
	add_child(gen)
	if not await apply_graph_options(gen, f, options):
		gen.queue_free()
		return null
	return gen

## Whether a loaded graph has what it needs (see MMPlugins.check_requirements),
## and with --strict, no nodes of unknown types
func check_requirements(gen : MMGenBase, f : String, options : Dictionary) -> bool:
	var missing : PackedStringArray = gen.get_meta("missing_requirements", PackedStringArray())
	var ok : bool = true
	for m in missing:
		if m.begins_with("nodes of type ") and not options.get("strict", false):
			print("WARNING: %s needs %s (kept as magenta placeholders)" % [ f.get_file(), m ])
		else:
			show_error("ERROR: %s needs %s" % [ f.get_file(), m ])
			ok = false
	if not ok:
		exit_code = 2
	return ok

## Checks --udim, --udim-tiles and --mesh, and sets options.tiles (the list of
## tiles) and options.mesh_resource (the loaded mesh). Returns false (after
## showing an error) if they are not valid. Plugin modes can use them.
func check_udim_options(mode : String, options : Dictionary) -> bool:
	if options.has("udim_tiles"):
		options.tiles = MMCliTools.parse_udim_tiles(options.udim_tiles)
		if options.tiles.is_empty():
			show_error("ERROR: incorrect UDIM tiles %s (e.g. 1001-1004,1011, from 1001 to 1999)" % options.udim_tiles)
			return false
	var builtin : bool = mode in CLI_MODES
	if (options.has("udim") or options.has("udim_tiles")) and builtin and not mode in [ "--bake", "--export", "--export-material" ]:
		show_error("ERROR: --udim and --udim-tiles need --bake or --export-material")
		return false
	if options.has("mesh"):
		if builtin and not mode in [ "--export", "--export-material", "--render" ]:
			show_error("ERROR: --mesh needs --export-material or --render")
			return false
		var mesh : Mesh = MMMeshLoader.load_mesh(options.mesh) if FileAccess.file_exists(options.mesh) else null
		if mesh == null:
			show_error("ERROR: cannot load the mesh %s" % options.mesh)
			return false
		options.mesh_resource = mesh
	return true

## Applies --mesh, --preset, then --set values (so they override the
## preset's). Seeds are changed afterwards, for each variation. Returns false
## (and sets the exit code) if the graph has no such preset.
func apply_graph_options(gen : MMGenBase, f : String, options : Dictionary) -> bool:
	if options.has("mesh") and gen is MMGenGraph:
		var mesh : Mesh = options.mesh_resource if options.has("mesh_resource") else MMMeshLoader.load_mesh(options.mesh)
		if mesh == null:
			show_error("ERROR: cannot load the mesh %s" % options.mesh)
		else:
			await MMCliTools.set_graph_mesh(gen, mesh)
	if options.has("preset") and not MMCliTools.apply_preset(gen, options.preset):
		var presets : PackedStringArray = MMCliTools.get_preset_names(gen)
		show_error("ERROR: %s: no preset '%s' (presets: %s)" % [ f.get_file(), options.preset, ", ".join(presets) if not presets.is_empty() else "none" ])
		if exit_code == 0:
			exit_code = 1
		return false
	for e in MMCliTools.apply_overrides(gen, options.get("set", [])):
		show_error("ERROR: %s: %s" % [ f.get_file(), e ])
	return true

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
	get_tree().quit(exit_code)

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
	var error : String
	if options.has("frames"):
		error = await MMCliTools.render_flipbook(gen, options.node, options.size, options.frames, options.duration, options.columns, options.separate_frames, file_name)
	else:
		error = await MMCliTools.render_node(gen, options.node, options.size, file_name, output_height)
	if error != "":
		show_error("ERROR: %s: %s" % [ f.get_file(), error ])
	elif not options.get("separate_frames", false):
		print("Rendered %s" % file_name)

func render_files(files : Array, options : Dictionary) -> void:
	# (and the image formats of plugins)
	var formats : Array = RENDER_FORMATS+MMPlugins.image_formats.keys()
	if not options.format in formats:
		show_error("ERROR: unknown image format %s (formats: %s)" % [ options.format, ", ".join(formats) ])
		get_tree().quit(1)
		return
	if options.size == 0:
		show_error("ERROR: incorrect size 0")
		get_tree().quit(1)
		return
	var flipbook_error : String = check_flipbook_options(options)
	if flipbook_error != "":
		show_error("ERROR: "+flipbook_error)
		get_tree().quit(1)
		return
	await process_graph_files(files, options, render_variation, "--render")

## Checks the --frames, --duration, --columns and --separate-frames options
## (and sets their defaults), returns an error message or ""
func check_flipbook_options(options : Dictionary) -> String:
	if not options.has("frames"):
		for o in [ "duration", "columns", "separate_frames" ]:
			if options.has(o):
				return "--%s requires --frames <n>" % o.replace("_", "-")
		return ""
	options.duration = options.get("duration", 1.0)
	options.columns = options.get("columns", 0)
	options.separate_frames = options.get("separate_frames", false)
	if options.frames < 1:
		return "incorrect value for --frames: %d (at least 1 frame)" % options.frames
	if options.duration <= 0.0:
		return "incorrect value for --duration: %s (must be positive)" % options.duration
	if options.columns < 0 or options.columns > options.frames:
		return "incorrect value for --columns: %d (from 1 to the number of frames, or 0 for a square sheet)" % options.columns
	if options.separate_frames and options.columns != 0:
		return "--columns cannot be used with --separate-frames"
	if output_height > 0:
		return "--frames renders square frames (--size <size>)"
	return ""

func bake_files(files : Array[String], options : Dictionary) -> void:
	if options.size == 0:
		show_error("ERROR: incorrect size 0")
		get_tree().quit(1)
		return
	if options.has("high") and options.maps == MMCliTools.DEFAULT_BAKE_MAPS:
		options.maps = MMCliTools.DEFAULT_HIGH_POLY_MAPS
	var failed : bool = false
	for f in files:
		var prefix : String = options.output_dir.path_join(f.get_file().get_basename())
		for e in await MMCliTools.bake(f, options.maps, options.size, prefix, options):
			show_error("ERROR: %s: %s" % [ f.get_file(), e ])
			failed = true
	print("Done")
	get_tree().quit(1 if failed else 0)

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
