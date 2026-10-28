class_name MMMeshLoader

static func get_file_dialog_filters() -> Array[String]:
	return [ "*.glb,*.gltf;GLTF file", "*.obj;Wavefront OBJ file", "*.fbx;FBX file" ]

static func load_gltf_mesh(file_path) -> ArrayMesh:
	# Contributed by wojtekpil
	# This will load all meshes of the gltf file in a single mesh
	var gltf : GLTFDocument = GLTFDocument.new()
	var gltf_state : GLTFState = GLTFState.new()
	if not FileAccess.file_exists(file_path):
		printerr("GLTF/GLB file does not exists or is not accesible")
		return null
	var glb_filebytes = FileAccess.get_file_as_bytes(file_path)
	if glb_filebytes == null:
		printerr("GLTF/GLB file data is null")
		return null
	var err = gltf.append_from_buffer(glb_filebytes, "", gltf_state)
	if err != OK:
		printerr("Failure during parsing GLTF/GLB buffer")
		return null
	var node: Node = gltf.generate_scene(gltf_state)
	var mesh : ArrayMesh = mesh_from_scene(node)
	node.free()
	if mesh == null:
		printerr("GLTF/GLB does not include any meshes")
	return mesh

static func load_fbx_mesh(file_path) -> ArrayMesh:
	var fbx : FBXDocument = FBXDocument.new()
	var fbx_state : FBXState = FBXState.new()
	if not FileAccess.file_exists(file_path):
		push_error("FBX file does not exists or is not accessible")
		return null
	var fbx_filebytes = FileAccess.get_file_as_bytes(file_path)
	if fbx_filebytes == null:
		push_error("FBX file data is null")
		return null
	var err = fbx.append_from_buffer(fbx_filebytes, "", fbx_state)
	if err != OK:
		push_error("Failure during parsing FBX buffer")
		return null
	var node: Node = fbx.generate_scene(fbx_state)
	var mesh : ArrayMesh = mesh_from_scene(node)
	node.free()
	if mesh == null:
		push_error("FBX does not include any meshes")
	return mesh

## A copy of a mesh with all its triangle surfaces merged into one (the mesh
## itself if it has a single surface)
static func merge_surfaces(mesh : Mesh) -> Mesh:
	if mesh == null or mesh.get_surface_count() < 2:
		return mesh
	var surface_tool : SurfaceTool = SurfaceTool.new()
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) == Mesh.PRIMITIVE_TRIANGLES:
			surface_tool.append_from(mesh, s, Transform3D.IDENTITY)
	var merged : ArrayMesh = surface_tool.commit()
	if mesh.has_meta("file_path"):
		merged.set_meta("file_path", mesh.get_meta("file_path"))
	return merged

