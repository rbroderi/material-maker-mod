@tool
extends MMGenBase
class_name MMGenPaintLayer


# A channel of a paint project (.mmpp): one of its layers, or all of its
# visible layers composited as the painter does. The project's files are
# watched, so the node follows the painting. Layers are composited in the
# shader generated for the node (each layer image is a texture uniform).


const CHANNELS : Array[String] = [ "albedo", "metallic", "roughness", "emission", "normal", "depth", "occlusion" ]
const GRAYSCALE_CHANNELS : Array[String] = [ "metallic", "roughness", "depth", "occlusion" ]
const LAYER_PAINT : int = 0
const LAYER_PROCEDURAL : int = 1
const LAYER_MASK : int = 2

## Layers of the project, in the order of the project file (top first):
## { name, type, hidden, alphas, textures: { channel file name: MMTexture }, layers }
var project_layers : Array = []
## Flat list of the names of all layers, for the layer parameter
var layer_names : PackedStringArray = PackedStringArray()
var project_time : int = 0
var timer : Timer


func _ready() -> void:
	timer = Timer.new()
	add_child(timer)
	timer.wait_time = 2
	timer.timeout.connect(_on_timeout)
	timer.start()
	load_project()

func get_type() -> String:
	return "paint_layer"

func get_type_name() -> String:
	return "Paint Layer"

func get_description() -> String:
	return "\n".join([ TranslationServer.translate("Paint Layer"), TranslationServer.translate("A channel of a paint project's layer, or of all its visible layers") ])

func get_parameter_defs() -> Array:
	var layer_values : Array = [ { name="All visible layers", value="all" } ]
	for i in layer_names.size():
		layer_values.append({ name=layer_names[i], value=str(i) })
	return [
		{ name="project", type="file", label="Paint project", filters=[ "*.mmpp;Paint project" ], default="",
			longdesc="A paint project (.mmpp) saved by Material Maker's painter" },
		{ name="layer", type="enum", label="Layer", default=0, values=layer_values,
			longdesc="A layer of the project, or all its visible layers composited as in the painter" },
		{ name="channel", type="enum", label="Channel", default=0,
			values=CHANNELS.map(func(c): return { name=c.capitalize(), value=c }),
			longdesc="The channel of the layer: albedo, emission and normal are colors, the others are grayscale" }
	]

func get_output_defs(_show_hidden : bool = false) -> Array:
	return [ { type="f" if get_channel() in GRAYSCALE_CHANNELS else "rgba" } ]

func get_channel() -> String:
	return CHANNELS[clampi(int(get_parameter("channel")), 0, CHANNELS.size()-1)]

func set_parameter(n : String, v) -> void:
	super.set_parameter(n, v)
	match n:
		"project":
			if is_inside_tree():
				load_project()
		"layer", "channel":
			notify_output_change(0)

func get_filetime(file_path : String) -> int:
	return FileAccess.get_modified_time(file_path) if FileAccess.file_exists(file_path) else 0

func _on_timeout() -> void:
	var project : String = get_parameter("project")
	if project != "" and get_filetime(project) != project_time:
		load_project()

## Loads the layers of the project and their images
func load_project() -> void:
	var project : String = get_parameter("project")
	project_layers = []
	layer_names = PackedStringArray()
	project_time = get_filetime(project)
	if project != "" and FileAccess.file_exists(project):
		var data = JSON.parse_string(FileAccess.get_file_as_string(project))
		if data is Dictionary and data.has("layers"):
			# Layer images are in a directory named as the project file
			project_layers = load_layers(data.layers, project.left(project.rfind(".")))
	# The layer parameter's values changed
	emit_signal("parameter_changed", "__update_all__", null)
	notify_output_change(0)

func load_layers(data_layers : Array, path : String) -> Array:
	var rv : Array = []
	for l in data_layers:
		var layer : Dictionary = { name=l.get("name", ""), type=int(l.get("type", LAYER_PAINT)), hidden=l.get("hidden", false), textures={}, alphas={} }
		for c in CHANNELS:
			layer.alphas[c] = float(l.get(c+"_alpha", 1.0))
		for c in [ "albedo", "mr", "emission", "normal", "do", "mask" ]:
			if l.has(c):
				var image : Image = Image.load_from_file(path.path_join(l[c]))
				if image != null and not image.is_empty():
					var texture : MMTexture = MMTexture.new()
					texture.set_texture(ImageTexture.create_from_image(image))
					layer.textures[c] = texture
		layer_names.append(layer.name)
		layer.layers = load_layers(l.get("layers", []), path)
		rv.append(layer)
	return rv

## The layers that are drawn, with the masks that apply to each, in drawing
## order (as MMPaintLayers.get_visible_layers)
func get_visible_layers(list : Array, layers_array : Array, masks : Array = []) -> void:
	for i in range(layers_array.size()-1, -1, -1):
		var l : Dictionary = layers_array[i]
		if l.hidden or l.type == LAYER_MASK:
			continue
		var m : Array = masks.duplicate()
		for cl in l.layers:
			if not cl.hidden and cl.type == LAYER_MASK and cl.textures.has("mask"):
				m.push_back(cl.textures.mask)
		get_visible_layers(list, l.layers, m)
		list.push_back({ layer=l, masks=m })

