extends Object
class_name MMHighPolyBaker


# High to low poly baking: maps of a high poly mesh are projected on the
# UV layout of a low poly mesh, by casting rays from a cage (the low poly
# surface pushed along its normals) towards the low poly surface.


const MAPS : Array[String] = [ "normal_tangent", "normal_object", "height", "color", "material_id", "position" ]

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
## builds a texture with 6 texels per face: the normals of its 3 vertices
## (the w component of the first one is the surface index), then their colors
static func prepare_high_poly(mesh : Mesh) -> Dictionary:
	var vertices : PackedVector3Array = PackedVector3Array()
	var indices : PackedInt32Array = PackedInt32Array()
	var attributes : PackedFloat32Array = PackedFloat32Array()
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
## start from it and front is not used.
static func bake(low_mesh : Mesh, high_mesh : Mesh, map : String, size : int, front : float = 0.01, rear : float = 0.01, samples : int = 4, force : bool = false, cage_mesh : Mesh = null) -> MMTexture:
	assert(map in MAPS)
	var key : String = "%d:%d:%s:%d:%f:%f:%d:%d" % [ low_mesh.get_instance_id(), high_mesh.get_instance_id(), map, size, front, rear, samples, cage_mesh.get_instance_id() if cage_mesh else 0 ]
	if force:
		baked_maps.erase(key)
	if not baked_maps.has(key):
		# Meshes with several surfaces are merged (as for mesh maps)
		var low : Mesh = MMMapGenerator.get_single_surface_mesh(low_mesh)
		if low.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV] == null:
			push_error("The mesh has no UVs, it cannot be baked")
			return await MMMapGenerator.get_map(null, map)
		if cage_mesh != null:
			cage_mesh = MMMapGenerator.get_single_surface_mesh(cage_mesh)
		# The seams map is used to dilate the result
		var seams : MMTexture = await MMMapGenerator.get_map(low, "seams", size)
		while busy:
			await mm_globals.get_tree().process_frame
		busy = true
		var texture : MMTexture = MMTexture.new()
		var start_time : int = Time.get_ticks_msec()
		await mm_renderer.thread_run(generate, [ low, high_mesh, map, size, front, rear, samples, seams, texture, cage_mesh ])
		print_verbose("Baked %s from high poly mesh in %d ms" % [ map, Time.get_ticks_msec()-start_time ])
		# Only the most recent maps are kept (each one is a 32 bits float texture)
		while baked_maps.size() >= MAX_BAKED_MAPS:
			baked_maps.erase(baked_maps.keys()[0])
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

## Bakes a map of a single surface low poly mesh (see bake()) in texture
static func generate(low_mesh : Mesh, high_mesh : Mesh, map : String, size : int, front : float, rear : float, samples : int, seams : MMTexture, texture : MMTexture, cage_mesh : Mesh = null) -> void:
	var data : HighPolyData = get_high_poly_data(high_mesh)
	var low : Mesh = with_tangents(low_mesh)
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
	pipeline.add_parameter_or_texture("use_cage", "int", 0 if cage_vertices.is_empty() else 1)
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
