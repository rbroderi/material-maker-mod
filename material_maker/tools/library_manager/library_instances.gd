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
## legacy_definition_hash)
static func legacy_strip_definition(value):
	if value is Dictionary:
		var rv : Dictionary = {}
		for k in value.keys():
			if not k in NON_DEFINITION_KEYS:
				rv[k] = legacy_strip_definition(value[k])
		return rv
	elif value is Array:
		return value.map(func(v): return legacy_strip_definition(v))
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
# What updating an instance changes
#

# Line diffs of shader code longer than this are cut
const MAX_CODE_LINES : int = 12
# Above this size (lines of the old code times lines of the new code, once
# the lines they start and end with are removed), code is not diffed line by
# line
const MAX_LINE_DIFF_SIZE : int = 40000
# Longer values and code lines are cut
const MAX_VALUE_LENGTH : int = 60

## Describes, line by line, what updating an instance changes in its
## definition: its parameters, inputs, outputs and shader code, and the nodes
## and connections of graphs. old_data is the instance and new_data the
## updated instance (both serialized), item the library item. As for the
## hashes, the layout (positions, seeds, previews) is not part of the
## definition, and the values of the parameters, which updating keeps, are
## not changes. The parameters of a graph whose library default differs
## from the instance's value are listed at the end.
static func describe_changes(old_data : Dictionary, new_data : Dictionary, item : Dictionary = {}) -> PackedStringArray:
	var changes : PackedStringArray = PackedStringArray()
	diff_definitions(normalized(strip_definition(old_data)), normalized(strip_definition(new_data)), "", changes)
	# (the defaults of the parameters of a graph are the parameters of its
	# gen_parameters node)
	var defaults : Dictionary = {}
	for n in item.get("nodes", []):
		if n is Dictionary and n.get("name") == "gen_parameters" and n.get("parameters") is Dictionary:
			defaults = normalized(n.parameters)
	var values : Dictionary = normalized(old_data.get("parameters", {}))
	var kept : PackedStringArray = PackedStringArray()
	for p in defaults.keys():
		if values.has(p) and not same_value(values[p], defaults[p]):
			kept.append("    %s: library default %s, this node %s" % [ p, short(defaults[p]), short(values[p]) ])
	if not kept.is_empty():
		changes.append("Parameter values kept (their library default differs):")
		changes.append_array(kept)
	return changes

## A copy of a value as it would be loaded from a file (JSON numbers are
## floats), so that values compare the same whether they were loaded or not
static func normalized(value):
	return JSON.parse_string(JSON.stringify(value))

## Compares values, numbers approximately (the values of a library item are
## not rounded as those of a node are)
static func same_value(a, b) -> bool:
	if (a is float or a is int) and (b is float or b is int):
		return is_equal_approx(a, b)
	elif a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not same_value(a[i], b[i]):
				return false
		return true
	elif a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for k in a.keys():
			if not b.has(k) or not same_value(a[k], b[k]):
				return false
		return true
	return a == b

