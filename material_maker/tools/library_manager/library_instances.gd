extends RefCounted
class_name MMLibraryInstances


# Versioning of nodes created from library items that embed their definition
# (graphs and custom shaders saved in a library). Each such node remembers
# the library item it comes from, a hash of the item's definition, and a hash
# of its own definition when it was created. This makes it possible to list
# the instances whose library item changed (outdated) and those that were
# edited locally, and to update them while keeping their parameter values
# and connections.


# Keys that are not part of a node's definition
const NON_DEFINITION_KEYS : Array[String] = [
	"display_name", "icon", "icon_data", "tree_item", "name", "node_position",
	"parameters", "seed", "seed_int", "seed_locked", "preview", "minimized",
	"library_source", "scroll_offset"
]


## Returns true if a library item (or node data) embeds its definition
static func embeds_definition(data : Dictionary) -> bool:
	return data.has("nodes") or data.has("shader_model")

static func definition_hash(data : Dictionary) -> String:
	return JSON.stringify(strip_definition(data), "", true).md5_text()

## Removes the keys that are not part of the definition, at all levels
## (parameter values of the nodes of a graph change with the graph's own
## parameters)
static func strip_definition(value):
	if value is Dictionary:
		var rv : Dictionary = {}
		for k in value.keys():
			if not k in NON_DEFINITION_KEYS:
				rv[k] = strip_definition(value[k])
		return rv
	elif value is Array:
		return value.map(strip_definition)
	return value

## Remembers which library item a newly created generator comes from
static func tag(generator : MMGenBase, item : Dictionary) -> void:
	generator.library_source = {
		item=item.tree_item,
		hash=definition_hash(item),
		instance_hash=definition_hash(generator.serialize())
	}

static func collect_instances(generator : Node, rv : Array) -> void:
	for c in generator.get_children():
		if c is MMGenBase:
			if not c.library_source.is_empty():
				rv.append(c)
			collect_instances(c, rv)

## Returns { status, item } for an instance: status is "up to date",
## "outdated", "modified" (edited locally), "outdated, modified" or "missing"
## (the library item does not exist anymore)
static func get_status(generator : MMGenBase, library_manager) -> Dictionary:
	var source : Dictionary = generator.library_source
	var library_item = library_manager.get_item(source.item)
	if library_item == null or not embeds_definition(library_item.item):
		return { status="missing", item=null }
	var outdated : bool = definition_hash(library_item.item) != source.hash
	var modified : bool = definition_hash(generator.serialize()) != source.instance_hash
	var status : String = "up to date"
	if outdated and modified:
		status = "outdated, modified"
	elif outdated:
		status = "outdated"
	elif modified:
		status = "modified"
	return { status=status, item=library_item.item }

## Replaces an instance with the current version of its library item,
## keeping its name, position, parameter values, seed and connections.
## The change is a single undoable step of graph_edit.
static func update_instance(generator : MMGenBase, item : Dictionary, graph_edit) -> void:
	var parent : MMGenGraph = generator.get_parent()
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
	var connections : Array = []
	for c in parent.connections:
		if c.from == old_data.name or c.to == old_data.name:
			connections.append(c.duplicate(true))
	var parent_path : String = parent.get_hier_name()
	var undo_actions : Array = [
		{ type="remove_generators", parent=parent_path, generators=[ old_data.name ] },
		{ type="add_to_graph", parent=parent_path, generators=[ old_data ], connections=connections } ]
	var redo_actions : Array = [
		{ type="remove_generators", parent=parent_path, generators=[ old_data.name ] },
		{ type="add_to_graph", parent=parent_path, generators=[ new_data ], connections=connections } ]
	for a in redo_actions:
		await graph_edit.undoredo_command(a)
	# The new instance's own hash can only be computed once it exists
	var new_generator = parent.get_node_or_null(NodePath(old_data.name))
	if new_generator != null:
		new_generator.library_source.instance_hash = definition_hash(new_generator.serialize())
		redo_actions[1].generators = [ new_generator.serialize() ]
	graph_edit.undoredo.add("Update library instance", undo_actions, redo_actions)
	graph_edit.set_need_save()
