@tool
extends MMGenTexture
class_name MMGenImage


# Texture generator from image


var timer : Timer
var filetime : int = 0


func _ready() -> void:
	timer = Timer.new()
	add_child(timer)
	timer.wait_time = 2
	timer.start()
	timer.connect("timeout", Callable(self, "_on_timeout"))

func get_type() -> String:
	return "image"

func get_type_name() -> String:
	return "Image"

func get_parameter_defs() -> Array:
	return [
		{ name="image", type="image_path", label="", default="" },
		{ name="fix_ar", type="boolean", label="Fix Aspect Ratio", default=false },
		{ name="clamp", type="boolean", label="Clamp", default=false },
		{ name="filter", type="boolean", label="Filter", default=true }
	]

func get_filetime(file_path : String) -> int:
	if FileAccess.file_exists(file_path):
		return FileAccess.get_modified_time(file_path)
	return 0

func get_adjusted_uv(uv : String) -> String:
	if get_parameter("fix_ar"):
		var ar : float = 1.0
		if texture.get_width() != 0 and texture.get_height() != 0:
			# Cast int to float
			ar = texture.get_height()
			ar /= texture.get_width()
		uv = "((%s) - vec2(0.0, %f)) * vec2(1.0, %f)" % [uv, (1-ar)/2, 1/ar]

	if get_parameter("clamp"):
		uv = "clamp(%s, 0.0, 1.0)" % uv
	else:
		uv = "mod(%s, 1.0)" % uv

	if not get_parameter("filter"):
		var tex_size : String = "vec2(%s, %s)" % [texture.get_width(), texture.get_height()]
		uv = "(floor(fract(%s) * %s)+vec2(0.5))/%s" % [uv, tex_size, tex_size]

	return uv

func set_parameter(n : String, v) -> void:
	super.set_parameter(n, v)
	if n == "image" and FileAccess.file_exists(v):
		filetime = get_filetime(v)
		var image : Image = Image.new()
		if v.get_extension() == "dds":
			# load_from_file does not work with dds, see godot issue #113063
			image.load_dds_from_buffer(FileAccess.get_file_as_bytes(v))
		else:
			image = Image.load_from_file(v)
		if image != null:
			var image_texture : ImageTexture = ImageTexture.create_from_image(image)
			texture.set_texture(image_texture)
		mm_deps.dependency_update("o%d_tex" % get_instance_id(), texture)

func _on_timeout() -> void:
	var file_path : String = get_parameter("image")
	var new_filetime : int = get_filetime(file_path)
	if filetime != new_filetime:
		filetime = new_filetime
		var image : Image = Image.new()
		if file_path.get_extension() == "dds":
			image.load_dds_from_buffer(FileAccess.get_file_as_bytes(file_path))
		else:
			image.load(file_path)
		var image_texture : ImageTexture = ImageTexture.create_from_image(image)
		if image_texture:
			texture.set_texture(image_texture)
		super.set_parameter("image", file_path)
		mm_deps.dependency_update("o%d_tex" % get_instance_id(), texture)

func _serialize(data: Dictionary) -> Dictionary:
	return data

func _serialize_data(data: Dictionary) -> Dictionary:
	data.parameters.image = encode_path(data.parameters.image)
	return data

## The image path as saved in graphs: the project, user data and Material
## Maker directories are replaced by tokens. A directory is only replaced at
## the start of the path, and only if it is the whole path or is followed by
## a slash (so a project in C:/x/proj does not match C:/x/proj2/a.png). Both
## slash styles are accepted, and the case is ignored on Windows. The first
## directory that matches is used, in the order above
static func encode_path(path : String) -> String:
	var tokens : Array = []
	if mm_loader.current_project_path != "":
		tokens.append([ mm_loader.current_project_path, "%PROJECT_PATH%" ])
	tokens.append([ OS.get_user_data_dir(), "%USER_DATA_PATH%" ])
	tokens.append([ MMPaths.get_resource_dir(), "%MATERIAL_MAKER_PATH%" ])
	var normalized_path : String = path.replace("\\", "/")
	var compared_path : String = normalized_path
	if OS.get_name() == "Windows":
		compared_path = compared_path.to_lower()
	for t in tokens:
		var dir : String = t[0].replace("\\", "/")
		while dir.ends_with("/"):
			dir = dir.left(-1)
		if dir == "":
			continue
		var compared_dir : String = dir.to_lower() if OS.get_name() == "Windows" else dir
		if compared_path == compared_dir:
			return t[1]
		if compared_path.begins_with(compared_dir + "/"):
			return t[1] + normalized_path.substr(dir.length())
	return path

func _deserialize(data : Dictionary) -> void:
	if data.has("parameters") and data.parameters.has("image"):
		data.parameters.image = data.parameters.image.replace("%PROJECT_PATH%", mm_loader.current_project_path)
		data.parameters.image = data.parameters.image.replace("%USER_DATA_PATH%", OS.get_user_data_dir())
		data.parameters.image = data.parameters.image.replace("%MATERIAL_MAKER_PATH%", MMPaths.get_resource_dir())
	elif data.has("image"):
		data.image = data.image.replace("%PROJECT_PATH%", mm_loader.current_project_path)
		data.image = data.image.replace("%USER_DATA_PATH%", OS.get_user_data_dir())
		data.image = data.image.replace("%MATERIAL_MAKER_PATH%", MMPaths.get_resource_dir())
