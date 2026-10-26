extends RefCounted
class_name MMColorManagement


# OpenColorIO support, when the mm_ocio GDExtension is built (native/ocio).
# Material Maker's values are in the working space (sRGB encoded by default),
# images can be converted from any color space of the config, and previews
# can show a display/view transform (baked into a 3D LUT).


const LUT_SIZE : int = 33

static var ocio = null
static var ocio_config : String = ""
static var view_luts : Dictionary = {}


static func is_available() -> bool:
	return ClassDB.class_exists("MMOCIO")

## The OCIO object, with the configured config loaded (null if unavailable)
static func get_ocio():
	if not is_available():
		return null
	var config : String = mm_globals.get_config("ocio_config")
	if ocio == null or config != ocio_config:
		ocio = ClassDB.instantiate("MMOCIO")
		ocio_config = config
		view_luts.clear()
		if not ocio.load_config(config):
			push_error("Cannot load OCIO config '%s': %s" % [ config, ocio.get_error() ])
			if config == "" or not ocio.load_config(""):
				ocio = null
	return ocio

static func get_working_space() -> String:
	return mm_globals.get_config("ocio_working_space")

static func get_color_spaces() -> PackedStringArray:
	var o = get_ocio()
	return o.get_color_spaces() if o != null else PackedStringArray()

## Display/view transforms, as "display / view"
static func get_views() -> PackedStringArray:
	var views : PackedStringArray = PackedStringArray()
	var o = get_ocio()
	if o != null:
		for display in o.get_displays():
			for view in o.get_views(display):
				views.append("%s / %s" % [ display, view ])
	return views

## Converts an image from a color space to the working space
static func convert_image(image : Image, source : String) -> Image:
	var o = get_ocio()
	if o == null or image == null:
		return image
	var converted : Image = o.convert_image(image, source, get_working_space())
	if converted == null:
		push_error("OCIO: %s" % o.get_error())
		return image
	return converted

## Color space of exported color maps: the command line's --color-space, or
## the ocio_export_space setting ("" for no conversion)
static var export_space_override : String = ""

static func get_export_space() -> String:
	if not is_available():
		return ""
	if export_space_override != "":
		return export_space_override
	return mm_globals.get_config("ocio_export_space") if mm_globals.has_config("ocio_export_space") else ""

## Converts an image from the working space to a color space
static func convert_image_to(image : Image, destination : String) -> Image:
	var o = get_ocio()
	if o == null or image == null or destination == "":
		return image
	var converted : Image = o.convert_image(image, get_working_space(), destination)
	if converted == null:
		push_error("OCIO: %s" % o.get_error())
		return image
	return converted

## A 3D texture that applies a display/view transform ("display / view") to
## working space values in [0, 1], or null
static func get_view_lut(view_name : String) -> ImageTexture3D:
	if view_luts.has(view_name):
		return view_luts[view_name]
	var o = get_ocio()
	var parts : PackedStringArray = view_name.split(" / ", true, 1)
	if o == null or parts.size() != 2:
		return null
	var data : PackedFloat32Array = o.bake_display_view_lut(get_working_space(), parts[0], parts[1], LUT_SIZE)
	if data.is_empty():
		push_error("OCIO: %s" % o.get_error())
		return null
	var slices : Array[Image] = []
	var slice_size : int = LUT_SIZE*LUT_SIZE*4
	for b in LUT_SIZE:
		slices.append(Image.create_from_data(LUT_SIZE, LUT_SIZE, false, Image.FORMAT_RGBAF, data.slice(b*slice_size, (b+1)*slice_size).to_byte_array()))
	var texture : ImageTexture3D = ImageTexture3D.new()
	texture.create(Image.FORMAT_RGBAF, LUT_SIZE, LUT_SIZE, LUT_SIZE, false, slices)
	view_luts[view_name] = texture
	return texture

## Shader code that applies a view LUT (mm_ocio_lut) to a color
static func get_view_shader_code() -> String:
	# Samples at texel centers: [0, 1] maps to [0.5/size, 1-0.5/size]
	var scale : float = float(LUT_SIZE-1)/LUT_SIZE
	var offset : float = 0.5/LUT_SIZE
	var code : String = "uniform sampler3D mm_ocio_lut : filter_linear, repeat_disable;\n"
	code += "vec3 mm_ocio_view(vec3 c) {\n"
	code += "\treturn textureLod(mm_ocio_lut, clamp(c, 0.0, 1.0)*%f+vec3(%f), 0.0).rgb;\n" % [ scale, offset ]
	code += "}\n"
	return code
