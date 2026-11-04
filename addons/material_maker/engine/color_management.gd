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
	return resolve_color_space(mm_globals.get_config("ocio_export_space"))

## Bit depths of converted PNG color maps (the ocio_export_color_depth
## setting): 16 bits for linear export color spaces, always 16 bits, always 8
## bits
enum { COLOR_DEPTH_AUTO, COLOR_DEPTH_16_BITS, COLOR_DEPTH_8_BITS }

## Bit depth of converted color maps set on the command line
## (--color-map-depth), that replaces the ocio_export_color_depth setting when
## not -1
static var export_color_depth_override : int = -1

## True if a color space of the current config (or of o) is linear (e.g.
## ACEScg, Linear Rec.709), false for encoded color spaces (sRGB, gamma, log,
## video...) and data (Raw)
static func is_linear_color_space(color_space : String, o = null) -> bool:
	if o == null:
		o = get_ocio()
	if o == null or color_space == "":
		return false
	if o.has_method("is_color_space_linear"):
		# The encoding of the color space, or its transform to its reference
		# space (OCIO::Config::isColorSpaceLinear())
		return o.is_color_space_linear(color_space)
	# Older builds of the extension: values converted to the scene_linear role
	# only differ by a scale factor per channel (data color spaces are not
	# converted, and display-referred color spaces are not seen as linear)
	var canonical : String = get_canonical_name(color_space, o)
	var reference : String = o.get_role("scene_linear")
	if canonical == "" or reference == "":
		return false
	if canonical == reference:
		return true
	# Pixels 1 and 3 are pixels 2 and 4 halved
	var probe : PackedFloat32Array = PackedFloat32Array([ 0.0, 0.0, 0.0, 1.0, 0.05, 0.1, 0.2, 1.0, 0.1, 0.2, 0.4, 1.0, 0.3, 0.6, 0.45, 1.0, 0.6, 1.2, 0.9, 1.0 ])
	var converted : PackedFloat32Array = o.convert(probe, canonical, reference)
	if converted.size() != probe.size() or converted == probe:
		return false
	for c in 3:
		if absf(converted[c]) > 1e-5:
			return false
		for p in [ 1, 3 ]:
			var half : float = converted[p*4+c]
			var full : float = converted[(p+1)*4+c]
			if absf(full-2.0*half) > 1e-4*maxf(1.0, absf(full)):
				return false
	return true

## True if converted color maps are written as 16 bits PNG files for an export
## color space (depending on the ocio_export_color_depth setting or on
## --color-map-depth)
static func is_export_16_bits(export_space : String) -> bool:
	var depth : int = export_color_depth_override
	if depth == -1:
		depth = int(mm_globals.get_config("ocio_export_color_depth"))
	match depth:
		COLOR_DEPTH_16_BITS:
			return true
		COLOR_DEPTH_8_BITS:
			return false
	return is_linear_color_space(export_space)

## The color spaces of a config file ("" is the built-in config), without
## changing the current config (empty if it cannot be loaded)
static func get_config_color_spaces(config : String) -> PackedStringArray:
	var o = get_config_ocio(config)
	return o.get_color_spaces() if o != null else PackedStringArray()

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

## Saves an image as a 16 bits RGBA PNG file (Image.save_png() writes 8 bits
## files, that show banding in dark areas for linear color spaces). Values
## are clamped to [0, 1].
static func save_png_16(image : Image, file_name : String) -> Error:
	var rgba16 : Image = image.duplicate()
	if rgba16.is_compressed():
		rgba16.decompress()
	rgba16.clear_mipmaps()
	rgba16.convert(Image.FORMAT_RGBA16)
	var width : int = rgba16.get_width()
	var height : int = rgba16.get_height()
	# PNG values are big endian: reversing the data swaps the bytes of each
	# value but also reverses their order, which flipping an image of one
	# value per pixel restores
	var data : PackedByteArray = rgba16.get_data()
	data.reverse()
	var values : Image = Image.create_from_data(width*4, height, false, Image.FORMAT_R16, data)
	values.flip_x()
	values.flip_y()
	data = values.get_data()
	# Each row starts with its filter type (0, none)
	var row_size : int = width*8
	var rows : PackedByteArray = PackedByteArray()
	for y in height:
		rows.append(0)
		rows.append_array(data.slice(y*row_size, (y+1)*row_size))
	data.clear()
	var png : PackedByteArray = PackedByteArray([ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A ])
	# Width, height, bit depth, color type (6: RGBA), compression, filter, interlace
	var header : PackedByteArray = png_u32(width)
	header.append_array(png_u32(height))
	header.append_array(PackedByteArray([ 16, 6, 0, 0, 0 ]))
	png.append_array(png_chunk("IHDR", header))
	var compressed : PackedByteArray = rows.compress(FileAccess.COMPRESSION_DEFLATE)
	rows.clear()
	const MAX_CHUNK_SIZE : int = 1 << 24
	for offset in range(0, compressed.size(), MAX_CHUNK_SIZE):
		png.append_array(png_chunk("IDAT", compressed.slice(offset, offset+MAX_CHUNK_SIZE)))
	png.append_array(png_chunk("IEND", PackedByteArray()))
	var file : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(png)
	return file.get_error()

## A big endian 32 bits integer (for PNG files)
static func png_u32(value : int) -> PackedByteArray:
	return PackedByteArray([ (value >> 24) & 255, (value >> 16) & 255, (value >> 8) & 255, value & 255 ])

## A PNG chunk: size, type, data and CRC (the CRC-32 that ends gzip data)
static func png_chunk(type : String, data : PackedByteArray) -> PackedByteArray:
	var body : PackedByteArray = type.to_ascii_buffer()
	body.append_array(data)
	var gzip : PackedByteArray = body.compress(FileAccess.COMPRESSION_GZIP)
	var rv : PackedByteArray = png_u32(data.size())
	rv.append_array(body)
	rv.append_array(png_u32(gzip.decode_u32(gzip.size()-8)))
	return rv
