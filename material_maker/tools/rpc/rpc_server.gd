extends Node
class_name MMRpcServer


# A JSON-RPC 2.0 server to drive Material Maker from scripts (see
# material_maker/doc/scripting.rst and the Python client in python/).
#
# Requests and responses are JSON objects, one per line, over TCP. The
# server only listens on 127.0.0.1. When the main window exists, methods
# act on the current graph of the current project (changes can be undone),
# otherwise (in --rpc mode) on a graph owned by the server.


const DEFAULT_PORT : int = 7680

const ERROR_PARSE : int = -32700
const ERROR_INVALID_REQUEST : int = -32600
const ERROR_METHOD_NOT_FOUND : int = -32601
const ERROR_INVALID_PARAMS : int = -32602
const ERROR_SERVER : int = -32000

var server : TCPServer = TCPServer.new()
var clients : Array[Dictionary] = []
## The graph used when there is no main window
var headless_graph : MMGenGraph = null
## The error of the method being executed (methods return null on error)
var method_error : String = ""
## With the user interface, connections wait until the main window is ready
## (else requests would act on a graph of the server)
var wait_for_main_window : bool = false


func start(port : int) -> Error:
	var error : Error = server.listen(port, "127.0.0.1")
	if error == OK:
		print("JSON-RPC server listening on 127.0.0.1:%d" % port)
	else:
		printerr("Cannot start JSON-RPC server on port %d: %s" % [ port, error_string(error) ])
	return error

func _exit_tree() -> void:
	for c in clients:
		c.peer.disconnect_from_host()
	clients.clear()
	server.stop()

func _process(_delta : float) -> void:
	if wait_for_main_window:
		if mm_globals.main_window == null or not mm_globals.main_window.is_node_ready():
			return
		wait_for_main_window = false
	while server.is_connection_available():
		var peer : StreamPeerTCP = server.take_connection()
		peer.set_no_delay(true)
		clients.append({ peer=peer, buffer=PackedByteArray(), busy=false })
	for c in clients.duplicate():
		var peer : StreamPeerTCP = c.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			clients.erase(c)
			continue
		var available : int = peer.get_available_bytes()
		if available > 0:
			var data : Array = peer.get_data(available)
			if data[0] == OK:
				c.buffer.append_array(data[1])
		# Requests of a client are handled one at a time, in order
		if not c.busy:
			var eol : int = c.buffer.find(10)
			if eol != -1:
				var line : String = c.buffer.slice(0, eol).get_string_from_utf8()
				c.buffer = c.buffer.slice(eol+1)
				if line.strip_edges() != "":
					c.busy = true
					handle_request(c, line)

func handle_request(client : Dictionary, line : String) -> void:
	var response : Dictionary = await process_request(line)
	if not response.is_empty() and client.peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		client.peer.put_data((JSON.stringify(response)+"\n").to_utf8_buffer())
	client.busy = false

func process_request(line : String) -> Dictionary:
	var json : JSON = JSON.new()
	if json.parse(line) != OK:
		return make_error(null, ERROR_PARSE, json.get_error_message())
	var request = json.data
	if not request is Dictionary or not request.get("method") is String:
		return make_error(null, ERROR_INVALID_REQUEST, "Invalid request")
	var id = request.get("id")
	# (JSON numbers are parsed as floats)
	if id is float and id == floor(id):
		id = int(id)
	var params = request.get("params", {})
	if params is Array and params.is_empty():
		params = {}
	if not params is Dictionary:
		return make_error(id, ERROR_INVALID_PARAMS, "params must be an object")
	var method_name : String = "api_"+request.method
	# Plugins can add methods
	var plugin_method : bool = not has_method(method_name) and MMPlugins.rpc_methods.has(request.method)
	if not has_method(method_name) and not plugin_method:
		return make_error(id, ERROR_METHOD_NOT_FOUND, "Unknown method '%s'" % request.method)
	method_error = ""
	# (await must apply to the call itself for asynchronous methods)
	var result
	if plugin_method:
		result = await MMPlugins.call_rpc_method(request.method, params, self)
	else:
		result = await call(method_name, params)
	# Notifications (requests without id) have no response
	if not request.has("id"):
		return {}
	if method_error != "":
		return make_error(id, ERROR_SERVER, method_error)
	return { jsonrpc="2.0", id=id, result=MMType.serialize_value(result) if result is Object else result }

