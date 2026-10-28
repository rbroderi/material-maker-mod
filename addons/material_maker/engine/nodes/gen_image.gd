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
		{ name="filter", type="boolean", label="Filter", default=true },
		{ name="color_space", type="enum", label="Color space", default=0,
			values=[ { name="As is", value="as_is" }, { name="Linear", value="linear" }, { name="Auto", value="auto" }, { name="OCIO", value="ocio" } ],
			longdesc="Material Maker works with sRGB encoded colors. As is uses the image's values (sRGB images and data such as normal maps), Linear converts linear colors to sRGB, Auto does it for EXR and HDR images, and OCIO converts from the OCIO color space below (when OpenColorIO support is built)" },
		{ name="ocio_space", type="string", label="OCIO color space", default="ACEScg",
			longdesc="The color space of the image in the OpenColorIO config (e.g. ACEScg, Linear Rec.709 (sRGB), sRGB - Texture), used by the OCIO color space mode" }
	]

const COLOR_SPACE_OCIO : int = 3

## Whether the image holds linear colors that must be converted to sRGB
func is_linear() -> bool:
	match int(get_parameter("color_space")):
		1:
			return true
		2:
			return get_parameter("image").get_extension().to_lower() in [ "exr", "hdr" ]
	return false

func _get_shader_code_lod(uv : String, output_index : int, context : MMGenContext, is_greyscale : bool = false, lod : float = -1.0, texture_suffix : String = "_tex") -> ShaderCode:
	var rv : ShaderCode = super._get_shader_code_lod(uv, output_index, context, is_greyscale, lod, texture_suffix)
	# The conversion is added where the texture is sampled (code is empty
	# for variants that were already generated)
	if is_linear() and rv.code != "":
		var v : String = rv.output_values[rv.output_type]
		if is_greyscale:
			rv.code += "%s = mix(1.055*pow(max(%s, 0.0), 1.0/2.4)-0.055, %s*12.92, float(%s < 0.0031308));\n" % [ v, v, v, v ]
		else:
			rv.code += "%s.rgb = mix(vec3(1.055)*pow(max(%s.rgb, vec3(0.0)), vec3(1.0/2.4))-vec3(0.055), %s.rgb*12.92, vec3(lessThan(%s.rgb, vec3(0.0031308))));\n" % [ v, v, v, v ]
	return rv

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
	if n == "image" or (n in [ "color_space", "ocio_space" ] and int(get_parameter("color_space")) == COLOR_SPACE_OCIO) or (n == "color_space" and parameters.has("image")):
		load_image()

## The UDIM tile loaded in UDIM exports (0 otherwise)
var udim_tile : int = 0

## A tile number in a file name (albedo.1001.png, albedo_1002.exr)
static func udim_regex() -> RegEx:
	return RegEx.create_from_string("(?<=[._])1\\d\\d\\d(?=\\.[^./\\\\]+$)")

## The file of the image: paths with <UDIM> (MaterialX and USD's placeholder)
## or a tile number load the tile of UDIM exports, and tile 1001 otherwise
func get_image_file() -> String:
	var path : String = get_parameter("image")
	if path.contains("<UDIM>"):
		return path.replace("<UDIM>", str(udim_tile if udim_tile != 0 else 1001))
	if udim_tile != 0:
		var number : RegExMatch = udim_regex().search(path)
		if number != null:
			return path.substr(0, number.get_start())+str(udim_tile)+path.substr(number.get_end())
	return path

func get_udim_tiles() -> PackedInt32Array:
	var path : String = get_parameter("image")
	var pattern : String
	if path.contains("<UDIM>"):
		pattern = path.get_file().replace("<UDIM>", "*")
	else:
		var number : RegExMatch = udim_regex().search(path.get_file())
		if number == null:
			return PackedInt32Array()
		pattern = path.get_file().substr(0, number.get_start())+"*"+path.get_file().substr(number.get_end())
	var tiles : PackedInt32Array = PackedInt32Array()
	for f in DirAccess.get_files_at(path.get_base_dir()):
		if f.match(pattern):
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
		load_image()

## Loads the image file, converting it to the working space in OCIO mode
func load_image() -> void:
	var file_path : String = get_image_file()
	if not FileAccess.file_exists(file_path):
		if udim_tile != 0:
			# Tiles without an image are transparent black
			push_warning("No image for UDIM tile %d (%s)" % [ udim_tile, file_path ])
			var empty : Image = Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
			texture.set_texture(ImageTexture.create_from_image(empty))
			mm_deps.dependency_update("o%d_tex" % get_instance_id(), texture)
		return
	filetime = get_filetime(file_path)
	var image : Image = Image.new()
	if file_path.get_extension() == "dds":
		# load_from_file does not work with dds, see godot issue #113063
		image.load_dds_from_buffer(FileAccess.get_file_as_bytes(file_path))
	else:
		image = Image.load_from_file(file_path)
	if image == null:
		return
	if int(get_parameter("color_space")) == COLOR_SPACE_OCIO:
		if MMColorManagement.is_available():
			image = MMColorManagement.convert_image(image, get_parameter("ocio_space"))
		else:
			push_warning("OCIO color spaces need the OpenColorIO extension (native/ocio)")
	texture.set_texture(ImageTexture.create_from_image(image))
	mm_deps.dependency_update("o%d_tex" % get_instance_id(), texture)

func _on_timeout() -> void:
	if filetime != get_filetime(get_image_file()):
		load_image()

func _serialize(data: Dictionary) -> Dictionary:
	return data

func _serialize_data(data: Dictionary) -> Dictionary:
	data.parameters.image = MMPaths.encode_path(data.parameters.image)
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
