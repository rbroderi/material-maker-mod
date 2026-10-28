@tool
extends MMGenTexture
class_name MMGenSVG


# Texture generator from vector graphics: an SVG file, path data edited in
# the node, or a polygon or Bézier curves edited in the 2D preview. Vector
# graphics are rendered (with ThorVG) at the selected resolution, so they
# stay sharp.


var update_pending : bool = false

static var invalid_path_character : RegEx = RegEx.create_from_string("[^MmLlHhVvCcSsQqTtAaZz0-9.,+eE \t\r\n-]")
static var path_number : RegEx = RegEx.create_from_string("[-+]?(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE][-+]?[0-9]+)?")

## Path coordinates are limited to this range: the renderer can freeze on
## paths with very large coordinates
const MAX_PATH_COORDINATE : float = 1000.0


func _ready() -> void:
	# Missing parameters get their default value, so the node's controls show them
	for p in get_parameter_defs():
		if not parameters.has(p.name):
			parameters[p.name] = MMType.deserialize_value(p.default)
	update_texture()

func get_type() -> String:
	return "svg"

func get_type_name() -> String:
	return "SVG"

func get_description() -> String:
	return "\n".join([ TranslationServer.translate("SVG"), TranslationServer.translate("Renders vector graphics (an SVG file or path data) at any resolution") ])

func get_parameter_defs() -> Array:
	return [
		{ name="source", type="enum", label="Source", default=0,
			values=[ { name="Path data", value="path" }, { name="Shape (edit in 2D preview)", value="shape" }, { name="File", value="file" }, { name="Curves (edit in 2D preview)", value="curves" } ],
			longdesc="What is rendered: the path data, the shape (a polygon edited in the 2D preview), the SVG file, or the curves (Bézier curves edited in the 2D preview)" },
		{ name="file", type="file", label="SVG file", filters=[ "*.svg;SVG file" ], default="",
			longdesc="An SVG file, used with the File source, or when the path data is empty" },
		{ name="shape", type="polygon", label="Shape", default={ type="Polygon", points=[ { x=0.5, y=0.1 }, { x=0.9, y=0.85 }, { x=0.1, y=0.85 } ] },
			longdesc="A polygon, edited in the 2D preview, used with the Shape source" },
		{ name="curves", type="splines", label="Curves", default={ type="Splines", values=[ 0.85, 0.5, 0.01, 0.0, 0.85, 0.6933, 0.01, 0.0, 0.6933, 0.85, 0.01, 0.0, 0.5, 0.85, 0.01, 0.0, 0.5, 0.85, 0.01, 0.0, 0.3067, 0.85, 0.01, 0.0, 0.15, 0.6933, 0.01, 0.0, 0.15, 0.5, 0.01, 0.0, 0.15, 0.5, 0.01, 0.0, 0.15, 0.3067, 0.01, 0.0, 0.3067, 0.15, 0.01, 0.0, 0.5, 0.15, 0.01, 0.0, 0.5, 0.15, 0.01, 0.0, 0.6933, 0.15, 0.01, 0.0, 0.85, 0.3067, 0.01, 0.0, 0.85, 0.5, 0.01, 0.0 ], point_groups=[ [ 3, 4 ], [ 7, 8 ], [ 11, 12 ], [ 15, 0 ] ] },
			longdesc="Cubic Bézier curves, edited in the 2D preview, used with the Curves source. Curves whose ends meet are joined, and closed outlines are filled" },
		{ name="path", type="string", label="Path data", default="M 50 10 L 61 39 L 92 39 L 67 58 L 76 88 L 50 70 L 24 88 L 33 58 L 8 39 L 39 39 Z",
			longdesc="SVG path data (the d attribute of an SVG path) on a 100x100 canvas, e.g. M 10 10 L 90 10 L 50 90 Z" },
		{ name="fill", type="color", label="Fill", default=Color(1.0, 1.0, 1.0, 1.0), longdesc="The fill color of the path" },
		{ name="fill_rule", type="enum", label="Fill rule", default=0,
			values=[ { name="Non-zero", value="nonzero" }, { name="Even-odd", value="evenodd" } ],
			longdesc="How overlapping parts of the path are filled: Non-zero fills everything inside the outline, Even-odd leaves holes where outlines overlap" },
		{ name="stroke", type="color", label="Stroke", default=Color(0.0, 0.0, 0.0, 0.0), longdesc="The stroke color of the path" },
		{ name="stroke_width", type="float", label="Stroke width", min=0.0, max=20.0, step=0.1, default=0.0, longdesc="The stroke width of the path, on the 100x100 canvas" },
		{ name="background", type="color", label="Background", default=Color(0.0, 0.0, 0.0, 1.0),
			longdesc="The color the vector graphics are drawn on. With a transparent background, the output is transparent outside of the shapes, and its colors are not anti-aliased (use its alpha channel as a mask)" },
		{ name="size", type="size", label="Size", first=6, last=13, default=10, longdesc="The resolution of the rendered image" }
	]

