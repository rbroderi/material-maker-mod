extends RefCounted
class_name MMPlugins


# Material Maker plugins: folders in user://plugins or in the plugins folder
# next to Material Maker, with a plugin.cfg file:
#
#	[plugin]
#	name="Example"
#	description="What it does"
#	version="1.0"
#	script="plugin.gd"              ; optional, extends MMPlugin
#	nodes="nodes"                   ; optional, a folder of node definitions (.mmg)
#	library="library.json"          ; optional, a node library
#	export_targets="export_targets" ; optional, a folder of export targets (.mme)
#	enabled_by_default=true         ; optional
#	depends=["car_paint", "other>=1.2"] ; optional, plugins (ids, i.e. folder
#	                                ; names, with an optional minimum version)
#	                                ; that are loaded first
#	cli_modes=["--export-volume"]   ; optional, command line modes added by
#	                                ; the script (with add_cli_mode)
#
# Plugins are loaded at startup (with the user interface, and in command line
# and RPC modes), unless they are disabled in the Plugins window (Tools menu).
# Dependencies are loaded before the plugins that need them (a dependency that
# is only disabled by default is enabled), and a plugin whose dependencies are
# missing, too old, disabled, failed to load or depend on it is not loaded.
# Their scripts can add menu items, import formats, RPC methods, command line
# commands (material_maker --plugin <command> [arguments]) and modes, sections
# of the 2D preview's export menu, export hooks, image file formats and node
# types implemented by scripts.
#
# Graphs can declare what they need (see check_requirements): a "requires"
# dictionary, or a line of their long description such as
#	sbsar2ptex-requires: {"material_maker_mod": ">=1.17", "plugins": {"sbs": ">=1.0"}}


const CONFIG_SECTION : String = "plugins"

## Version of this fork's features that graphs can require, increased when
## features are added (see check_requirements)
const MM_MOD_VERSION : String = "1.17"
## Features of this fork that graphs can require
const MM_MOD_FEATURES : PackedStringArray = [
	"buffer_release", "buffer_size_relative_to_input", "buffer_size_expressions",
	"pass_size", "iterate_buffer_v2", "iteration_variable", "unorm16", "rg_formats",
	"store_rounding", "node_types", "missing_node_placeholders", "sbs_fxmap" ]
## A line of a graph's long description that holds its requirements as JSON
## (for files that are also loaded by versions that do not save "requires")
const REQUIRES_LINE_PATTERN : String = "(?m)^\\s*[A-Za-z0-9_.-]*requires:\\s*(\\{.*\\})\\s*$"