static func make_error(id, code : int, message : String) -> Dictionary:
	return { jsonrpc="2.0", id=id, error={ code=code, message=message } }

## Sets the error of the current method, and returns null for convenience
func fail(message : String):
	method_error = message
	return null

## Checks that the string parameters given by names are there
func require(params : Dictionary, names : Array) -> bool:
	for n in names:
		if not params.has(n):
			fail("missing parameter '%s'" % n)
			return false
		if not params[n] is String:
			fail("parameter '%s' must be a string" % n)
			return false
	return true

## An optional integer parameter (sets an error and returns default if it
## is not a number)
func get_int(params : Dictionary, parameter_name : String, default : int) -> int:
	var value = params.get(parameter_name, default)
	if value is int or value is float:
		return int(value)
	fail("parameter '%s' must be a number" % parameter_name)
	return default

# Graph access

func get_graph_edit() -> MMGraphEdit:
	if mm_globals.main_window != null:
		return mm_globals.main_window.get_current_graph_edit()
	return null

func get_graph() -> MMGenGraph:
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit != null:
		return graph_edit.generator
	if headless_graph == null:
		await set_headless_graph(await mm_loader.create_gen({nodes=[{name="Material", type="material", parameters={size=11}}], connections=[]}))
	return headless_graph

func set_headless_graph(graph : MMGenGraph) -> void:
	if headless_graph != null:
		headless_graph.queue_free()
	headless_graph = graph
	if graph != null:
		add_child(graph)

func get_generator(graph : MMGenGraph, node_name : String) -> MMGenBase:
	var generator : MMGenBase = graph.get_node_or_null(NodePath(node_name)) as MMGenBase
	if generator == null:
		fail("node '%s' not found" % node_name)
	return generator

## Applies a change to the graph, with undo support in the main window
func change_graph(action_name : String, change : Callable):
	var graph_edit : MMGraphEdit = get_graph_edit()
	var graph : MMGenGraph = await get_graph()
	if graph_edit == null:
		return await change.call(graph)
	# serialize() shares the connections array with the graph
	var prev : Dictionary = graph.serialize().duplicate(true)
	var result = await change.call(graph)
	if method_error == "":
		graph_edit.undoredo_create_step(action_name, graph.get_hier_name(), prev, graph.serialize())
		graph_edit.update_view(graph)
		graph_edit.send_changed_signal()
	return result

static func describe_node(generator : MMGenBase) -> Dictionary:
	var parameters : Dictionary = {}
	for p in generator.get_parameter_defs():
		parameters[p.name] = MMType.serialize_value(generator.get_parameter(p.name))
	return {
		name=generator.name,
		# The type of the node in graph files
		type=generator.model if generator.model != null else generator.get_type(),
		type_name=generator.get_type_name(),
		position=[ generator.position.x, generator.position.y ],
		inputs=generator.get_input_defs().map(func(i): return { name=i.get("name", ""), type=i.get("type", "") }),
		outputs=generator.get_output_defs(true).map(func(o): return { type=o.get("type", "") }),
		parameters=parameters,
		parameter_defs=generator.get_parameter_defs().map(func(p): return { name=p.name, type=p.get("type", ""), label=p.get("label", "") }),
	}

# Methods

func api_ping(_params : Dictionary):
	return { version=ProjectSettings.get_setting("application/config/actual_release", ProjectSettings.get_setting("application/config/version", "")), gui=mm_globals.main_window != null }

## Creates a new material, optionally from an output template (by name or
## export target)
func api_new_graph(params : Dictionary):
	if not params.get("template", "") is String:
		return fail("parameter 'template' must be a string")
	var template : String = params.get("template", "")
	if template != "" and MMCliTools.get_engine_template_graph(template).is_empty():
		return fail("no template '%s' (templates: %s)" % [ template, ", ".join(list_templates()) ])
	if mm_globals.main_window != null:
		mm_globals.main_window.new_material(template)
		await get_tree().process_frame
	elif template != "":
		await set_headless_graph(await mm_loader.create_gen(MMCliTools.get_engine_template_graph(template)))
	else:
		await set_headless_graph(null)
		await get_graph()
	return true

