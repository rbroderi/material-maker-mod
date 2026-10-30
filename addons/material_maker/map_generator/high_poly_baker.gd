extends Object
class_name MMHighPolyBaker


# High to low poly baking: maps of a high poly mesh are projected on the
# UV layout of a low poly mesh, by casting rays from a cage (the low poly
# surface pushed along its normals) towards the low poly surface.
#
# Options (the options dictionary of bake()):
# - match_by_name: rays from a part of the low poly mesh (a named surface)
#   only hit the part of the high poly mesh with the same name, ignoring
#   _low/_high suffixes, so parts close to each other don't bleed
# - skew_map: a texture (red channel, in the low poly UV space) that bends
#   rays from the smooth direction (0) to the low poly face normal (1), to fix
#   skewed details near hard edges
# - high_texture: the texture of the high poly mesh, sampled at the hit point
#   with the high poly UVs for the "texture" map


const MAPS : Array[String] = [ "normal_tangent", "normal_object", "height", "color", "material_id", "position", "texture" ]

## Data built from a high poly mesh: its BVH and per-face attributes
class HighPolyData:
	var bvh : MMTexture
	var attributes : MMTexture
	var face_count : int

static var high_poly_data : Dictionary = {}
static var baked_maps : Dictionary = {}
static var busy : bool = false

const MAX_HIGH_POLY_DATA : int = 4
const MAX_BAKED_MAPS : int = 8


## Merges all triangle surfaces of a mesh into a single indexed surface, and
## builds a texture with 8 texels per face: the normals of its 3 vertices
## (the w component of the first one is the surface index, and of the second
## one the part index, see get_surface_parts()), their colors, then their UVs
## (u0, v0, u1, v1), (u2, v2, 0, 0)
static func prepare_high_poly(mesh : Mesh) -> Dictionary:
	var vertices : PackedVector3Array = PackedVector3Array()
	var indices : PackedInt32Array = PackedInt32Array()
	var attributes : PackedFloat32Array = PackedFloat32Array()
	var surface_parts : PackedInt32Array = get_surface_parts(mesh, get_part_names(mesh))
	for s in mesh.get_surface_count():
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
		var part : float = float(surface_parts[s])
		for f in surface_indices.size()/3:
			var face : PackedInt32Array = surface_indices.slice(3*f, 3*f+3)
			for v in 3:
				indices.append(offset+face[v])
			for v in 3:
				var n : Vector3 = normals[face[v]]
				attributes.append_array([ n.x, n.y, n.z, [ float(s), part, 0.0 ][v] ])
			for v in 3:
				var c : Color = colors[face[v]] if colors != null else Color.WHITE
				attributes.append_array([ c.r, c.g, c.b, c.a ])
			var face_uvs : Array[Vector2] = [ Vector2(), Vector2(), Vector2() ]
			if uvs != null:
				for v in 3:
					face_uvs[v] = uvs[face[v]]
			attributes.append_array([ face_uvs[0].x, face_uvs[0].y, face_uvs[1].x, face_uvs[1].y, face_uvs[2].x, face_uvs[2].y, 0.0, 0.0 ])
	var merged : ArrayMesh = ArrayMesh.new()
	var merged_arrays : Array = []
	merged_arrays.resize(Mesh.ARRAY_MAX)
	merged_arrays[Mesh.ARRAY_VERTEX] = vertices
	merged_arrays[Mesh.ARRAY_INDEX] = indices
	merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged_arrays)
	# Texels are stored in rows of 4096
	var texel_count : int = max(1, attributes.size()/4)
	var width : int = min(texel_count, 4096)
	var height : int = (texel_count+width-1)/width
	attributes.resize(width*height*4)
	var image : Image = Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, attributes.to_byte_array())
	return { mesh=merged, attributes=image, face_count=indices.size()/3 }

static func get_high_poly_data(mesh : Mesh) -> HighPolyData:
	if not high_poly_data.has(mesh):
		while high_poly_data.size() >= MAX_HIGH_POLY_DATA:
			high_poly_data.erase(high_poly_data.keys()[0])
		var prepared : Dictionary = prepare_high_poly(mesh)
		var data : HighPolyData = HighPolyData.new()
		data.bvh = MMTexture.new()
		data.bvh.set_texture(MMBvhGenerator.generate(prepared.mesh))
		data.attributes = MMTexture.new()
		data.attributes.set_texture(ImageTexture.create_from_image(prepared.attributes))
		data.face_count = prepared.face_count
		high_poly_data[mesh] = data
	return high_poly_data[mesh]