## What plugin scripts can register (one API object per plugin)
class API:
	extends RefCounted
	var plugin_id : String
	var plugin_path : String

	## The main window (null in command line and RPC modes)
	func get_main_window() -> Node:
		return mm_globals.main_window

	## Adds a menu item (user interface only): in the Plugins menu, or in
	## another menu (e.g. "File"), after one of its items (e.g. "Export
	## material", by default at the end)
	func add_menu_item(label : String, callable : Callable, menu : String = "Plugins", after : String = "") -> void:
		MMPlugins.menu_items.append({ plugin=plugin_id, label=label, callable=callable, menu=menu, after=after })

	## Adds a file format that is imported as a material graph (in the Load
	## dialog, by drag and drop, with the RPC load method and on the command
	## line): callable receives the file's path and returns the graph (a
	## dictionary, as in .ptex files, with optional "warnings"), or an empty
	## dictionary (it can be a coroutine)
	func add_import_format(extension : String, description : String, callable : Callable) -> void:
		MMPlugins.import_formats[extension.to_lower()] = { plugin=plugin_id, description=description, callable=callable }

	## Adds a JSON-RPC method: callable receives the parameters dictionary
	## (and, if it has 2 arguments, the MMRpcServer, for its fail(), require(),
	## get_graph() and get_generator() helpers) and returns the result (it can
	## be a coroutine)
	func add_rpc_method(method_name : String, callable : Callable) -> void:
		MMPlugins.rpc_methods[method_name] = callable

	## Adds a command line command (material_maker --plugin <name> [args]):
	## callable receives the arguments (PackedStringArray) and returns an exit
	## code (it can be a coroutine)
	func add_command(command_name : String, callable : Callable) -> void:
		MMPlugins.commands[command_name] = callable

	## Adds a command line mode (e.g. --export-volume, that must also be listed
	## in the plugin's cli_modes): callable receives the command line tool
	## (parse_args.gd, for process_graph_files() and expand_files()), the files
	## and the options, and returns an exit code (it can be a coroutine).
	## options maps the mode's own options to { key, type (TYPE_INT,
	## TYPE_FLOAT, TYPE_STRING or TYPE_BOOL for flags), help }, that set
	## options[key]. usage is a line of the --help text.
	func add_cli_mode(mode : String, callable : Callable, usage : String, options : Dictionary = {}) -> void:
		MMPlugins.cli_modes[mode] = { plugin=plugin_id, callable=callable, usage=usage }
		for o in options.keys():
			MMPlugins.cli_options[o] = options[o]

	## Adds a section to the 2D preview's export menu: callable receives the
	## export menu and returns a Control, whose optional
	## update(generator, output_index) method is called when the previewed
	## output changes (e.g. to hide the section)
	func add_export_menu_section(callable : Callable) -> void:
		MMPlugins.export_menu_sections.append(callable)

	## Called after each material export, with the Material node, the export
	## prefix and the target
	func add_export_hook(callable : Callable) -> void:
		MMPlugins.export_hooks.append(callable)

	## Adds an image file format, used wherever images are saved (texture
	## exports, the 2D preview's export menu): callable receives the image, the
	## file name and options (from export targets, e.g. srgb or bits) and
	## returns an error code
	func add_image_format(extension : String, description : String, callable : Callable) -> void:
		MMPlugins.image_formats[extension.to_lower()] = { plugin=plugin_id, description=description, callable=callable }

	## Adds a format of files that hold several images (layers): texture files
	## of export targets with a "layer" name and the same file name are saved
	## together. callable receives the file name and the layers (an array of
	## { name, image, options }) and returns an error code.
	func add_layered_image_format(extension : String, description : String, callable : Callable) -> void:
		MMPlugins.layered_image_formats[extension.to_lower()] = { plugin=plugin_id, description=description, callable=callable }

	## Adds a node type (the "type" of nodes in graph files) implemented by a
	## generator script (that extends MMGenBase), for nodes that shader
	## definitions (.mmg files) cannot describe. Graphs with nodes of a type
	## that is not available load them as placeholders (MMGenMissing).
	func add_node_type(type : String, script : Script) -> void:
		MMPlugins.node_types[type] = { plugin=plugin_id, script=script }

static var plugins : Array[Dictionary] = []
static var menu_items : Array[Dictionary] = []
static var import_formats : Dictionary = {}
static var rpc_methods : Dictionary = {}
static var commands : Dictionary = {}
static var cli_modes : Dictionary = {}
static var cli_options : Dictionary = {}
static var export_menu_sections : Array[Callable] = []
static var export_hooks : Array[Callable] = []
static var image_formats : Dictionary = {}
static var layered_image_formats : Dictionary = {}
static var node_types : Dictionary = {}
static var loaded : bool = false
static var discovered : bool = false
static var configs : Dictionary = {}


## Plugin directories: the user's, the one next to Material Maker (builds),
## and the source tree's (when running from source)
static func get_plugin_dirs() -> Array[String]:
	var dirs : Array[String] = [ "user://plugins", MMPaths.get_resource_dir().path_join("plugins") ]
	if DirAccess.dir_exists_absolute("res://material_maker/plugins"):
		dirs.append("res://material_maker/plugins")
	return dirs

static func get_disabled() -> Array:
	if mm_globals.config.has_section_key(CONFIG_SECTION, "disabled"):
		return mm_globals.config.get_value(CONFIG_SECTION, "disabled")
	return []

static func get_enabled() -> Array:
	if mm_globals.config.has_section_key(CONFIG_SECTION, "enabled"):
		return mm_globals.config.get_value(CONFIG_SECTION, "enabled")
	return []

