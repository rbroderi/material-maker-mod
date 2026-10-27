extends Object
class_name MMHighPolyBaker


# High to low poly baking: maps of a high poly mesh are projected on the
# UV layout of a low poly mesh, by casting rays from a cage (the low poly
# surface pushed along its normals) towards the low poly surface.
#
# Options (the options dictionary of bake()):
# - match_by_name: rays from a part of the low poly mesh (a named surface)
#   only hit the part of the high poly mesh with the same name, ignoring
#   _low/_high suffixes, so parts close to each other do not bleed
# - skew_map: a texture (red channel) that bends rays from the averaged
#   (smooth) direction (0) to the low poly face normal (1), to fix skewed
#   details near hard edges
# - high_texture: the texture of the high poly mesh, sampled at the hit point
#   for the "texture" map
# - hardware: use hardware ray tracing when the GPU supports it (the default)


const MAPS : Array[String] = [ "normal_tangent", "normal_object", "height", "color", "material_id", "position", "texture" ]

## Data built from a high poly mesh: its BVH and per-face attributes
class HighPolyData:
	var bvh : MMTexture
	var attributes : MMTexture
	var face_count : int
	var surface_names : PackedStringArray

static var high_poly_data : Dictionary = {}
static var baked_maps : Dictionary = {}
static var busy : bool = false
## Whether the last bake used hardware ray tracing (see MMHighPolyBakerRT)
static var last_bake_used_hardware : bool = false


## Merges all triangle surfaces of a mesh into a single indexed surface, and
## builds a texture with 8 texels per face: the normals of its 3 vertices
## (the w component of the first one is the surface index), their colors,
## then their UVs (u0, v0, u1, v1), (u2, v2, 0, 0)
static func prepare_high_poly(mesh : Mesh) -> Dictionary:
	var vertices : PackedVector3Array = PackedVector3Array()
	var indices : PackedInt32Array = PackedInt32Array()
	var attributes : PackedFloat32Array = PackedFloat32Array()
	var surface_names : PackedStringArray = PackedStringArray()
	for s in mesh.get_surface_count():
		surface_names.append(mesh.surface_get_name(s) if mesh is ArrayMesh else "")
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays : Array = mesh.surface_get_arrays(s)
		if arrays[Mesh.ARRAY_NORMAL] == null:
			var surface_tool : SurfaceTool = SurfaceTool.new()
			surface_tool.create_from(mesh, s)
			surface_tool.generate_normals()
			arrays = surface_tool.commit_to_arrays()
		var surface_vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals : PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var colors = arrays[Mesh.ARRAY_COLOR]
		var uvs = arrays[Mesh.ARRAY_TEX_UV]
		var surface_indices = arrays[Mesh.ARRAY_INDEX]
		if surface_indices == null:
			surface_indices = PackedInt32Array(range(surface_vertices.size()))
		var offset : int = vertices.size()
		vertices.append_array(surface_vertices)
		for f in surface_indices.size()/3:
			var face : PackedInt32Array = surface_indices.slice(3*f, 3*f+3)
			for v in 3:
				indices.append(offset+face[v])
			for v in 3:
				var n : Vector3 = normals[face[v]]
				attributes.append_array([ n.x, n.y, n.z, float(s) if v == 0 else 0.0 ])
			for v in 3:
				var c : Color = colors[face[v]] if colors != null else Color.WHITE
				attributes.append_array([ c.r, c.g, c.b, c.a ])
			var face_uvs : Array[Vector2] = []
			for v in 3:
				face_uvs.append(uvs[face[v]] if uvs != null else Vector2())
			attributes.append_array([ face_uvs[0].x, face_uvs[0].y, face_uvs[1].x, face_uvs[1].y, face_uvs[2].x, face_uvs[2].y, 0.0, 0.0 ])
	var merged : ArrayMesh = ArrayMesh.new()
	var merged_arrays : Array = []
	merged_arrays.resize(Mesh.ARRAY_MAX)
	merged_arrays[Mesh.ARRAY_VERTEX] = vertices
	merged_arrays[Mesh.ARRAY_INDEX] = indices
	merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged_arrays)
	return { mesh=merged, attributes=MMTexture.pack_texels(attributes), face_count=indices.size()/3, surface_names=surface_names }

