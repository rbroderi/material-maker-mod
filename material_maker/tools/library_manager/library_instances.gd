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


#
# Differences between an instance and its library item
#

## Describes, line by line, the changes that updating an instance would make
## to its definition (nodes, connections, parameters, inputs, outputs and code)
static func describe_changes(old_data : Dictionary, new_data : Dictionary) -> PackedStringArray:
	var changes : PackedStringArray = PackedStringArray()
	diff_definitions(strip_for_diff(old_data), strip_for_diff(new_data), "", changes)
	return changes

## Like strip_definition, but keeps node names, and shader models as they are
## (their parameter definitions are part of the definition)
static func strip_for_diff(value):
	if value is Dictionary:
		var rv : Dictionary = {}
		for k in value.keys():
			if k == "shader_model":
				rv[k] = value[k]
			elif k == "name" or not k in NON_DEFINITION_KEYS:
				rv[k] = strip_for_diff(value[k])
		return rv
	elif value is Array:
		return value.map(strip_for_diff)
	return value

static func diff_definitions(old_data : Dictionary, new_data : Dictionary, prefix : String, changes : PackedStringArray) -> void:
	# Graphs: nodes by name, and connections
	if old_data.has("nodes") or new_data.has("nodes"):
		var old_nodes : Dictionary = {}
		var new_nodes : Dictionary = {}
		var index : int = 0
		for n in old_data.get("nodes", []):
			old_nodes[n.get("name", str(index))] = n
			index += 1
		index = 0
		for n in new_data.get("nodes", []):
			new_nodes[n.get("name", str(index))] = n
			index += 1
		for n in new_nodes.keys():
			if not old_nodes.has(n):
				changes.append("%s+ node %s (%s)" % [ prefix, n, new_nodes[n].get("type", "") ])
		for n in old_nodes.keys():
			if not new_nodes.has(n):
				changes.append("%s- node %s (%s)" % [ prefix, n, old_nodes[n].get("type", "") ])
			elif JSON.stringify(old_nodes[n], "", true) != JSON.stringify(new_nodes[n], "", true):
				changes.append("%s~ node %s (%s)" % [ prefix, n, new_nodes[n].get("type", "") ])
				diff_definitions(old_nodes[n], new_nodes[n], prefix+"    ", changes)
		var old_connections : Array = old_data.get("connections", []).map(connection_text)
		var new_connections : Array = new_data.get("connections", []).map(connection_text)
		for c in new_connections:
			if not c in old_connections:
				changes.append("%s+ connection %s" % [ prefix, c ])
		for c in old_connections:
			if not c in new_connections:
				changes.append("%s- connection %s" % [ prefix, c ])
	# Shaders: parameters, inputs and outputs by name, and code line by line
	var old_model : Dictionary = old_data.get("shader_model", {})
	var new_model : Dictionary = new_data.get("shader_model", {})
	for k in [ "parameters", "inputs", "outputs" ]:
		diff_named_list(old_model.get(k, []), new_model.get(k, []), k.left(-1), prefix, changes)
	for k in [ "global", "instance", "code", "includes" ]:
		var old_text : String = old_model.get(k, "") if not old_model.get(k) is Array else "\n".join(old_model.get(k))
		var new_text : String = new_model.get(k, "") if not new_model.get(k) is Array else "\n".join(new_model.get(k))
		if old_text != new_text:
			changes.append("%s~ %s:" % [ prefix, k ])
			for l in diff_lines(old_text.split("\n"), new_text.split("\n")):
				changes.append(prefix+"    "+l)
	for k in new_data.keys():
		if not k in [ "nodes", "connections", "shader_model", "library_source" ] and old_data.get(k) != new_data.get(k):
			changes.append("%s~ %s: %s -> %s" % [ prefix, k, JSON.stringify(old_data.get(k)), JSON.stringify(new_data.get(k)) ])

static func connection_text(c : Dictionary) -> String:
	return "%s:%d -> %s:%d" % [ c.get("from", ""), int(c.get("from_port", 0)), c.get("to", ""), int(c.get("to_port", 0)) ]

static func diff_named_list(old_list : Array, new_list : Array, what : String, prefix : String, changes : PackedStringArray) -> void:
	var old_items : Dictionary = {}
	for i in old_list:
		old_items[i.get("name", JSON.stringify(i))] = i
	var new_items : Dictionary = {}
	for i in new_list:
		new_items[i.get("name", JSON.stringify(i))] = i
	for n in new_items.keys():
		if not old_items.has(n):
			changes.append("%s+ %s %s" % [ prefix, what, n ])
		elif JSON.stringify(old_items[n], "", true) != JSON.stringify(new_items[n], "", true):
			var fields : Array = []
			for k in new_items[n].keys():
				if old_items[n].get(k) != new_items[n][k]:
					fields.append("%s: %s -> %s" % [ k, JSON.stringify(old_items[n].get(k)), JSON.stringify(new_items[n][k]) ])
			for k in old_items[n].keys():
				if not new_items[n].has(k):
					fields.append("%s removed" % k)
			changes.append("%s~ %s %s (%s)" % [ prefix, what, n, ", ".join(fields) ])
	for n in old_items.keys():
		if not new_items.has(n):
			changes.append("%s- %s %s" % [ prefix, what, n ])

## Line diff (longest common subsequence), as "+ line" and "- line"
static func diff_lines(old_lines : PackedStringArray, new_lines : PackedStringArray) -> PackedStringArray:
	var n : int = old_lines.size()
	var m : int = new_lines.size()
	var lcs : Array = []
	for i in n+1:
		var row : PackedInt32Array = PackedInt32Array()
		row.resize(m+1)
		lcs.append(row)
	for i in range(n-1, -1, -1):
		for j in range(m-1, -1, -1):
			lcs[i][j] = lcs[i+1][j+1]+1 if old_lines[i] == new_lines[j] else maxi(lcs[i+1][j], lcs[i][j+1])
	var rv : PackedStringArray = PackedStringArray()
	var i : int = 0
	var j : int = 0
	while i < n or j < m:
		if i < n and j < m and old_lines[i] == new_lines[j]:
			i += 1
			j += 1
		elif j < m and (i == n or lcs[i][j+1] >= lcs[i+1][j]):
			rv.append("+ "+new_lines[j])
			j += 1
		else:
			rv.append("- "+old_lines[i])
			i += 1
	return rv
