extends RefCounted
class_name MMCliTools


# Helpers for the command line modes (see parse_args.gd and
# material_maker/doc/command_line.rst): parameter overrides, reseeding,
# rendering node outputs and baking mesh maps.


const BAKE_MAPS : Array[String] = [ "position", "normal", "tangent", "ambient_occlusion", "bent_normals", "thickness", "curvature", "seams", "adjacency" ]
const DEFAULT_BAKE_MAPS : Array[String] = [ "ambient_occlusion", "curvature", "thickness", "normal", "position" ]


## Converts a command line value to a parameter value
static func parse_value(s : String):
	match s.to_lower():
		"true":
			return true
		"false":
			return false
	if s.is_valid_float():
		return s.to_float()
	if s.begins_with("#") and Color.html_is_valid(s):
		return Color.html(s)
	var json : JSON = JSON.new()
	if json.parse(s) == OK:
		return MMType.deserialize_value(json.data)
	return s

## Applies "name=value" overrides to a graph. Names are either
## "node/path:parameter" or the name or label of a parameter of a remote
## node of the graph. Returns the list of errors.
static func apply_overrides(graph : MMGenBase, overrides : Array) -> PackedStringArray:
	var errors : PackedStringArray = PackedStringArray()
	for o in overrides:
		var equal : int = o.find("=")
		if equal == -1:
			errors.append("invalid override '%s' (expected name=value)" % o)
			continue
		var error : String = set_parameter_by_name(graph, o.left(equal).strip_edges(), parse_value(o.right(-equal-1).strip_edges()))
		if error != "":
			errors.append(error)
	return errors

## Sets a parameter given as "node/path:parameter" or as the name or label
## of a remote parameter. Returns an error message, or "".
static func set_parameter_by_name(graph : MMGenBase, parameter_name : String, value) -> String:
	var p : Dictionary = resolve_parameter(graph, parameter_name)
	if p.has("error"):
		return p.error
	p.generator.set_parameter(p.parameter, value)
	return ""

## Finds a parameter given as for set_parameter_by_name. Returns
## { generator, parameter } or { error }.
static func resolve_parameter(graph : MMGenBase, parameter_name : String) -> Dictionary:
	var target : MMGenBase = null
	var target_parameter : String = parameter_name
	if parameter_name.contains(":"):
		var node_path : String = parameter_name.get_slice(":", 0)
		target_parameter = parameter_name.get_slice(":", 1)
		target = graph.get_node_or_null(NodePath(node_path)) as MMGenBase
		if target == null:
			return { error="node '%s' not found" % node_path }
	else:
		target = find_remote_parameter(graph, parameter_name)
		if target != null:
			target_parameter = get_remote_parameter_name(target, parameter_name)
	if target == null:
		return { error="parameter '%s' not found" % parameter_name }
	if not target.get_parameter_defs().any(func(d): return d.name == target_parameter):
		return { error="node '%s' has no parameter '%s'" % [ target.get_hier_name(), target_parameter ] }
	return { generator=target, parameter=target_parameter }

## Returns the remote node of graph that has a parameter with this name or
## label (case insensitive)
static func find_remote_parameter(graph : MMGenBase, parameter_name : String) -> MMGenBase:
	for c in graph.get_children():
		if c is MMGenRemote and get_remote_parameter_name(c, parameter_name) != "":
			return c
	return null

static func get_remote_parameter_name(remote : MMGenRemote, parameter_name : String) -> String:
	for w in remote.widgets:
		if w.name == parameter_name or w.get("label", "").to_lower() == parameter_name.to_lower():
			return w.name
	return ""

## Unlocked seeds are offset by the golden ratio (modulo 1) for each step, so
## successive seeds are well distributed
const SEED_OFFSET : float = 0.6180339887
## Frames without pending renders after which rendering is considered done
const IDLE_FRAMES_DONE : int = 10

## Changes the seeds of all nodes that are not locked, deterministically
static func reseed(generator : Node, seed_offset : int) -> void:
	for c in generator.get_children():
		if c is MMGenBase:
			if c.has_randomness() and not c.is_seed_locked():
				c.set_seed(fmod(c.seed_value+SEED_OFFSET*seed_offset, 1.0))
			reseed(c, seed_offset)