## A part name without its low/high poly suffix (such as _low, _high, .lp or
## -hp) and Blender's duplicate number (.001), in lower case
static func part_name(surface_name : String) -> String:
	var name : String = surface_name.strip_edges().to_lower()
	var regex : RegEx = RegEx.create_from_string("(\\.\\d{3})?([._ -](low|high|lowpoly|highpoly|lp|hp))?(\\.\\d{3})?$")
	return regex.sub(name, "")

## The part names of the surfaces of a mesh (see part_name()), each one once,
## in the order of the surfaces
static func get_part_names(mesh : Mesh) -> PackedStringArray:
	var rv : PackedStringArray = PackedStringArray()
	for s in mesh.get_surface_count():
		var name : String = part_name(mesh.surface_get_name(s)) if mesh is ArrayMesh else ""
		if not name in rv:
			rv.append(name)
	return rv

## For each surface of a mesh, the index of its part name in part_names, or
## -1 when it is not in it (or the surface has no name)
static func get_surface_parts(mesh : Mesh, part_names : PackedStringArray) -> PackedInt32Array:
	var rv : PackedInt32Array = PackedInt32Array()
	for s in mesh.get_surface_count():
		var name : String = part_name(mesh.surface_get_name(s)) if mesh is ArrayMesh else ""
		rv.append(part_names.find(name) if name != "" else -1)
	return rv

## All triangle surfaces of a mesh merged in a single surface with normals and
## tangents, and for each vertex the index of the surface it comes from
static func merge_parts(mesh : Mesh) -> Dictionary:
	var vertices : PackedVector3Array = PackedVector3Array()
	var normals : PackedVector3Array = PackedVector3Array()
	var tangents : PackedFloat32Array = PackedFloat32Array()
	var uvs : PackedVector2Array = PackedVector2Array()
	var indices : PackedInt32Array = PackedInt32Array()
	var surfaces : PackedInt32Array = PackedInt32Array()
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var surface_tool : SurfaceTool = SurfaceTool.new()
		surface_tool.create_from(mesh, s)
		var arrays : Array = mesh.surface_get_arrays(s)
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
	var merged_arrays : Array = []
	merged_arrays.resize(Mesh.ARRAY_MAX)
	merged_arrays[Mesh.ARRAY_VERTEX] = vertices
	merged_arrays[Mesh.ARRAY_NORMAL] = normals
	merged_arrays[Mesh.ARRAY_TANGENT] = tangents
	merged_arrays[Mesh.ARRAY_TEX_UV] = uvs
	merged_arrays[Mesh.ARRAY_INDEX] = indices
	var merged : ArrayMesh = ArrayMesh.new()
	merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged_arrays)
	return { mesh=merged, surfaces=surfaces }