func set_parameter(n : String, v) -> void:
	super.set_parameter(n, v)
	# Several parameters are set at once when loading, so render once
	if is_inside_tree() and not update_pending:
		update_pending = true
		update_texture.call_deferred()

## Only the shape or curves that are rendered are edited in the 2D preview
func get_preview_2d_parameter_defs(parameter_defs : Array) -> Array:
	var source : int = int(get_parameter("source"))
	return parameter_defs.filter(func(p): return not ((p.name == "shape" and source != 1) or (p.name == "curves" and source != 3)))

static func color_to_svg(c : Color) -> String:
	return "fill=\"#%s\" fill-opacity=\"%f\"" % [ c.to_html(false), c.a ]

## Checks that a document can be given to the SVG renderer: ThorVG crashes on
## some malformed documents (an unterminated tag, comment, CDATA section or
## attribute value, or a < that does not start a tag)
static func is_well_formed(svg : String) -> bool:
	var length : int = svg.length()
	var position : int = 0
	while true:
		var tag_start : int = svg.find("<", position)
		if tag_start == -1:
			return true
		var tag_end : int
		if svg.substr(tag_start, 4) == "<!--":
			tag_end = svg.find("-->", tag_start+4)
			position = tag_end+3
		elif svg.substr(tag_start, 9) == "<![CDATA[":
			tag_end = svg.find("]]>", tag_start+9)
			position = tag_end+3
		elif svg.substr(tag_start, 2) == "<?":
			tag_end = svg.find("?>", tag_start+2)
			position = tag_end+2
		else:
			# Element tag, closing tag or doctype: quoted values may contain > and <,
			# and a doctype may have an internal subset between brackets
			var first : String = svg.substr(tag_start+1, 1)
			if first == "" or not (first in "/!:_" or first.to_lower() != first.to_upper()):
				return false
			var i : int = tag_start+1
			var in_brackets : bool = false
			tag_end = -1
			while i < length:
				var c : String = svg[i]
				if c == "\"" or c == "'":
					i = svg.find(c, i+1)
					if i == -1:
						return false
				elif c == "[" and first == "!":
					in_brackets = true
				elif c == "]":
					in_brackets = false
				elif c == ">" and not in_brackets:
					tag_end = i
					break
				elif c == "<" and not in_brackets:
					return false
				i += 1
			position = tag_end+1
		if tag_end == -1:
			return false
	return true

## Approximate size of a document in pixels, at scale 1 (the renderer only
## gives the size of a rendered image, and scales down images larger than 16384)
static func get_document_size(svg : String) -> Vector2:
	var image : Image = Image.new()
	for probe_scale in [ 1.0/64.0, 1.0, 64.0 ]:
		if image.load_svg_from_string(svg, probe_scale) != OK or image.is_empty():
			return Vector2(0, 0)
		# Measure small documents at a larger scale, for precision
		if max(image.get_width(), image.get_height()) >= 64 or probe_scale == 64.0:
			return Vector2(image.get_size())/probe_scale
	return Vector2(0, 0)

## The SVG document that is rendered
func get_svg() -> String:
	var source : int = int(get_parameter("source"))
	var path : String = ""
	match source:
		0:
			path = get_parameter("path")
		1:
			path = get_shape_path()
		3:
			path = get_curves_path()
	if path.strip_edges() == "":
		var file_name : String = get_parameter("file")
		if file_name == "" or not FileAccess.file_exists(file_name):
			return ""
		return FileAccess.get_file_as_string(file_name)
	# The renderer ignores a path with an error, so render the path up to its
	# first invalid character, as SVG viewers do
	var invalid : RegExMatch = invalid_path_character.search(path)
	if invalid != null:
		path = path.left(invalid.get_start())
	path = clamp_path_numbers(path)
	var fill : Color = MMType.deserialize_value(get_parameter("fill"))
	var stroke : Color = MMType.deserialize_value(get_parameter("stroke"))
	var stroke_attributes : String = ""
	if get_parameter("stroke_width") > 0.0 and stroke.a > 0.0:
		stroke_attributes = " stroke=\"#%s\" stroke-opacity=\"%f\" stroke-width=\"%f\"" % [ stroke.to_html(false), stroke.a, get_parameter("stroke_width") ]
	var fill_rule : String = "evenodd" if int(get_parameter("fill_rule")) == 1 else "nonzero"
	return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\" viewBox=\"0 0 100 100\"><path d=\"%s\" %s fill-rule=\"%s\"%s/></svg>" % [ path.xml_escape(true), color_to_svg(fill), fill_rule, stroke_attributes ]

