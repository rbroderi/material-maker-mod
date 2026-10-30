extends RefCounted

## Loads an OBJ file. Vertex colors ("v x y z r g b", as written by ZBrush,
## MeshLab and others) are loaded in the color array of the mesh.
## By default, the mesh has a single surface. With split_materials, each
## material (usemtl) is a separate surface. With split_objects, each object
## or group (o, g) is a separate surface named after it.
static func load_obj_file(path : String, split_materials : bool = false, split_objects : bool = false) -> ArrayMesh:
	if path == null:
		return null
	var ext := path.get_extension()
	if !ext.matchn("obj"):
		print("given file isn't an OBJ mesh")
		return null

	var mdlFile : FileAccess = FileAccess.open(path, FileAccess.READ)
	if mdlFile == null:
		print("cannot open file at path[", path,"]")
		#mdlFile.close()
		return null
	var newTriMsh : TriMesh = _import_obj(mdlFile)
	mdlFile.close()

	var hasTex := newTriMsh.uvs.size() > 0
	var hasNrm := newTriMsh.normals.size() > 0
	var hasCol := newTriMsh.has_colors

	# Triangles of each surface, in file order. Surfaces are sorted by object,
	# then by material, in order of first use.
	var material_count : int = maxi(1, newTriMsh.materials.size()) if split_materials else 1
	var surfaces : Dictionary = {}
	if split_materials or split_objects:
		for triangle : Triangle in newTriMsh.indices:
			var surface : int = 0
			if split_objects:
				surface = triangle.object*material_count
			if split_materials:
				surface += triangle.material
			if not surfaces.has(surface):
				surfaces[surface] = []
			surfaces[surface].push_back(triangle)
	else:
		surfaces[0] = newTriMsh.indices
	var surface_ids : Array = surfaces.keys()
	surface_ids.sort()
	var object_names : Array = newTriMsh.objects.keys()

	var mdl : ArrayMesh = ArrayMesh.new()
	for surface : int in surface_ids:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for triangle : Triangle in surfaces[surface]:
			_add_triangle(st, newTriMsh, triangle, hasTex, hasNrm, hasCol)
		if !hasNrm:
			st.generate_normals()
		if hasTex:
			st.generate_tangents()
		st.commit(mdl)
		if split_objects and not object_names.is_empty():
			mdl.surface_set_name(mdl.get_surface_count()-1, object_names[surface/material_count])

	return mdl

static func _add_triangle(st : SurfaceTool, mesh : TriMesh, triangle : Triangle, hasTex : bool, hasNrm : bool, hasCol : bool) -> void:
	if hasTex:
		st.set_uv(mesh.uvs[triangle.uv_id_0])
	if hasNrm:
		st.set_normal(mesh.normals[triangle.nrm_id_0])
	if hasCol:
		st.set_color(mesh.colors[triangle.id_0])
	st.add_vertex(mesh.vertices[triangle.id_0])

	if hasTex:
		st.set_uv(mesh.uvs[triangle.uv_id_1])
	if hasNrm:
		st.set_normal(mesh.normals[triangle.nrm_id_1])
	if hasCol:
		st.set_color(mesh.colors[triangle.id_1])
	st.add_vertex(mesh.vertices[triangle.id_1])

	if hasTex:
		st.set_uv(mesh.uvs[triangle.uv_id_2])
	if hasNrm:
		st.set_normal(mesh.normals[triangle.nrm_id_2])
	if hasCol:
		st.set_color(mesh.colors[triangle.id_2])
	st.add_vertex(mesh.vertices[triangle.id_2])

static func _obj_rel_indice(indice : Vector3, cur_vArr_size : int) -> Vector3:
	var output := Vector3.ZERO
	var indSign := indice.sign()
	output.x = indice.x - 1 if (indSign.x >= 0) else cur_vArr_size + indice.x
	output.y = indice.y - 1 if (indSign.y >= 0) else cur_vArr_size + indice.y
	output.z = indice.z - 1 if (indSign.z >= 0) else cur_vArr_size + indice.z

	return output