## Returns a description of the parameters that can be overridden
static func list_parameters(graph : MMGenBase) -> PackedStringArray:
	var lines : PackedStringArray = PackedStringArray()
	for c in graph.get_children():
		if c is MMGenRemote:
			for w in c.widgets:
				lines.append("%s (%s) = %s" % [ w.name, w.get("label", ""), value_to_string(c.get_parameter(w.name)) ])
	for c in graph.get_children():
		if c is MMGenBase and not c is MMGenRemote:
			for p in c.get_parameter_defs():
				lines.append("%s:%s = %s" % [ c.name, p.name, value_to_string(c.get_parameter(p.name)) ])
	return lines

## Converts a parameter value to a string that parse_value accepts
static func value_to_string(value) -> String:
	if value is Color:
		return "#"+value.to_html()
	if value is Object:
		return JSON.stringify(MMType.serialize_value(value))
	return str(value)

## Waits until all buffers are rendered (or max_frames frames)
static func wait_for_renders(tree : SceneTree, max_frames : int = 6000) -> void:
	var idle_frames : int = 0
	for i in max_frames:
		await tree.process_frame
		idle_frames = idle_frames+1 if mm_deps.get_render_queue_size() == 0 else 0
		if idle_frames >= IDLE_FRAMES_DONE:
			return

## The generator and output of a node output spec ("node/path" or
## "node/path:output"): { generator, output }, or { error }
static func resolve_node_output(graph : MMGenBase, node_spec : String) -> Dictionary:
	var node_path : String = node_spec.get_slice(":", 0)
	var generator = graph.get_node_or_null(NodePath(node_path))
	if not generator is MMGenBase:
		return { error="node '%s' not found" % node_path }
	return { generator=generator, output=node_spec.get_slice(":", 1).to_int() if node_spec.contains(":") else 0 }

## A node output spec as a part of a file name
static func spec_to_file_part(node_spec : String) -> String:
	return node_spec.replace("/", "_").replace(":", "_")

## Renders a node output ("node/path" or "node/path:output") to a size x size
## image file. Returns an error message, or "".
static func render_node(graph : MMGenBase, node_spec : String, size : int, file_name : String) -> String:
	var resolved : Dictionary = resolve_node_output(graph, node_spec)
	if resolved.has("error"):
		return resolved.error
	var generator : MMGenBase = resolved.generator
	var output : int = resolved.output
	var node_path : String = node_spec.get_slice(":", 0)
	# Material nodes only show their (export) outputs with show_hidden
	if output < 0 or output >= generator.get_output_defs(true).size():
		return "node '%s' has no output %d" % [ node_path, output ]
	var texture : MMTexture = await render_output_texture(generator, output, Vector2i(size, size))
	if await texture.save_to_file(file_name) != OK:
		return "could not save '%s'" % file_name
	return ""

## Renders an output of a generator, after the buffers it needs are rendered
static func render_output_texture(generator : MMGenBase, output : int, size : Vector2i) -> MMTexture:
	generator.get_shader_code("uv", output, MMGenContext.new())
	await wait_for_renders(generator.get_tree())
	return await generator.render_output_to_texture(output, size)

## Bakes mesh maps to files named <prefix>_<map>.png, returns the errors
static func bake(mesh_path : String, maps : Array, size : int, prefix : String) -> PackedStringArray:
	var errors : PackedStringArray = PackedStringArray()
	var mesh : Mesh = MMMeshLoader.load_mesh(mesh_path)
	if mesh == null:
		errors.append("could not load mesh '%s'" % mesh_path)
		return errors
	for m in maps:
		if not m in BAKE_MAPS:
			errors.append("unknown map '%s' (valid maps: %s)" % [ m, ", ".join(BAKE_MAPS) ])
			continue
		var texture : MMTexture = await MMMapGenerator.get_map(mesh, m, size, true)
		var file_name : String = "%s_%s.png" % [ prefix, m ]
		if await texture.save_to_file(file_name) != OK:
			errors.append("could not save '%s'" % file_name)
		else:
			print("Baked %s" % file_name)
	return errors