## The parts of a low poly mesh matched with those of a high poly mesh: for
## each low poly surface, the index of the high poly part with the same name
## (or -1), and the names of the low poly parts that have no match
static func match_parts(low_mesh : Mesh, high_mesh : Mesh) -> Dictionary:
	var surface_parts : PackedInt32Array = get_surface_parts(low_mesh, get_part_names(high_mesh))
	var unmatched : PackedStringArray = PackedStringArray()
	for s in surface_parts.size():
		var name : String = low_mesh.surface_get_name(s) if low_mesh is ArrayMesh else ""
		if name == "":
			name = "(unnamed)"
		if surface_parts[s] == -1 and not name in unmatched:
			unmatched.append(name)
	return { surface_parts=surface_parts, unmatched=unmatched }

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
## start from it and front is not used. See the top of this file for options.
static func bake(low_mesh : Mesh, high_mesh : Mesh, map : String, size : int, front : float = 0.01, rear : float = 0.01, samples : int = 4, force : bool = false, cage_mesh : Mesh = null, options : Dictionary = {}) -> MMTexture:
	assert(map in MAPS)
	var key : String = "%d:%d:%s:%d:%f:%f:%d:%d" % [ low_mesh.get_instance_id(), high_mesh.get_instance_id(), map, size, front, rear, samples, cage_mesh.get_instance_id() if cage_mesh else 0 ]
	for o in options.keys():
		key += ":%s=%s" % [ o, str(options[o].get_instance_id()) if options[o] is Object else str(options[o]) ]
	if force:
		baked_maps.erase(key)
	if not baked_maps.has(key):
		var low : Mesh
		# For each low poly vertex, the high poly part its rays can hit (-1 for any)
		var vertex_parts : PackedFloat32Array = PackedFloat32Array()
		if options.get("match_by_name", false):
			for s in low_mesh.get_surface_count():
				if low_mesh.surface_get_arrays(s)[Mesh.ARRAY_TEX_UV] == null:
					push_error("The mesh has no UVs, it cannot be baked")
					return await MMMapGenerator.get_map(null, map)
			# Parts are merged here, to know the part of each vertex
			var merged : Dictionary = merge_parts(low_mesh)
			low = merged.mesh
			var matches : Dictionary = match_parts(low_mesh, high_mesh)
			if not matches.unmatched.is_empty():
				push_warning("Low poly parts without a high poly part of the same name (their rays hit all parts): %s" % ", ".join(matches.unmatched))
			for s in merged.surfaces:
				vertex_parts.append(matches.surface_parts[s])
			if cage_mesh != null:
				cage_mesh = merge_parts(cage_mesh).mesh
		else:
			# Meshes with several surfaces are merged (as for mesh maps)
			low = MMMapGenerator.get_single_surface_mesh(low_mesh)
			if cage_mesh != null:
				cage_mesh = MMMapGenerator.get_single_surface_mesh(cage_mesh)
		if low.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV] == null:
			push_error("The mesh has no UVs, it cannot be baked")
			return await MMMapGenerator.get_map(null, map)
		if map == "texture":
			var error : String = check_texture_transfer(high_mesh, options)
			if error != "":
				push_error(error)
				return await MMMapGenerator.get_map(null, map)
		# The seams map is used to dilate the result
		var seams : MMTexture = await MMMapGenerator.get_map(low, "seams", size)
		while busy:
			await mm_globals.get_tree().process_frame
		busy = true
		var texture : MMTexture = MMTexture.new()
		var start_time : int = Time.get_ticks_msec()
		await mm_renderer.thread_run(generate, [ low, high_mesh, map, size, front, rear, samples, seams, texture, cage_mesh, options, vertex_parts ])
		print_verbose("Baked %s from high poly mesh in %d ms" % [ map, Time.get_ticks_msec()-start_time ])
		# Only the most recent maps are kept (each one is a 32 bits float texture)
		while baked_maps.size() >= MAX_BAKED_MAPS:
			baked_maps.erase(baked_maps.keys()[0])
		baked_maps[key] = texture
		busy = false
	return baked_maps[key]

## Why the texture map cannot be baked ("" if it can): it needs the high poly
## texture and UVs
static func check_texture_transfer(high_mesh : Mesh, options : Dictionary) -> String:
	if not options.get("high_texture") is Texture2D:
		return "The transferred texture map needs the texture of the high poly mesh"
	for s in high_mesh.get_surface_count():
		if high_mesh.surface_get_arrays(s)[Mesh.ARRAY_TEX_UV] != null:
			return ""
	return "The high poly mesh has no UVs, its texture cannot be transferred"

## Returns the vertices of the cage, in the same order as those of the low
## poly mesh, or an empty array if their topologies don't match
static func get_cage_vertices(low : Mesh, cage_mesh : Mesh) -> PackedVector3Array:
	var cage : Mesh = with_tangents(cage_mesh)
	var low_arrays : Array = low.surface_get_arrays(0)
	var cage_arrays : Array = cage.surface_get_arrays(0)
	if cage_arrays[Mesh.ARRAY_VERTEX].size() != low_arrays[Mesh.ARRAY_VERTEX].size() or cage_arrays[Mesh.ARRAY_INDEX] != low_arrays[Mesh.ARRAY_INDEX]:
		return PackedVector3Array()
	return cage_arrays[Mesh.ARRAY_VERTEX]

