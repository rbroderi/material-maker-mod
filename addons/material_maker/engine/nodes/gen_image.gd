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
	add_to_group(MMColorManagement.UPDATE_GROUP)

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
			longdesc="Material Maker works with sRGB encoded colors. As is uses the image's values (sRGB images and data such as normal maps), Linear converts linear colors to sRGB, Auto does it for EXR and HDR images only, and OCIO converts from the OCIO color space below (when OpenColorIO support is built)" },
		{ name="ocio_space", type="string", label="OCIO color space", default="ACEScg",
			longdesc="The color space of the image in the OpenColorIO config (e.g. ACEScg, Linear Rec.709 (sRGB), sRGB Encoded Rec.709 (sRGB)), used by the OCIO color space mode" }
	]

const COLOR_SPACE_OCIO : int = 3

## The OCIO conversion of the loaded image ("" if none, see get_conversion)
var loaded_conversion : String = ""

## The OCIO color space the image must be converted from ("" if none)
func get_ocio_space() -> String:
	if int(get_parameter("color_space")) != COLOR_SPACE_OCIO:
		return ""
	return get_parameter("ocio_space")

## The OCIO conversion the image needs: its color space, the config and the
## working space ("" if none)
func get_conversion() -> String:
	var ocio_space : String = get_ocio_space()
	if ocio_space == "":
		return ""
	return "%s|%s" % [ ocio_space, MMColorManagement.get_settings_key() ]

## Converts a loaded image to the working space in OCIO mode (when
## OpenColorIO support is built, the image is unchanged otherwise)
func convert_color_space(image : Image) -> Image:
	loaded_conversion = get_conversion()
	var ocio_space : String = get_ocio_space()
	if ocio_space == "" or image.is_empty():
		return image
	if not MMColorManagement.is_available():
		push_warning("The OCIO color space mode needs OpenColorIO support (native/ocio)")
		return image
	return MMColorManagement.convert_image(image, ocio_space)

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
	if n == "image" and FileAccess.file_exists(v):
		filetime = get_filetime(v)
		var image : Image = Image.new()
		if v.get_extension() == "dds":
			# load_from_file does not work with dds, see godot issue #113063
			image.load_dds_from_buffer(FileAccess.get_file_as_bytes(v))
		else:
			image = Image.load_from_file(v)
		if image != null:
			var image_texture : ImageTexture = ImageTexture.create_from_image(convert_color_space(image))
			texture.set_texture(image_texture)
		mm_deps.dependency_update("o%d_tex" % get_instance_id(), texture)
	elif n in [ "color_space", "ocio_space" ] and get_conversion() != loaded_conversion and parameters.has("image"):
		# Load the image again with the new conversion
		set_parameter("image", get_parameter("image"))

## Loads the image again when the OCIO config or the working space changed
func on_color_management_changed() -> void:
	if get_conversion() != loaded_conversion and parameters.has("image"):
		set_parameter("image", get_parameter("image"))

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
		var image_texture : ImageTexture = ImageTexture.create_from_image(convert_color_space(image))
		if image_texture:
			texture.set_texture(image_texture)
		super.set_parameter("image", file_path)
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
	# When loading, the color space is set before the image so the image is
	# loaded (and converted) once
	if data.has("parameters") and not is_inside_tree():
		for p in [ "color_space", "ocio_space" ]:
			if data.parameters.has(p):
				parameters[p] = MMType.deserialize_value(data.parameters[p])
	if data.has("parameters") and data.parameters.has("image"):
		data.parameters.image = data.parameters.image.replace("%PROJECT_PATH%", mm_loader.current_project_path)
		data.parameters.image = data.parameters.image.replace("%USER_DATA_PATH%", OS.get_user_data_dir())
		data.parameters.image = data.parameters.image.replace("%MATERIAL_MAKER_PATH%", MMPaths.get_resource_dir())
	elif data.has("image"):
		data.image = data.image.replace("%PROJECT_PATH%", mm_loader.current_project_path)
		data.image = data.image.replace("%USER_DATA_PATH%", OS.get_user_data_dir())
		data.image = data.image.replace("%MATERIAL_MAKER_PATH%", MMPaths.get_resource_dir())