## Enables or disables a plugin (when Material Maker starts again), with the
## plugins it depends on (when enabled) or the plugins that depend on it (when
## disabled). Returns the ids of the plugins that were changed.
static func set_plugin_enabled(plugin_id : String, enabled : bool) -> PackedStringArray:
	var disabled : Array = get_disabled()
	var enabled_list : Array = get_enabled()
	var changed : PackedStringArray = PackedStringArray()
	var pending : Array[String] = [ plugin_id ]
	while not pending.is_empty():
		var id : String = pending.pop_back()
		if id in changed:
			continue
		changed.append(id)
		disabled.erase(id)
		enabled_list.erase(id)
		(enabled_list if enabled else disabled).append(id)
		for p in plugins:
			if enabled and p.id == id:
				pending.append_array(p.depends.map(func(d): return parse_dependency(d).id))
			elif not enabled and p.depends.any(func(d): return parse_dependency(d).id == id):
				pending.append(p.id)
	mm_globals.config.set_value(CONFIG_SECTION, "disabled", disabled)
	mm_globals.config.set_value(CONFIG_SECTION, "enabled", enabled_list)
	return changed

## A dependency ("id" or "id>=version") as { id, version }
static func parse_dependency(dependency : String) -> Dictionary:
	var parts : PackedStringArray = dependency.split(">=")
	return { id=parts[0].strip_edges(), version=parts[1].strip_edges() if parts.size() > 1 else "" }

## Compares dotted versions (1.10 > 1.9), returns -1, 0 or 1
static func compare_versions(a : String, b : String) -> int:
	var va : PackedStringArray = a.split(".")
	var vb : PackedStringArray = b.split(".")
	for i in max(va.size(), vb.size()):
		var na : int = va[i].to_int() if i < va.size() else 0
		var nb : int = vb[i].to_int() if i < vb.size() else 0
		if na != nb:
			return -1 if na < nb else 1
	return 0

## Finds the plugins and loads the enabled ones (once)
static func load_plugins() -> void:
	if loaded:
		return
	loaded = true
	# Callables of plugins (lambdas in particular) must not outlive their
	# scripts: static variables are only freed after them (crash at exit)
	var tree : SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.root.tree_exiting.connect(clear_registrations)
	discover_plugins()
	var disabled : Array = get_disabled()
	for plugin in plugins:
		if plugin.enabled:
			load_with_dependencies(plugin, disabled, [])

## The command line mode of the arguments added by an enabled plugin (see
## cli_modes in plugin.cfg), or ""
static func find_cli_mode(args : PackedStringArray) -> String:
	discover_plugins()
	for p in plugins:
		if p.enabled:
			for m in p.cli_modes:
				if m in args:
					return m
	return ""

## Reads the configurations of the plugins (once)
static func discover_plugins() -> void:
	if discovered:
		return
	discovered = true
	var disabled : Array = get_disabled()
	var enabled_list : Array = get_enabled()
	for base_dir in get_plugin_dirs():
		var dir : DirAccess = DirAccess.open(base_dir)
		if dir == null:
			continue
		for plugin_dir in dir.get_directories():
			# A plugin in several directories is loaded from the first one
			if configs.has(plugin_dir):
				continue
			var path : String = base_dir.path_join(plugin_dir)
			var config : ConfigFile = ConfigFile.new()
			if config.load(path.path_join("plugin.cfg")) != OK:
				continue
			var plugin : Dictionary = {
				id=plugin_dir, path=path,
				name=config.get_value("plugin", "name", plugin_dir),
				description=config.get_value("plugin", "description", ""),
				version=config.get_value("plugin", "version", ""),
				depends=Array(config.get_value("plugin", "depends", [])),
				cli_modes=Array(config.get_value("plugin", "cli_modes", [])),
				error="" }
			var by_default : bool = config.get_value("plugin", "enabled_by_default", true)
			plugin.enabled = plugin_dir in enabled_list or (by_default and not plugin_dir in disabled)
			configs[plugin_dir] = config
			plugins.append(plugin)