static func get_high_poly_data(mesh : Mesh) -> HighPolyData:
	if not high_poly_data.has(mesh):
		var prepared : Dictionary = prepare_high_poly(mesh)
		var data : HighPolyData = HighPolyData.new()
		data.bvh = MMTexture.new()
		data.bvh.set_texture(MMBvhGenerator.generate(prepared.mesh))
		data.attributes = MMTexture.from_image(prepared.attributes)
		data.face_count = prepared.face_count
		data.surface_names = prepared.surface_names
		high_poly_data[mesh] = data
	return high_poly_data[mesh]

## Returns a copy of the first surface of mesh with MikkTSpace tangents (the
## baked tangent space must match the one used by the target engine)
static func with_tangents(mesh : Mesh) -> Mesh:
	if mesh.surface_get_arrays(0)[Mesh.ARRAY_TANGENT] != null:
		return mesh
	var surface_tool : SurfaceTool = SurfaceTool.new()
	surface_tool.create_from(mesh, 0)
	if mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL] == null:
		surface_tool.generate_normals()
	surface_tool.generate_tangents()
	return surface_tool.commit()

## All triangle surfaces of a mesh merged in a single surface with tangents,
## and the surface each vertex comes from
static func merge_surfaces(mesh : Mesh) -> Dictionary:
	var merged_arrays : Array = []
	merged_arrays.resize(Mesh.ARRAY_MAX)
	var vertices : PackedVector3Array = PackedVector3Array()
	var normals : PackedVector3Array = PackedVector3Array()
	var tangents : PackedFloat32Array = PackedFloat32Array()
	var uvs : PackedVector2Array = PackedVector2Array()
	var indices : PackedInt32Array = PackedInt32Array()
	var surfaces : PackedInt32Array = PackedInt32Array()
	for s in mesh.get_surface_count():
		if mesh is ArrayMesh and mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var surface_tool : SurfaceTool = SurfaceTool.new()
		surface_tool.create_from(mesh, s)
		var arrays : Array = surface_tool.commit_to_arrays()
		if arrays[Mesh.ARRAY_NORMAL] == null:
			surface_tool.generate_normals()
		if arrays[Mesh.ARRAY_TANGENT] == null and arrays[Mesh.ARRAY_TEX_UV] != null:
			surface_tool.generate_tangents()
		arrays = surface_tool.commit_to_arrays()
		var count : int = arrays[Mesh.ARRAY_VERTEX].size()
		var surface_indices = arrays[Mesh.ARRAY_INDEX]
		if surface_indices == null:
			surface_indices = PackedInt32Array(range(count))
		for i in surface_indices:
			indices.append(vertices.size()+i)
		vertices.append_array(arrays[Mesh.ARRAY_VERTEX])
		normals.append_array(arrays[Mesh.ARRAY_NORMAL])
		if arrays[Mesh.ARRAY_TANGENT] != null:
			tangents.append_array(arrays[Mesh.ARRAY_TANGENT])
		else:
			for i in count:
				tangents.append_array([ 1.0, 0.0, 0.0, 1.0 ])
		if arrays[Mesh.ARRAY_TEX_UV] != null:
			uvs.append_array(arrays[Mesh.ARRAY_TEX_UV])
		else:
			uvs.resize(uvs.size()+count)
		for i in count:
			surfaces.append(s)
	merged_arrays[Mesh.ARRAY_VERTEX] = vertices
	merged_arrays[Mesh.ARRAY_NORMAL] = normals
	merged_arrays[Mesh.ARRAY_TANGENT] = tangents
	merged_arrays[Mesh.ARRAY_TEX_UV] = uvs
	merged_arrays[Mesh.ARRAY_INDEX] = indices
	var merged : ArrayMesh = ArrayMesh.new()
	merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged_arrays)
	return { mesh=merged, surfaces=surfaces }

## A part name without its low/high poly suffix (and Blender's .001 numbers)
static func part_name(surface_name : String) -> String:
	var regex : RegEx = RegEx.create_from_string("(?i)([._ -]?\\d+)?[._ -]?(low|high|lowpoly|highpoly|lp|hp)?([._ -]?\\d+)?$")
	return regex.sub(surface_name.strip_edges(), "").to_lower()

