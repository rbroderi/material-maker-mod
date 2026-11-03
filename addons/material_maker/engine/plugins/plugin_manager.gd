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
# (material_maker --plugin <command> [arguments]), export hooks and node types.
#
# Graph files list the plugins whose nodes they use (see
# get_graph_requirements), and what is missing is reported when they are
# loaded (see check_requirements).


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

	## Adds a command line command (material_maker --plugin <name> [args]):
	## callable receives the arguments (PackedStringArray) and returns an exit
	## code (it can be a coroutine)
	func add_command(command_name : String, callable : Callable) -> void:
		MMPlugins.commands[command_name] = callable

	## Called after each material export, with the Material node, the export
	## prefix and the target
	func add_export_hook(callable : Callable) -> void:
		MMPlugins.export_hooks.append(callable)

	## Adds a node type (the "type" of nodes in graph files and libraries),
	## implemented by a generator script (that extends MMGenBase and whose
	## get_type() returns the type), for nodes that node definitions (.mmg
	## files) cannot describe. Types of Material Maker's nodes, of node
	## definitions and of other plugins cannot be replaced.
	func add_node_type(type : String, script : Script) -> void:
		var error : String = MMPlugins.check_node_type(type, script)
		if error != "":
			push_error("Plugin %s: cannot add node type %s (%s)" % [ plugin_id, type, error ])
			return
		MMPlugins.node_types[type] = { plugin=plugin_id, script=script }

static var plugins : Array[Dictionary] = []
static var menu_items : Array[Dictionary] = []
static var commands : Dictionary = {}
static var export_hooks : Array[Callable] = []
## Node types of plugins (type -> { plugin, script })
static var node_types : Dictionary = {}
## Node definitions (.mmg files) of plugins (type -> plugin id)
static var node_definitions : Dictionary = {}
## Plugins that loaded graphs need for node types that are missing
## (type -> { plugin, version }, see check_requirements)
static var missing_node_type_plugins : Dictionary = {}
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
		var dir : DirAccess = DirAccess.open(path.path_join(nodes))
		if dir != null:
			for file_name in dir.get_files():
				if file_name.get_extension() == "mmg":
					node_definitions[file_name.get_basename()] = plugin.id
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
		if p.enabled and p.error == "" and p.get("library", "") != "":
			rv.append(p.library)
	return rv

## Why a plugin cannot add a node type (empty if it can)
static func check_node_type(type : String, script : Script) -> String:
	if type == "":
		return "empty name"
	if mm_loader.node_types.has(type) or mm_loader.predefined_generators.has(type):
		return "a node of Material Maker or a node definition has this name"
	if node_types.has(type):
		return "already added by the %s plugin" % node_types[type].plugin
	if script == null or not script.can_instantiate():
		return "invalid script"
	var base : Script = script
	while base != null and base != MMGenBase:
		base = base.get_base_script()
	if base == null:
		return "the script does not extend MMGenBase"
	return ""

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

## A plugin's description (empty if it is not installed)
static func get_plugin(plugin_id : String) -> Dictionary:
	for p in plugins:
		if p.id == plugin_id:
			return p
	return {}

## The plugin a node type comes from ("" if none): the plugin that adds it,
## or for a missing type, the plugin a loaded graph said it comes from
static func get_node_type_plugin(type : String) -> String:
	if node_types.has(type):
		return node_types[type].plugin
	if node_definitions.has(type):
		return node_definitions[type]
	if missing_node_type_plugins.has(type) and not mm_loader.has_node_type(type):
		return missing_node_type_plugins[type].plugin
	return ""

## What a graph (its data, as saved in .ptex files) needs: the plugins of its
## nodes (with the installed version as minimum version) and their node types,
##	{ "plugins": { "example": ">=1.0" }, "node_types": { "example_maze": "example" } }
## or an empty dictionary. Nodes of missing types keep the plugin (and minimum
## version) their graph was loaded with. declared is the requirements the
## graph was loaded with: its plugins that are not loaded (they may still be
## needed), its higher minimum versions and its other keys (e.g. a
## "material_maker" minimum version) are kept.
static func get_graph_requirements(data : Dictionary, declared : Dictionary = {}) -> Dictionary:
	var rv : Dictionary = {}
	for k in declared.keys():
		if not k in [ "plugins", "node_types" ]:
			rv[k] = declared[k]
	var required_plugins : Dictionary = {}
	var required_types : Dictionary = {}
	var stack : Array = [ data ]
	while not stack.is_empty():
		var node = stack.pop_back()
		if not node is Dictionary:
			continue
		if node.get("type") is String:
			var plugin_id : String = get_node_type_plugin(node.type)
			if plugin_id != "":
				required_types[node.type] = plugin_id
				if mm_loader.has_node_type(node.type):
					add_required_plugin(required_plugins, plugin_id, get_plugin(plugin_id).version)
				else:
					add_required_plugin(required_plugins, plugin_id, missing_node_type_plugins.get(node.type, {}).get("version", ""))
		if node.get("nodes") is Array:
			stack.append_array(node.nodes)
	if declared.get("plugins") is Dictionary:
		for plugin_id in declared.plugins.keys():
			var plugin : Dictionary = get_plugin(plugin_id)
			if required_plugins.has(plugin_id) or not plugin.get("loaded", false) or plugin.error != "":
				add_required_plugin(required_plugins, plugin_id, declared.plugins[plugin_id])
	if not required_plugins.is_empty():
		rv.plugins = required_plugins
	if not required_types.is_empty():
		rv.node_types = required_types
	return rv