func find_layer(index : int, layers_array : Array = project_layers, counter : Array = [ 0 ]) -> Dictionary:
	for l in layers_array:
		if counter[0] == index:
			return l
		counter[0] += 1
		var found : Dictionary = find_layer(index, l.layers, counter)
		if not found.is_empty():
			return found
	return {}

## GLSL source (texture, channel components and alpha) of a channel of a layer
## (see MMPaintLayers.update_layers_renderer)
func channel_source(channel : String) -> Dictionary:
	match channel:
		"albedo":
			return { texture="albedo", value="t.rgb", alpha="t.a" }
		"metallic":
			return { texture="mr", value="vec3(t.r)", alpha="t.b" }
		"roughness":
			return { texture="mr", value="vec3(t.g)", alpha="t.a" }
		"emission":
			return { texture="emission", value="t.rgb", alpha="t.a" }
		"normal":
			return { texture="normal", value="t.rgb", alpha="t.a" }
		"depth":
			return { texture="do", value="vec3(t.r)", alpha="t.b" }
		"occlusion":
			return { texture="do", value="vec3(t.g)", alpha="t.a" }
	return {}

func _get_shader_code(uv : String, _output_index : int, context : MMGenContext) -> ShaderCode:
	var genname : String = "o"+str(get_instance_id())
	var rv : ShaderCode = ShaderCode.new()
	var channel : String = get_channel()
	var is_greyscale : bool = channel in GRAYSCALE_CHANNELS
	rv.output_type = "f" if is_greyscale else "rgba"
	var variant_index : int = context.get_variant(self, uv)
	if variant_index == -1:
		variant_index = context.get_variant(self, uv)
		var function : String = build_function(genname, channel, rv)
		rv.add_global(function, genname+"_paint_layer")
		rv.code = "vec4 %s_%d = %s_paint(%s);\n" % [ genname, variant_index, genname, uv ]
	rv.output_values[rv.output_type] = ("%s_%d.r" if is_greyscale else "%s_%d") % [ genname, variant_index ]
	return rv

## The GLSL function that composites the channel, and its texture uniforms
func build_function(genname : String, channel : String, rv : ShaderCode) -> String:
	var source : Dictionary = channel_source(channel)
	var drawn : Array = []
	var start : String = "vec4(0.0)"
	var selected_layer : int = int(get_parameter("layer"))
	if selected_layer == 0:
		get_visible_layers(drawn, project_layers)
		# Backgrounds of the painter's channels
		if channel == "normal":
			start = "vec4(0.5, 0.5, 0.0, 1.0)"
		elif channel == "occlusion":
			start = "vec4(1.0)"
	else:
		var layer : Dictionary = find_layer(selected_layer-1)
		if not layer.is_empty():
			if layer.type == LAYER_MASK:
				source = { texture="mask", value="vec3(t.r)", alpha="1.0" }
			var masks : Array = []
			for cl in layer.layers:
				if not cl.hidden and cl.type == LAYER_MASK and cl.textures.has("mask"):
					masks.push_back(cl.textures.mask)
			drawn.push_back({ layer=layer, masks=masks })
	var lines : PackedStringArray = PackedStringArray([ "vec4 %s_paint(vec2 uv) {" % genname, "\tvec4 c = %s;" % start, "\tvec4 t;", "\tfloat a;" ])
	var sample_uv : String = "fract(uv)"
	for i in drawn.size():
		var layer : Dictionary = drawn[i].layer
		var masks : String = ""
		for m in drawn[i].masks.size():
			var mask_name : String = "%s_l%d_mask%d" % [ genname, i, m ]
			rv.add_uniform(mask_name, "sampler2D", drawn[i].masks[m])
			masks += "*textureLod(%s, %s, 0.0).r" % [ mask_name, sample_uv ]
		var passes : Array = [ source ]
		if channel == "emission" and selected_layer == 0:
			# The layer's albedo hides the emission of the layers below
			passes = [ { texture="albedo", value="vec3(0.0)", alpha="t.a", alpha_channel="albedo" }, source ]
		for p in passes:
			if not layer.textures.has(p.texture):
				continue
			var texture_name : String = "%s_l%d_%s" % [ genname, i, p.texture ]
			rv.add_uniform(texture_name, "sampler2D", layer.textures[p.texture])
			var modulate : float = layer.alphas.get(p.get("alpha_channel", channel), 1.0) if p.texture != "mask" else 1.0
			lines.append("\tt = textureLod(%s, %s, 0.0);" % [ texture_name, sample_uv ])
			lines.append("\ta = clamp(%s*%f%s, 0.0, 1.0);" % [ p.alpha, modulate, masks ])
			lines.append("\tc = vec4(mix(c.rgb, %s, a), a+c.a*(1.0-a));" % p.value)
	lines.append("\treturn c;")
	lines.append("}")
	return "\n".join(lines)+"\n"

# The project path is stored relative to the project, as for images

func _serialize_data(data: Dictionary) -> Dictionary:
	var path : String = data.parameters.get("project", "")
	path = path.replace(mm_loader.current_project_path, "%PROJECT_PATH%")
	path = path.replace(OS.get_user_data_dir(), "%USER_DATA_PATH%")
	data.parameters.project = path
	return data

func _deserialize(data : Dictionary) -> void:
	if data.has("parameters") and data.parameters.has("project"):
		data.parameters.project = data.parameters.project.replace("%PROJECT_PATH%", mm_loader.current_project_path)
		data.parameters.project = data.parameters.project.replace("%USER_DATA_PATH%", OS.get_user_data_dir())
