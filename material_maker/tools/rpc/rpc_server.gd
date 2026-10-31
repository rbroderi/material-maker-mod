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
	if not has_method(method_name):
		return make_error(id, ERROR_METHOD_NOT_FOUND, "Unknown method '%s'" % request.method)
	method_error = ""
	# (await must apply to the call itself for asynchronous methods)
	var result = await call(method_name, params)
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
		set_headless_graph(await mm_loader.create_gen({nodes=[{name="Material", type="material", parameters={size=11}}], connections=[]}))
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

## Creates a new material
func api_new_graph(_params : Dictionary):
	if mm_globals.main_window != null:
		mm_globals.main_window.new_material()
		await get_tree().process_frame
	else:
		set_headless_graph(null)
		await get_graph()
	return true

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
	return await change_graph("Create node", func(graph : MMGenGraph):
		# Items with a type are a single node (graph nodes also have nodes)
		var nodes : Dictionary
		if data.has("type"):
			nodes = await mm_loader.add_to_gen_graph(graph, [ data ], [], position)
		else:
			nodes = await mm_loader.add_to_gen_graph(graph, data.get("nodes", []), data.get("connections", []), position)
		if nodes.generators.is_empty():
			return fail("cannot create node of type '%s'" % data.get("type", ""))
		var generator : MMGenBase = nodes.generators[0]
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
		if not graph.connections.any(func(c): return c.from == params.from and int(c.from_port) == from_port and c.to == params.to and int(c.to_port) == to_port):
			return fail("%s is not connected to %s" % [ params.from, params.to ])
		graph.disconnect_children_by_name(params.from, from_port, params.to, to_port)
		return true)

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
	if method_error != "":
		return null
	if size <= 0:
		return fail("incorrect size %d" % size)
	var graph : MMGenGraph = await get_graph()
	DirAccess.make_dir_recursive_absolute(params.path.get_base_dir())
	await MMCliTools.wait_for_renders(get_tree())
	var error : String = await MMCliTools.render_node(graph, "%s:%d" % [ params.node, output ], size, params.path)
	if error == "":
		var failed : PackedStringArray = mm_deps.get_failed_buffers(graph)
		if not failed.is_empty():
			error = "buffers failed to render: "+", ".join(failed)
	return fail(error) if error != "" else params.path

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

func get_material(graph : MMGenGraph) -> MMGenBase:
	return MMCliTools.find_material_node(MMCliTools.get_top_graph(graph))

func api_list_export_targets(_params : Dictionary):
	var material : MMGenBase = get_material(await get_graph())
	return material.get_export_profiles() if material != null else []

## Exports the material, prefix being the path of the exported files
## without extension
func api_export(params : Dictionary):
	if not require(params, [ "target", "prefix" ]):
		return null
	var size : int = get_int(params, "size", 0)
	if method_error != "":
		return null
	if size < 0:
		return fail("incorrect size %d" % size)
	var material : MMGenBase = get_material(await get_graph())
	if material == null:
		return fail("the graph has no material node")
	if not params.target in material.get_export_profiles():
		return fail("unknown export target '%s'" % params.target)
	DirAccess.make_dir_recursive_absolute(params.prefix.get_base_dir())
	await MMCliTools.wait_for_renders(get_tree())
	await material.export_material(params.prefix, params.target, size, true)
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
