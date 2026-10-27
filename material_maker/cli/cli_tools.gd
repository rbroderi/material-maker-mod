extends RefCounted
class_name MMCliTools


# Helpers for the command line modes (see parse_args.gd and
# material_maker/doc/command_line.rst): parameter overrides, reseeding,
# rendering node outputs and baking mesh maps.


const BAKE_MAPS : Array[String] = [ "position", "normal", "tangent", "ambient_occlusion", "bent_normals", "thickness", "curvature", "seams", "adjacency" ]
const DEFAULT_BAKE_MAPS : Array[String] = [ "ambient_occlusion", "curvature", "thickness", "normal", "position" ]
const DEFAULT_HIGH_POLY_MAPS : Array[String] = [ "normal_tangent", "height" ]


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

## Output templates: new materials set up for an engine (export target and
## Material node values)
const ENGINE_TEMPLATES : Array[Dictionary] = [
	{ name="Godot 4", export="Godot/Godot 4 Standard", parameters={},
		description="Godot 4 StandardMaterial3D (.tres) and its textures" },
	{ name="Godot 4 (ORM)", export="Godot/Godot 4 ORM", parameters={},
		description="Godot 4 ORMMaterial3D, with occlusion, roughness and metallic in one texture" },
	{ name="Unity HDRP", export="Unity/HDRP", parameters={},
		description="Unity High Definition Render Pipeline Lit material, with a mask map" },
	{ name="Unity URP", export="Unity/URP", parameters={},
		description="Unity Universal Render Pipeline Lit material" },
	{ name="Unreal Engine 5", export="Unreal/Unreal Engine 5", parameters={ size=12, depth_scale=0.0 },
		description="Unreal Engine 5 textures (base color, normal, occlusion/roughness/metallic), 4096x4096" },
	{ name="glTF", export="GLTF/Plane", parameters={},
		description="glTF 2.0 material on a plane" },
	{ name="MaterialX (OpenPBR)", export="MaterialX/OpenPBR", parameters={},
		description="MaterialX document with an OpenPBR surface" },
	{ name="USD", export="USD/UsdPreviewSurface", parameters={},
		description="USD layer with a UsdPreviewSurface material" },
	{ name="Blender", export="Blender", parameters={},
		description="Blender material import script and textures" },
]

## Graph data of a new material from an output template (by name or export
## target), or an empty dictionary
static func get_engine_template_graph(template_name : String) -> Dictionary:
	for t in ENGINE_TEMPLATES:
		if t.name == template_name or t.export == template_name:
			var parameters : Dictionary = { size=11 }
			parameters.merge(t.parameters, true)
			return { nodes=[ { name="Material", type="material", parameters=parameters, export_last_target=t.export } ], connections=[] }
	return {}

## Applies a preset of the graph's remote nodes, returns false if none has it
static func apply_preset(graph : MMGenBase, preset_name : String) -> bool:
	var found : bool = false
	for c in graph.get_children():
		if c is MMGenRemote and c.apply_preset(preset_name):
			found = true
	return found

## Names of the presets of the graph's remote nodes
static func get_preset_names(graph : MMGenBase) -> PackedStringArray:
	var names : PackedStringArray = PackedStringArray()
	for c in graph.get_children():
		if c is MMGenRemote:
			for n in c.get_preset_names():
				if not n in names:
					names.append(n)
	return names

## Changes the seeds of all nodes that are not locked, deterministically
static func reseed(generator : Node, seed_offset : int) -> void:
	for c in generator.get_children():
		if c is MMGenBase:
			if c.has_randomness() and not c.is_seed_locked():
				c.set_seed(fmod(c.seed_value+0.6180339887*seed_offset, 1.0))
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
		if idle_frames >= 10:
			return

## Renders a node output ("node/path" or "node/path:output") to a file, size
## pixels wide and height pixels high (0 for a square image)
static func render_node(graph : MMGenBase, node_spec : String, size : int, file_name : String, height : int = 0) -> String:
	var node_path : String = node_spec.get_slice(":", 0)
	var output : int = node_spec.get_slice(":", 1).to_int() if node_spec.contains(":") else 0
	var generator = graph.get_node_or_null(NodePath(node_path))
	if not generator is MMGenBase:
		return "node '%s' not found" % node_path
	# Material nodes only show their (export) outputs with show_hidden
	if output < 0 or output >= generator.get_output_defs(true).size():
		return "node '%s' has no output %d" % [ node_path, output ]
	# Generating the shader creates the automatic buffers it needs, that must
	# be rendered first
	generator.get_shader_code("uv", output, MMGenContext.new())
	await wait_for_renders(generator.get_tree())
	var texture : MMTexture = await generator.render_output_to_texture(output, Vector2i(size, height if height > 0 else size))
	if await texture.save_to_file(file_name) != OK:
		return "could not save '%s'" % file_name
	return ""