func list_templates() -> Array:
	return MMCliTools.get_engine_templates().map(func(t): return t.name)

func api_list_templates(_params : Dictionary):
	return MMCliTools.get_engine_templates().map(func(t): return { name=t.name, export=t.export, description=t.description })

func api_load(params : Dictionary):
	if not require(params, [ "path" ]):
		return null
	if not FileAccess.file_exists(params.path):
		return fail("file '%s' not found" % params.path)
	if mm_globals.main_window != null:
		var projects = mm_globals.main_window.projects_panel.get_projects()
		var previous_tab : int = projects.current_tab
		var tab_count : int = projects.get_tab_count()
		if not await mm_globals.main_window.do_load_material(params.path):
			# Close the project that was created for the file, so the
			# current graph is still the one that was open
			if projects.get_tab_count() > tab_count:
				projects.do_close_tab(tab_count)
				projects.current_tab = previous_tab
			return fail("cannot load '%s'" % params.path)
	else:
		var graph : MMGenBase = await mm_loader.load_gen(params.path)
		if not graph is MMGenGraph:
			return fail("cannot load '%s'" % params.path)
		set_headless_graph(graph)
	# What the graph needs that is missing (unknown node types are placeholders)
	var current_graph = await get_graph()
	if current_graph != null and current_graph.has_meta("missing_requirements"):
		var missing : PackedStringArray = current_graph.get_meta("missing_requirements")
		if not missing.is_empty():
			return { loaded=true, missing=Array(missing) }
	return true

func api_save(params : Dictionary):
	if not require(params, [ "path" ]):
		return null
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit != null:
		if not await graph_edit.save_file(params.path):
			return fail("cannot save '%s'" % params.path)
	else:
		# (save_gen does not report errors)
		var file : FileAccess = FileAccess.open(params.path, FileAccess.WRITE)
		if file == null:
			return fail("cannot save '%s': %s" % [ params.path, error_string(FileAccess.get_open_error()) ])
		file.close()
		mm_loader.save_gen(params.path, await get_graph())
	return true

func api_list_nodes(_params : Dictionary):
	var graph : MMGenGraph = await get_graph()
	var nodes : Array = []
	for c in graph.get_children():
		if c is MMGenBase:
			nodes.append(describe_node(c))
	return nodes

func api_get_node(params : Dictionary):
	if not require(params, [ "node" ]):
		return null
	var generator : MMGenBase = get_generator(await get_graph(), params.node)
	return describe_node(generator) if generator != null else null

func api_list_connections(_params : Dictionary):
	var graph : MMGenGraph = await get_graph()
	return graph.connections.duplicate(true)

func api_list_parameters(_params : Dictionary):
	return Array(MMCliTools.list_parameters(await get_graph()))

func api_set_parameter(params : Dictionary):
	if not require(params, [ "node", "parameter" ]):
		return null
	if not params.has("value"):
		return fail("missing parameter 'value'")
	return await set_parameters({ params.node+":"+params.parameter: params.value })

## Sets several parameters, given as { name: value } where names are remote
## parameter names or labels, or "node:parameter"
func api_set_parameters(params : Dictionary):
	if not params.get("values") is Dictionary:
		return fail("values must be an object")
	return await set_parameters(params.values)

## Parameter changes are recorded as the user interface does (graph diffs
## do not work for remote parameters, that also change other nodes)
func set_parameters(values : Dictionary):
	var graph : MMGenGraph = await get_graph()
	var targets : Array[Dictionary] = []
	for k in values.keys():
		var p : Dictionary = MMCliTools.resolve_parameter(graph, k)
		if p.has("error"):
			return fail(p.error)
		p.value = values[k]
		targets.append(p)
	var undo_actions : Array = []
	var redo_actions : Array = []
	for target in targets:
		var generator : MMGenBase = target.generator
		var parameter : String = target.parameter
		var node_hier_name : String = generator.get_hier_name()
		undo_actions.append({ type="setparams", node=node_hier_name, params={ parameter: MMType.serialize_value(generator.get_parameter(parameter)) } })
		generator.set_parameter(parameter, MMType.deserialize_value(target.value))
		redo_actions.append({ type="setparams", node=node_hier_name, params={ parameter: MMType.serialize_value(generator.get_parameter(parameter)) } })
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit != null:
		graph_edit.undoredo.add("Set parameters", undo_actions, redo_actions)
		graph_edit.send_changed_signal()
	return true