## For each surface of the low poly mesh, the index of the high poly surface
## with the same part name, or -1 (no restriction)
static func match_surfaces(low_mesh : Mesh, high_names : PackedStringArray) -> PackedInt32Array:
	var high_parts : PackedStringArray = PackedStringArray()
	for n in high_names:
		high_parts.append(part_name(n))
	var rv : PackedInt32Array = PackedInt32Array()
	for s in low_mesh.get_surface_count():
		var low_name : String = part_name(low_mesh.surface_get_name(s)) if low_mesh is ArrayMesh else ""
		rv.append(high_parts.find(low_name) if low_name != "" else -1)
	return rv

## UDIM tiles used by the UV layout of a mesh (1001 is the [0, 1] square).
## Godot's V axis points down (V = 1-v of the mesh files), so tile rows are
## counted from the top.
static func udim_tiles(mesh : Mesh) -> PackedInt32Array:
	var tiles : Dictionary = {}
	for s in mesh.get_surface_count():
		var uvs = mesh.surface_get_arrays(s)[Mesh.ARRAY_TEX_UV]
		var indices = mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX]
		if uvs == null:
			continue
		if indices == null:
			indices = range(uvs.size())
		# The tile of a triangle is the tile of its center (vertices can be on
		# tile borders)
		for f in indices.size()/3:
			var center : Vector2 = (uvs[indices[3*f]]+uvs[indices[3*f+1]]+uvs[indices[3*f+2]])/3.0
			tiles[udim_tile(center)] = true
	var rv : PackedInt32Array = PackedInt32Array(tiles.keys())
	rv.sort()
	return rv

static func udim_tile(uv : Vector2) -> int:
	return 1001+int(floor(uv.x))+10*int(floor(1.0-uv.y))

## A copy of a mesh whose UVs are shifted so a UDIM tile is the [0, 1] square
## (triangles of other tiles are outside of it)
static func udim_tile_mesh(mesh : Mesh, tile : int) -> Mesh:
	var offset : Vector2 = Vector2((tile-1001)%10, -((tile-1001)/10))
	if offset == Vector2():
		return mesh
	var rv : ArrayMesh = ArrayMesh.new()
	for s in mesh.get_surface_count():
		var arrays : Array = mesh.surface_get_arrays(s)
		if arrays[Mesh.ARRAY_TEX_UV] != null:
			var uvs : PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
			for i in uvs.size():
				uvs[i] -= offset
			arrays[Mesh.ARRAY_TEX_UV] = uvs
		rv.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		rv.surface_set_name(s, mesh.surface_get_name(s) if mesh is ArrayMesh else "")
	if mesh.has_meta("file_path"):
		rv.set_meta("file_path", mesh.get_meta("file_path"))
	return rv

## Jitter offsets (in pixels) of anti-aliasing passes: a rotated grid for
## up to 4 samples, then a Halton sequence
static func get_jitter(sample : int) -> Vector2:
	const GRID : Array[Vector2] = [ Vector2(0.0, 0.0), Vector2(0.25, -0.375), Vector2(-0.375, -0.125), Vector2(0.125, 0.375) ]
	if sample < GRID.size():
		return GRID[sample]
	return Vector2(halton(sample, 2), halton(sample, 3))-Vector2(0.5, 0.5)

static func halton(index : int, base : int) -> float:
	var f : float = 1.0
	var r : float = 0.0
	var i : int = index
	while i > 0:
		f /= base
		r += f*(i%base)
		i /= base
	return r

