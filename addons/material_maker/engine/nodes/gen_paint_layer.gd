@tool
extends MMGenBase
class_name MMGenPaintLayer


# A channel of a paint project (.mmpp): one of its layers, or all of its
# visible layers composited as the painter does. Layers are composited in the
# shader generated for the node (each layer image is a texture uniform).
#
# When the project is open in a paint panel, its layers are read from the
# panel, and the node is updated after each stroke and change of the layers.
# Otherwise the project's files are read, and watched.


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
var reload_pending : bool = false
## Textures of the uniforms of the generated shaders, by uniform name
var uniform_textures : Dictionary = {}

## Layers panels (MMPaintLayers) of the paint projects open in the user
## interface, by project path
static var open_projects : Dictionary = {}
## Paint layer nodes, to update them when an open project changes
static var paint_layer_nodes : Array = []

## Registers (or unregisters, with a null panel) an open paint project
static func set_open_project(path : String, layers_panel) -> void:
	if path == "":
		return
	path = path.simplify_path()
	if layers_panel == null:
		open_projects.erase(path)
	else:
		open_projects[path] = layers_panel
	project_changed(path)

## Called by paint projects when their layers change
static func project_changed(path) -> void:
	if not path is String or path == "":
		return
	path = path.simplify_path()
	for n in paint_layer_nodes.duplicate():
		if is_instance_valid(n) and String(n.get_parameter("project")).simplify_path() == path:
			n.schedule_reload()

func _enter_tree() -> void:
	if not self in paint_layer_nodes:
		paint_layer_nodes.append(self)

func _exit_tree() -> void:
	paint_layer_nodes.erase(self)

## Reloads the layers soon (several changes are coalesced)
func schedule_reload() -> void:
	if reload_pending or not is_inside_tree():
		return
	reload_pending = true
	await get_tree().create_timer(0.2).timeout
	reload_pending = false
	load_project()


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
	if project != "" and not open_projects.has(project.simplify_path()) and get_filetime(project) != project_time:
		load_project()

## Loads the layers of the project and their images
func load_project() -> void:
	var project : String = get_parameter("project")
	project_layers = []
	layer_names = PackedStringArray()
	project_time = get_filetime(project)
	var layers_panel = open_projects.get(project.simplify_path()) if project != "" else null
	if layers_panel != null and is_instance_valid(layers_panel):
		project_layers = read_open_layers(layers_panel.layers)
	elif project != "" and FileAccess.file_exists(project):
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
				var texture : MMTexture = channel_texture(Image.load_from_file(path.path_join(l[c])))
				if texture != null:
					layer.textures[c] = texture
		layer_names.append(layer.name)
		layer.layers = load_layers(l.get("layers", []), path)
		rv.append(layer)
	return rv

## Layers of a paint panel (MMLayers), as the layers read from files
func read_open_layers(layers : Array) -> Array:
	var rv : Array = []
	for l in layers:
		var layer : Dictionary = { name=l.name, type=l.get_layer_type(), hidden=l.hidden, textures={}, alphas={} }
		for c in CHANNELS:
			var alpha = l.get(c+"_alpha")
			layer.alphas[c] = float(alpha) if alpha != null else 1.0
		for c in l.get_channels():
			var source : Texture2D = l.get(c)
			if source != null:
				var texture : MMTexture = channel_texture(source.get_image())
				if texture != null:
					layer.textures[c] = texture
		layer_names.append(layer.name)
		layer.layers = read_open_layers(l.layers)
		rv.append(layer)
	return rv

## The texture of a channel's image (null if there is no image)
static func channel_texture(image : Image) -> MMTexture:
	if image == null or image.is_empty():
		return null
	image.convert(Image.FORMAT_RGBAH)
	var texture : MMTexture = MMTexture.new()
	texture.set_texture(ImageTexture.create_from_image(image))
	return texture

## The masks of a layer (its visible mask layers) added to masks
static func get_layer_masks(layer : Dictionary, masks : Array = []) -> Array:
	var rv : Array = masks.duplicate()
	for cl in layer.layers:
		if not cl.hidden and cl.type == LAYER_MASK and cl.textures.has("mask"):
			rv.push_back(cl.textures.mask)
	return rv

