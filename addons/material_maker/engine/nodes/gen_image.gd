@tool
extends MMGenTexture
class_name MMGenImage


# Texture generator from image


var timer : Timer
var filetime : int = 0
## The UDIM tile loaded by UDIM exports (0 otherwise)
var udim_tile : int = 0


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
	if n == "image":
		load_image(get_image_file())

## Loads an image file (if it exists)
func load_image(file_path : String) -> void:
	if FileAccess.file_exists(file_path):
		filetime = get_filetime(file_path)
		var image : Image = Image.new()
		if file_path.get_extension() == "dds":
			# load_from_file does not work with dds, see godot issue #113063
			image.load_dds_from_buffer(FileAccess.get_file_as_bytes(file_path))
		else:
			image = Image.load_from_file(file_path)
		if image != null:
			var image_texture : ImageTexture = ImageTexture.create_from_image(image)
			texture.set_texture(image_texture)
		mm_deps.dependency_update("o%d_tex" % get_instance_id(), texture)
	elif udim_tile != 0:
		# Tiles without an image file are transparent black
		push_warning("No image for UDIM tile %d (%s)" % [ udim_tile, file_path ])
		filetime = 0
		texture.set_texture(ImageTexture.create_from_image(Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)))
		mm_deps.dependency_update("o%d_tex" % get_instance_id(), texture)

## A UDIM tile number (1001 to 1999) in a file name (albedo.1001.png)
static func udim_regex() -> RegEx:
	return RegEx.create_from_string("(?<=\\.)1(?!000)\\d\\d\\d(?=\\.[^./\\\\]+$)")

## The image file: in UDIM exports, the file of the tile when the path
## contains <UDIM> (the placeholder of MaterialX and USD) or a tile number
## (albedo.1001.png). Outside UDIM exports, see get_preview_file().
func get_image_file() -> String:
	var path : String = get_parameter("image")
	if path.contains("<UDIM>"):
		if udim_tile == 0:
			return get_preview_file(path)
		return path.replace("<UDIM>", str(udim_tile))
	if udim_tile != 0:
		var number : RegExMatch = udim_regex().search(path)
		if number != null:
			return path.substr(0, number.get_start())+str(udim_tile)+path.substr(number.get_end())
	return path

## The file shown outside UDIM exports (thumbnail, previews): for paths that
## contain <UDIM>, tile 1001, or the lowest tile that has a file if 1001 has
## none. Other paths are returned unchanged.
static func get_preview_file(path : String) -> String:
	if not path.contains("<UDIM>"):
		return path
	var tile : int = 1001
	if not FileAccess.file_exists(path.replace("<UDIM>", str(tile))):
		var tiles : PackedInt32Array = find_udim_tiles(path)
		if not tiles.is_empty():
			tile = tiles[0]
	return path.replace("<UDIM>", str(tile))

## The tiles that have a file, when the path contains <UDIM> or a tile number
func get_udim_tiles() -> PackedInt32Array:
	return find_udim_tiles(get_parameter("image"))

## The tiles that have a file, when path contains <UDIM> or a tile number
static func find_udim_tiles(path : String) -> PackedInt32Array:
	var file_name : String = path.get_file()
	var pattern : String
	if file_name.contains("<UDIM>"):
		pattern = file_name.replace("<UDIM>", "*")
	else:
		var number : RegExMatch = udim_regex().search(file_name)
		if number == null:
			return PackedInt32Array()
		pattern = file_name.substr(0, number.get_start())+"*"+file_name.substr(number.get_end())
	var tiles : PackedInt32Array = PackedInt32Array()
	for f in DirAccess.get_files_at(path.get_base_dir()):
		var number : RegExMatch = udim_regex().search(f)
		if number != null and f == pattern.replace("*", number.get_string()):
			tiles.append(number.get_string().to_int())
	tiles.sort()
	return tiles

func set_udim_tile(tile : int) -> void:
	if tile == udim_tile:
		return
	var file_path : String = get_image_file()
	udim_tile = tile
	if get_image_file() != file_path:
		load_image(get_image_file())

func _on_timeout() -> void:
	var file_path : String = get_image_file()
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
		super.set_parameter("image", get_parameter("image"))
		mm_deps.dependency_update("o%d_tex" % get_instance_id(), texture)

func _serialize(data: Dictionary) -> Dictionary:
	return data

func _serialize_data(data: Dictionary) -> Dictionary:
	var image_path : String = data.parameters.image
	image_path = image_path.replace(mm_loader.current_project_path, "%PROJECT_PATH%")
	image_path = image_path.replace(OS.get_user_data_dir(), "%USER_DATA_PATH%")
	image_path = image_path.replace(MMPaths.get_resource_dir(), "%MATERIAL_MAKER_PATH%")
	data.parameters.image = image_path
	return data

func _deserialize(data : Dictionary) -> void:
	if data.has("parameters") and data.parameters.has("image"):
		data.parameters.image = data.parameters.image.replace("%PROJECT_PATH%", mm_loader.current_project_path)
		data.parameters.image = data.parameters.image.replace("%USER_DATA_PATH%", OS.get_user_data_dir())
		data.parameters.image = data.parameters.image.replace("%MATERIAL_MAKER_PATH%", MMPaths.get_resource_dir())
	elif data.has("image"):
		data.image = data.image.replace("%PROJECT_PATH%", mm_loader.current_project_path)
		data.image = data.image.replace("%USER_DATA_PATH%", OS.get_user_data_dir())
		data.image = data.image.replace("%MATERIAL_MAKER_PATH%", MMPaths.get_resource_dir())