## Bakes a map. front and rear are the ray distances in front of and behind
## the low poly surface, relative to the diagonal of its bounding box. When
## a cage mesh (with the same topology as the low poly mesh) is given, rays
## start from it and front is not used.
static func bake(low_mesh : Mesh, high_mesh : Mesh, map : String, size : int, front : float = 0.01, rear : float = 0.01, samples : int = 4, force : bool = false, cage_mesh : Mesh = null, options : Dictionary = {}) -> MMTexture:
	assert(map in MAPS)
	var key : String = "%d:%d:%s:%d:%f:%f:%d:%d" % [ low_mesh.get_instance_id(), high_mesh.get_instance_id(), map, size, front, rear, samples, cage_mesh.get_instance_id() if cage_mesh else 0 ]
	for o in options.keys():
		key += ":%s=%s" % [ o, str(options[o].get_instance_id()) if options[o] is Object else str(options[o]) ]
	if force:
		baked_maps.erase(key)
	if not baked_maps.has(key):
		# Low poly meshes with several surfaces (parts) are merged, and when
		# matching by name, each vertex gets the high poly surface it can hit
		var low : Mesh = low_mesh
		var vertex_matches : PackedFloat32Array = PackedFloat32Array()
		if low_mesh.get_surface_count() > 1:
			var merged : Dictionary = merge_surfaces(low_mesh)
			low = merged.mesh
			if options.get("match_by_name", false):
				var high_names : PackedStringArray = PackedStringArray()
				for s in high_mesh.get_surface_count():
					high_names.append(high_mesh.surface_get_name(s) if high_mesh is ArrayMesh else "")
				var surface_matches : PackedInt32Array = match_surfaces(low_mesh, high_names)
				for s in merged.surfaces:
					vertex_matches.append(surface_matches[s])
			if cage_mesh != null and cage_mesh.get_surface_count() > 1:
				cage_mesh = merge_surfaces(cage_mesh).mesh
		# The seams map is used to dilate the result
		var seams : MMTexture = await MMMapGenerator.get_map(low, "seams", size)
		while busy:
			await mm_globals.get_tree().process_frame
		busy = true
		var texture : MMTexture = MMTexture.new()
		var start_time : int = Time.get_ticks_msec()
		await mm_renderer.thread_run(generate, [ low, high_mesh, map, size, front, rear, samples, seams, texture, cage_mesh, options, vertex_matches ])
		print_verbose("Baked %s from high poly mesh in %d ms" % [ map, Time.get_ticks_msec()-start_time ])
		baked_maps[key] = texture
		busy = false
	return baked_maps[key]

## Returns the vertices of the cage, in the same order as those of the low
## poly mesh, or an empty array if their topologies don't match
static func get_cage_vertices(low : Mesh, cage_mesh : Mesh) -> PackedVector3Array:
	var cage : Mesh = with_tangents(cage_mesh)
	var low_arrays : Array = low.surface_get_arrays(0)
	var cage_arrays : Array = cage.surface_get_arrays(0)
	if cage_arrays[Mesh.ARRAY_VERTEX].size() != low_arrays[Mesh.ARRAY_VERTEX].size() or cage_arrays[Mesh.ARRAY_INDEX] != low_arrays[Mesh.ARRAY_INDEX]:
		return PackedVector3Array()
	return cage_arrays[Mesh.ARRAY_VERTEX]