## All meshes of a scene in a single mesh, in the scene's space, with a
## surface per mesh surface (keeping its material) named after its node
static func merge_mesh_instances(node : Node) -> ArrayMesh:
	var instances : Array[Node] = node.find_children("*", "MeshInstance3D", true, false)
	if node is MeshInstance3D:
		instances.push_front(node)
	if instances.is_empty():
		return null
	var merged : ArrayMesh = ArrayMesh.new()
	for instance : MeshInstance3D in instances:
		if instance.mesh == null:
			continue
		# The scene is not in a tree, so global transforms are computed here.
		# Skinned meshes are kept in their bind pose (glTF ignores the
		# transform of skinned mesh nodes).
		var transform : Transform3D = Transform3D.IDENTITY
		if instance.skin == null:
			var parent : Node = instance
			while parent is Node3D:
				transform = parent.transform*transform
				parent = parent.get_parent()
		var normal_basis : Basis = transform.basis.inverse().transposed()
		# Mirroring transforms reverse the winding of triangles
		var mirrored : bool = transform.basis.determinant() < 0.0
		for s in instance.mesh.get_surface_count():
			var source : Array = instance.mesh.surface_get_arrays(s)
			var vertices : PackedVector3Array = source[Mesh.ARRAY_VERTEX]
			if vertices.is_empty():
				continue
			# Only keep the arrays used by Material Maker (skinning and
			# custom data are dropped)
			var arrays : Array = []
			arrays.resize(Mesh.ARRAY_MAX)
			for i in vertices.size():
				vertices[i] = transform*vertices[i]
			arrays[Mesh.ARRAY_VERTEX] = vertices
			if source[Mesh.ARRAY_NORMAL] != null:
				var normals : PackedVector3Array = source[Mesh.ARRAY_NORMAL]
				for i in normals.size():
					normals[i] = (normal_basis*normals[i]).normalized()
				arrays[Mesh.ARRAY_NORMAL] = normals
			if source[Mesh.ARRAY_TANGENT] != null:
				var tangents : PackedFloat32Array = source[Mesh.ARRAY_TANGENT]
				for i in tangents.size()/4:
					var t : Vector3 = (transform.basis*Vector3(tangents[4*i], tangents[4*i+1], tangents[4*i+2])).normalized()
					tangents[4*i] = t.x
					tangents[4*i+1] = t.y
					tangents[4*i+2] = t.z
					if mirrored:
						tangents[4*i+3] = -tangents[4*i+3]
				arrays[Mesh.ARRAY_TANGENT] = tangents
			for a in [ Mesh.ARRAY_COLOR, Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_INDEX ]:
				arrays[a] = source[a]
			var primitive : Mesh.PrimitiveType = instance.mesh.surface_get_primitive_type(s)
			if mirrored and primitive == Mesh.PRIMITIVE_TRIANGLES:
				var indices : PackedInt32Array = source[Mesh.ARRAY_INDEX] if source[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(vertices.size()))
				for i in range(0, indices.size()-2, 3):
					var swap : int = indices[i+1]
					indices[i+1] = indices[i+2]
					indices[i+2] = swap
				arrays[Mesh.ARRAY_INDEX] = indices
			merged.add_surface_from_arrays(primitive, arrays)
			var surface : int = merged.get_surface_count()-1
			merged.surface_set_name(surface, instance.name)
			merged.surface_set_material(surface, instance.get_active_material(s))
	return merged

## The triangle surfaces of a mesh that use the same material merged into a
## single surface
static func merge_surfaces_by_material(mesh : ArrayMesh) -> ArrayMesh:
	# Surfaces grouped by material, in order of first use
	var groups : Dictionary = {}
	for s in mesh.get_surface_count():
		var key : Array = [ mesh.surface_get_material(s), mesh.surface_get_primitive_type(s) ]
		if key[1] != Mesh.PRIMITIVE_TRIANGLES:
			key.push_back(s)
		if not groups.has(key):
			groups[key] = []
		groups[key].push_back(s)
	var merged : ArrayMesh = ArrayMesh.new()
	for key in groups.keys():
		var surfaces : Array = groups[key]
		if surfaces.size() == 1:
			merged.add_surface_from_arrays(key[1], mesh.surface_get_arrays(surfaces[0]))
		else:
			merged.add_surface_from_arrays(key[1], concatenate_surfaces(mesh, surfaces))
		var surface : int = merged.get_surface_count()-1
		merged.surface_set_name(surface, key[0].resource_name if key[0] != null and key[0].resource_name != "" else mesh.surface_get_name(surfaces[0]))
		merged.surface_set_material(surface, key[0])
	return merged