## Creates a node from a generator type (e.g. "perlin"), a library item (as
## stored in library files) or a library item path (e.g. "Noise/Voronoi",
## main window only)
func api_create_node(params : Dictionary):
	if params.has("item"):
		if not params.item is Dictionary:
			return fail("item must be an object")
	elif not require(params, [ "type" ]):
		return null
	if not params.get("parameters", {}) is Dictionary:
		return fail("parameters must be an object")
	if params.has("name") and not params.name is String:
		return fail("name must be a string")
	var position : Vector2 = Vector2()
	if params.has("position"):
		var p = params.position
		if not p is Array or p.size() != 2 or not (p[0] is float or p[0] is int) or not (p[1] is float or p[1] is int):
			return fail("position must be an array of 2 numbers")
		position = Vector2(p[0], p[1])
	var data : Dictionary = { type=params.get("type", ""), parameters=params.get("parameters", {}) }
	if params.has("item"):
		data = params.item.duplicate(true)
	elif mm_globals.main_window != null:
		var item = mm_globals.main_window.node_library_manager.get_item(params.type)
		if item != null:
			data = item.item.duplicate(true)
	# (the loader recognizes remote nodes by their widgets, that new ones
	# don't have yet)
	if data.get("type") == "remote" and not data.has("widgets"):
		data.widgets = []
	if params.has("name"):
		data.name = params.name
	# (the hash of a library item is computed before a node is created from it)
	var library_hash : String = MMLibraryInstances.definition_hash(data) if data.has("tree_item") and data.has("type") and MMLibraryInstances.embeds_definition(data) else ""
	return await change_graph("Create node", func(graph : MMGenGraph):
		# Items with a type are a single node (graph nodes also have nodes)
		var nodes : Dictionary
		if data.has("type"):
			nodes = await mm_loader.add_to_gen_graph(graph, [ data ], [], position)
		else:
			nodes = await mm_loader.add_to_gen_graph(graph, data.get("nodes", []), data.get("connections", []), position)
		# (graph files keep nodes of unknown types as placeholders, but new
		# nodes must have a known type)
		for g in nodes.generators:
			if g is MMGenMissing:
				for n in nodes.generators:
					graph.remove_generator(n)
				return fail("cannot create node of type '%s'" % g.get_type())
		if nodes.generators.is_empty():
			return fail("cannot create node of type '%s'" % data.get("type", ""))
		var generator : MMGenBase = nodes.generators[0]
		if library_hash != "":
			MMLibraryInstances.tag(generator, data, library_hash)
		for p in params.get("parameters", {}).keys():
			generator.set_parameter(p, MMType.deserialize_value(params.parameters[p]))
		return generator.name)

func api_delete_node(params : Dictionary):
	if not require(params, [ "node" ]):
		return null
	return await change_graph("Delete node", func(graph : MMGenGraph):
		var generator : MMGenBase = get_generator(graph, params.node)
		if generator == null:
			return null
		if not graph.remove_generator(generator):
			return fail("cannot delete node '%s'" % params.node)
		return true)

func api_connect(params : Dictionary):
	if not require(params, [ "from", "to" ]):
		return null
	var from_port : int = get_int(params, "from_port", 0)
	var to_port : int = get_int(params, "to_port", 0)
	if method_error != "":
		return null
	return await change_graph("Connect nodes", func(graph : MMGenGraph):
		var from : MMGenBase = get_generator(graph, params.from)
		var to : MMGenBase = get_generator(graph, params.to)
		if from == null or to == null:
			return null
		# Same ports as in the graph editor (the Material node's outputs are
		# only used for previews and cannot be connected)
		var output_count : int = from.get_output_defs().size()
		if from_port < 0 or from_port >= output_count:
			return fail("node '%s' has no output %d (it has %d)" % [ params.from, from_port, output_count ])
		var input_count : int = to.get_input_defs().size()
		if to_port < 0 or to_port >= input_count:
			return fail("node '%s' has no input %d (it has %d)" % [ params.to, to_port, input_count ])
		if not graph.connect_children(from, from_port, to, to_port):
			return fail("cannot connect %s to %s" % [ params.from, params.to ])
		return true)

