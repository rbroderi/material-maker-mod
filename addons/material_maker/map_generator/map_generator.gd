extends Object
class_name MMMapGenerator


static var mesh_maps : Dictionary = {}
static var debug_index : int = 0

static var error_texture : MMTexture


const SHADERS_PATH : String = "res://addons/material_maker/map_generator"
const MAP_DEFINITIONS : Dictionary = {
	position = {
		type="simple",
		vertex = "position_vertex",
		fragment = "common_fragment",
		postprocess=["dilate"],
		dependencies=["seams"]
	},
	normal = {
		type="simple",
		vertex = "normal_vertex",
		fragment = "normal_fragment",
		postprocess=["dilate"],
		dependencies=["seams"]
	},
	tangent = {
		type="simple",
		vertex = "tangent_vertex",
		fragment = "normal_fragment",
		postprocess=["dilate"],
		dependencies=["seams"]
	},
	ambient_occlusion = {
		type="bvh",
		vertex = "ao_vertex",
		fragment = "ao_fragment",
		mode=0,
		postprocess=["dilate"],
		dependencies=["seams"]
	},
	bent_normals = {
		type="bvh",
		vertex = "ao_vertex",
		fragment = "ao_fragment",
		mode=1,
		postprocess=["dilate"],
		dependencies=["seams"]
	},
	thickness = {
		type="bvh",
		vertex = "ao_vertex",
		fragment = "ao_fragment",
		mode=2,
		postprocess=["dilate"],
		dependencies=["seams"]
	},
	curvature = {
		type="curvature",
		vertex = "curvature_vertex",
		fragment = "common_fragment",
		postprocess=["dilate"],
		dependencies=["seams"]
	},
	seams = {
		type="simple",
		vertex = "position_vertex",
		fragment = "common_fragment",
		postprocess=["seams_1", "seams_2"]
	},
	adjacency = {
		type="adjacency",
		vertex = "normal_vertex",
		fragment = "common_fragment",
		postprocess=["adjacency_dilate"],
		dependencies=["seams"]
	}
}


class DefaultProgress:
	var text : String
	var progress : int = 0
	
	func set_text(t : String):
		text = t
	
	func set_progress(v : float):
		if int(v*100.0) > progress:
			progress = int(v*100.0)
			print(text+" ("+str(progress)+"%)")


class UIProgress:
	var text : String
	var progress : int = 0
	
	func set_text(t : String):
		text = t
	
	func set_progress(v : float):
		if int(v*100.0) > progress:
			progress = int(v*100.0)
			mm_globals.main_window.set_tip_text(text+" ("+str(progress)+"%)", 0.0 if (progress >= 100) else 1.0)


## Shows the progress of generate() (called deferred, in the main thread). The
## progress object is an argument of the deferred call so that the call holds
## a reference to it: generate() runs in the rendering thread and drops its
## reference when it returns, and a deferred call on the object itself could
## run while it is being freed ("Bad address index" in set_progress()).
static func show_progress(progress, v : float) -> void:
	progress.set_progress(v)

