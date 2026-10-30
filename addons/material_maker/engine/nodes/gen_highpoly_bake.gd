@tool
extends MMGenMeshMap
class_name MMGenHighPolyBake


# Bakes maps of a high poly mesh onto the current (low poly) mesh


const BAKE_MAPS : Array[Dictionary] = [
	{
		name="Normal (tangent space)",
		output_type="rgb",
		map="normal_tangent",
		output="texture($TEXTURE, $UV).rgb"
	},
	{
		name="Normal (object space)",
		output_type="rgb",
		map="normal_object",
		output="2.0*texture($TEXTURE, $UV).rgb-vec3(1.0)"
	},
	{
		name="Height",
		output_type="f",
		map="height",
		output="texture($TEXTURE, $UV).r"
	},
	{
		name="Vertex color",
		output_type="rgb",
		map="color",
		output="texture($TEXTURE, $UV).rgb"
	},
	{
		name="Material ID",
		output_type="rgb",
		map="material_id",
		output="texture($TEXTURE, $UV).rgb"
	},
	{
		name="Position",
		output_type="rgb",
		map="position",
		output="$AABB_POSITION+$AABB_SIZE*texture($TEXTURE, $UV).rgb"
	},
	{
		name="Coverage",
		output_type="f",
		map="normal_tangent",
		output="texture($TEXTURE, $UV).a"
	}
]

const SAMPLES : Array[int] = [ 1, 4, 16 ]

## Loaded meshes, by path, modification time and options, shared by all nodes
## (so the high poly mesh data used for baking is built once)
static var loaded_meshes : Dictionary = {}
const MAX_LOADED_MESHES : int = 4
var update_pending : bool = false


func get_type() -> String:
	return "highpoly_bake"

func get_type_name() -> String:
	return "High Poly Bake"

func get_description() -> String:
	var desc_list : PackedStringArray = PackedStringArray()
	desc_list.push_back(TranslationServer.translate("High Poly Bake"))
	desc_list.push_back(TranslationServer.translate("Bakes maps of a high poly mesh onto the current custom mesh"))
	return "\n".join(desc_list)

func get_parameter_defs() -> Array:
	return [
		{ name="high_mesh", type="file", label="High poly", filters=MMMeshLoader.get_file_dialog_filters(), default="",
			longdesc="The high poly mesh, in the same space as the current mesh" },
		{ name="cage_mesh", type="file", label="Cage", filters=MMMeshLoader.get_file_dialog_filters(), default="",
			longdesc="Optional cage mesh, with the same topology as the current mesh (rays start from it, and the front distance is not used)" },
		{ name="map", type="enum", values=BAKE_MAPS, label="Map", default=0 },
		{ name="size", type="size", label="Size", first=8, last=13, default=11 },
		{ name="front", type="float", label="Front distance", min=0.0, max=0.2, step=0.001, default=0.01,
			longdesc="Maximum distance of the high poly surface in front of the current mesh, relative to its bounding box diagonal" },
		{ name="rear", type="float", label="Rear distance", min=0.0, max=0.2, step=0.001, default=0.01,
			longdesc="Maximum distance of the high poly surface behind the current mesh, relative to its bounding box diagonal" },
		{ name="samples", type="enum", label="Antialiasing", default=1,
			values=[ { name="None", value="1" }, { name="4 samples", value="4" }, { name="16 samples", value="16" } ] },
	]

func get_map_definition() -> Dictionary:
	return BAKE_MAPS[get_parameter("map")]

func get_mesh_parameter(parameter_name : String) -> Mesh:
	var path : String = get_parameter(parameter_name)
	if path == "" or not FileAccess.file_exists(path):
		return null
	# High poly materials are separate surfaces, for material ID maps
	var split_materials : bool = parameter_name == "high_mesh"
	# Reload the mesh when the file changes
	var key : String = "%s:%d:%s" % [ path, FileAccess.get_modified_time(path), split_materials ]
	if not loaded_meshes.has(key):
		while loaded_meshes.size() >= MAX_LOADED_MESHES:
			loaded_meshes.erase(loaded_meshes.keys()[0])
		loaded_meshes[key] = MMMeshLoader.load_mesh(path, split_materials)
	return loaded_meshes[key]

func generate_map() -> MMTexture:
	var high : Mesh = get_mesh_parameter("high_mesh")
	if current_mesh == null or high == null:
		return await MMMapGenerator.get_map(null, "position")
	return await MMHighPolyBaker.bake(current_mesh, high, get_map_definition().map, 1 << int(get_parameter("size")),
		get_parameter("front"), get_parameter("rear"), SAMPLES[get_parameter("samples")], false, get_mesh_parameter("cage_mesh"))

func set_parameter(n : String, v) -> void:
	super.set_parameter(n, v)
	# Several parameters are set at once when loading, so bake only once
	if n != "map" and not update_pending:
		update_pending = true
		deferred_update.call_deferred()

func deferred_update() -> void:
	update_pending = false
	update_map()

func get_texture_parameter_name() -> String:
	return "o%d_highpoly_%s" % [ get_instance_id(), get_map_definition().map ]

# Mesh paths are stored relative to the project, as for images

const MESH_PARAMETERS : Array[String] = [ "high_mesh", "cage_mesh" ]

func _serialize_data(data: Dictionary) -> Dictionary:
	for p in MESH_PARAMETERS:
		if data.parameters.has(p):
			var path : String = data.parameters[p]
			path = path.replace(mm_loader.current_project_path, "%PROJECT_PATH%")
			path = path.replace(OS.get_user_data_dir(), "%USER_DATA_PATH%")
			path = path.replace(MMPaths.get_resource_dir(), "%MATERIAL_MAKER_PATH%")
			data.parameters[p] = path
	return data

func _deserialize(data : Dictionary) -> void:
	if not data.has("parameters"):
		return
	for p in MESH_PARAMETERS:
		if data.parameters.has(p):
			var path : String = data.parameters[p]
			path = path.replace("%PROJECT_PATH%", mm_loader.current_project_path)
			path = path.replace("%USER_DATA_PATH%", OS.get_user_data_dir())
			path = path.replace("%MATERIAL_MAKER_PATH%", MMPaths.get_resource_dir())
			data.parameters[p] = path
