extends RefCounted
class_name MMCliTools


# Helpers for the command line modes (see parse_args.gd and
# material_maker/doc/command_line.rst): parameter overrides, reseeding,
# rendering node outputs and baking mesh maps.


const BAKE_MAPS : Array[String] = [ "position", "normal", "tangent", "ambient_occlusion", "bent_normals", "thickness", "curvature", "seams", "adjacency" ]
const DEFAULT_BAKE_MAPS : Array[String] = [ "ambient_occlusion", "curvature", "thickness", "normal", "position" ]
const DEFAULT_HIGH_POLY_MAPS : Array[String] = [ "normal_tangent", "height" ]

const ExportAnimation = preload("res://material_maker/windows/export_animation/export_animation.gd")


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

## The output templates whose export target exists (some are added by
## plugins)
static func get_engine_templates() -> Array[Dictionary]:
	var material : Dictionary = mm_loader.predefined_generators.get("material", {})
	var targets : Array = material.get("shader_model", {}).get("exports", {}).keys()+mm_loader.get_external_export_targets("material").keys()
	return ENGINE_TEMPLATES.filter(func(t): return t.export in targets)

## Graph data of a new material from an output template (by name or export
## target), or an empty dictionary
static func get_engine_template_graph(template_name : String) -> Dictionary:
	for t in get_engine_templates():
		if t.name == template_name or t.export == template_name:
			var parameters : Dictionary = { size=11 }
			parameters.merge(t.parameters, true)
			return { nodes=[ { name="Material", type="material", parameters=parameters, export_last_target=t.export } ], connections=[] }
	return {}

## The remote nodes of a graph (not those of its subgraphs)
static func get_remote_nodes(graph : MMGenBase) -> Array[MMGenRemote]:
	var remotes : Array[MMGenRemote] = []
	for c in graph.get_children():
		if c is MMGenRemote:
			remotes.append(c)
	return remotes

## Applies a preset to all the remote nodes of a graph that have it. Returns
## false if none has it.
static func apply_preset(graph : MMGenBase, preset_name : String) -> bool:
	var found : bool = false
	for r in get_remote_nodes(graph):
		if r.apply_preset(preset_name):
			found = true
	return found

## The names of the presets of the remote nodes of a graph, sorted
static func get_preset_names(graph : MMGenBase) -> PackedStringArray:
	var names : PackedStringArray = PackedStringArray()
	for r in get_remote_nodes(graph):
		for n in r.get_preset_names():
			if not n in names:
				names.append(n)
	names.sort()
	return names

## Unlocked seeds are offset by the golden ratio (modulo 1) for each step, so
## successive seeds are well distributed (the runtimes use the same constant)
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

## Sets the mesh of a graph's Mesh Map and High Poly Bake nodes (as the 3D
## preview's custom mesh does) and waits until their maps are generated
static func set_graph_mesh(graph : MMGenGraph, mesh : Mesh) -> void:
	graph.current_mesh = mesh
	for g in collect_generators(graph, func(g): return g is MMGenMeshMap):
		g.current_mesh = mesh
		await g.update_map()

## UDIM tiles from a list ("1001-1004,1011", sorted), empty if it is invalid
## (tiles are from 1001 to 1999, and ranges go up)
static func parse_udim_tiles(list : String) -> PackedInt32Array:
	var tiles : PackedInt32Array = PackedInt32Array()
	for item in list.split(",", false):
		var bounds : PackedStringArray = item.strip_edges().split("-")
		if bounds.size() > 2 or not bounds[0].strip_edges().is_valid_int() or not bounds[-1].strip_edges().is_valid_int():
			return PackedInt32Array()
		var first : int = bounds[0].to_int()
		var last : int = bounds[-1].to_int()
		if first < 1001 or last > 1999 or first > last:
			return PackedInt32Array()
		for t in range(first, last+1):
			if not t in tiles:
				tiles.append(t)
	tiles.sort()
	return tiles

## The generator and output of a node output spec ("node/path" or
## "node/path:output"): { generator, output }, or { error }
static func resolve_node_output(graph : MMGenBase, node_spec : String) -> Dictionary:
	var node_path : String = node_spec.get_slice(":", 0)
	var generator = graph.get_node_or_null(NodePath(node_path))
	if not generator is MMGenBase:
		return { error="node '%s' not found" % node_path }
	var output : int = node_spec.get_slice(":", 1).to_int() if node_spec.contains(":") else 0
	# Material nodes only show their (export) outputs with show_hidden
	if output < 0 or output >= generator.get_output_defs(true).size():
		return { error="node '%s' has no output %d" % [ node_path, output ] }
	return { generator=generator, output=output }