## An image texture as an MMTexture (8 bits images are converted, as
## MMTexture only handles float formats)
static func to_mm_texture(texture : Texture2D) -> MMTexture:
	var image : Image = texture.get_image() if texture != null else null
	if image == null:
		image = Image.create(1, 1, false, Image.FORMAT_RGBAH)
	elif not image.get_format() in [ Image.FORMAT_RF, Image.FORMAT_RGBAF, Image.FORMAT_RH, Image.FORMAT_RGBAH ]:
		image = image.duplicate()
		image.convert(Image.FORMAT_RGBAH)
	var rv : MMTexture = MMTexture.new()
	rv.set_texture(ImageTexture.create_from_image(image))
	return rv

## Bakes a map of a single surface low poly mesh (see bake()) in texture.
## vertex_parts is, for each low poly vertex, the high poly part its rays can
## hit (-1 for any, and empty for no restriction).
static func generate(low_mesh : Mesh, high_mesh : Mesh, map : String, size : int, front : float, rear : float, samples : int, seams : MMTexture, texture : MMTexture, cage_mesh : Mesh = null, options : Dictionary = {}, vertex_parts : PackedFloat32Array = PackedFloat32Array()) -> void:
	var data : HighPolyData = get_high_poly_data(high_mesh)
	var low : Mesh = with_tangents(low_mesh)
	if vertex_parts.is_empty():
		vertex_parts.resize(low.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size())
		vertex_parts.fill(-1.0)
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
	pipeline.extra_buffers.append(vertex_parts.to_byte_array())
	pipeline.add_parameter_or_texture("use_cage", "int", 0 if cage_vertices.is_empty() else 1)
	var skew_map = options.get("skew_map")
	pipeline.add_parameter_or_texture("use_skew", "int", 1 if skew_map is Texture2D else 0)
	pipeline.add_parameter_or_texture("skew_tex", "sampler2D", to_mm_texture(skew_map if skew_map is Texture2D else null))
	var high_texture = options.get("high_texture")
	pipeline.add_parameter_or_texture("high_texture", "sampler2D", to_mm_texture(high_texture if high_texture is Texture2D else null))
	pipeline.add_parameter_or_texture("bvh_data", "sampler2D", data.bvh)
	pipeline.add_parameter_or_texture("attribute_data", "sampler2D", data.attributes)
	pipeline.add_parameter_or_texture("prev_iteration_tex", "sampler2D", texture)
	pipeline.add_parameter_or_texture("front_dist", "float", front*diagonal)
	pipeline.add_parameter_or_texture("rear_dist", "float", rear*diagonal)
	pipeline.add_parameter_or_texture("aabb_position", "vec3", aabb.position)
	pipeline.add_parameter_or_texture("aabb_size", "vec3", aabb.size)
	pipeline.add_parameter_or_texture("mode", "int", MAPS.find(map))
	pipeline.add_parameter_or_texture("iteration", "int", 1)
	pipeline.add_parameter_or_texture("jitter", "vec2", Vector2(0, 0))
	var vertex_shader : String = load("res://addons/material_maker/map_generator/highpoly_vertex.tres").text
	var fragment_shader : String = load("res://addons/material_maker/map_generator/highpoly_fragment.tres").text
	if not await pipeline.set_shader(vertex_shader, fragment_shader):
		push_error("Cannot compile high poly baking shader")
		return
	for i in max(1, samples):
		pipeline.set_parameter("iteration", i+1)
		pipeline.set_parameter("prev_iteration_tex", texture)
		pipeline.set_parameter("jitter", get_jitter(i))
		pipeline.in_thread_render(Vector2i(size, size), 3, texture)
	# Extend the map past UV seams
	var dilate_pipeline : MMComputeShader = MMComputeShader.new()
	dilate_pipeline.clear()
	dilate_pipeline.add_parameter_or_texture("tex", "sampler2D", texture)
	dilate_pipeline.add_parameter_or_texture("pixels", "int", size/4)
	dilate_pipeline.add_parameter_or_texture("seams_map", "sampler2D", seams)
	await dilate_pipeline.set_shader(load("res://addons/material_maker/map_generator/dilate_compute.tres").text, 3)
	dilate_pipeline.in_thread_render_ext([texture], Vector2i(size, size))
