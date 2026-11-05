extends RefCounted
class_name MMColorManagement


# OpenColorIO support, when the mm_ocio GDExtension is built (native/ocio).
# Material Maker works unchanged without it: is_available() is false and the
# functions below return empty lists, null or their input unchanged.
# Material Maker's values are in the working space (sRGB encoded by default),
# images can be converted between color spaces of the config (images when
# they are loaded, exported color maps), and previews can show a
# display/view transform (baked into a 3D LUT).


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
## The config ocio was created for (it is not reloaded until the setting
## changes, even if it failed to load)
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
	return resolve_color_space(mm_globals.get_config("ocio_working_space"))

static func get_color_spaces() -> PackedStringArray:
	var o = get_ocio()
	return o.get_color_spaces() if o != null else PackedStringArray()

## The name of a color space as the config lists it, for a color space name,
## an alias (e.g. "sRGB - Texture") or a role, in the current config or in o
## (an OCIO object). "" if the config has no such color space.
static func get_canonical_name(color_space : String, o = null) -> String:
	if o == null:
		o = get_ocio()
	if o == null or color_space == "":
		return ""
	if o.has_method("get_canonical_name"):
		return o.get_canonical_name(color_space)
	# Older builds of the extension (get_role() also accepts color spaces
	# and aliases)
	return o.get_role(color_space)

## A color space name or alias as the config lists it (the name is returned
## unchanged if the config has no such color space)
static func resolve_color_space(color_space : String, o = null) -> String:
	var canonical : String = get_canonical_name(color_space, o)
	return canonical if canonical != "" else color_space

## The color spaces of the current config (or of o) grouped by family, as an
## array of { family, color_spaces } in the order of the config (color spaces
## without family are in a last "Other" group)
static func get_color_space_groups(o = null) -> Array[Dictionary]:
	if o == null:
		o = get_ocio()
	var groups : Array[Dictionary] = []
	if o == null:
		return groups
	var families : Dictionary = {}
	var others : PackedStringArray = PackedStringArray()
	for color_space in o.get_color_spaces():
		var family : String = o.get_color_space_family(color_space) if o.has_method("get_color_space_family") else ""
		if family == "":
			others.append(color_space)
		elif families.has(family):
			families[family].color_spaces.append(color_space)
		else:
			families[family] = { family=family, color_spaces=PackedStringArray([ color_space ]) }
			groups.append(families[family])
	if not others.is_empty():
		groups.append({ family="Other" if not groups.is_empty() else "", color_spaces=others })
	return groups

## The color spaces of the current config (or of o) grouped by family, one
## family per line (for messages)
static func get_color_space_list(o = null) -> String:
	var lines : PackedStringArray = PackedStringArray()
	for group in get_color_space_groups(o):
		var names : String = ", ".join(group.color_spaces)
		lines.append("  %s: %s" % [ group.family, names ] if group.family != "" else "  "+names)
	return "\n".join(lines)

## Lists the color spaces of the current config (or of o) in an OptionButton,
## grouped by family (one separator per family), with current (a name or an
## alias) selected. The item metadata are the color space names (none_text is
## a first item for "" if not empty), and current is added if the config does
## not have it, so a name that is not in the config is kept.
static func fill_color_space_picker(picker : OptionButton, current : String, none_text : String = "", o = null) -> void:
	if o == null:
		o = get_ocio()
	picker.clear()
	if none_text != "":
		picker.add_item(none_text)
		picker.set_item_metadata(0, "")
	var resolved : String = resolve_color_space(current, o)
	var listed : bool = current == ""
	for group in get_color_space_groups(o):
		if group.family != "":
			picker.add_separator(group.family)
		for color_space in group.color_spaces:
			picker.add_item(color_space)
			var index : int = picker.item_count-1
			picker.set_item_metadata(index, color_space)
			var aliases : PackedStringArray = o.get_color_space_aliases(color_space) if o.has_method("get_color_space_aliases") else PackedStringArray()
			if not aliases.is_empty():
				picker.set_item_tooltip(index, "%s\nAliases: %s" % [ color_space, ", ".join(aliases) ])
			if color_space == resolved:
				listed = true
	if not listed:
		picker.add_item("%s (not in config)" % current)
		picker.set_item_metadata(picker.item_count-1, current)
	var selection : String = resolved if listed else current
	picker.selected = -1
	for i in picker.item_count:
		if not picker.is_item_separator(i) and picker.get_item_metadata(i) == selection:
			picker.selected = i
			break
	if picker.selected == -1:
		for i in picker.item_count:
			if not picker.is_item_separator(i):
				picker.selected = i
				break
	picker.tooltip_text = get_picker_color_space(picker)

## The color space selected in a picker filled by fill_color_space_picker()
static func get_picker_color_space(picker : OptionButton) -> String:
	if picker.selected == -1:
		return ""
	var color_space = picker.get_item_metadata(picker.selected)
	return color_space if color_space is String else ""

## The OCIO object of a config file ("" is the built-in config): the current
## one for the configured config, a new one otherwise (null if it cannot be
## loaded)
static func get_config_ocio(config : String):
	if config == mm_globals.get_config("ocio_config"):
		return get_ocio()
	if not is_available():
		return null
	var o = ClassDB.instantiate("MMOCIO")
	return o if o.load_config(config) else null

## The color spaces of a config file ("" is the built-in config), without
## changing the current config (empty if it cannot be loaded)
static func get_config_color_spaces(config : String) -> PackedStringArray:
	var o = get_config_ocio(config)
	return o.get_color_spaces() if o != null else PackedStringArray()

## The settings that images converted to the working space depend on
static func get_settings_key() -> String:
	return "%s|%s" % [ mm_globals.get_config("ocio_config"), get_working_space() ]

## Group of the nodes (Image generators and nodes, 2D previews) that are
## notified with on_color_management_changed() when the settings may have
## changed
const UPDATE_GROUP : String = "mm_color_management"

## Notifies the nodes that depend on the config and the working space (called
## when the configuration changes)
static func settings_changed() -> void:
	if not is_available():
		return
	var tree : SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null:
		tree.call_group(UPDATE_GROUP, "on_color_management_changed")

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

## Color space of exported color maps set on the command line (--color-space),
## that replaces the ocio_export_space setting when not empty
static var export_space_override : String = ""

## The color space exported color maps are converted to ("" for no conversion)
static func get_export_space() -> String:
	if not is_available():
		return ""
	if export_space_override != "":
		return export_space_override
	return resolve_color_space(mm_globals.get_config_or("ocio_export_space", ""))

## Converts an image from the working space to a color space
static func convert_image_to(image : Image, destination : String) -> Image:
	return convert_between(image, get_working_space(), destination)

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
