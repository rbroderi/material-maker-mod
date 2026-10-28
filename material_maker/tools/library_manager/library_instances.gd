extends RefCounted
class_name MMLibraryInstances


# Versioning of nodes created from library items that embed their definition
# (graphs and custom shaders saved in a library). Each such node remembers
# the library item it comes from, a hash of the item's definition, and a hash
# of its own definition when it was created. This makes it possible to list
# the instances whose library item changed (outdated) and those that were
# edited locally, and to update them while keeping their parameter values
# and connections.


# Keys of a library item or instance that are not part of its definition
const NON_DEFINITION_KEYS : Array[String] = [
	"display_name", "icon", "icon_data", "tree_item", "name", "node_position",
	"parameters", "seed", "seed_int", "seed_locked", "preview", "minimized",
	"library_source"
]

# Keys of the nodes of a graph that are not part of its definition (their
# names are, since connections use them)
const NODE_LAYOUT_KEYS : Array[String] = [
	"node_position", "seed", "seed_int", "seed_locked", "preview", "minimized",
	"library_source"
]


## Returns true if a library item (or node data) embeds its definition (an
## empty one, such as the Custom Shader item, is a starting point, not a
## definition)
static func embeds_definition(data : Dictionary) -> bool:
	return not data.get("nodes", []).is_empty() or not data.get("shader_model", {}).is_empty()

## A hash of the definition of a library item or instance. The parameter
## values of the nodes inside a graph are part of a library item's definition.
## For an instance, those its own parameters control (through the remote nodes
## of the graph) are not, since they change with the instance's parameters.
static func definition_hash(data : Dictionary, controlled_parameters : bool = true) -> String:
	return JSON.stringify(strip_definition(data, controlled_parameters), "", true).md5_text()

## Removes the keys that are not part of the definition (shader models are
## kept as they are)
static func strip_definition(data : Dictionary, controlled_parameters : bool = true) -> Dictionary:
	var rv : Dictionary = {}
	for k in data.keys():
		if not k in NON_DEFINITION_KEYS:
			rv[k] = strip_nodes(data[k], controlled_parameters) if k == "nodes" else data[k]
	return rv

static func strip_nodes(nodes, controlled_parameters : bool):
	if not nodes is Array:
		return nodes
	# Parameters controlled by the widgets of remote nodes, as "node/parameter"
	var controlled : Dictionary = {}
	if not controlled_parameters:
		for n in nodes:
			if n is Dictionary and n.get("widgets") is Array:
				for w in n.widgets:
					if not w is Dictionary:
						continue
					var linked : Array = w.get("linked_widgets", []).duplicate()
					for c in w.get("configurations", {}).values():
						linked.append_array(c)
					for l in linked:
						if l is Dictionary:
							controlled["%s/%s" % [ l.get("node", ""), l.get("widget", "") ]] = true
	var rv : Array = []
	for n in nodes:
		if not n is Dictionary:
			rv.append(n)
			continue
		var node : Dictionary = {}
		for k in n.keys():
			if k in NODE_LAYOUT_KEYS:
				continue
			elif k == "nodes":
				node[k] = strip_nodes(n[k], controlled_parameters)
			elif k == "parameters" and not controlled_parameters and n[k] is Dictionary:
				# (the parameters of remote nodes are the instance's parameters)
				var parameters : Dictionary = {}
				if n.get("type") != "remote":
					for p in n[k].keys():
						if not controlled.has("%s/%s" % [ n.get("name", ""), p ]):
							parameters[p] = n[k][p]
				node[k] = parameters
			else:
				node[k] = n[k]
		rv.append(node)
	return rv

static func instance_hash(generator : MMGenBase) -> String:
	return definition_hash(generator.serialize(), false)

## Remembers which library item a newly created generator comes from
## (item_hash is the hash of the item before the generator was created from it)
static func tag(generator : MMGenBase, item : Dictionary, item_hash : String) -> void:
	generator.library_source = {
		item=item.tree_item,
		hash=item_hash,
		instance_hash=instance_hash(generator)
	}

