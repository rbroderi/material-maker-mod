@tool
extends MMGenTexture
class_name MMGenSVG


# Texture generator from vector graphics: an SVG file, or path data edited
# in the node. Vector graphics are rendered (with ThorVG) at the selected
# resolution, so they stay sharp.


var update_pending : bool = false


func _ready() -> void:
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
		{ name="stroke", type="color", label="Stroke", default=Color(0.0, 0.0, 0.0, 0.0), longdesc="The stroke color of the path" },
		{ name="stroke_width", type="float", label="Stroke width", min=0.0, max=20.0, step=0.1, default=0.0, longdesc="The stroke width of the path, on the 100x100 canvas" },
		{ name="size", type="size", label="Size", first=6, last=13, default=10, longdesc="The resolution of the rendered image" }
	]

func set_parameter(n : String, v) -> void:
	super.set_parameter(n, v)
	# Several parameters are set at once when loading, so render once
	if is_inside_tree() and not update_pending:
		update_pending = true
		update_texture.call_deferred()

static func color_to_svg(c : Color) -> String:
	return "fill=\"#%s\" fill-opacity=\"%f\"" % [ c.to_html(false), c.a ]

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
	var fill : Color = MMType.deserialize_value(get_parameter("fill"))
	var stroke : Color = MMType.deserialize_value(get_parameter("stroke"))
	var stroke_attributes : String = ""
	if get_parameter("stroke_width") > 0.0 and stroke.a > 0.0:
		stroke_attributes = " stroke=\"#%s\" stroke-opacity=\"%f\" stroke-width=\"%f\"" % [ stroke.to_html(false), stroke.a, get_parameter("stroke_width") ]
	return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\" viewBox=\"0 0 100 100\"><path d=\"%s\" %s%s/></svg>" % [ path.xml_escape(), color_to_svg(fill), stroke_attributes ]

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
		# Render once to get the document's size, then at the right scale
		if image.load_svg_from_string(svg, 1.0) == OK and image.get_width() > 0:
			var scale : float = float(resolution)/max(image.get_width(), image.get_height())
			image.load_svg_from_string(svg, scale)
	if image.is_empty():
		image = Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)
	# Non square documents are centered on a square image
	if image.get_width() != resolution or image.get_height() != resolution:
		var square : Image = Image.create(resolution, resolution, false, Image.FORMAT_RGBA8)
		image.convert(Image.FORMAT_RGBA8)
		var w : int = min(image.get_width(), resolution)
		var h : int = min(image.get_height(), resolution)
		square.blit_rect(image, Rect2i(0, 0, w, h), Vector2i((resolution-w)/2, (resolution-h)/2))
		image = square
	texture.set_texture(ImageTexture.create_from_image(image))
	mm_deps.dependency_update("o%d_tex" % get_instance_id(), texture)

# The file path is stored relative to the project, as for images

func _serialize_data(data: Dictionary) -> Dictionary:
	var path : String = data.parameters.get("file", "")
	path = path.replace(mm_loader.current_project_path, "%PROJECT_PATH%")
	path = path.replace(OS.get_user_data_dir(), "%USER_DATA_PATH%")
	path = path.replace(MMPaths.get_resource_dir(), "%MATERIAL_MAKER_PATH%")
	data.parameters.file = path
	return data

func _deserialize(data : Dictionary) -> void:
	if data.has("parameters") and data.parameters.has("file"):
		data.parameters.file = data.parameters.file.replace("%PROJECT_PATH%", mm_loader.current_project_path)
		data.parameters.file = data.parameters.file.replace("%USER_DATA_PATH%", OS.get_user_data_dir())
		data.parameters.file = data.parameters.file.replace("%MATERIAL_MAKER_PATH%", MMPaths.get_resource_dir())
