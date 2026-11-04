extends RefCounted
class_name MMColorManagement


# OpenColorIO support, when the mm_ocio GDExtension is built (native/ocio).
# Material Maker works unchanged without it: is_available() is false and the
# functions below return empty lists, null or their input unchanged.
# Material Maker's values are in the working space (sRGB encoded by default),
# images can be converted between color spaces of the config (images when
# they are loaded, exported color maps), and previews
# can show a display/view transform (baked into a 3D LUT).


const LUT_SIZE : int = 33

static var ocio = null
## The config ocio was created for (it is not reloaded until the setting changes)
static var ocio_config : String = ""
static var ocio_created : bool = false
static var view_luts : Dictionary = {}


static func is_available() -> bool:
	return ClassDB.class_exists("MMOCIO")

## The OCIO object, with the configured config loaded (null if unavailable)
static func get_ocio():
	if not is_available():
		return null
	var config : String = mm_globals.get_config("ocio_config")
	if not ocio_created or config != ocio_config:
		ocio_created = true
		ocio_config = config
		view_luts.clear()
		ocio = ClassDB.instantiate("MMOCIO")
		if not ocio.load_config(config):
			push_error("Cannot load OCIO config '%s': %s" % [ config, ocio.get_error() ])
			# Fall back to the built-in config
			if config == "" or not ocio.load_config(""):
				ocio = null
	return ocio

## The color space of Material Maker's values
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

## An OptionButton of the display/view transforms ("None" first), with
## current selected, that calls on_selected with the selected view ("" for
## None)
static func create_view_picker(current : String, on_selected : Callable) -> OptionButton:
	var picker : OptionButton = OptionButton.new()
	fill_view_picker(picker, current)
	picker.item_selected.connect(func(i : int): on_selected.call("" if i == 0 else picker.get_item_text(i)))
	return picker

## Lists the display/view transforms of the current config in a view picker,
## with current selected
static func fill_view_picker(picker : OptionButton, current : String) -> void:
	picker.clear()
	picker.add_item("None")
	for v in get_views():
		picker.add_item(v)
	select_view(picker, current)

## Selects a view in a view picker ("None" if it is not listed)
static func select_view(picker : OptionButton, view : String) -> void:
	picker.selected = 0
	for i in picker.item_count:
		if i > 0 and picker.get_item_text(i) == view:
			picker.selected = i

## Converts an image from a color space to the working space
static func convert_image(image : Image, source : String) -> Image:
	return convert_between(image, source, get_working_space())

## Converts an image between two color spaces (as RGBAF; the image is returned
## unchanged without OCIO or on error)
static func convert_between(image : Image, source : String, destination : String) -> Image:
	var o = get_ocio()
	if o == null or image == null or source == "" or destination == "":
		return image
	var converted : Image = o.convert_image(image, source, destination)
	if converted == null:
		push_error("OCIO: %s" % o.get_error())
		return image
	return converted

## Converts an image from the working space to a color space
static func convert_image_to(image : Image, destination : String) -> Image:
	return convert_between(image, get_working_space(), destination)

## Color space of exported color maps set on the command line (--color-space),
## that replaces the ocio_export_space setting when not empty
static var export_space_override : String = ""

## The color space exported color maps are converted to ("" for no conversion)
static func get_export_space() -> String:
	if not is_available():
		return ""
	if export_space_override != "":
		return export_space_override
	return mm_globals.get_config("ocio_export_space")

## The color spaces of a config file ("" is the built-in config), without
## changing the current config (empty if it cannot be loaded)
static func get_config_color_spaces(config : String) -> PackedStringArray:
	if config == mm_globals.get_config("ocio_config"):
		return get_color_spaces()
	if not is_available():
		return PackedStringArray()
	var o = ClassDB.instantiate("MMOCIO")
	if not o.load_config(config):
		return PackedStringArray()
	return o.get_color_spaces()

## The settings that images converted to the working space depend on
static func get_settings_key() -> String:
	return "%s|%s" % [ mm_globals.get_config("ocio_config"), get_working_space() ]

## Group of the nodes (Image generators, 2D previews) that are notified with
## on_color_management_changed() when the settings may have changed
const UPDATE_GROUP : String = "mm_color_management"

## Notifies the nodes that depend on the config and the working space (called
## when the configuration changes)
static func settings_changed() -> void:
	if not is_available():
		return
	var tree : SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.call_group(UPDATE_GROUP, "on_color_management_changed")

## A 3D texture that applies a display/view transform ("display / view") to
## values in [0, 1] of a color space (by default the working space), or null
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
	var data : PackedFloat32Array = o.bake_display_view_lut(source, parts[0], parts[1], LUT_SIZE)
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