func api_disconnect(params : Dictionary):
	if not require(params, [ "from", "to" ]):
		return null
	var from_port : int = get_int(params, "from_port", 0)
	var to_port : int = get_int(params, "to_port", 0)
	if method_error != "":
		return null
	return await change_graph("Disconnect nodes", func(graph : MMGenGraph):
		# (disconnect_children_by_name always returns true)
		if not graph.connections.any(func(c): return c.from == params.from and int(c.from_port) == from_port and c.to == params.to and int(c.to_port) == to_port):
			return fail("%s is not connected to %s" % [ params.from, params.to ])
		graph.disconnect_children_by_name(params.from, from_port, params.to, to_port)
		return true)

# Presets (of the remote nodes of the current graph)

## The remote node given by the optional "node" parameter, or the only remote
## node of the graph (sets an error and returns null if there is none)
func get_remote_node(graph : MMGenGraph, params : Dictionary) -> MMGenRemote:
	if params.has("node"):
		if not require(params, [ "node" ]):
			return null
		var generator : MMGenBase = get_generator(graph, params.node)
		if generator != null and not generator is MMGenRemote:
			fail("node '%s' is not a remote node" % params.node)
			return null
		return generator as MMGenRemote
	var remotes : Array[MMGenRemote] = MMCliTools.get_remote_nodes(graph)
	if remotes.is_empty():
		fail("the graph has no remote node")
		return null
	if remotes.size() > 1:
		fail("the graph has several remote nodes (%s), choose one with 'node'" % ", ".join(PackedStringArray(remotes.map(func(r): return r.name))))
		return null
	return remotes[0]

## Applies a change to remote nodes, recorded (as one step) as the user
## interface does, and updates their preset lists
func change_remote_nodes(action_name : String, remotes : Array, change : Callable) -> void:
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit != null:
		graph_edit.undoredo.start_group()
	for r : MMGenRemote in remotes:
		var prev : Dictionary = r.serialize().duplicate(true)
		change.call(r)
		if graph_edit != null:
			graph_edit.undoredo_create_step(action_name, r.get_hier_name(), prev, r.serialize().duplicate(true))
			var node : Node = graph_edit.get_node_or_null(NodePath("node_"+r.name))
			if node != null and node.has_method("update_preset_list"):
				node.update_preset_list()
	if graph_edit != null:
		graph_edit.undoredo.end_group()
		graph_edit.send_changed_signal()

func api_list_presets(_params : Dictionary):
	return Array(MMCliTools.get_preset_names(await get_graph()))

## Applies a preset to all the remote nodes that have it
func api_apply_preset(params : Dictionary):
	if not require(params, [ "name" ]):
		return null
	var graph : MMGenGraph = await get_graph()
	var remotes : Array = MMCliTools.get_remote_nodes(graph).filter(func(r): return r.presets.has(params.name))
	if remotes.is_empty():
		var presets : PackedStringArray = MMCliTools.get_preset_names(graph)
		return fail("no preset '%s' (presets: %s)" % [ params.name, ", ".join(presets) if not presets.is_empty() else "none" ])
	change_remote_nodes("Apply preset", remotes, func(r): r.apply_preset(params.name))
	return true

## Saves the current values of a remote node as a preset (an existing preset
## with this name is replaced)
func api_save_preset(params : Dictionary):
	if not require(params, [ "name" ]):
		return null
	var preset_name : String = params.name.strip_edges()
	if preset_name == "":
		return fail("the preset name is empty")
	var remote : MMGenRemote = get_remote_node(await get_graph(), params)
	if remote == null:
		return null
	change_remote_nodes("Save preset", [ remote ], func(r): r.save_preset(preset_name))
	return true

