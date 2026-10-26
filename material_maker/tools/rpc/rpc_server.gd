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


func start(port : int) -> Error:
	var error : Error = server.listen(port, "127.0.0.1")
	if error == OK:
		print("JSON-RPC server listening on 127.0.0.1:%d" % port)
	else:
		printerr("Cannot start JSON-RPC server on port %d: %s" % [ port, error_string(error) ])
	return error

func _exit_tree() -> void:
	server.stop()

func _process(_delta : float) -> void:
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
	var params = request.get("params", {})
	if params is Array and params.is_empty():
		params = {}
	if not params is Dictionary:
		return make_error(id, ERROR_INVALID_PARAMS, "params must be an object")
	var method_name : String = "api_"+request.method
	if not has_method(method_name):
		return make_error(id, ERROR_METHOD_NOT_FOUND, "Unknown method '%s'" % request.method)
	method_error = ""
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

func require(params : Dictionary, names : Array) -> bool:
	for n in names:
		if not params.has(n):
			fail("missing parameter '%s'" % n)
			return false
	return true

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
		type=generator.get_type(),
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
	return MMCliTools.ENGINE_TEMPLATES.map(func(t): return t.name)

func api_list_templates(_params : Dictionary):
	return MMCliTools.ENGINE_TEMPLATES.map(func(t): return { name=t.name, export=t.export, description=t.description })

func api_load(params : Dictionary):
	if not require(params, [ "path" ]):
		return null
	if not FileAccess.file_exists(params.path):
		return fail("file '%s' not found" % params.path)
	if mm_globals.main_window != null:
		if not await mm_globals.main_window.do_load_material(params.path):
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
	if not require(params, [ "node", "parameter", "value" ]):
		return null
	return await set_parameters({ params.node+":"+params.parameter: params.value })

## Sets several parameters, given as { name: value } where names are remote
## parameter names or labels, or "node:parameter"
func api_set_parameters(params : Dictionary):
	if not require(params, [ "values" ]) or not params.values is Dictionary:
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
		targets.append(p)
	var undo_actions : Array = []
	var redo_actions : Array = []
	for i in targets.size():
		var generator : MMGenBase = targets[i].generator
		var parameter : String = targets[i].parameter
		var node_hier_name : String = generator.get_hier_name()
		undo_actions.append({ type="setparams", node=node_hier_name, params={ parameter: MMType.serialize_value(generator.get_parameter(parameter)) } })
		generator.set_parameter(parameter, MMType.deserialize_value(values.values()[i]))
		redo_actions.append({ type="setparams", node=node_hier_name, params={ parameter: MMType.serialize_value(generator.get_parameter(parameter)) } })
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit != null:
		graph_edit.undoredo.add("Set parameters", undo_actions, redo_actions)
		graph_edit.send_changed_signal()
	return true

## Creates a node from a generator type (e.g. "perlin") or a library item
## path (e.g. "Noise/Perlin", main window only)
func api_create_node(params : Dictionary):
	if not params.has("item") and not require(params, [ "type" ]):
		return null
	var data : Dictionary = { type=params.get("type", ""), parameters=params.get("parameters", {}) }
	if params.get("item") is Dictionary:
		# A library item, as stored in library files
		data = params.item.duplicate(true)
	elif mm_globals.main_window != null:
		var item = mm_globals.main_window.node_library_manager.get_item(params.type)
		if item != null:
			data = item.item.duplicate(true)
	if params.has("name"):
		data.name = params.name
	var position : Vector2 = Vector2(params.position[0], params.position[1]) if params.get("position") is Array else Vector2()
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
		if data.has("tree_item") and MMLibraryInstances.embeds_definition(data):
			MMLibraryInstances.tag(generator, data)
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
	return await change_graph("Connect nodes", func(graph : MMGenGraph):
		var from : MMGenBase = get_generator(graph, params.from)
		var to : MMGenBase = get_generator(graph, params.to)
		if from == null or to == null:
			return null
		if not graph.connect_children(from, int(params.get("from_port", 0)), to, int(params.get("to_port", 0))):
			return fail("cannot connect %s to %s" % [ params.from, params.to ])
		return true)

func api_disconnect(params : Dictionary):
	if not require(params, [ "from", "to" ]):
		return null
	return await change_graph("Disconnect nodes", func(graph : MMGenGraph):
		if not graph.disconnect_children_by_name(params.from, int(params.get("from_port", 0)), params.to, int(params.get("to_port", 0))):
			return fail("%s is not connected to %s" % [ params.from, params.to ])
		return true)

