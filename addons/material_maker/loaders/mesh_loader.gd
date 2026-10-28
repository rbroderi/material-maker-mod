class_name MMMeshLoader

static func get_file_dialog_filters() -> Array[String]:
	return [ "*.glb,*.gltf;GLTF file", "*.obj;Wavefront OBJ file", "*.fbx;FBX file" ]

static func load_gltf_mesh(file_path) -> ArrayMesh:
	# Contributed by wojtekpil
	# This will load gltf mesh and return #1 Mesh of #1 MeshInstance
	# Material Editing will work only on first surface too. This should be easy to
	# fix with MeshInstance.material_overwrite instaed of get_surface_override_material
	# Probably can be improved later to combine/support all Meshes in GTLF
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
	if node is MeshInstance3D:
		return node.mesh
	var mesh_instances : Array[Node] = node.find_children("*", "MeshInstance3D", true, false)
	if mesh_instances.size() == 0:
		printerr("GLTF/GLB does not include any meshes")
		return null
	return mesh_instances[0].mesh

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
	if node is MeshInstance3D:
		return node.mesh
	var mesh_instances : Array[Node] = node.find_children("*", "MeshInstance3D", true, false)
	if mesh_instances.size() == 0:
		push_error("FBX does not include any meshes")
		return null
	return mesh_instances[0].mesh

## All meshes of a scene in a single mesh, in the scene's space, with a
## surface per mesh (and material) named after its node
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
		# The scene is not in a tree, so global transforms are computed here
		var transform : Transform3D = instance.transform
		var parent : Node = instance.get_parent()
		while parent is Node3D:
			transform = parent.transform*transform
			parent = parent.get_parent()
		for s in instance.mesh.get_surface_count():
			var surface_tool : SurfaceTool = SurfaceTool.new()
			surface_tool.create_from(instance.mesh, s)
			var arrays : Array = surface_tool.commit_to_arrays()
			var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for i in vertices.size():
				vertices[i] = transform*vertices[i]
			arrays[Mesh.ARRAY_VERTEX] = vertices
			var normal_basis : Basis = transform.basis.inverse().transposed()
			if arrays[Mesh.ARRAY_NORMAL] != null:
				var normals : PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
				for i in normals.size():
					normals[i] = (normal_basis*normals[i]).normalized()
				arrays[Mesh.ARRAY_NORMAL] = normals
			if arrays[Mesh.ARRAY_TANGENT] != null:
				var tangents : PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
				for i in tangents.size()/4:
					var t : Vector3 = (transform.basis*Vector3(tangents[4*i], tangents[4*i+1], tangents[4*i+2])).normalized()
					tangents[4*i] = t.x
					tangents[4*i+1] = t.y
					tangents[4*i+2] = t.z
				arrays[Mesh.ARRAY_TANGENT] = tangents
			merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			merged.surface_set_name(merged.get_surface_count()-1, instance.name)
	return merged

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

## The surfaces of a mesh merged into a single surface, for tools that use
## only one surface (mesh maps). Returns the mesh itself if it has a single
## surface.
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