static func _import_obj(mdlFile : FileAccess) -> TriMesh:
	var newMsh := TriMesh.new()

	while !mdlFile.eof_reached():
		var mdlData := mdlFile.get_line()
		if mdlData.begins_with("#"):
			continue

		var f2c = mdlData.substr(0, 2)
		var lineData := mdlData.split(" ", false)

		match f2c:
			"v ":
				var vertex := Vector3(
					float(lineData[1]),
					float(lineData[2]),
					float(lineData[3])
				)
				newMsh.vertices.push_back(vertex)
				# Vertex colors, white for vertices that have none
				if lineData.size() >= 7:
					if not newMsh.has_colors:
						newMsh.has_colors = true
						newMsh.colors.resize(newMsh.vertices.size()-1)
						newMsh.colors.fill(Color(1.0, 1.0, 1.0))
					newMsh.colors.push_back(Color(float(lineData[4]), float(lineData[5]), float(lineData[6]), float(lineData[7]) if lineData.size() >= 8 else 1.0))
				elif newMsh.has_colors:
					newMsh.colors.push_back(Color(1.0, 1.0, 1.0))
			"vt":
				var uv := Vector2(
					float(lineData[1]),
					1.0 - float(lineData[2])
				)
				newMsh.uvs.push_back(uv)
			"vn":
				var normal := Vector3(
					float(lineData[1]),
					float(lineData[2]),
					float(lineData[3])
				)
				newMsh.normals.push_back(normal)
			"o ", "g ":
				if lineData.size() >= 2:
					var object_name : String = " ".join(lineData.slice(1))
					if not newMsh.objects.has(object_name):
						newMsh.objects[object_name] = newMsh.objects.size()
					# Faces before the first object or group belong to it
					newMsh.current_object = newMsh.objects[object_name]
			"us":
				if lineData.size() >= 2 and lineData[0] == "usemtl":
					if not newMsh.materials.has(lineData[1]):
						newMsh.materials[lineData[1]] = newMsh.materials.size()
					newMsh.current_material = newMsh.materials[lineData[1]]
			"f ":
				var misc = []

				for i in lineData.size() - 1:
					misc.push_back(lineData[i + 1].split("/"))
				for i in misc.size() - 2:
					var intVar : int = i + 2
					var num : int = misc[intVar].size()
					var vArr_size : int = newMsh.vertices.size()
					var tArr_size : int = newMsh.uvs.size()
					var nArr_size : int = newMsh.normals.size()

					var faceIndices = Vector3(
					int(misc[intVar][0]),
					int(misc[intVar-1][0]),
					int(misc[0][0]))
					faceIndices = _obj_rel_indice(faceIndices, vArr_size)

					var uvIndices : Vector3
					if num >= 2:
						uvIndices = Vector3(
						int(misc[intVar][1]),
						int(misc[intVar-1][1]),
						int(misc[0][1]))
					uvIndices = _obj_rel_indice(uvIndices, tArr_size)

					var normIndices : Vector3
					if num == 3:
						normIndices = Vector3(
						int(misc[intVar][2]),
						int(misc[intVar-1][2]),
						int(misc[0][2]))
					normIndices = _obj_rel_indice(normIndices, nArr_size)

					var triangle := Triangle.new()

					triangle.id_0 = int(faceIndices.x)
					triangle.id_1 = int(faceIndices.y)
					triangle.id_2 = int(faceIndices.z)

					triangle.uv_id_0 = int(uvIndices.x)
					triangle.uv_id_1 = int(uvIndices.y)
					triangle.uv_id_2 = int(uvIndices.z)

					triangle.nrm_id_0 = int(normIndices.x)
					triangle.nrm_id_1 = int(normIndices.y)
					triangle.nrm_id_2 = int(normIndices.z)

					triangle.material = newMsh.current_material
					triangle.object = newMsh.current_object

					newMsh.indices.push_back(triangle)

	return newMsh

class TriMesh:
	var vertices : Array
	var colors : PackedColorArray
	var has_colors : bool = false
	## Indices of materials and objects, by name
	var materials : Dictionary = {}
	var current_material : int = 0
	var objects : Dictionary = {}
	var current_object : int = 0
	var normals : Array
	var uvs : Array
	var indices : Array

class Triangle:
	var id_0 : int
	var uv_id_0 : int
	var nrm_id_0 : int
	var id_1 : int
	var uv_id_1 : int
	var nrm_id_1 : int
	var id_2 : int
	var uv_id_2 : int
	var nrm_id_2 : int
	var material : int = 0
	var object : int = 0