## Presets of the remote nodes of the current graph
func api_list_presets(_params : Dictionary):
	return Array(MMCliTools.get_preset_names(await get_graph()))

func api_apply_preset(params : Dictionary):
	if not require(params, [ "name" ]):
		return null
	return await change_graph("Apply preset", func(graph : MMGenGraph):
		return true if MMCliTools.apply_preset(graph, params.name) else fail("no preset '%s'" % params.name))

## Saves the current values of a remote node (the first one by default) as a preset
func api_save_preset(params : Dictionary):
	if not require(params, [ "name" ]):
		return null
	return await change_graph("Save preset", func(graph : MMGenGraph):
		for c in graph.get_children():
			if c is MMGenRemote and (not params.has("node") or c.name == params.node):
				c.save_preset(params.name)
				return true
		return fail("no remote node"))

## Sets random values to the parameters of the remote nodes
func api_randomize_parameters(params : Dictionary):
	return await change_graph("Randomize parameters", func(graph : MMGenGraph):
		var random_seed : int = int(params.get("seed", randi()))
		for c in graph.get_children():
			if c is MMGenRemote:
				c.randomize_parameters(random_seed)
				random_seed += 1
		return true)

## Changes the seeds of all nodes that are not locked (cannot be undone)
func api_reseed(params : Dictionary):
	MMCliTools.reseed(await get_graph(), int(params.get("offset", 1)))
	var graph_edit : MMGraphEdit = get_graph_edit()
	if graph_edit != null:
		graph_edit.send_changed_signal()
	return true

func api_render(params : Dictionary):
	if not require(params, [ "node", "path" ]):
		return null
	var graph : MMGenGraph = await get_graph()
	await MMCliTools.wait_for_renders(get_tree())
	var error : String = await MMCliTools.render_node(graph, "%s:%d" % [ params.node, int(params.get("output", 0)) ], int(params.get("size", 1024)), params.path)
	if error == "":
		var failed : PackedStringArray = mm_deps.get_failed_buffers(graph)
		if not failed.is_empty():
			error = "buffers failed to render: "+", ".join(failed)
	return fail(error) if error != "" else params.path

## Exports a 3D texture or SDF output as a volume (.vdb, .dds or .ktx2)
func api_export_volume(params : Dictionary):
	if not require(params, [ "node", "path" ]):
		return null
	var graph : MMGenGraph = await get_graph()
	var generator : MMGenBase = get_generator(graph, params.node)
	if generator == null:
		return null
	await MMCliTools.wait_for_renders(get_tree())
	var error : String = await MMVolumeExport.export_volume(generator, int(params.get("output", 0)), params.path, int(params.get("resolution", 128)), float(params.get("extent", 1.0)), params.get("texel_format", ""))
	return fail(error) if error != "" else params.path

func get_material(graph : MMGenGraph) -> MMGenBase:
	var top : Node = graph
	while top.get_parent() is MMGenGraph:
		top = top.get_parent()
	for c in top.get_children():
		if c.has_method("get_export_profiles"):
			return c
	return null

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
	var material : MMGenBase = get_material(await get_graph())
	if material == null:
		return fail("the graph has no material node")
	if not params.target in material.get_export_profiles():
		return fail("unknown export target '%s'" % params.target)
	DirAccess.make_dir_recursive_absolute(params.prefix.get_base_dir())
	await MMCliTools.wait_for_renders(get_tree())
	await material.export_material(params.prefix, params.target, int(params.get("size", 0)), true)
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

## Exports a runtime package (.mmr) of the material (size 0 is the material's size)
func api_export_mmr(params : Dictionary):
	if not require(params, [ "path" ]):
		return null
	var graph : MMGenGraph = await get_graph()
	var top : Node = graph
	while top.get_parent() is MMGenGraph:
		top = top.get_parent()
	DirAccess.make_dir_recursive_absolute(params.path.get_base_dir())
	await MMCliTools.wait_for_renders(get_tree())
	var errors : PackedStringArray = await MMRuntimeExporter.export_package(top, params.path, int(params.get("size", 0)))
	return fail(", ".join(errors)) if not errors.is_empty() else params.path

## Quits Material Maker (only when there is no main window)
func api_quit(_params : Dictionary):
	if mm_globals.main_window != null:
		return fail("quit is only available in --rpc mode")
	get_tree().quit.call_deferred()
	return true