## Path data with its numbers limited to +/-MAX_PATH_COORDINATE
static func clamp_path_numbers(path : String) -> String:
	var clamped : String = ""
	var position : int = 0
	for m in path_number.search_all(path):
		var value : float = m.get_string().to_float()
		if absf(value) > MAX_PATH_COORDINATE:
			clamped += path.substr(position, m.get_start()-position)+" %f" % (signf(value)*MAX_PATH_COORDINATE)
			position = m.get_end()
	return clamped+path.substr(position)

## SVG path data of the shape parameter, on the 100x100 canvas
func get_shape_path() -> String:
	var shape = get_parameter("shape")
	if shape is Dictionary:
		shape = MMType.deserialize_value(shape)
	if not shape is MMPolygon or shape.points.size() < 2:
		return ""
	var commands : PackedStringArray = PackedStringArray()
	for i in shape.points.size():
		commands.append("%s %f %f" % [ "M" if i == 0 else "L", 100.0*shape.points[i].x, 100.0*shape.points[i].y ])
	commands.append("Z")
	return " ".join(commands)

## SVG path data of the curves parameter: curves whose ends meet are joined,
## and outlines that end where they start are closed
func get_curves_path() -> String:
	var curves = get_parameter("curves")
	if curves is Dictionary:
		curves = MMType.deserialize_value(curves)
	if not curves is MMSplines or curves.splines.is_empty():
		return ""
	var commands : PackedStringArray = PackedStringArray()
	var start : Vector2
	var last : Vector2
	for i in curves.splines.size():
		var points : Array = curves.splines[i].points.map(func(p): return 100.0*p.position)
		if i == 0 or points[0].distance_to(last) > 0.01:
			if i > 0 and last.distance_to(start) < 0.01:
				commands.append("Z")
			commands.append("M %f %f" % [ points[0].x, points[0].y ])
			start = points[0]
		commands.append("C %f %f %f %f %f %f" % [ points[1].x, points[1].y, points[2].x, points[2].y, points[3].x, points[3].y ])
		last = points[3]
	if last.distance_to(start) < 0.01:
		commands.append("Z")
	return " ".join(commands)

func update_texture() -> void:
	update_pending = false
	var svg : String = get_svg()
	var resolution : int = 1 << int(get_parameter("size"))
	var image : Image = Image.new()
	if svg != "":
		if not svg.contains("<svg") or not is_well_formed(svg):
			print("SVG node: not a valid SVG document")
		else:
			# Measure the document, then render it at the right scale
			var document_size : Vector2 = get_document_size(svg)
			if document_size.x > 0.0 and document_size.y > 0.0:
				var scale : float = float(resolution)/max(document_size.x, document_size.y)
				if image.load_svg_from_string(svg, scale) != OK:
					image = Image.new()
				else:
					# Correct the scale if the measure was not precise enough
					var rendered_size : int = max(image.get_width(), image.get_height())
					if abs(rendered_size-resolution) > 1 and image.load_svg_from_string(svg, scale*resolution/rendered_size) != OK:
						image = Image.new()
	# The image is drawn over the background, and non square documents are centered
	var background : Color = MMType.deserialize_value(get_parameter("background"))
	if image.is_empty() or image.get_width() != resolution or image.get_height() != resolution or background.a > 0.0:
		var square : Image = Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)
		square.fill(background)
		if not image.is_empty():
			image.convert(Image.FORMAT_RGBA8)
			var w : int = min(image.get_width(), resolution)
			var h : int = min(image.get_height(), resolution)
			var source_rect : Rect2i = Rect2i((image.get_width()-w)/2, (image.get_height()-h)/2, w, h)
			if background.a > 0.0:
				square.blend_rect(image, source_rect, Vector2i((resolution-w)/2, (resolution-h)/2))
			else:
				square.blit_rect(image, source_rect, Vector2i((resolution-w)/2, (resolution-h)/2))
		image = square
	texture.set_texture(ImageTexture.create_from_image(image))
	mm_deps.dependency_update("o%d_tex" % get_instance_id(), texture)

# The file path is stored relative to the project, as for images

func _serialize_data(data: Dictionary) -> Dictionary:
	var file_path : String = data.parameters.get("file", "")
	file_path = file_path.replace(mm_loader.current_project_path, "%PROJECT_PATH%")
	file_path = file_path.replace(OS.get_user_data_dir(), "%USER_DATA_PATH%")
	file_path = file_path.replace(MMPaths.get_resource_dir(), "%MATERIAL_MAKER_PATH%")
	data.parameters.file = file_path
	return data

func _deserialize(data : Dictionary) -> void:
	if data.has("parameters") and data.parameters.has("file"):
		var file_path : String = data.parameters.file
		file_path = file_path.replace("%PROJECT_PATH%", mm_loader.current_project_path)
		file_path = file_path.replace("%USER_DATA_PATH%", OS.get_user_data_dir())
		file_path = file_path.replace("%MATERIAL_MAKER_PATH%", MMPaths.get_resource_dir())
		data.parameters.file = file_path
