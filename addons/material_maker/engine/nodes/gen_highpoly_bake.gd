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
	},
	{
		name="Transferred texture",
		output_type="rgb",
		map="texture",
		output="texture($TEXTURE, $UV).rgb"
	}
]

const SAMPLES : Array[int] = [ 1, 4, 16 ]

## Loaded meshes, by path, modification time and options, shared by all nodes
## (so the high poly mesh data used for baking is built once)
static var loaded_meshes : Dictionary = {}
const MAX_LOADED_MESHES : int = 4
## Loaded images (skew maps and high poly textures), by path and modification time
static var loaded_images : Dictionary = {}
const MAX_LOADED_IMAGES : int = 4
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
		{ name="match_by_name", type="boolean", label="Match by name", default=false,
			longdesc="Rays from each part (object) of the current mesh only hit the part of the high poly mesh with the same name (ignoring _low and _high suffixes)" },
		{ name="skew_map", type="file", label="Skew map", filters=[ "*.png,*.jpg,*.exr,*.tga,*.webp;Image file" ], default="",
			longdesc="Optional grayscale image (in the current mesh's UV space): white bends rays towards the face normal, to fix skewed details near hard edges" },
		{ name="high_texture", type="file", label="High poly texture", filters=[ "*.png,*.jpg,*.exr,*.tga,*.webp;Image file" ], default="",
			longdesc="Texture of the high poly mesh (in its UV space), for the Transferred texture map" },
		{ name="udim", type="float", label="UDIM tile", min=1001, max=1100, step=1, default=1001,
			longdesc="The UDIM tile of the current mesh's UV layout that is baked (1001 is the [0, 1] square, 1002 is on its right and 1011 above it)" },
	]

func get_map_definition() -> Dictionary:
	return BAKE_MAPS[get_parameter("map")]

## A cache key that changes when the file changes
static func file_key(path : String) -> String:
	return "%s:%d" % [ path, FileAccess.get_modified_time(path) ]

func get_mesh_parameter(parameter_name : String) -> Mesh:
	var path : String = get_parameter(parameter_name)
	if path == "" or not FileAccess.file_exists(path):
		return null
	return load_mesh(path, parameter_name == "high_mesh", get_parameter("match_by_name"))

## Loads a mesh, or returns it from the cache (shared by all nodes). High poly
## materials are separate surfaces, for material ID maps, and objects are
## separate surfaces (parts) when matching them by name.
static func load_mesh(path : String, split_materials : bool, parts : bool) -> Mesh:
	# The mesh is loaded again when the file changes
	var key : String = "%s:%s:%s" % [ file_key(path), split_materials, parts ]
	if not loaded_meshes.has(key):
		while loaded_meshes.size() >= MAX_LOADED_MESHES:
			loaded_meshes.erase(loaded_meshes.keys()[0])
		loaded_meshes[key] = MMMeshLoader.load_mesh(path, split_materials, parts)
	return loaded_meshes[key]

## The image of a parameter (or null), from a cache shared by all nodes
func get_image_parameter(parameter_name : String) -> Texture2D:
	var path : String = get_parameter(parameter_name)
	if path == "" or not FileAccess.file_exists(path):
		return null
	var key : String = file_key(path)
	if not loaded_images.has(key):
		while loaded_images.size() >= MAX_LOADED_IMAGES:
			loaded_images.erase(loaded_images.keys()[0])
		var image : Image = Image.load_from_file(path)
		loaded_images[key] = ImageTexture.create_from_image(image) if image != null else null
	return loaded_images[key]

## The current mesh, with its parts as separate surfaces when matching by name
func get_low_mesh() -> Mesh:
	if not get_parameter("match_by_name") or not current_mesh.has_meta("file_path"):
		return current_mesh
	var path : String = current_mesh.get_meta("file_path")
	if not FileAccess.file_exists(path):
		return current_mesh
	var mesh : Mesh = load_mesh(path, false, true)
	return mesh if mesh != null else current_mesh

func generate_map() -> MMTexture:
	var high : Mesh = get_mesh_parameter("high_mesh")
	if current_mesh == null or high == null:
		return await MMMapGenerator.get_map(null, "position")
	var options : Dictionary = { match_by_name=get_parameter("match_by_name") }
	for p in [ "skew_map", "high_texture" ]:
		var texture : Texture2D = get_image_parameter(p)
		if texture != null:
			options[p] = texture
	return await MMHighPolyBaker.bake(MMMapGenerator.get_tile_mesh(get_low_mesh(), get_udim_tile()), high, get_map_definition().map, 1 << int(get_parameter("size")),
		get_parameter("front"), get_parameter("rear"), SAMPLES[get_parameter("samples")], false, get_mesh_parameter("cage_mesh"), options)

func set_parameter(n : String, v) -> void:
	super.set_parameter(n, v)
	# Several parameters are set at once when loading, so bake only once (the
	# map and the UDIM tile update the map right away, see MMGenMeshMap)
	if n != "map" and n != "udim" and not update_pending:
		update_pending = true
		deferred_update.call_deferred()

func deferred_update() -> void:
	update_pending = false
	update_map()

func get_texture_parameter_name() -> String:
	return "o%d_highpoly_%s" % [ get_instance_id(), get_map_definition().map ]

# Mesh paths are stored relative to the project, as for images

const MESH_PARAMETERS : Array[String] = [ "high_mesh", "cage_mesh", "skew_map", "high_texture" ]

func _serialize_data(data: Dictionary) -> Dictionary:
	for p in MESH_PARAMETERS:
		if data.parameters.has(p):
			data.parameters[p] = MMPaths.encode_path(data.parameters[p])
	return data

func _deserialize(data : Dictionary) -> void:
	if not data.has("parameters"):
		return
	for p in MESH_PARAMETERS:
		if data.parameters.has(p):
			data.parameters[p] = MMPaths.decode_path(data.parameters[p])