static func generate(mesh : Mesh, map : String, size : int, texture : MMTexture):
	assert(mesh != null)
	print.call_deferred("Generating %s map for mesh %s" % [ map, str(mesh) ])
	var progress
	if mm_globals.main_window:
		progress = UIProgress.new()
	else:
		progress = DefaultProgress.new()
	progress.set_text("Generating "+map+" map")
	show_progress.call_deferred(progress, 0.0)
	var pixels : int = size/4
	var map_definition : Dictionary = MAP_DEFINITIONS[map]
	var mesh_pipeline : MMMeshRenderingPipeline = MMMeshRenderingPipeline.new()
	mesh_pipeline.cull_mode = RenderingDevice.POLYGON_CULL_DISABLED
	var vertex_shader : String = load(SHADERS_PATH+"/"+map_definition.vertex+".tres").text
	var fragment_shader : String = load(SHADERS_PATH+"/"+map_definition.fragment+".tres").text
	match map_definition.type:
		"simple":
			mesh_pipeline.mesh = mesh
			await mesh_pipeline.set_shader(vertex_shader, fragment_shader)
			mesh_pipeline.in_thread_render(Vector2i(size, size), 3, texture)
		"curvature":
			var curvature_generator : MMCurvatureGenerator = MMCurvatureGenerator.new()
			mesh_pipeline.mesh = curvature_generator.generate(mesh)
			await mesh_pipeline.set_shader(vertex_shader, fragment_shader)
			mesh_pipeline.in_thread_render(Vector2i(size, size), 3, texture)
		"adjacency":
			var adjacency_generator : MMAdjacencyGenerator = MMAdjacencyGenerator.new()
			mesh_pipeline.mesh = adjacency_generator.generate(mesh)
			await mesh_pipeline.set_shader(vertex_shader, fragment_shader)
			mesh_pipeline.in_thread_render(Vector2i(size, size), 3, texture)
		"bvh":
			mesh_pipeline.mesh = mesh
			var bvh : MMTexture = MMTexture.new()
			bvh.set_texture(MMBvhGenerator.generate(mesh))
			var ray_count = mm_globals.get_config("bake_ray_count")
			var ao_ray_dist = -mesh.get_aabb().size.length() if map == "thickness" else mm_globals.get_config("bake_ao_ray_dist")
			var ao_ray_bias = mm_globals.get_config("bake_ao_ray_bias")
			var denoise_radius = mm_globals.get_config("bake_denoise_radius")
			mesh_pipeline.add_parameter_or_texture("bvh_data", "sampler2D", bvh)
			mesh_pipeline.add_parameter_or_texture("prev_iteration_tex", "sampler2D", texture)
			mesh_pipeline.add_parameter_or_texture("max_dist", "float", ao_ray_dist)
			mesh_pipeline.add_parameter_or_texture("bias_dist", "float", ao_ray_bias)
			mesh_pipeline.add_parameter_or_texture("iteration", "int", 1)
			mesh_pipeline.add_parameter_or_texture("mode", "int", map_definition.mode)
			await mesh_pipeline.set_shader(vertex_shader, fragment_shader)
			print.call_deferred("Casting %d rays..." % ray_count)
			for i in range(ray_count):
				show_progress.call_deferred(progress, float(i)/ray_count)
				mesh_pipeline.set_parameter("iteration", i+1)
				mesh_pipeline.set_parameter("prev_iteration_tex", texture)
				mesh_pipeline.in_thread_render(Vector2i(size, size), 3, texture)
			
			if map == "bent_normals":
				print.call_deferred("Normalizing...")
				var normalize_pipeline : MMComputeShader = MMComputeShader.new()
				normalize_pipeline.clear()
				normalize_pipeline.add_parameter_or_texture("tex", "sampler2D", texture)
				await normalize_pipeline.set_shader(load("res://addons/material_maker/map_generator/normalize_compute.tres").text, 3)
				normalize_pipeline.in_thread_render_ext([texture], Vector2i(size, size))
			
			# Denoise
			if true:
				print.call_deferred("Denoising...")
				var denoise_pipeline : MMComputeShader = MMComputeShader.new()
				denoise_pipeline.clear()
				denoise_pipeline.add_parameter_or_texture("tex", "sampler2D", texture)
				denoise_pipeline.add_parameter_or_texture("radius", "int", 3)
				await denoise_pipeline.set_shader(load("res://addons/material_maker/map_generator/denoise_compute.tres").text, 3)
				denoise_pipeline.in_thread_render_ext([texture], Vector2i(size, size))

	# Extend the map past seams
	if pixels > 0 and map_definition.has("postprocess"):
		print.call_deferred("Postprocessing...")
		#texture.save_to_file("d:/debug_x_%d.png" % debug_index)
		debug_index += 1
		for p in map_definition.postprocess:
			var postprocess_pipeline : MMComputeShader = MMComputeShader.new()
			postprocess_pipeline.clear()
			postprocess_pipeline.add_parameter_or_texture("tex", "sampler2D", texture)
			postprocess_pipeline.add_parameter_or_texture("pixels", "int", pixels)
			match p:
				"adjacency_dilate", "dilate":
					var seams_map : MMTexture = mesh_maps[mesh]["seams:"+str(size)]
					postprocess_pipeline.add_parameter_or_texture("seams_map", "sampler2D", seams_map)
			var shader_string : String = load("res://addons/material_maker/map_generator/"+p+"_compute.tres").text
			await postprocess_pipeline.set_shader(shader_string, 3)
			postprocess_pipeline.in_thread_render_ext([texture], Vector2i(size, size))
			#texture.save_to_file("d:/debug_%d.png" % debug_index)
			debug_index += 1
		show_progress.call_deferred(progress, 1.0)

static var busy : bool = false

## Meshes with several surfaces, merged into one (map generators use a
## single surface)
static var merged_meshes : Dictionary = {}

## A mesh with a single surface: the mesh itself, or its surfaces merged
static func get_single_surface_mesh(mesh : Mesh) -> Mesh:
	if mesh != null and mesh.get_surface_count() > 1:
		if not merged_meshes.has(mesh):
			merged_meshes[mesh] = MMMeshLoader.merge_surfaces(mesh)
		return merged_meshes[mesh]
	return mesh

## Copies of meshes whose UVs are moved so that a UDIM tile is the [0, 1]
## square, by mesh instance id and tile
static var tile_meshes : Dictionary = {}
const MAX_TILE_MESHES : int = 8