## The nodes of a graph (including those inside groups) that were created
## from a library item
static func collect_instances(generator : Node, rv : Array = []) -> Array:
	for c in generator.get_children():
		if c is MMGenBase:
			if not c.library_source.is_empty():
				rv.append(c)
			collect_instances(c, rv)
	return rv

## Returns { status, item } for an instance: status is "up to date",
## "outdated", "modified" (edited locally), "outdated, modified" or "missing"
## (the library item does not exist anymore)
static func get_status(generator : MMGenBase, library_manager) -> Dictionary:
	var source : Dictionary = generator.library_source
	var library_item = library_manager.get_item(source.get("item", ""))
	if library_item == null or not embeds_definition(library_item.item):
		return { status="missing", item=null }
	var outdated : bool = definition_hash(library_item.item) != source.get("hash", "")
	var modified : bool = instance_hash(generator) != source.get("instance_hash", "")
	var status : String = "up to date"
	if outdated and modified:
		status = "outdated, modified"
	elif outdated:
		status = "outdated"
	elif modified:
		status = "modified"
	return { status=status, item=library_item.item }

## The data of an instance updated to the current version of its library
## item, keeping its name, position, parameter values and seed
static func get_updated_data(generator : MMGenBase, item : Dictionary) -> Dictionary:
	var old_data : Dictionary = generator.serialize()
	var new_data : Dictionary = item.duplicate(true)
	for k in [ "display_name", "icon", "icon_data", "tree_item" ]:
		new_data.erase(k)
	new_data.name = old_data.name
	new_data.node_position = old_data.node_position
	var parameters : Dictionary = new_data.get("parameters", {})
	for p in old_data.get("parameters", {}).keys():
		if parameters.has(p):
			parameters[p] = old_data.parameters[p]
	new_data.parameters = parameters
	for k in [ "seed", "seed_int", "seed_locked" ]:
		if old_data.has(k):
			new_data[k] = old_data[k]
		else:
			new_data.erase(k)
	new_data.library_source = { item=item.tree_item, hash=definition_hash(item), instance_hash="" }
	return new_data

## Replaces an instance with the current version of its library item,
## keeping its name, position, parameter values, seed and connections.
## The change is a single undoable step of graph_edit.
static func update_instance(generator : MMGenBase, item : Dictionary, graph_edit) -> void:
	var parent : MMGenGraph = generator.get_parent()
	var old_data : Dictionary = generator.serialize()
	var new_data : Dictionary = get_updated_data(generator, item)
	# Connections to ports the new version does not have are dropped
	var input_count : int = 0
	var output_count : int = 0
	var probe = await mm_loader.create_gen(new_data.duplicate(true))
	if probe != null:
		input_count = probe.get_input_defs().size()
		output_count = probe.get_output_defs().size()
		probe.free()
	var connections : Array = []
	var new_connections : Array = []
	for c in parent.connections:
		if c.from == old_data.name or c.to == old_data.name:
			connections.append(c.duplicate(true))
			if (c.from != old_data.name or c.from_port < output_count) and (c.to != old_data.name or c.to_port < input_count):
				new_connections.append(c.duplicate(true))
	var parent_path : String = parent.get_hier_name()
	var undo_actions : Array = [
		{ type="remove_generators", parent=parent_path, generators=[ old_data.name ] },
		{ type="add_to_graph", parent=parent_path, generators=[ old_data ], connections=connections } ]
	var redo_actions : Array = [
		{ type="remove_generators", parent=parent_path, generators=[ old_data.name ] },
		{ type="add_to_graph", parent=parent_path, generators=[ new_data ], connections=new_connections } ]
	for a in redo_actions:
		await graph_edit.undoredo_command(a)
	# The new instance's own hash can only be computed once it exists
	var new_generator = parent.get_node_or_null(NodePath(old_data.name))
	if new_generator != null:
		new_generator.library_source.instance_hash = instance_hash(new_generator)
		redo_actions[1].generators = [ new_generator.serialize() ]
	graph_edit.undoredo.add("Update library instance", undo_actions, redo_actions)
	graph_edit.set_need_save()