## The top graph of a project, that contains a graph
static func get_top_graph(graph : MMGenGraph) -> MMGenGraph:
	var top : MMGenGraph = graph
	while top.get_parent() is MMGenGraph:
		top = top.get_parent()
	return top

## The material node (the node with export profiles) of a graph, or null
static func find_material_node(graph : Node) -> MMGenBase:
	for c in graph.get_children():
		if c.has_method("get_export_profiles"):
			return c
	return null

## A node output spec as a part of a file name
static func spec_to_file_part(node_spec : String) -> String:
	return node_spec.replace("/", "_").replace(":", "_")

## Renders a node output ("node/path" or "node/path:output") to a file, size
## pixels wide and height pixels high (0 for a square image)
static func render_node(graph : MMGenBase, node_spec : String, size : int, file_name : String, height : int = 0) -> String:
	var resolved : Dictionary = resolve_node_output(graph, node_spec)
	if resolved.has("error"):
		return resolved.error
	var texture : MMTexture = await render_output_texture(resolved.generator, resolved.output, Vector2i(size, height if height > 0 else size))
	if await texture.save_to_file(file_name) != OK:
		return "could not save '%s'" % file_name
	return ""

## Renders animation frames of a node output, $time going from 0 to duration
## (frame i is rendered at duration*i/frames, so the animation loops), in a
## sprite sheet with the given number of columns (a square sheet if 0, rows
## are filled first), or in separate files (<file_name>_<frame>.<extension>,
## from 1) if separate is true. Returns an error message, or "".
static func render_flipbook(graph : MMGenBase, node_spec : String, size : int, frames : int, duration : float, columns : int, separate : bool, file_name : String) -> String:
	var resolved : Dictionary = resolve_node_output(graph, node_spec)
	if resolved.has("error"):
		return resolved.error
	var images : Array[Image] = []
	var digits : int = str(frames).length()
	# Buffer nodes whose inputs use $time (the buffers that depend on them
	# follow)
	var animated_buffers : Array = collect_generators(graph, func(g): return ExportAnimation.is_animated_buffer(g))
	for frame in frames:
		MMComputeShader.fixed_time = duration*float(frame)/float(frames)
		# They are rendered again at this time (iterations start again)
		ExportAnimation.invalidate_buffers(animated_buffers)
		mm_deps.update()
		var texture : MMTexture = await render_output_texture(resolved.generator, resolved.output, Vector2i(size, size))
		if separate:
			var frame_file : String = "%s_%0*d.%s" % [ file_name.get_basename(), digits, frame+1, file_name.get_extension() ]
			if await texture.save_to_file(frame_file) != OK:
				MMComputeShader.fixed_time = -1.0
				return "could not save '%s'" % frame_file
			print("Rendered %s" % frame_file)
		else:
			images.append((await texture.get_texture()).get_image())
	MMComputeShader.fixed_time = -1.0
	if separate:
		return ""
	var sheet : Image = make_sprite_sheet(images, columns)
	if sheet == null:
		return "no frame rendered"
	# (saved as other renders: 8 bits values are rounded, and plugins add formats)
	if await MMTexture.from_image(sheet).save_to_file(file_name) != OK:
		return "could not save '%s'" % file_name
	return ""

## The generators under root (in its subgraphs too, and including the
## buffers that are children of nodes, such as value processors') for which
## predicate returns true
static func collect_generators(root : Node, predicate : Callable) -> Array:
	var rv : Array = []
	add_generators(root, predicate, rv)
	return rv

static func add_generators(root : Node, predicate : Callable, rv : Array) -> void:
	for c in root.get_children():
		if c is MMGenBase:
			if predicate.call(c):
				rv.append(c)
			add_generators(c, predicate, rv)

## Renders an output of a generator, after the buffers it needs are rendered
static func render_output_texture(generator : MMGenBase, output : int, size : Vector2i) -> MMTexture:
	generator.get_shader_code("uv", output, MMGenContext.new())
	await wait_for_renders(generator.get_tree())
	return await generator.render_output_to_texture(output, size)

static func render_output_image(generator : MMGenBase, output : int, size : Vector2i) -> Image:
	var texture : MMTexture = await render_output_texture(generator, output, size)
	return (await texture.get_texture()).get_image()

## Images of the same size in a sprite sheet with the given number of columns
## (a square sheet when 0), rows being filled first, in the format of the
## first image (null without images)
static func make_sprite_sheet(images : Array[Image], columns : int = 0) -> Image:
	if images.is_empty():
		return null
	if columns <= 0:
		columns = ceili(sqrt(images.size()))
	var rows : int = ceili(float(images.size())/columns)
	var frame_size : Vector2i = images[0].get_size()
	var sheet : Image = Image.create(frame_size.x*columns, frame_size.y*rows, false, images[0].get_format())
	for i in images.size():
		var image : Image = images[i]
		if image.get_format() != sheet.get_format():
			image.convert(sheet.get_format())
		sheet.blit_rect(image, Rect2i(Vector2i(), frame_size), Vector2i(i%columns, i/columns)*frame_size)
	return sheet

