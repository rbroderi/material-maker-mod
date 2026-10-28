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
	"library_source", "scroll_offset"
]

# Keys of the nodes of a graph that are not part of its definition (their
# names are, since connections use them)
const NODE_LAYOUT_KEYS : Array[String] = [
	"node_position", "seed", "seed_int", "seed_locked", "preview", "minimized",
	"library_source", "scroll_offset"
]

# Version of the hashes of library_source records. Records without a version
# were hashed by legacy_definition_hash(), and are still compared with it.
const HASH_VERSION : int = 2


## Returns true if a library item (or node data) embeds its definition (an
## empty one, such as the Custom Shader item, is a starting point, not a
## definition)
static func embeds_definition(data : Dictionary) -> bool:
	var nodes = data.get("nodes", [])
	var shader_model = data.get("shader_model", {})
	return (nodes is Array and not nodes.is_empty()) or (shader_model is Dictionary and not shader_model.is_empty())

## A hash of the definition of a library item or instance. The parameter
## values of the nodes inside a graph and the shader model (including its
## parameter definitions) are part of a library item's definition. For an
## instance, the parameters its own parameters control (through the remote
## nodes of the graph) are not, since they change with the instance's
## parameters.
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

## The parameters of the nodes of a graph that are controlled by the widgets
## of its remote nodes, as "node/parameter" keys
static func get_controlled_parameters(nodes : Array, rv : Dictionary = {}) -> Dictionary:
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
						rv["%s/%s" % [ l.get("node", ""), l.get("widget", "") ]] = true
	return rv

static func strip_nodes(nodes, controlled_parameters : bool):
	if not nodes is Array:
		return nodes
	var controlled : Dictionary = {} if controlled_parameters else get_controlled_parameters(nodes)
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

## The hash of library_source records without a version, that ignored the
## parameter values of inner nodes and the parameter definitions of shaders
static func legacy_definition_hash(data : Dictionary) -> String:
	return JSON.stringify(legacy_strip_definition(data), "", true).md5_text()

## Removes the keys that are not part of the definition at all levels (see
## legacy_definition_hash). For diffs, node names and shader models are kept
## as they are.
static func legacy_strip_definition(value, for_diff : bool = false):
	if value is Dictionary:
		var rv : Dictionary = {}
		for k in value.keys():
			if for_diff and k == "shader_model":
				rv[k] = value[k]
			elif (for_diff and k == "name") or not k in NON_DEFINITION_KEYS:
				rv[k] = legacy_strip_definition(value[k], for_diff)
		return rv
	elif value is Array:
		return value.map(func(v): return legacy_strip_definition(v, for_diff))
	return value

## Remembers which library item a newly created generator comes from.
## item_hash is the hash of the item computed before the generator was
## created from it (creating a node can change the data it is created from).
static func tag(generator : MMGenBase, item : Dictionary, item_hash : String = "") -> void:
	generator.library_source = {
		item=item.tree_item,
		hash=item_hash if item_hash != "" else definition_hash(item),
		instance_hash=instance_hash(generator),
		version=HASH_VERSION
	}

static func collect_instances(generator : Node) -> Array:
	return MMCliTools.collect_generators(generator, func(g): return not g.library_source.is_empty())

## Returns { status, item } for an instance: status is "up to date",
## "outdated", "modified" (edited locally), "outdated, modified" or "missing"
## (the library item does not exist anymore)
static func get_status(generator : MMGenBase, library_manager) -> Dictionary:
	var source : Dictionary = generator.library_source
	var library_item = library_manager.get_item(source.get("item", ""))
	if library_item == null or not embeds_definition(library_item.item):
		return { status="missing", item=null }
	var outdated : bool
	var modified : bool
	if int(source.get("version", 1)) >= HASH_VERSION:
		outdated = definition_hash(library_item.item) != source.get("hash", "")
		modified = instance_hash(generator) != source.get("instance_hash", "")
	else:
		outdated = legacy_definition_hash(library_item.item) != source.get("hash", "")
		modified = legacy_definition_hash(generator.serialize()) != source.get("instance_hash", "")
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
	new_data.library_source = { item=item.tree_item, hash=definition_hash(item), instance_hash="", version=HASH_VERSION }
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


#
# Differences between an instance and its library item
#

## Describes, line by line, the changes that updating an instance would make
## to its definition (nodes, connections, parameters, inputs, outputs and code)
static func describe_changes(old_data : Dictionary, new_data : Dictionary) -> PackedStringArray:
	var changes : PackedStringArray = PackedStringArray()
	diff_definitions(legacy_strip_definition(old_data, true), legacy_strip_definition(new_data, true), "", changes)
	return changes

## The items of a list by name (key(item, index) for items without a name)
static func by_name(list : Array, key : Callable) -> Dictionary:
	var rv : Dictionary = {}
	for i in list.size():
		rv[list[i].get("name", key.call(list[i], i))] = list[i]
	return rv

## Compares lists of named items: { added, removed, changed } names (added and
## changed in the order of the new list, removed in the order of the old one)
static func diff_by_name(old_items : Dictionary, new_items : Dictionary) -> Dictionary:
	var rv : Dictionary = { added=[], removed=[], changed=[] }
	for n in new_items.keys():
		if not old_items.has(n):
			rv.added.append(n)
		elif JSON.stringify(old_items[n], "", true) != JSON.stringify(new_items[n], "", true):
			rv.changed.append(n)
	for n in old_items.keys():
		if not new_items.has(n):
			rv.removed.append(n)
	return rv

static func diff_definitions(old_data : Dictionary, new_data : Dictionary, prefix : String, changes : PackedStringArray) -> void:
	# Graphs: nodes by name, and connections
	if old_data.has("nodes") or new_data.has("nodes"):
		var old_nodes : Dictionary = by_name(old_data.get("nodes", []), func(_n, i): return str(i))
		var new_nodes : Dictionary = by_name(new_data.get("nodes", []), func(_n, i): return str(i))
		var nodes_diff : Dictionary = diff_by_name(old_nodes, new_nodes)
		for n in nodes_diff.added:
			changes.append("%s+ node %s (%s)" % [ prefix, n, new_nodes[n].get("type", "") ])
		for n in nodes_diff.removed:
			changes.append("%s- node %s (%s)" % [ prefix, n, old_nodes[n].get("type", "") ])
		for n in nodes_diff.changed:
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
	var old_items : Dictionary = by_name(old_list, func(i, _index): return JSON.stringify(i))
	var new_items : Dictionary = by_name(new_list, func(i, _index): return JSON.stringify(i))
	var items_diff : Dictionary = diff_by_name(old_items, new_items)
	for n in items_diff.added:
		changes.append("%s+ %s %s" % [ prefix, what, n ])
	for n in items_diff.removed:
		changes.append("%s- %s %s" % [ prefix, what, n ])
	for n in items_diff.changed:
		var fields : Array = []
		for k in new_items[n].keys():
			if old_items[n].get(k) != new_items[n][k]:
				fields.append("%s: %s -> %s" % [ k, JSON.stringify(old_items[n].get(k)), JSON.stringify(new_items[n][k]) ])
		for k in old_items[n].keys():
			if not new_items[n].has(k):
				fields.append("%s removed" % k)
		changes.append("%s~ %s %s (%s)" % [ prefix, what, n, ", ".join(fields) ])

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