## Loads a plugin after its dependencies (once), returns its error
static func load_with_dependencies(plugin : Dictionary, disabled : Array, loading : Array) -> String:
	if plugin.has("loaded"):
		return plugin.error
	if plugin.id in loading:
		return "dependency cycle (%s)" % " > ".join(loading.slice(loading.find(plugin.id)) + [ plugin.id ])
	loading.append(plugin.id)
	for d in plugin.depends:
		var dependency : Dictionary = parse_dependency(d)
		var found : Array = plugins.filter(func(p): return p.id == dependency.id)
		if found.is_empty():
			plugin.error = "needs the %s plugin, which is not installed" % dependency.id
		elif dependency.version != "" and compare_versions(found[0].version, dependency.version) < 0:
			plugin.error = "needs the %s plugin version %s or later (installed: %s)" % [ dependency.id, dependency.version, found[0].version ]
		elif not found[0].enabled and dependency.id in disabled:
			plugin.error = "needs the %s plugin, which is disabled" % dependency.id
		else:
			# Plugins that are only disabled by default are enabled when needed
			found[0].enabled = true
			var error : String = load_with_dependencies(found[0], disabled, loading)
			if error.begins_with("dependency cycle"):
				plugin.error = error
			elif error != "":
				plugin.error = "needs the %s plugin, which could not be loaded" % dependency.id
		if plugin.error != "":
			break
	loading.erase(plugin.id)
	if plugin.error == "":
		plugin.error = load_plugin(plugin, configs[plugin.id])
	plugin.loaded = true
	if plugin.error != "":
		push_error("Plugin %s: %s" % [ plugin.name, plugin.error ])
	return plugin.error

static func load_plugin(plugin : Dictionary, config : ConfigFile) -> String:
	var path : String = plugin.path
	var nodes : String = config.get_value("plugin", "nodes", "")
	if nodes != "":
		mm_loader.get_predefined_generators_from_dir(path.path_join(nodes))
	var export_targets : String = config.get_value("plugin", "export_targets", "")
	if export_targets != "":
		load_export_targets(path.path_join(export_targets))
	plugin.library = path.path_join(config.get_value("plugin", "library", "")) if config.get_value("plugin", "library", "") != "" else ""
	var script_name : String = config.get_value("plugin", "script", "")
	if script_name != "":
		var script = load(path.path_join(script_name))
		if not script is GDScript or not script.can_instantiate():
			return "cannot load %s" % script_name
		var instance = script.new()
		if not instance is MMPlugin:
			return "%s does not extend MMPlugin" % script_name
		var api : API = API.new()
		api.plugin_id = plugin.id
		api.plugin_path = path
		instance._enable(api)
		plugin.instance = instance
	return ""

## Export targets (.mme files) of a plugin, for Material nodes
static func load_export_targets(path : String) -> void:
	var dir : DirAccess = DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		if file_name.get_extension() != "mme":
			continue
		var file : FileAccess = FileAccess.open(path.path_join(file_name), FileAccess.READ)
		if file == null:
			continue
		var export_data : Dictionary = mm_loader.string_to_dict_tree(file.get_as_text())
		if export_data.has("material") and export_data.has("name"):
			mm_loader.add_plugin_export_target(export_data)

## The importer of a file (see API.add_import_format), or an empty dictionary
static func get_import_format(path : String) -> Dictionary:
	return import_formats.get(path.get_extension().to_lower(), {})

## Imports a file as a material graph (a dictionary, empty on error)
static func import_file(path : String) -> Dictionary:
	var import_format : Dictionary = get_import_format(path)
	if import_format.is_empty():
		return {}
	var imported = await import_format.callable.call(path)
	if not imported is Dictionary or imported.is_empty():
		return {}
	for w in imported.get("warnings", []):
		print("%s import: %s" % [ import_format.description, w ])
	imported.erase("warnings")
	return imported

## Calls a plugin's RPC method, with the RPC server if it takes 2 arguments
static func call_rpc_method(method_name : String, params : Dictionary, server : Node):
	var callable : Callable = rpc_methods[method_name]
	if callable.get_argument_count() >= 2:
		return await callable.call(params, server)
	return await callable.call(params)

## Node libraries of the enabled plugins (added to the library manager when
## the user interface starts)
static func get_libraries() -> PackedStringArray:
	var rv : PackedStringArray = PackedStringArray()
	for p in plugins:
		if p.enabled and p.get("library", "") != "":
			rv.append(p.library)
	return rv

static func call_export_hooks(material : MMGenBase, prefix : String, target : String) -> void:
	for h in export_hooks:
		await h.call(material, prefix, target)

## Saves an image in a format added by a plugin (see API.add_image_format)
static func save_image(image : Image, file_name : String, options : Dictionary = {}) -> Error:
	var image_format : Dictionary = image_formats.get(file_name.get_extension().to_lower(), {})
	if image_format.is_empty():
		return ERR_FILE_UNRECOGNIZED
	return image_format.callable.call(image, file_name, options)