## Bakes mesh maps to files named <prefix>_<map>.png, returns the errors.
## With a high poly mesh (options.high), maps are baked from it (see
## MMHighPolyBaker) with options.front, options.rear and options.samples,
## and optionally options.match_names, options.skew (image) and
## options.high_texture (image).
static func bake(mesh_path : String, maps : Array, size : int, prefix : String, options : Dictionary = {}) -> PackedStringArray:
	var errors : PackedStringArray = PackedStringArray()
	var match_names : bool = options.get("match_names", false)
	if options.get("high", "") == "":
		for o in [ "match_names", "skew", "high_texture", "software_raytracing" ]:
			if options.has(o):
				errors.append("--%s needs --high" % o.replace("_", "-"))
				return errors
	var mesh : Mesh = MMMeshLoader.load_mesh(mesh_path, false, match_names)
	if mesh == null:
		errors.append("could not load mesh '%s'" % mesh_path)
		return errors
	var bake_options : Dictionary = { match_by_name=match_names, hardware=not options.get("software_raytracing", false) }
	for o in [ [ "skew", "skew_map" ], [ "high_texture", "high_texture" ] ]:
		if options.get(o[0], "") != "":
			var image : Image = Image.load_from_file(options[o[0]]) if FileAccess.file_exists(options[o[0]]) else null
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
	if match_names:
		# Matching nothing would bake as without --match-names (parts without
		# a match only get a warning)
		var matches : Dictionary = MMHighPolyBaker.match_parts(mesh, high_mesh)
		if matches.surface_parts.count(-1) == matches.surface_parts.size():
			errors.append("--match-names: no part of the mesh (%s) has the name of a part of the high poly mesh (%s)" % [ ", ".join(matches.unmatched), ", ".join(MMHighPolyBaker.get_part_names(high_mesh)) ])
			return errors
	var valid_maps : Array = BAKE_MAPS.duplicate()
	if high_mesh != null:
		# With a high poly mesh, the position map is the high poly surface's
		for m in MMHighPolyBaker.MAPS:
			if not m in valid_maps:
				valid_maps.append(m)
	# Maps that cannot be baked are errors, before baking anything
	var baked_maps : Array = []
	for m in maps:
		if not m in valid_maps:
			errors.append("unknown map '%s' (valid maps: %s)" % [ m, ", ".join(valid_maps) ])
			continue
		if m == "texture" and high_mesh != null:
			if not bake_options.has("high_texture"):
				errors.append("the texture map needs --high-texture")
				continue
			var error : String = MMHighPolyBaker.check_texture_transfer(high_mesh, bake_options)
			if error != "":
				errors.append(error.left(1).to_lower()+error.substr(1))
				continue
		baked_maps.append(m)
	# UDIM tiles (options.tiles, or all tiles of the mesh with options.udim)
	# are baked to <prefix>_<map>.<tile>.png
	var tiles : PackedInt32Array = options.get("tiles", PackedInt32Array())
	if tiles.is_empty() and options.get("udim", false):
		tiles = MMMapGenerator.udim_tiles(mesh)
		if tiles.is_empty():
			errors.append("the mesh has no UVs in UDIM tiles")
			return errors
	for tile in (Array(tiles) if not tiles.is_empty() else [ 0 ]):
		# The cage is the same for all tiles (only its vertices are used)
		var tile_mesh : Mesh = MMMapGenerator.get_tile_mesh(mesh, tile) if tile != 0 else mesh
		for m in baked_maps:
			var texture : MMTexture
			if m in MMHighPolyBaker.MAPS and high_mesh != null:
				texture = await MMHighPolyBaker.bake(tile_mesh, high_mesh, m, size, options.get("front", 0.01), options.get("rear", 0.01), options.get("samples", 4), true, cage_mesh, bake_options)
			else:
				texture = await MMMapGenerator.get_map(tile_mesh, m, size, true)
			var file_name : String = "%s_%s.png" % [ prefix, m ] if tile == 0 else "%s_%s.%d.png" % [ prefix, m, tile ]
			if await texture.save_to_file(file_name) != OK:
				errors.append("could not save '%s'" % file_name)
			else:
				print("Baked %s%s" % [ file_name, " (hardware ray tracing)" if m in MMHighPolyBaker.MAPS and high_mesh != null and MMHighPolyBaker.last_bake_used_hardware else "" ])
	return errors