## Adds a plugin to the plugins of requirements (id -> ">=version"), keeping
## the highest minimum version
static func add_required_plugin(required_plugins : Dictionary, plugin_id : String, requirement) -> void:
	var version : String = get_required_version(requirement)
	var previous_version : String = get_required_version(required_plugins.get(plugin_id))
	if not required_plugins.has(plugin_id) or (version != "" and (previous_version == "" or compare_versions(version, previous_version) > 0)):
		required_plugins[plugin_id] = (">="+version) if version != "" else ""

## The minimum version of a requirement (">=1.2" or "1.2"), or "" when there
## is none or it cannot be compared
static func get_required_version(requirement) -> String:
	if not requirement is String:
		return ""
	var version : String = requirement.strip_edges().trim_prefix(">=").strip_edges()
	if RegEx.create_from_string("^[0-9]+(\\.[0-9]+)*$").search(version) == null:
		return ""
	return version

## What a graph needs that is missing (empty if nothing), from its
## requirements (see get_graph_requirements; "node_types" can also be a list
## of types, and "material_maker" a minimum version of Material Maker) and the
## types of its nodes that were loaded as placeholders. The plugins of missing
## node types are remembered (see get_node_type_plugin).
static func check_requirements(requires : Dictionary, placeholder_types : PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var missing : PackedStringArray = PackedStringArray()
	var mm_version : String = get_required_version(requires.get("material_maker"))
	var current_version : String = ProjectSettings.get_setting("application/config/actual_release", "")
	if mm_version != "" and compare_versions(current_version, mm_version) < 0:
		missing.append("Material Maker %s or later (this is %s)" % [ mm_version, current_version ])
	var required_plugins : Dictionary = requires.plugins if requires.get("plugins") is Dictionary else {}
	var required_types = requires.get("node_types")
	var unknown_types : PackedStringArray = placeholder_types.duplicate()
	# Missing node types, by plugin
	var plugin_types : Dictionary = {}
	for plugin_id in required_plugins.keys():
		plugin_types[plugin_id] = PackedStringArray()
	if required_types is Dictionary:
		for type in required_types.keys():
			var plugin_id = required_types[type]
			if not plugin_id is String or plugin_id == "" or mm_loader.has_node_type(type):
				continue
			if not plugin_types.has(plugin_id):
				plugin_types[plugin_id] = PackedStringArray()
			plugin_types[plugin_id].append(type)
			var index : int = unknown_types.find(type)
			if index != -1:
				unknown_types.remove_at(index)
			missing_node_type_plugins[type] = { plugin=plugin_id, version=str(required_plugins.get(plugin_id, "")) }
	elif required_types is Array:
		for type in required_types:
			if type is String and not mm_loader.has_node_type(type) and not type in unknown_types:
				unknown_types.append(type)
	# Types that another graph said come from a plugin
	for type in unknown_types.duplicate():
		var plugin_id : String = get_node_type_plugin(type)
		if plugin_id != "":
			if not plugin_types.has(plugin_id):
				plugin_types[plugin_id] = PackedStringArray()
			plugin_types[plugin_id].append(type)
			unknown_types.remove_at(unknown_types.find(type))
	for plugin_id in plugin_types.keys():
		var types : PackedStringArray = plugin_types[plugin_id]
		var plugin : Dictionary = get_plugin(plugin_id)
		var version : String = get_required_version(required_plugins.get(plugin_id))
		var problem : String = ""
		if plugin.is_empty():
			problem = "not installed"
		elif not plugin.enabled:
			problem = "disabled"
		elif plugin.error != "":
			problem = "not loaded: %s" % plugin.error
		elif version != "" and compare_versions(plugin.version, version) < 0:
			problem = "version %s or later is needed, %s is installed" % [ version, plugin.version ]
		elif not types.is_empty():
			problem = "version %s does not have these node types" % plugin.version
		if problem == "":
			continue
		var description : String = "the plugin \"%s\" (%s)" % [ plugin.get("name", plugin_id), problem ]
		if not types.is_empty():
			types.sort()
			description += ", for nodes of type %s" % ", ".join(types)
		missing.append(description)
	if not unknown_types.is_empty():
		unknown_types.sort()
		missing.append("nodes of unknown types (%s)" % ", ".join(unknown_types))
	return missing

## The plugin that a loaded graph said nodes of a missing type come from,
## with its state (e.g. 'the plugin "Example", which is disabled'), or "" if
## none did
static func get_missing_node_type_plugin(type : String) -> String:
	var plugin_id : String = get_node_type_plugin(type)
	if plugin_id == "":
		return ""
	var plugin : Dictionary = get_plugin(plugin_id)
	if plugin.is_empty():
		return "the plugin \"%s\", which is not installed" % plugin_id
	if not plugin.enabled:
		return "the plugin \"%s\", which is disabled" % plugin.name
	if plugin.error != "":
		return "the plugin \"%s\", which could not be loaded" % plugin.name
	return "the plugin \"%s\"" % plugin.name

static func unload_plugins() -> void:
	for p in plugins:
		if p.has("instance"):
			p.instance._disable()

## Releases what plugins registered, and their scripts' instances
static func clear_registrations() -> void:
	menu_items.clear()
	commands.clear()
	export_hooks.clear()
	node_types.clear()
	for p in plugins:
		p.erase("instance")