## Bakes a map of a (single surface) low poly mesh. vertex_matches is, for
## each low poly vertex, the high poly surface its rays can hit (-1 for any,
## and empty for no restriction)
static func generate(low_mesh : Mesh, high_mesh : Mesh, map : String, size : int, front : float, rear : float, samples : int, seams : MMTexture, texture : MMTexture, cage_mesh : Mesh = null, options : Dictionary = {}, vertex_matches : PackedFloat32Array = PackedFloat32Array()) -> void:
	# The software BVH (built in GDScript, slow for large meshes) is not needed
	# with hardware ray tracing
	var hardware : bool = options.get("hardware", true) and MMHighPolyBakerRT.is_available()
	var data : HighPolyData = null if hardware else get_high_poly_data(high_mesh)
	var low : Mesh = with_tangents(low_mesh)
	if vertex_matches.is_empty():
		vertex_matches.resize(low.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size())
		vertex_matches.fill(-1.0)
	var aabb : AABB = low.get_aabb()
	var diagonal : float = aabb.size.length()
	var pipeline : MMMeshRenderingPipeline = MMMeshRenderingPipeline.new()
	pipeline.mesh = low
	pipeline.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	var cage_vertices : PackedVector3Array = PackedVector3Array()
	if cage_mesh != null:
		cage_vertices = get_cage_vertices(low, cage_mesh)
		if cage_vertices.is_empty():
			push_error("The cage mesh must have the same topology as the low poly mesh, it is ignored")
	pipeline.extra_buffers.append((cage_vertices if not cage_vertices.is_empty() else low.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]).to_byte_array())
	pipeline.extra_buffers.append(vertex_matches.to_byte_array())
	pipeline.add_parameter_or_texture("use_cage", "int", 0 if cage_vertices.is_empty() else 1)
	var dummy : MMTexture = MMTexture.from_image(Image.create(1, 1, false, Image.FORMAT_RGBA8))
	var skew_map : MMTexture = dummy
	if options.get("skew_map") is Texture2D:
		skew_map = MMTexture.new()
		skew_map.set_texture(options.skew_map)
	pipeline.add_parameter_or_texture("use_skew", "int", 0 if skew_map == dummy else 1)
	pipeline.add_parameter_or_texture("skew_tex", "sampler2D", skew_map)
	var high_texture : MMTexture = dummy
	if options.get("high_texture") is Texture2D:
		high_texture = MMTexture.new()
		high_texture.set_texture(options.high_texture)
	pipeline.add_parameter_or_texture("high_texture", "sampler2D", high_texture)
	pipeline.add_parameter_or_texture("bvh_data", "sampler2D", data.bvh if data != null else dummy)
	pipeline.add_parameter_or_texture("attribute_data", "sampler2D", data.attributes if data != null else dummy)
	pipeline.add_parameter_or_texture("prev_iteration_tex", "sampler2D", texture)
	pipeline.add_parameter_or_texture("front_dist", "float", front*diagonal)
	pipeline.add_parameter_or_texture("rear_dist", "float", rear*diagonal)
	pipeline.add_parameter_or_texture("aabb_position", "vec3", aabb.position)
	pipeline.add_parameter_or_texture("aabb_size", "vec3", aabb.size)
	pipeline.add_parameter_or_texture("mode", "int", MAPS.find(map))
	pipeline.add_parameter_or_texture("iteration", "int", 1)
	pipeline.add_parameter_or_texture("jitter", "vec2", Vector2(0, 0))
	pipeline.add_parameter_or_texture("gbuffer", "int", 0)
	var vertex_shader : String = load("res://addons/material_maker/map_generator/highpoly_vertex.tres").text
	last_bake_used_hardware = false
	if hardware:
		# Hardware ray tracing: the rasterization pass only writes the rays
		var rays_shader : String = load("res://addons/material_maker/map_generator/highpoly_rays_fragment.tres").text
		if await pipeline.set_shader(vertex_shader, rays_shader):
			last_bake_used_hardware = await MMHighPolyBakerRT.generate(pipeline, high_mesh, MAPS.find(map), size, front*diagonal, rear*diagonal, aabb, samples, high_texture, texture)
	if not last_bake_used_hardware:
		if data == null:
			data = get_high_poly_data(high_mesh)
			pipeline.set_parameter("bvh_data", data.bvh)
			pipeline.set_parameter("attribute_data", data.attributes)
		var fragment_shader : String = load("res://addons/material_maker/map_generator/highpoly_fragment.tres").text
		if not await pipeline.set_shader(vertex_shader, fragment_shader):
			push_error("Cannot compile high poly baking shader")
			return
		for i in max(1, samples):
			pipeline.set_parameter("iteration", i+1)
			pipeline.set_parameter("prev_iteration_tex", texture)
			# Jitter is in normalized device coordinates (2 units for the texture's width)
			pipeline.set_parameter("jitter", get_jitter(i)*2.0/size)
			pipeline.in_thread_render(Vector2i(size, size), 3, texture)
	# Extend the map past UV seams
	var dilate_pipeline : MMComputeShader = MMComputeShader.new()
	dilate_pipeline.clear()
	dilate_pipeline.add_parameter_or_texture("tex", "sampler2D", texture)
	dilate_pipeline.add_parameter_or_texture("pixels", "int", size/4)
	dilate_pipeline.add_parameter_or_texture("seams_map", "sampler2D", seams)
	dilate_pipeline.set_shader(load("res://addons/material_maker/map_generator/dilate_compute.tres").text, 3)
	dilate_pipeline.in_thread_render_ext([texture], Vector2i(size, size))