## The arrays of several triangle surfaces of a mesh, in a single indexed
## surface. Arrays that only some of the surfaces have are filled with
## default values for the others.
static func concatenate_surfaces(mesh : Mesh, surfaces : Array) -> Array:
	var sources : Array = surfaces.map(func(s): return mesh.surface_get_arrays(s))
	var has : Callable = func(a : int) -> bool: return sources.any(func(source): return source[a] != null)
	var vertices : PackedVector3Array = PackedVector3Array()
	var normals : PackedVector3Array = PackedVector3Array()
	var tangents : PackedFloat32Array = PackedFloat32Array()
	var colors : PackedColorArray = PackedColorArray()
	var uvs : PackedVector2Array = PackedVector2Array()
	var uv2s : PackedVector2Array = PackedVector2Array()
	var indices : PackedInt32Array = PackedInt32Array()
	for source in sources:
		var count : int = source[Mesh.ARRAY_VERTEX].size()
		var source_indices : PackedInt32Array = source[Mesh.ARRAY_INDEX] if source[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(count))
		for i in source_indices:
			indices.push_back(vertices.size()+i)
		vertices.append_array(source[Mesh.ARRAY_VERTEX])
		var fill : Array = []
		fill.resize(count)
		if source[Mesh.ARRAY_NORMAL] != null:
			normals.append_array(source[Mesh.ARRAY_NORMAL])
		else:
			fill.fill(Vector3.UP)
			normals.append_array(PackedVector3Array(fill))
		if source[Mesh.ARRAY_TANGENT] != null:
			tangents.append_array(source[Mesh.ARRAY_TANGENT])
		else:
			for i in count:
				tangents.append_array([ 1.0, 0.0, 0.0, 1.0 ])
		if source[Mesh.ARRAY_COLOR] != null:
			colors.append_array(source[Mesh.ARRAY_COLOR])
		else:
			fill.fill(Color.WHITE)
			colors.append_array(PackedColorArray(fill))
		if source[Mesh.ARRAY_TEX_UV] != null:
			uvs.append_array(source[Mesh.ARRAY_TEX_UV])
		else:
			fill.fill(Vector2.ZERO)
			uvs.append_array(PackedVector2Array(fill))
		if source[Mesh.ARRAY_TEX_UV2] != null:
			uv2s.append_array(source[Mesh.ARRAY_TEX_UV2])
		else:
			fill.fill(Vector2.ZERO)
			uv2s.append_array(PackedVector2Array(fill))
	var arrays : Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_INDEX] = indices
	if has.call(Mesh.ARRAY_NORMAL):
		arrays[Mesh.ARRAY_NORMAL] = normals
	if has.call(Mesh.ARRAY_TANGENT):
		arrays[Mesh.ARRAY_TANGENT] = tangents
	if has.call(Mesh.ARRAY_COLOR):
		arrays[Mesh.ARRAY_COLOR] = colors
	if has.call(Mesh.ARRAY_TEX_UV):
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	if has.call(Mesh.ARRAY_TEX_UV2):
		arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	return arrays

## The meshes of an imported (glTF or FBX) scene in a single mesh. A scene
## with a single mesh gives that mesh as it is. Otherwise all meshes are
## merged with their transforms applied, with a surface per material (so
## Material Maker, that uses the first surface, sees all of a model that
## has a single material).
static func mesh_from_scene(node : Node) -> ArrayMesh:
	var instances : Array[Node] = node.find_children("*", "MeshInstance3D", true, false)
	if node is MeshInstance3D:
		instances.push_front(node)
	instances = instances.filter(func(instance): return instance.mesh != null)
	if instances.is_empty():
		return null
	if instances.size() == 1:
		return instances[0].mesh
	return merge_surfaces_by_material(merge_mesh_instances(node))

static func load_scene_parts(file_path : String) -> ArrayMesh:
	var state
	var document
	if file_path.get_extension().matchn("fbx"):
		document = FBXDocument.new()
		state = FBXState.new()
	else:
		document = GLTFDocument.new()
		state = GLTFState.new()
	if not FileAccess.file_exists(file_path) or document.append_from_buffer(FileAccess.get_file_as_bytes(file_path), "", state) != OK:
		push_error("Cannot load %s" % file_path)
		return null
	var node : Node = document.generate_scene(state)
	var mesh : ArrayMesh = merge_mesh_instances(node)
	node.free()
	return mesh

## Loads a mesh. With split_materials, OBJ materials are separate surfaces
## (glTF and FBX meshes always have a surface per material). With parts, each
## object (OBJ objects and groups, glTF and FBX mesh nodes) is a separate
## surface named after it, and all meshes of glTF and FBX files are loaded.
static func load_mesh(path : String, split_materials : bool = false, parts : bool = false) -> ArrayMesh:
	if path == null:
		return null
	var ext : String = path.get_extension()
	var mesh : ArrayMesh = null
	if ext.matchn("obj"):
		var obj_loader = load("res://addons/material_maker/loaders/obj_loader.gd")
		mesh = obj_loader.load_obj_file(path, split_materials, parts)
	elif parts and (ext.matchn("glb") or ext.matchn("gltf") or ext.matchn("fbx")):
		mesh = load_scene_parts(path)
	elif ext.matchn("glb") or ext.matchn("gltf"):
		mesh = load_gltf_mesh(path)
	elif ext.matchn("fbx"):
		mesh = load_fbx_mesh(path)
	if mesh:
		mesh.set_meta("file_path", path)
	return mesh