## Adds the changes between two stripped definitions (of an instance or of a
## node of a graph) to changes. controlled lists the parameters set by the
## remote nodes of the graph the node is in (see get_controlled_parameters),
## their values are the instance's.
static func diff_definitions(old_data : Dictionary, new_data : Dictionary, prefix : String, changes : PackedStringArray, controlled : Dictionary = {}) -> void:
	var node_name : String = new_data.get("name", old_data.get("name", ""))
	# Graphs: parameters, inputs and outputs (widgets of the gen_parameters
	# node and ports of the gen_inputs and gen_outputs nodes), the other
	# changes of nodes by name, and connections
	if old_data.has("nodes") or new_data.has("nodes"):
		var old_nodes : Dictionary = by_name(old_data.get("nodes", []))
		var new_nodes : Dictionary = by_name(new_data.get("nodes", []))
		var inner_controlled : Dictionary = get_controlled_parameters(old_data.get("nodes", []))
		get_controlled_parameters(new_data.get("nodes", []), inner_controlled)
		var special_nodes : Dictionary = { gen_parameters=[ "widgets", "parameter" ], gen_inputs=[ "ports", "input" ], gen_outputs=[ "ports", "output" ] }
		for n in special_nodes.keys():
			var key : String = special_nodes[n][0]
			diff_named_list(old_nodes.get(n, {}).get(key, []), new_nodes.get(n, {}).get(key, []), special_nodes[n][1], prefix, changes)
			for nodes in [ old_nodes, new_nodes ]:
				if nodes.has(n):
					nodes[n] = nodes[n].duplicate()
					nodes[n].erase(key)
					# (the parameters of gen_parameters are those of the graph)
					if n == "gen_parameters":
						nodes[n].erase("parameters")
		for n in new_nodes.keys():
			if not old_nodes.has(n):
				changes.append("%s+ node %s (%s)" % [ prefix, n, new_nodes[n].get("type", "") ])
		for n in old_nodes.keys():
			if not new_nodes.has(n):
				changes.append("%s- node %s (%s)" % [ prefix, n, old_nodes[n].get("type", "") ])
		for n in new_nodes.keys():
			if old_nodes.has(n) and old_nodes[n] != new_nodes[n]:
				var node_changes : PackedStringArray = PackedStringArray()
				diff_definitions(old_nodes[n], new_nodes[n], prefix+"    ", node_changes, inner_controlled)
				if not node_changes.is_empty():
					changes.append("%s~ node %s (%s)" % [ prefix, n, new_nodes[n].get("type", "") ])
					changes.append_array(node_changes)
		var old_connections : Array = old_data.get("connections", []).map(connection_text)
		var new_connections : Array = new_data.get("connections", []).map(connection_text)
		for c in new_connections:
			if not c in old_connections:
				changes.append("%s+ connection %s" % [ prefix, c ])
		for c in old_connections:
			if not c in new_connections:
				changes.append("%s- connection %s" % [ prefix, c ])
	# Parameter values of the nodes of a graph
	var old_parameters : Dictionary = old_data.get("parameters", {})
	var new_parameters : Dictionary = new_data.get("parameters", {})
	for p in new_parameters.keys():
		if not controlled.has("%s/%s" % [ node_name, p ]) and old_parameters.get(p) != new_parameters[p]:
			changes.append("%s%s: %s" % [ prefix, p, change_text(old_parameters, new_parameters, p) ])
	for p in old_parameters.keys():
		if not controlled.has("%s/%s" % [ node_name, p ]) and not new_parameters.has(p):
			changes.append("%s%s: %s" % [ prefix, p, change_text(old_parameters, new_parameters, p) ])
	# Shaders: parameters and inputs by name, outputs by index, and code line
	# by line
	var old_model : Dictionary = old_data.get("shader_model", {})
	var new_model : Dictionary = new_data.get("shader_model", {})
	if old_model != new_model:
		diff_named_list(old_model.get("parameters", []), new_model.get("parameters", []), "parameter", prefix, changes)
		diff_named_list(old_model.get("inputs", []), new_model.get("inputs", []), "input", prefix, changes)
		diff_indexed_list(old_model.get("outputs", []), new_model.get("outputs", []), "output", prefix, changes)
		for k in [ "global", "instance", "code", "includes" ]:
			diff_code(k, old_model.get(k, ""), new_model.get(k, ""), prefix, changes)
		diff_other_keys(old_model, new_model, [ "parameters", "inputs", "outputs", "global", "instance", "code", "includes" ], prefix+"shader ", changes)
	# Widgets of the other remote nodes
	diff_named_list(old_data.get("widgets", []), new_data.get("widgets", []), "widget", prefix, changes)
	diff_other_keys(old_data, new_data, [ "name", "nodes", "connections", "parameters", "shader_model", "widgets" ], prefix, changes)

static func diff_other_keys(old_data : Dictionary, new_data : Dictionary, ignored : Array, prefix : String, changes : PackedStringArray) -> void:
	for k in new_data.keys():
		if not k in ignored and old_data.get(k) != new_data[k]:
			changes.append("%s%s: %s" % [ prefix, k, change_text(old_data, new_data, k) ])
	for k in old_data.keys():
		if not k in ignored and not new_data.has(k):
			changes.append("%s%s: %s" % [ prefix, k, change_text(old_data, new_data, k) ])