## Deletes a preset of a remote node (by default, of all the remote nodes
## that have it)
func api_delete_preset(params : Dictionary):
	if not require(params, [ "name" ]):
		return null
	var graph : MMGenGraph = await get_graph()
	var remotes : Array = MMCliTools.get_remote_nodes(graph)
	if params.has("node"):
		var remote : MMGenRemote = get_remote_node(graph, params)
		if remote == null:
			return null
		remotes = [ remote ]
	remotes = remotes.filter(func(r): return r.presets.has(params.name))
	if remotes.is_empty():
		return fail("no preset '%s'" % params.name)
	change_remote_nodes("Delete preset", remotes, func(r): r.delete_preset(params.name))
	return true

## Sets random values to the parameters of a remote node (by default, of all
## the remote nodes, each with the next seed), and returns the seed
func api_randomize_parameters(params : Dictionary):
	var random_seed : int = get_int(params, "seed", randi())
	if method_error != "":
		return null
	var graph : MMGenGraph = await get_graph()
	var remotes : Array = MMCliTools.get_remote_nodes(graph)
	if params.has("node"):
		var remote : MMGenRemote = get_remote_node(graph, params)
		if remote == null:
			return null
		remotes = [ remote ]
	if remotes.is_empty():
		return fail("the graph has no remote node")
	change_remote_nodes("Randomize parameters", remotes, func(r): r.randomize_parameters(random_seed+remotes.find(r)))
	return random_seed

## Changes the seeds of all nodes that are not locked (cannot be undone)
func api_reseed(params : Dictionary):
	var offset : int = get_int(params, "offset", 1)
	if method_error != "":
		return null
	MMCliTools.reseed(await get_graph(), offset)
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit != null:
		graph_edit.send_changed_signal()
	return true

func api_render(params : Dictionary):
	if not require(params, [ "node", "path" ]):
		return null
	var output : int = get_int(params, "output", 0)
	var size : int = get_int(params, "size", 1024)
	var height : int = get_int(params, "height", 0)
	if method_error != "":
		return null
	if size <= 0 or height < 0:
		return fail("incorrect size %d" % size if size <= 0 else "incorrect height %d" % height)
	var graph : MMGenGraph = await get_graph()
	DirAccess.make_dir_recursive_absolute(params.path.get_base_dir())
	await MMCliTools.wait_for_renders(get_tree())
	var error : String = await MMCliTools.render_node(graph, "%s:%d" % [ params.node, output ], size, params.path, height)
	if error == "":
		var failed : PackedStringArray = mm_deps.get_failed_buffers(graph)
		if not failed.is_empty():
			error = "buffers failed to render: "+", ".join(failed)
	return fail(error) if error != "" else params.path

func get_preview_3d():
	if mm_globals.main_window == null:
		fail("The 3D preview requires the GUI")
		return null
	return mm_globals.main_window.get_panel("Preview3D")

## The 3D preview, once params has the required path and renders are done
## (null after an error)
func prepare_preview(params : Dictionary):
	if not require(params, [ "path" ]):
		return null
	var preview = get_preview_3d()
	if preview != null:
		await MMCliTools.wait_for_renders(get_tree())
	return preview

## Path traced render of the 3D preview's object (PNG, or linear EXR)
func api_render_path_traced(params : Dictionary):
	var size : int = get_int(params, "size", 512)
	var samples : int = get_int(params, "samples", 64)
	if method_error != "":
		return null
	if size <= 0 or samples <= 0:
		return fail("incorrect size %d" % size if size <= 0 else "incorrect samples %d" % samples)
	var preview = await prepare_preview(params)
	if preview == null:
		return null
	DirAccess.make_dir_recursive_absolute(params.path.get_base_dir())
	var error : String = await preview.render_path_traced(params.path, Vector2i(size, size), samples, bool(params.get("transparent", false)), Callable(), bool(params.get("thin_walled", false)))
	return fail(error) if error != "" else params.path

