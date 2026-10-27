extends RefCounted

## Loads an OBJ file. With split_materials, each material (usemtl) is a
## separate surface (used to bake material IDs). With split_objects, each
## object or group (o, g) is a separate surface named after it (used to match
## low and high poly parts by name).
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
	# Vertex colors ("v x y z r g b", as exported by ZBrush and others)
	var hasCol := newTriMsh.colors.size() == newTriMsh.vertices.size()

	var mdl : ArrayMesh = ArrayMesh.new()
	var material_count : int = max(1, newTriMsh.material_count) if split_materials else 1
	var object_names : Array = newTriMsh.objects.keys()
	var object_count : int = max(1, object_names.size()) if split_objects else 1
	for surface in material_count*object_count:
		var material : int = surface%material_count
		var object : int = surface/material_count
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var empty : bool = true
		for i in newTriMsh.indices.size():
			var triangle : Triangle = newTriMsh.indices[i]
			if split_materials and triangle.material != material:
				continue
			if split_objects and triangle.object != object:
				continue
			empty = false
			for v in 3:
				if hasTex:
					st.set_uv(newTriMsh.uvs[triangle.get("uv_id_%d" % v)])
				if hasNrm:
					st.set_normal(newTriMsh.normals[triangle.get("nrm_id_%d" % v)])
				if hasCol:
					st.set_color(newTriMsh.colors[triangle.get("id_%d" % v)])
				st.add_vertex(newTriMsh.vertices[triangle.get("id_%d" % v)])
		if empty:
			continue
		if !hasNrm:
			st.generate_normals()
		if hasTex:
			st.generate_tangents()
		st.commit(mdl)
		if split_objects and not object_names.is_empty():
			mdl.surface_set_name(mdl.get_surface_count()-1, object_names[object])

	return mdl

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
				if lineData.size() >= 7:
					newMsh.colors.push_back(Color(float(lineData[4]), float(lineData[5]), float(lineData[6])))
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
						# Faces before the first object belong to it
						newMsh.objects[object_name] = newMsh.objects.size()
					newMsh.current_object = newMsh.objects[object_name]
			"us":
				if lineData.size() >= 2 and lineData[0] == "usemtl":
					if not newMsh.materials.has(lineData[1]):
						newMsh.materials[lineData[1]] = newMsh.materials.size()
					newMsh.current_material = newMsh.materials[lineData[1]]
					newMsh.material_count = newMsh.materials.size()
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
	var colors : Array
	var materials : Dictionary = {}
	var current_material : int = 0
	var material_count : int = 0
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