## The items of a list by name (by index for those without a name)
static func by_name(list : Array) -> Dictionary:
	var rv : Dictionary = {}
	for i in list.size():
		if list[i] is Dictionary:
			rv[str(list[i].get("name", i))] = list[i]
	return rv

static func connection_text(c) -> String:
	if not c is Dictionary:
		return str(c)
	return "%s:%d -> %s:%d" % [ c.get("from", ""), int(c.get("from_port", 0)), c.get("to", ""), int(c.get("to_port", 0)) ]

## A value in one line, cut if it is too long
static func short(value) -> String:
	var text : String
	if value is Dictionary and value.get("type") == "Color":
		text = "Color(%s, %s, %s, %s)" % [ value.get("r"), value.get("g"), value.get("b"), value.get("a") ]
	elif value is Dictionary and value.has("type") and value.get("points") is Array:
		# (gradients, curves, polygons)
		text = "%s with %d points" % [ value.type, value.points.size() ]
	else:
		text = JSON.stringify(value)
	if text.length() > MAX_VALUE_LENGTH:
		text = text.left(MAX_VALUE_LENGTH-3)+"..."
	return text

## The change of a value of a dictionary, as "old -> new"
static func change_text(old_data : Dictionary, new_data : Dictionary, key) -> String:
	var old_text : String = short(old_data[key]) if old_data.has(key) else "(none)"
	var new_text : String = short(new_data[key]) if new_data.has(key) else "(none)"
	# (values that are different but look the same once cut)
	return "%s -> %s" % [ old_text, new_text ] if old_text != new_text else "%s, changed" % new_text

## A summary of a parameter, input, output or widget
static func summary(item : Dictionary) -> String:
	var parts : PackedStringArray = PackedStringArray()
	if item.has("label"):
		parts.append(short(item.label))
	if item.has("type"):
		parts.append(str(item.type))
	if item.has("min") and item.has("max"):
		parts.append("%s to %s" % [ short(item.min), short(item.max) ])
	if item.has("default"):
		parts.append("default %s" % short(item.default))
	if item.get("linked_widgets") is Array:
		parts.append("controls %s" % linked_text(item.linked_widgets))
	return " (%s)" % ", ".join(parts) if not parts.is_empty() else ""

static func linked_text(linked : Array) -> String:
	var rv : PackedStringArray = PackedStringArray()
	for l in linked:
		if l is Dictionary:
			rv.append("%s.%s" % [ l.get("node", ""), l.get("widget", "") ])
	return ", ".join(rv) if not rv.is_empty() else "nothing"

## The changed fields of a parameter, input, output or widget
static func diff_fields(old_item : Dictionary, new_item : Dictionary) -> PackedStringArray:
	var rv : PackedStringArray = PackedStringArray()
	for k in new_item.keys():
		if old_item.get(k) == new_item[k]:
			continue
		elif k == "linked_widgets" and new_item[k] is Array and old_item.get(k) is Array:
			rv.append("controls %s -> %s" % [ linked_text(old_item[k]), linked_text(new_item[k]) ])
		elif k == "configurations" and new_item[k] is Dictionary and old_item.get(k) is Dictionary:
			var configurations : PackedStringArray = PackedStringArray()
			for c in new_item[k].keys():
				if not old_item[k].has(c):
					configurations.append("+ "+str(c))
				elif old_item[k][c] != new_item[k][c]:
					configurations.append("~ "+str(c))
			for c in old_item[k].keys():
				if not new_item[k].has(c):
					configurations.append("- "+str(c))
			rv.append("configurations %s" % ", ".join(configurations))
		else:
			rv.append("%s: %s" % [ k, change_text(old_item, new_item, k) ])
	for k in old_item.keys():
		if not new_item.has(k):
			rv.append("%s: %s" % [ k, change_text(old_item, new_item, k) ])
	return rv