## Turntable of the 3D preview's object, as a sprite sheet or a PNG sequence
## (when the path contains #)
func api_render_turntable(params : Dictionary):
	var size : int = get_int(params, "size", 256)
	var frames : int = get_int(params, "frames", 36)
	if method_error != "":
		return null
	if size <= 0 or frames <= 0:
		return fail("incorrect size %d" % size if size <= 0 else "incorrect frames %d" % frames)
	var preview = await prepare_preview(params)
	if preview == null:
		return null
	DirAccess.make_dir_recursive_absolute(params.path.get_base_dir())
	var images : Array[Image] = await preview.render_turntable(frames, Vector2i(size, size))
	var error : String = preview.save_turntable(images, params.path)
	return fail(error) if error != "" else params.path

## The plugins (see MMPlugins), and the RPC methods and commands they add
func api_list_plugins(_params : Dictionary):
	var plugins : Array = []
	for p in MMPlugins.plugins:
		plugins.append({ id=p.id, name=p.name, version=p.version, enabled=p.enabled, depends=p.depends, error=p.error, path=ProjectSettings.globalize_path(p.path) })
	return { plugins=plugins, rpc_methods=MMPlugins.rpc_methods.keys(), commands=MMPlugins.commands.keys() }

func get_material(graph : MMGenGraph) -> MMGenBase:
	return MMCliTools.find_material_node(MMCliTools.get_top_graph(graph))

## Buffers that are not rendered yet (or failed), to diagnose renders that
## never finish
func api_render_queue(_params : Dictionary):
	var queue : Array = []
	for b in mm_deps.buffers.keys():
		var buffer = mm_deps.buffers[b]
		if buffer.status == buffer.Updated:
			continue
		var pending : Array = []
		for d in buffer.dependencies:
			if mm_deps.buffers.has(d) and mm_deps.buffers[d].status != buffer.Updated:
				pending.append(d)
		var object_name : String = ""
		if is_instance_valid(buffer.object) and buffer.object.has_method("get_hier_name"):
			object_name = buffer.object.get_hier_name()
		queue.append({ name=b, node=object_name, status=buffer.STATUS[buffer.status], pending=pending })
	return queue

func api_list_export_targets(_params : Dictionary):
	var material : MMGenBase = get_material(await get_graph())
	return material.get_export_profiles() if material != null else []

## Exports the material, prefix being the path of the exported files
## without extension
func api_export(params : Dictionary):
	if not require(params, [ "target", "prefix" ]):
		return null
	var size : int = get_int(params, "size", 0)
	var height : int = get_int(params, "height", 0)
	if method_error != "":
		return null
	if size < 0 or height < 0:
		return fail("incorrect size %d" % size if size < 0 else "incorrect height %d" % height)
	var material : MMGenBase = get_material(await get_graph())
	if material == null:
		return fail("the graph has no material node")
	if not params.target in material.get_export_profiles():
		return fail("unknown export target '%s'" % params.target)
	# UDIM tiles: a list ("1001-1004,1011" or an array), or true for the
	# graph's tiles
	var tiles : PackedInt32Array = PackedInt32Array()
	var udim = params.get("udim", false)
	if udim is bool:
		if udim:
			tiles = material.get_graph_udim_tiles()
	elif udim is String or udim is Array:
		if udim is Array:
			for t in udim:
				if not (t is int or t is float):
					return fail("UDIM tiles must be numbers")
		tiles = MMCliTools.parse_udim_tiles(",".join(udim.map(func(t): return str(int(t)))) if udim is Array else udim)
		if tiles.is_empty():
			return fail("invalid UDIM tiles '%s' (e.g. \"1001-1004,1011\", from 1001 to 1999)" % str(udim))
	else:
		return fail("parameter 'udim' must be a boolean, a string or a list")
	DirAccess.make_dir_recursive_absolute(params.prefix.get_base_dir())
	await MMCliTools.wait_for_renders(get_tree())
	await material.export_material(params.prefix, params.target, size, true, height, tiles)
	return true

func api_undo(_params : Dictionary):
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit == null:
		return fail("undo is only available with the user interface")
	graph_edit.undoredo.undo()
	return true

func api_redo(_params : Dictionary):
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit == null:
		return fail("redo is only available with the user interface")
	graph_edit.undoredo.redo()
	return true

## Quits Material Maker (only when there is no main window)
func api_quit(_params : Dictionary):
	if mm_globals.main_window != null:
		return fail("quit is only available in --rpc mode")
	get_tree().quit.call_deferred()
	return true