## Saves layers in a file (see API.add_layered_image_format)
static func save_layered_image(file_name : String, layers : Array) -> Error:
	var layered_format : Dictionary = layered_image_formats.get(file_name.get_extension().to_lower(), {})
	if layered_format.is_empty():
		return ERR_FILE_UNRECOGNIZED
	return layered_format.callable.call(file_name, layers)

## File dialog filters of the image formats added by plugins
static func get_image_format_filters() -> PackedStringArray:
	var filters : PackedStringArray = PackedStringArray()
	for extension in image_formats.keys():
		filters.append("*.%s; %s" % [ extension, image_formats[extension].description ])
	return filters

## A file of a plugin (e.g. a script shared with the plugins that depend on
## it), or null if the plugin is not loaded
static func load_plugin_file(plugin_id : String, file_name : String) -> Resource:
	for p in plugins:
		if p.id == plugin_id and p.get("loaded", false) and p.error == "":
			return load(p.path.path_join(file_name))
	return null

## The requirements of a graph (its data, as in .ptex files): its "requires"
## dictionary, or the JSON of a "...requires:" line of its long description
static func get_graph_requirements(data : Dictionary) -> Dictionary:
	if data.get("requires") is Dictionary:
		return data.requires
	var longdesc = data.get("longdesc", "")
	if longdesc is String and longdesc.contains("requires:"):
		var regex : RegEx = RegEx.create_from_string(REQUIRES_LINE_PATTERN)
		var match_result : RegExMatch = regex.search(longdesc)
		if match_result != null:
			var parsed = JSON.parse_string(match_result.get_string(1))
			if parsed is Dictionary:
				return parsed
	return {}

## The minimum version of a requirement (">=1.2", "1.2"), or "" when there is
## none or it cannot be compared (e.g. a commit hash)
static func get_required_version(requirement) -> String:
	if not requirement is String:
		return ""
	var version : String = requirement.strip_edges().trim_prefix(">=").strip_edges()
	if RegEx.create_from_string("^[0-9]+(\\.[0-9]+)*$").search(version) == null:
		return ""
	return version

## What a graph needs that is missing (empty if nothing): requires is
##	{ "material_maker_mod": ">=1.17", "plugins": { "sbs": ">=1.0" },
##	  "node_types": [ "sbs_fxmap" ], "features": [ "iterate_buffer_v2" ] }
## (dashes in keys are accepted, e.g. "material-maker-mod")
static func check_requirements(requires : Dictionary) -> PackedStringArray:
	var missing : PackedStringArray = PackedStringArray()
	for k in requires.keys():
		var value = requires[k]
		match str(k).replace("-", "_"):
			"material_maker_mod":
				var version : String = get_required_version(value)
				if version != "" and compare_versions(MM_MOD_VERSION, version) < 0:
					missing.append("Material Maker (mod) %s or later (this is %s)" % [ version, MM_MOD_VERSION ])
			"plugins":
				if not value is Dictionary:
					continue
				for id in value.keys():
					var found : Array = plugins.filter(func(p): return p.id == id)
					var version : String = get_required_version(value[id])
					if found.is_empty():
						missing.append("the %s plugin (not installed)" % id)
					elif not found[0].get("loaded", false):
						missing.append("the %s plugin (disabled)" % id)
					elif found[0].error != "":
						missing.append("the %s plugin (%s)" % [ id, found[0].error ])
					elif version != "" and compare_versions(found[0].version, version) < 0:
						missing.append("the %s plugin %s or later (installed: %s)" % [ id, version, found[0].version ])
			"node_types":
				if value is Array:
					for t in value:
						if not mm_loader.has_node_type(t):
							missing.append("the %s node type" % t)
			"features":
				if value is Array:
					for f in value:
						if not f in MM_MOD_FEATURES:
							missing.append("the %s feature" % f)
	return missing

static func unload_plugins() -> void:
	for p in plugins:
		if p.has("instance"):
			p.instance._disable()

## Releases what plugins registered, and their scripts' instances
static func clear_registrations() -> void:
	menu_items.clear()
	import_formats.clear()
	rpc_methods.clear()
	commands.clear()
	cli_modes.clear()
	cli_options.clear()
	export_menu_sections.clear()
	export_hooks.clear()
	image_formats.clear()
	layered_image_formats.clear()
	node_types.clear()
	for p in plugins:
		p.erase("instance")
