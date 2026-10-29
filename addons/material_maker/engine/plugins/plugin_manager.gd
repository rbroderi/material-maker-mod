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
#	depends=["other", "another>=1.2"] ; optional, plugins (ids, i.e. folder
#	                                ; names, with an optional minimum version)
#	                                ; that are loaded first
#
# Plugins are loaded at startup (with the user interface, and on the command
# line), unless they are disabled in the Plugins window (Tools menu).
# Dependencies are loaded before the plugins that need them (a dependency that
# is only disabled by default is enabled), and a plugin whose dependencies are
# missing, too old, disabled, failed to load or depend on it is not loaded.
# Their scripts can add menu items, command line commands
# (material_maker --plugin <command> [arguments]) and export hooks.


const CONFIG_SECTION : String = "plugins"

## What plugin scripts can register (one API object per plugin)
class API:
	extends RefCounted
	var plugin_id : String
	var plugin_path : String

	## The main window (null on the command line)
	func get_main_window() -> Node:
		return mm_globals.main_window

	## Adds a menu item (user interface only): in the Plugins menu, or in
	## another menu (e.g. "File"), after one of its items (e.g. "Export
	## material", by default at the end)
	func add_menu_item(label : String, callable : Callable, menu : String = "Plugins", after : String = "") -> void:
		MMPlugins.menu_items.append({ plugin=plugin_id, label=label, callable=callable, menu=menu, after=after })

	## Adds an operation to function graphs (Pixel Processor nodes): operands
	## are the keys of nodes that reference other nodes, and compile_callable
	## receives the compiler (MMFunctionGraph.Compiler), the node id, the
	## node, the operation and the operand ids, and returns the node's GLSL
	## expression after setting its type in compiler.types (or calls
	## compiler.error() and returns ""). globals are the global GLSL
	## definitions the operation needs (added once per shader). Graphs that use
	## an operation that is not available show an error.
	func add_function_graph_op(op_name : String, operands : Array, compile_callable : Callable, globals : Array = []) -> void:
		if not MMFunctionGraph.add_operation(op_name, operands, compile_callable, globals, plugin_id):
			push_error("Plugin %s: cannot add function graph operation %s (invalid or existing name)" % [ plugin_id, op_name ])

	## Adds a command line command (material_maker --plugin <name> [args]):
	## callable receives the arguments (PackedStringArray) and returns an exit
	## code (it can be a coroutine)
	func add_command(command_name : String, callable : Callable) -> void:
		MMPlugins.commands[command_name] = callable

	## Called after each material export, with the Material node, the export
	## prefix and the target
	func add_export_hook(callable : Callable) -> void:
		MMPlugins.export_hooks.append(callable)

static var plugins : Array[Dictionary] = []
static var menu_items : Array[Dictionary] = []
static var commands : Dictionary = {}
static var export_hooks : Array[Callable] = []
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

## A file of a plugin (e.g. a script shared with the plugins that depend on
## it), or null if the plugin is not loaded
static func load_plugin_file(plugin_id : String, file_name : String) -> Resource:
	for p in plugins:
		if p.id == plugin_id and p.get("loaded", false) and p.error == "":
			return load(p.path.path_join(file_name))
	return null

static func unload_plugins() -> void:
	for p in plugins:
		if p.has("instance"):
			p.instance._disable()

## Releases what plugins registered, and their scripts' instances
static func clear_registrations() -> void:
	MMFunctionGraph.remove_plugin_operations()
	menu_items.clear()
	commands.clear()
	export_hooks.clear()
	for p in plugins:
		p.erase("instance")
