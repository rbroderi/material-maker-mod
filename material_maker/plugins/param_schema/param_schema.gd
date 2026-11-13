class_name MMParamSchema


# Describes the parameters of a graph as a JSON document, so tools that drive
# Material Maker (the Voxel material pipeline, scripts, other editors) know the
# names, types and ranges without loading the graph in the editor.

const FORMAT : String = "mm-param-schema"
const VERSION : int = 1

## The Voxel Inputs parameters, in the order of the schema: [ name, parameter ]
const VOXEL_INPUTS : Array = [
	[ "seed", "vox_seed" ], [ "age", "vox_age" ], [ "upkeep", "vox_upkeep" ],
	[ "fresh", "vox_fresh" ], [ "char", "vox_char" ], [ "wet", "vox_wet" ],
	[ "axis_x", "vox_axis_x" ], [ "axis_y", "vox_axis_y" ], [ "axis_z", "vox_axis_z" ],
	[ "origin_x", "vox_origin_x" ], [ "origin_y", "vox_origin_y" ], [ "origin_z", "vox_origin_z" ],
	[ "footprint", "vox_footprint" ],
]
const VOXEL_INPUTS_TYPE : String = "voxel_inputs"


## The schema of a graph (see the plan: format, version, graph, material,
## voxel_inputs, remotes and parameters)
static func build(graph : MMGenGraph) -> Dictionary:
	var schema : Dictionary = {
		"format": FORMAT,
		"version": VERSION,
		"graph": String(graph.name),
		"material": { "type": "", "inputs": [] },
		"voxel_inputs": [],
		"remotes": [],
		"parameters": [],
	}
	var material_found : bool = false
	for c in graph.get_children():
		if not c is MMGenBase:
			continue
		if c is MMGenRemote:
			schema.remotes.append_array(describe_remote(c))
			continue
		if c is MMGenMaterial and not material_found:
			material_found = true
			schema.material = describe_material(c)
		if get_node_type(c) == VOXEL_INPUTS_TYPE:
			schema.voxel_inputs.append_array(describe_voxel_inputs(c))
		for p in c.get_parameter_defs():
			schema.parameters.append(describe_parameter(c, p))
	return schema

## The schema as a string with sorted keys (the same graph gives the same string)
static func to_json(schema : Dictionary) -> String:
	return JSON.stringify(schema, "\t", true)

static func get_node_type(generator : MMGenBase) -> String:
	if generator.model is String:
		return generator.model
	return generator.get_type()

static func describe_material(material : MMGenBase) -> Dictionary:
	var inputs : Array = []
	var input_defs : Array = material.get_input_defs()
	for i in input_defs.size():
		inputs.append({ "name": input_defs[i].get("name", ""), "type": input_defs[i].get("type", ""), "connected": material.get_source(i) != null })
	var template = material.get_template_name()
	return { "type": template if template is String else material.get_type(), "inputs": inputs }

static func describe_voxel_inputs(generator : MMGenBase) -> Array:
	var rv : Array = []
	for entry in VOXEL_INPUTS:
		var def : Dictionary = generator.get_parameter_def(entry[1])
		if def.is_empty():
			continue
		var d : Dictionary = { "name": entry[0], "parameter": "%s:%s" % [ generator.name, entry[1] ], "type": def.get("type", "float") }
		add_range(d, def)
		rv.append(d)
	return rv

static func describe_parameter(generator : MMGenBase, def : Dictionary) -> Dictionary:
	var d : Dictionary = {
		"node": String(generator.name),
		"node_type": get_node_type(generator),
		"name": def.name,
		"label": def.get("label", ""),
		"type": def.get("type", ""),
		"value": convert_value(generator.get_parameter(def.name)),
	}
	add_range(d, def)
	return d

## One entry per widget of a remote
static func describe_remote(remote : MMGenRemote) -> Array:
	var defs : Dictionary = {}
	for p in remote.get_parameter_defs():
		defs[p.name] = p
	var rv : Array = []
	for w in remote.widgets:
		var def : Dictionary = defs.get(w.name, {})
		var d : Dictionary = {
			"name": w.name,
			"label": w.get("label", ""),
			"type": def.get("type", ""),
			"node": String(remote.name),
			"linked": [],
			"value": convert_value(remote.get_parameter(w.name)) if def.has("default") or remote.parameters.has(w.name) else null,
		}
		add_range(d, def)
		for l in w.get("linked_widgets", []):
			d.linked.append("%s:%s" % [ l.node, l.widget ])
		rv.append(d)
	return rv

## min, max, step, default and values of a parameter definition
static func add_range(d : Dictionary, def : Dictionary) -> void:
	for k in [ "min", "max", "step", "default" ]:
		if def.has(k):
			d[k] = convert_value(def[k])
	if def.has("values"):
		var values : Array = []
		for v in def.values:
			values.append({ "name": v.get("name", ""), "value": convert_value(v.get("value")) })
		d["values"] = values

## Colors are [r, g, b, a], other objects are serialized by MMType
static func convert_value(value):
	if value is Color:
		return [ value.r, value.g, value.b, value.a ]
	if value is Object:
		return MMType.serialize_value(value)
	return value