## The layers that are drawn, with the masks that apply to each, in drawing
## order (as MMPaintLayers.get_visible_layers)
func get_visible_layers(list : Array, layers_array : Array, masks : Array = []) -> void:
	for i in range(layers_array.size()-1, -1, -1):
		var l : Dictionary = layers_array[i]
		if l.hidden or l.type == LAYER_MASK:
			continue
		var m : Array = get_layer_masks(l, masks)
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

## Adds a texture uniform, and gives its texture to the shaders that use it
## (e.g. the material previews), as MMGenImage does
func add_texture_uniform(rv : ShaderCode, uniform_name : String, texture : MMTexture) -> void:
	rv.add_uniform(uniform_name, "sampler2D", texture)
	if uniform_textures.get(uniform_name) != texture:
		uniform_textures[uniform_name] = texture
		mm_deps.dependency_update(uniform_name, texture)

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
			drawn.push_back({ layer=layer, masks=get_layer_masks(layer) })
	var lines : PackedStringArray = PackedStringArray([ "vec4 %s_paint(vec2 uv) {" % genname, "\tvec4 c = %s;" % start, "\tvec4 t;", "\tfloat a;" ])
	var sample_uv : String = "fract(uv)"
	for i in drawn.size():
		var layer : Dictionary = drawn[i].layer
		var masks : String = ""
		for m in drawn[i].masks.size():
			var mask_name : String = "%s_l%d_mask%d" % [ genname, i, m ]
			add_texture_uniform(rv, mask_name, drawn[i].masks[m])
			masks += "*textureLod(%s, %s, 0.0).r" % [ mask_name, sample_uv ]
		var passes : Array = [ source ]
		if channel == "emission" and selected_layer == 0:
			# The layer's albedo hides the emission of the layers below
			passes = [ { texture="albedo", value="vec3(0.0)", alpha="t.a", alpha_channel="albedo" }, source ]
		for p in passes:
			if not layer.textures.has(p.texture):
				continue
			var texture_name : String = "%s_l%d_%s" % [ genname, i, p.texture ]
			add_texture_uniform(rv, texture_name, layer.textures[p.texture])
			var modulate : float = layer.alphas.get(p.get("alpha_channel", channel), 1.0) if p.texture != "mask" else 1.0
			lines.append("\tt = textureLod(%s, %s, 0.0);" % [ texture_name, sample_uv ])
			lines.append("\ta = clamp(%s*%f%s, 0.0, 1.0);" % [ p.alpha, modulate, masks ])
			lines.append("\tc = vec4(mix(c.rgb, %s, a), a+c.a*(1.0-a));" % p.value)
	lines.append("\treturn c;")
	lines.append("}")
	return "\n".join(lines)+"\n"

# The project path is stored relative to the graph, as for images (see MMGenImage)

func _serialize(data: Dictionary) -> Dictionary:
	return data

func _serialize_data(data: Dictionary) -> Dictionary:
	var project_path : String = data.parameters.get("project", "")
	# A directory is only replaced at the start of the path
	for d in [ [ mm_loader.current_project_path, "%PROJECT_PATH%" ], [ OS.get_user_data_dir(), "%USER_DATA_PATH%" ], [ MMPaths.get_resource_dir(), "%MATERIAL_MAKER_PATH%" ] ]:
		if d[0] != "" and project_path.begins_with(d[0]+"/"):
			project_path = d[1]+project_path.substr(d[0].length())
			break
	data.parameters.project = project_path
	return data

func _deserialize(data : Dictionary) -> void:
	if data.has("parameters") and data.parameters.has("project"):
		var project_path : String = data.parameters.project
		if mm_loader.current_project_path != "":
			project_path = project_path.replace("%PROJECT_PATH%", mm_loader.current_project_path)
		project_path = project_path.replace("%USER_DATA_PATH%", OS.get_user_data_dir())
		data.parameters.project = project_path.replace("%MATERIAL_MAKER_PATH%", MMPaths.get_resource_dir())