## Renders animation frames of a node output ($time from 0 to duration) in a
## sprite sheet with the given number of columns (rows are filled first)
static func render_flipbook(graph : MMGenBase, node_spec : String, size : int, frames : int, duration : float, columns : int, file_name : String) -> String:
	var node_path : String = node_spec.get_slice(":", 0)
	var output : int = node_spec.get_slice(":", 1).to_int() if node_spec.contains(":") else 0
	var generator = graph.get_node_or_null(NodePath(node_path))
	if not generator is MMGenBase:
		return "node '%s' not found" % node_path
	if columns <= 0:
		columns = int(ceil(sqrt(float(frames))))
	var rows : int = (frames+columns-1)/columns
	var sheet : Image = null
	var buffers : Array = []
	collect_buffers(graph, buffers)
	for frame in frames:
		MMComputeShader.fixed_time = duration*float(frame)/float(frames)
		# Buffers (including automatic ones) are rendered again at this time
		for b in buffers:
			var buffer_name : String = "o%d_tex" % b.get_instance_id()
			if mm_deps.buffers.has(buffer_name):
				mm_deps.buffer_invalidate(buffer_name)
		mm_deps.update()
		await wait_for_renders(generator.get_tree())
		var texture : MMTexture = await generator.render_output_to_texture(output, Vector2i(size, size))
		var image : Image = (await texture.get_texture()).get_image()
		if sheet == null:
			sheet = Image.create(size*columns, size*rows, false, image.get_format())
		sheet.blit_rect(image, Rect2i(0, 0, size, size), Vector2i((frame%columns)*size, (frame/columns)*size))
	MMComputeShader.fixed_time = -1.0
	if sheet == null:
		return "no frame rendered"
	var error : Error = sheet.save_exr(file_name) if file_name.get_extension() == "exr" else sheet.save_png(file_name)
	return "could not save '%s'" % file_name if error != OK else ""

static func collect_buffers(generator : Node, buffers : Array) -> void:
	for c in generator.get_children():
		if c is MMGenBuffer:
			buffers.append(c)
		collect_buffers(c, buffers)

## Bakes mesh maps to files named <prefix>_<map>.png, returns the errors.
## With a high poly mesh (options.high), maps are baked from it (see
## MMHighPolyBaker) with options.front, options.rear and options.samples,
## and optionally options.match_names, options.skew (image) and
## options.high_texture (image).
static func bake(mesh_path : String, maps : Array, size : int, prefix : String, options : Dictionary = {}) -> PackedStringArray:
	var errors : PackedStringArray = PackedStringArray()
	var match_names : bool = options.get("match_names", false)
	var mesh : Mesh = MMMeshLoader.load_mesh(mesh_path, false, match_names)
	if mesh == null:
		errors.append("could not load mesh '%s'" % mesh_path)
		return errors
	var bake_options : Dictionary = { match_by_name=match_names }
	for o in [ [ "skew", "skew_map" ], [ "high_texture", "high_texture" ] ]:
		if options.get(o[0], "") != "":
			var image : Image = Image.load_from_file(options[o[0]])
			if image == null:
				errors.append("could not load image '%s'" % options[o[0]])
				return errors
			bake_options[o[1]] = ImageTexture.create_from_image(image)
	var high_mesh : Mesh = null
	if options.get("high", "") != "":
		high_mesh = MMMeshLoader.load_mesh(options.high, true, match_names)
		if high_mesh == null:
			errors.append("could not load mesh '%s'" % options.high)
			return errors
	var cage_mesh : Mesh = null
	if options.get("cage", "") != "":
		cage_mesh = MMMeshLoader.load_mesh(options.cage, false, match_names)
		if cage_mesh == null:
			errors.append("could not load mesh '%s'" % options.cage)
			return errors
	var valid_maps : Array = BAKE_MAPS+(Array(MMHighPolyBaker.MAPS) if high_mesh != null else [])
	for m in maps:
		if not m in valid_maps:
			errors.append("unknown map '%s' (valid maps: %s)" % [ m, ", ".join(valid_maps) ])
			continue
		var texture : MMTexture
		if m in MMHighPolyBaker.MAPS and high_mesh != null:
			texture = await MMHighPolyBaker.bake(mesh, high_mesh, m, size, options.get("front", 0.01), options.get("rear", 0.01), options.get("samples", 4), true, cage_mesh, bake_options)
		else:
			texture = await MMMapGenerator.get_map(mesh, m, size, true)
		var file_name : String = "%s_%s.png" % [ prefix, m ]
		if await texture.save_to_file(file_name) != OK:
			errors.append("could not save '%s'" % file_name)
		else:
			print("Baked %s" % file_name)
	return errors