## Compares lists of named items (parameters, inputs, outputs, widgets)
static func diff_named_list(old_list, new_list, what : String, prefix : String, changes : PackedStringArray) -> void:
	if not old_list is Array or not new_list is Array or old_list == new_list:
		return
	var old_items : Dictionary = by_name(old_list)
	var new_items : Dictionary = by_name(new_list)
	for n in new_items.keys():
		if not old_items.has(n):
			changes.append("%s+ %s %s%s" % [ prefix, what, n, summary(new_items[n]) ])
	for n in old_items.keys():
		if not new_items.has(n):
			changes.append("%s- %s %s%s" % [ prefix, what, n, summary(old_items[n]) ])
	for n in new_items.keys():
		if old_items.has(n) and old_items[n] != new_items[n]:
			changes.append("%s~ %s %s: %s" % [ prefix, what, n, ", ".join(diff_fields(old_items[n], new_items[n])) ])
	if new_items.size() == old_items.size() and new_items.keys().all(func(n): return old_items.has(n)) and new_items.keys() != old_items.keys():
		changes.append("%s~ %s order: %s -> %s" % [ prefix, what, ", ".join(old_items.keys()), ", ".join(new_items.keys()) ])

## Compares lists of items that have no name (the outputs of shaders)
static func diff_indexed_list(old_list, new_list, what : String, prefix : String, changes : PackedStringArray) -> void:
	if not old_list is Array or not new_list is Array:
		return
	for i in maxi(old_list.size(), new_list.size()):
		var old_item = old_list[i] if i < old_list.size() and old_list[i] is Dictionary else {}
		var new_item = new_list[i] if i < new_list.size() and new_list[i] is Dictionary else {}
		if i >= old_list.size():
			changes.append("%s+ %s %d%s" % [ prefix, what, i, summary(new_item) ])
		elif i >= new_list.size():
			changes.append("%s- %s %d%s" % [ prefix, what, i, summary(old_item) ])
		elif old_item != new_item:
			changes.append("%s~ %s %d: %s" % [ prefix, what, i, ", ".join(diff_fields(old_item, new_item)) ])

## Compares code (a string, or an array of lines), line by line
static func diff_code(what : String, old_code, new_code, prefix : String, changes : PackedStringArray) -> void:
	var old_text : String = "\n".join(old_code) if old_code is Array else str(old_code)
	var new_text : String = "\n".join(new_code) if new_code is Array else str(new_code)
	if old_text == new_text:
		return
	# (an empty text has no lines)
	var lines : PackedStringArray = diff_lines(old_text.split("\n", old_text != ""), new_text.split("\n", new_text != ""))
	var added : int = 0
	for l in lines:
		if l.begins_with("+"):
			added += 1
	changes.append("%s~ %s: %d line(s) added, %d removed" % [ prefix, what, added, lines.size()-added ])
	for i in mini(lines.size(), MAX_CODE_LINES):
		var line : String = lines[i]
		changes.append(prefix+"    "+(line if line.length() <= MAX_VALUE_LENGTH+20 else line.left(MAX_VALUE_LENGTH+17)+"..."))
	if lines.size() > MAX_CODE_LINES:
		changes.append("%s    ... and %d more changed line(s)" % [ prefix, lines.size()-MAX_CODE_LINES ])

## Line diff (longest common subsequence), as "+ line" and "- line"
static func diff_lines(old_lines : PackedStringArray, new_lines : PackedStringArray) -> PackedStringArray:
	# Lines both start and end with
	var start : int = 0
	while start < old_lines.size() and start < new_lines.size() and old_lines[start] == new_lines[start]:
		start += 1
	var old_end : int = old_lines.size()
	var new_end : int = new_lines.size()
	while old_end > start and new_end > start and old_lines[old_end-1] == new_lines[new_end-1]:
		old_end -= 1
		new_end -= 1
	old_lines = old_lines.slice(start, old_end)
	new_lines = new_lines.slice(start, new_end)
	var n : int = old_lines.size()
	var m : int = new_lines.size()
	var rv : PackedStringArray = PackedStringArray()
	if n*m > MAX_LINE_DIFF_SIZE:
		for l in old_lines:
			rv.append("- "+l)
		for l in new_lines:
			rv.append("+ "+l)
		return rv
	var lcs : Array[PackedInt32Array] = []
	for i in n+1:
		var row : PackedInt32Array = PackedInt32Array()
		row.resize(m+1)
		lcs.append(row)
	for i in range(n-1, -1, -1):
		for j in range(m-1, -1, -1):
			lcs[i][j] = lcs[i+1][j+1]+1 if old_lines[i] == new_lines[j] else maxi(lcs[i+1][j], lcs[i][j+1])
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