## The mesh used to bake a UDIM tile (1001 is the [0, 1] square, 1002 is on
## its right and 1011 above it): a copy of the mesh with UVs moved by whole
## tiles, so that the faces of the tile are in [0, 1] and the faces of other
## tiles are outside of the map. The geometry is unchanged, so rays still hit
## the whole mesh (ambient occlusion, thickness) and positions keep the
## bounding box of the whole mesh. Godot's V axis points down (V = 1-v of
## mesh files), so tile rows go towards negative V.
static func get_tile_mesh(mesh : Mesh, tile : int) -> Mesh:
	if mesh == null or tile == 1001:
		return mesh
	var key : String = "%d:%d" % [ mesh.get_instance_id(), tile ]
	if not tile_meshes.has(key):
		# Only the most recent tile meshes are kept, and the maps generated
		# for the others are freed
		while tile_meshes.size() >= MAX_TILE_MESHES:
			var old_key : String = tile_meshes.keys()[0]
			forget_mesh(tile_meshes[old_key])
			tile_meshes.erase(old_key)
		tile_meshes[key] = create_tile_mesh(mesh, tile)
	return tile_meshes[key]

## A copy of a mesh with UVs moved for a UDIM tile (see get_tile_mesh()),
## with the same surfaces (and primitive types), surface names and metadata
static func create_tile_mesh(mesh : Mesh, tile : int) -> Mesh:
	var offset : Vector2 = Vector2((tile-1001)%10, -((tile-1001)/10))
	var rv : ArrayMesh = ArrayMesh.new()
	for s in mesh.get_surface_count():
		var arrays : Array = mesh.surface_get_arrays(s)
		if arrays[Mesh.ARRAY_TEX_UV] != null:
			var uvs : PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
			for i in uvs.size():
				uvs[i] -= offset
			arrays[Mesh.ARRAY_TEX_UV] = uvs
		rv.add_surface_from_arrays(mesh.surface_get_primitive_type(s), arrays)
		if mesh is ArrayMesh:
			rv.surface_set_name(s, mesh.surface_get_name(s))
	for m in mesh.get_meta_list():
		rv.set_meta(m, mesh.get_meta(m))
	return rv

## The UDIM tile of a UV (with Godot's V axis, see get_tile_mesh())
static func udim_tile(uv : Vector2) -> int:
	return 1001+int(floor(uv.x))+10*int(floor(1.0-uv.y))

## UDIM tiles of meshes, by mesh instance id (finding them reads all faces)
static var mesh_udim_tiles : Dictionary = {}

## The UDIM tiles used by the UVs of a mesh (sorted). The tile of a face is
## the tile of its center, since vertices can be on tile borders. Faces that
## are not in tiles 1001 to 1999 (negative UVs, U of 10 or more) are ignored.
static func udim_tiles(mesh : Mesh) -> PackedInt32Array:
	if mesh == null:
		return PackedInt32Array()
	var id : int = mesh.get_instance_id()
	if mesh_udim_tiles.has(id):
		return mesh_udim_tiles[id]
	var tiles : Dictionary = {}
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays : Array = mesh.surface_get_arrays(s)
		if arrays[Mesh.ARRAY_TEX_UV] == null:
			continue
		var uvs : PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var indices : PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(uvs.size()))
		for f in indices.size()/3:
			var center : Vector2 = (uvs[indices[3*f]]+uvs[indices[3*f+1]]+uvs[indices[3*f+2]])/3.0
			var tile : int = udim_tile(center)
			if center.x >= 0.0 and center.x < 10.0 and tile >= 1001 and tile <= 1999:
				tiles[tile] = true
	var rv : PackedInt32Array = PackedInt32Array(tiles.keys())
	rv.sort()
	mesh_udim_tiles[id] = rv
	return rv

## Forgets the maps generated for a mesh that is not used anymore
static func forget_mesh(mesh : Mesh) -> void:
	if merged_meshes.has(mesh):
		mesh_maps.erase(merged_meshes[mesh])
		merged_meshes.erase(mesh)
	mesh_maps.erase(mesh)

static func get_map(mesh : Mesh, map : String, size : int = 2048, force_generate : bool = false) -> MMTexture:
	mesh = get_single_surface_mesh(mesh)
	if mesh == null or size <= 0 or mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV] == null:
		if error_texture == null:
			error_texture = MMTexture.new()
			var image : Image = Image.create(1, 1, 0, Image.FORMAT_RGBAH)
			image.fill(Color(1.0, 0.0, 0.0))
			error_texture.set_texture(ImageTexture.create_from_image(image))
		return error_texture
	if ! mesh_maps.has(mesh):
		mesh_maps[mesh] = {}
	var field_name : String = map+":"+str(size)
	if force_generate:
		mesh_maps[mesh].erase(field_name)
	if not mesh_maps[mesh].has(field_name):
		if MAP_DEFINITIONS[map].has("dependencies"):
			for d in MAP_DEFINITIONS[map].dependencies:
				await get_map(mesh, d, size)
		#print("Creating map ", field_name, " for mesh ", mesh)
		while not mesh_maps[mesh].has(field_name):
			if busy:
				await mm_globals.get_tree().process_frame
			else:
				busy = true
				var texture : MMTexture = MMTexture.new()
				await mm_renderer.thread_run(generate, [mesh, map, size, texture])
				mesh_maps[mesh][field_name] = texture
				busy = false
	return mesh_maps[mesh][field_name] as MMTexture
