extends RefCounted
class_name MMColorManagement


# OpenColorIO support, when the mm_ocio GDExtension is built (native/ocio).
# Material Maker's values are in the working space (sRGB encoded by default),
# images can be converted from any color space of the config, and previews
# can show a display/view transform (baked into a 3D LUT).


const LUT_SIZE : int = 49
## The input of view LUTs is shaped so they also cover HDR values: [0, 1] uses
## the first SHAPER_KNEE of the LUT, and values above 1 the rest, in log2 up
## to 2^SHAPER_STOPS. [0, 1] is spaced linearly for the working space (so LDR
## values are as precise as with a plain LUT), and as a square root for
## scene linear values (display transforms are steep near black)
const SHAPER_KNEE : float = 0.75
const SHAPER_STOPS : float = 4.0
## Names of the linear Rec.709 color space (Godot's 3D rendering space) in
## common configs
const SCENE_LINEAR_NAMES : Array[String] = [ "Linear Rec.709 (sRGB)", "lin_rec709_srgb", "Utility - Linear - sRGB", "lin_srgb", "Linear" ]

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

## The color space of Godot's 3D rendering (linear Rec.709) in the config
static func get_scene_linear_space() -> String:
	var spaces : PackedStringArray = get_color_spaces()
	for n in SCENE_LINEAR_NAMES:
		if n in spaces:
			return n
	return ""

static func shaper_inverse(t : float, scene_linear : bool = false) -> float:
	if t <= SHAPER_KNEE:
		return t*t/(SHAPER_KNEE*SHAPER_KNEE) if scene_linear else t/SHAPER_KNEE
	return pow(2.0, (t-SHAPER_KNEE)/(1.0-SHAPER_KNEE)*SHAPER_STOPS)

## A 3D texture that applies a display/view transform ("display / view") to
## values of a color space (by default the working space), with a shaped
## input (see get_view_shader_code), or null
static func get_view_lut(view_name : String, source : String = "") -> ImageTexture3D:
	if source == "":
		source = get_working_space()
	var key : String = view_name+"|"+source
	if view_luts.has(key):
		return view_luts[key]
	var o = get_ocio()
	var parts : PackedStringArray = view_name.split(" / ", true, 1)
	if o == null or parts.size() != 2 or source == "":
		return null
	var grid : PackedFloat32Array = PackedFloat32Array()
	var scene_linear : bool = source != get_working_space() and source == get_scene_linear_space()
	for i in LUT_SIZE:
		grid.append(shaper_inverse(float(i)/(LUT_SIZE-1), scene_linear))
	var lattice : PackedFloat32Array = PackedFloat32Array()
	lattice.resize(LUT_SIZE*LUT_SIZE*LUT_SIZE*4)
	var index : int = 0
	for b in LUT_SIZE:
		for g in LUT_SIZE:
			for r in LUT_SIZE:
				lattice[index] = grid[r]
				lattice[index+1] = grid[g]
				lattice[index+2] = grid[b]
				lattice[index+3] = 1.0
				index += 4
	var data : PackedFloat32Array = o.display_view(lattice, source, parts[0], parts[1])
	if data.is_empty():
		push_error("OCIO: %s" % o.get_error())
		return null
	var slices : Array[Image] = []
	var slice_size : int = LUT_SIZE*LUT_SIZE*4
	for b in LUT_SIZE:
		slices.append(Image.create_from_data(LUT_SIZE, LUT_SIZE, false, Image.FORMAT_RGBAF, data.slice(b*slice_size, (b+1)*slice_size).to_byte_array()))
	var texture : ImageTexture3D = ImageTexture3D.new()
	texture.create(Image.FORMAT_RGBAF, LUT_SIZE, LUT_SIZE, LUT_SIZE, false, slices)
	view_luts[key] = texture
	return texture

## Shader code that applies a view LUT (mm_ocio_lut) to a color, for a LUT
## baked from the working space or (scene_linear) from get_scene_linear_space()
static func get_view_shader_code(scene_linear : bool = false) -> String:
	# Samples at texel centers: [0, 1] maps to [0.5/size, 1-0.5/size]
	var scale : float = float(LUT_SIZE-1)/LUT_SIZE
	var offset : float = 0.5/LUT_SIZE
	var code : String = "uniform sampler3D mm_ocio_lut : filter_linear, repeat_disable;\n"
	code += "vec3 mm_ocio_view(vec3 c) {\n"
	code += "\tc = max(c, vec3(0.0));\n"
	code += "\tvec3 shaped = mix(%s*%f, vec3(%f)+%f*log2(max(c, vec3(1.0))), greaterThan(c, vec3(1.0)));\n" % [ "sqrt(c)" if scene_linear else "c", SHAPER_KNEE, SHAPER_KNEE, (1.0-SHAPER_KNEE)/SHAPER_STOPS ]
	code += "\treturn textureLod(mm_ocio_lut, clamp(shaped, 0.0, 1.0)*%f+vec3(%f), 0.0).rgb;\n" % [ scale, offset ]
	code += "}\n"
	return code
