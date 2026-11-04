extends RefCounted


# Imports MaterialX materials (.mtlx) as Material Maker graphs: the inputs of
# the material's surface shader (standard_surface, open_pbr_surface,
# UsdPreviewSurface or gltf_pbr) become inputs and parameters of a Material
# node. Images become Image nodes, and the common nodes that select, convert
# or scale them (constant, multiply, convert, extract, swizzle, separate,
# normalmap) are followed. Procedural MaterialX nodes are not translated: the
# inputs they drive are reported in the warnings and left unconnected.


## A MaterialX element: tag, attributes and children
class Element:
	extends RefCounted
	var tag : String
	var attributes : Dictionary = {}
	var children : Array[Element] = []
	var parent : Element = null

	func get_attribute(n : String, default : String = "") -> String:
		return attributes.get(n, default)

	func find_child(child_name : String) -> Element:
		for c in children:
			if c.get_attribute("name") == child_name:
				return c
		return null

	func get_input(input_name : String) -> Element:
		for c in children:
			if c.tag == "input" and c.get_attribute("name") == input_name:
				return c
		return null


const SHADERS : Array[String] = [ "standard_surface", "open_pbr_surface", "UsdPreviewSurface", "gltf_pbr" ]

## Material node channels: the Material input, the parameter that holds its
## value (or scales it when it is connected), whether it is a color (sRGB
## encoded in Material Maker), and the name and default value of the matching
## input of each surface shader
const CHANNELS : Array[Dictionary] = [
	{ input="albedo_tex", parameter="albedo_color", color=true,
		names={ standard_surface="base_color", open_pbr_surface="base_color", UsdPreviewSurface="diffuseColor", gltf_pbr="base_color" },
		defaults={ standard_surface=0.8, open_pbr_surface=0.8, UsdPreviewSurface=0.18, gltf_pbr=1.0 } },
	{ input="metallic_tex", parameter="metallic",
		names={ standard_surface="metalness", open_pbr_surface="base_metalness", UsdPreviewSurface="metallic", gltf_pbr="metallic" },
		defaults={ standard_surface=0.0, open_pbr_surface=0.0, UsdPreviewSurface=0.0, gltf_pbr=1.0 } },
	{ input="roughness_tex", parameter="roughness",
		names={ standard_surface="specular_roughness", open_pbr_surface="specular_roughness", UsdPreviewSurface="roughness", gltf_pbr="roughness" },
		defaults={ standard_surface=0.2, open_pbr_surface=0.3, UsdPreviewSurface=0.5, gltf_pbr=1.0 } },
	{ input="emission_tex", parameter="emission_energy", color=true,
		names={ standard_surface="emission_color", open_pbr_surface="emission_color", UsdPreviewSurface="emissiveColor", gltf_pbr="emissive" } },
	{ input="normal_tex", parameter="normal",
		names={ standard_surface="normal", open_pbr_surface="geometry_normal", UsdPreviewSurface="normal", gltf_pbr="normal" } },
	{ input="ao_tex", parameter="",
		names={ UsdPreviewSurface="occlusion", gltf_pbr="occlusion" } },
	{ input="opacity_tex", parameter="",
		names={ standard_surface="opacity", open_pbr_surface="geometry_opacity", UsdPreviewSurface="opacity", gltf_pbr="alpha" } },
	{ input="coat_tex", parameter="coat",
		names={ standard_surface="coat", open_pbr_surface="coat_weight", UsdPreviewSurface="clearcoat", gltf_pbr="clearcoat" } },
	{ input="coat_roughness_tex", parameter="coat_roughness",
		names={ standard_surface="coat_roughness", open_pbr_surface="coat_roughness", UsdPreviewSurface="clearcoatRoughness", gltf_pbr="clearcoat_roughness" } },
	{ input="anisotropy_tex", parameter="anisotropy",
		names={ standard_surface="specular_anisotropy", open_pbr_surface="specular_roughness_anisotropy" } },
	{ input="sheen_tex", parameter="sheen",
		names={ standard_surface="sheen", open_pbr_surface="fuzz_weight", gltf_pbr="sheen_color" } },
	{ input="transmission_tex", parameter="transmission",
		names={ standard_surface="transmission", open_pbr_surface="transmission_weight", gltf_pbr="transmission" } },
]

## The input that scales the base color, and the input that gives the
## emission strength (with its default value) of each surface shader (as in
## MaterialX's standard_surface_to_open_pbr translation, emission_luminance is
## used as is)
const BASE_WEIGHTS : Dictionary = { standard_surface="base", open_pbr_surface="base_weight" }
const EMISSION_WEIGHTS : Dictionary = {
	standard_surface={ name="emission", default=0.0 },
	open_pbr_surface={ name="emission_luminance", default=0.0 },
	gltf_pbr={ name="emissive_strength", default=1.0 } }

## Material inputs, when the Material node's definition cannot be read
const DEFAULT_MATERIAL_INPUTS : Dictionary = {
	albedo_tex="rgb", metallic_tex="f", roughness_tex="f", emission_tex="rgb", normal_tex="rgb",
	ao_tex="f", depth_tex="f", opacity_tex="f", sss_tex="f" }

## Color spaces of gamma encoded images (other color spaces are linear)
const GAMMA_SPACES : Array[String] = [ "srgb_texture", "srgb", "srgb_displayp3", "g22_rec709", "g18_rec709", "g22_ap1" ]

var document : Element
var base_dir : String
## The Material node's inputs (name -> type) and parameters
var material_inputs : Dictionary = {}
var material_parameters : Array = []
var nodes : Array = []
var connections : Array = []
var images : Dictionary = {}
var conversions : Dictionary = {}
var decomposers : Dictionary = {}
var warnings : PackedStringArray = PackedStringArray()
## Why the import failed
var error : String = ""
## Why the last evaluated input is not supported
var unsupported : String = ""


## The graph of the first material of a MaterialX file (or of the material
## with the given name), as a dictionary for mm_loader.create_gen(), with the
## import warnings in "warnings". Returns an empty dictionary on errors (and
## the reason in error).
func do_import(path : String, material_name : String) -> Dictionary:
	base_dir = path.get_base_dir()
	document = parse(path)
	if document == null:
		fail("Cannot read MaterialX file %s" % path)
		return {}
	var material : Element = null
	for e in all_elements(document):
		if e.tag == "surfacematerial" and (material_name == "" or e.get_attribute("name") == material_name):
			material = e
			break
	if material == null:
		fail("No material in %s" % path)
		return {}
	var shader_input : Element = material.get_input("surfaceshader")
	var shader : Element = resolve_connection(shader_input) if shader_input != null else null
	if shader == null:
		fail("The material %s has no surface shader" % material.get_attribute("name"))
		return {}
	var shader_type : String = shader.tag
	if not shader_type in SHADERS:
		fail("The surface shader of %s (%s) is not supported (supported shaders: %s)" % [ material.get_attribute("name"), shader_type, ", ".join(SHADERS) ])
		return {}
	read_material_definition()
	var parameters : Dictionary = { size=11 }
	var imported_inputs : Array[String] = []
	for channel in CHANNELS:
		var input_name : String = channel.names.get(shader_type, "")
		if input_name == "":
			continue
		imported_inputs.append(input_name)
		var input : Element = shader.get_input(input_name)
		if not material_inputs.has(channel.input):
			# Inputs that are set (connected or not 0) but cannot be imported
			# (coat_roughness is only reported with coat)
			var is_set : bool = input != null and (is_connected_input(input) or not is_zero(get_value(input, 0.0)))
			var reported : bool = input_name.ends_with("roughness") and not material_inputs.has(channel.input.replace("_roughness", ""))
			if is_set and not reported:
				warnings.append("%s: not imported, the Material node has no %s input" % [ input_name, channel.input.trim_suffix("_tex") ])
			continue
		if input == null:
			# The shader's default value
			if channel.has("defaults"):
				set_channel_value(channel, channel.defaults[shader_type], parameters)
			continue
		import_channel(channel, input, parameters)
	# Base color weight
	var base_weight : Element = shader.get_input(BASE_WEIGHTS.get(shader_type, ""))
	if base_weight != null:
		imported_inputs.append(base_weight.get_attribute("name"))
		var weight = evaluate(base_weight)
		if weight.has("value") and not weight.value is Array:
			var color : Dictionary = parameters.get("albedo_color", { type="Color", r=1.0, g=1.0, b=1.0, a=1.0 })
			for c in [ "r", "g", "b" ]:
				color[c] *= weight.value
			parameters.albedo_color = color
		else:
			warnings.append("%s: not imported (only constant weights are supported)" % base_weight.get_attribute("name"))
	# Emission strength (no emission when it is 0)
	if EMISSION_WEIGHTS.has(shader_type) and parameters.has("emission_energy"):
		var weight_info : Dictionary = EMISSION_WEIGHTS[shader_type]
		imported_inputs.append(weight_info.name)
		var weight : float = weight_info.default
		var weight_input : Element = shader.get_input(weight_info.name)
		if weight_input != null:
			var w : Dictionary = evaluate(weight_input)
			if w.has("value") and not w.value is Array:
				weight = w.value
			else:
				warnings.append("%s: not imported (only constant weights are supported)" % weight_info.name)
		parameters.emission_energy *= weight
		if weight == 0.0:
			disconnect_input("emission_tex")
			parameters.erase("emission_energy")
	import_displacement(material, parameters)
	parameters.flags_transparent = is_input_connected("opacity_tex")
	if shader_type == "UsdPreviewSurface" and float(get_value(shader.get_input("useSpecularWorkflow"), 0.0)) != 0.0:
		warnings.append("useSpecularWorkflow: the specular workflow is not supported, the material is imported as metallic")
	# Other inputs that are set but not imported
	for c in shader.children:
		if c.tag == "input" and not c.get_attribute("name") in imported_inputs and is_connected_input(c):
			warnings.append("%s: not imported" % c.get_attribute("name"))
	# The material's size is the size of its largest texture (2048 if there is
	# no texture), so maps are not resampled
	var largest : int = 0
	for image_path in images.keys():
		var image : Image = Image.load_from_file(image_path) if FileAccess.file_exists(image_path) else null
		if image != null:
			largest = max(largest, image.get_width(), image.get_height())
		else:
			warnings.append("cannot read image %s" % image_path)
	if largest > 0:
		parameters.size = clampi(roundi(log(largest)/log(2.0)), 6, 13)
	for p in parameters.keys():
		if not p in material_parameters:
			parameters.erase(p)
	nodes.push_front({ name="Material", type="material", node_position={ x=0, y=0 }, parameters=parameters })
	return { name=material.get_attribute("name"), label=material.get_attribute("name"), type="graph", node_position={ x=0, y=0 },
		nodes=nodes, connections=connections, warnings=warnings }

func fail(message : String) -> void:
	error = message

## Reads the inputs and parameters of the Material node
func read_material_definition() -> void:
	material_inputs = DEFAULT_MATERIAL_INPUTS
	material_parameters = [ "albedo_color", "metallic", "roughness", "emission_energy", "normal", "ao", "depth_scale", "flags_transparent", "size" ]
	var definition = mm_loader.predefined_generators.get("material", {})
	if definition is Dictionary and definition.has("shader_model"):
		material_inputs = {}
		for i in definition.shader_model.get("inputs", []):
			material_inputs[i.name] = i.type
		material_parameters = []
		for p in definition.shader_model.get("parameters", []):
			material_parameters.append(p.name)

## Imports a shader input: a value (Material parameter) or a connection to
## images (Material input, and the parameter as a scale)
func import_channel(channel : Dictionary, input : Element, parameters : Dictionary) -> void:
	var input_name : String = input.get_attribute("name")
	var source : Dictionary = evaluate(input)
	if source.is_empty():
		warnings.append("%s: not imported (%s)" % [ input_name, unsupported ])
		return
	if source.has("value"):
		if channel.input == "emission_tex":
			# Constant emission colors are uniform nodes
			if not is_zero(source.value):
				connect_constant(channel, source.value)
				parameters.emission_energy = 1.0
		else:
			set_channel_value(channel, source.value, parameters)
		return
	var from : Dictionary = output_of(source, channel)
	if channel.input == "normal_tex":
		# Material Maker's normal convention, from OpenGL tangent space normal maps
		var convert_name : String = "normal_from_opengl"
		nodes.append({ name=convert_name, type="normal_map_convert", node_position={ x=-300, y=200 }, parameters={ op=0 } })
		connections.append({ from=from.node, from_port=from.port, to=convert_name, to_port=0 })
		from = { node=convert_name, port=0 }
		parameters.normal = source.get("strength", 1.0)
	elif channel.parameter == "":
		if not is_equal_approx(source.get("scale", 1.0), 1.0):
			warnings.append("%s: the scale of the texture is ignored" % input_name)
	elif channel.parameter == "albedo_color" and source.has("color_scale"):
		set_channel_value(channel, source.color_scale, parameters)
	else:
		# A connected input is scaled by its parameter
		set_channel_value(channel, source.get("scale", 1.0), parameters)
	connections.append({ from=from.node, from_port=from.port, to="Material", to_port=material_inputs.keys().find(channel.input) })

## Imports the height map of the material's displacement shader (Material
## Maker's depth is 1 - height)
func import_displacement(material : Element, parameters : Dictionary) -> void:
	var shader_input : Element = material.get_input("displacementshader")
	if shader_input == null:
		return
	var shader : Element = resolve_connection(shader_input)
	if shader == null or shader.tag != "displacement" or not material_inputs.has("depth_tex"):
		warnings.append("displacementshader: not imported")
		return
	var displacement : Element = shader.get_input("displacement")
	if displacement == null:
		return
	var source : Dictionary = evaluate(displacement)
	if not source.has("image"):
		if not source.has("value"):
			warnings.append("displacement: not imported (%s)" % unsupported)
		return
	var from : Dictionary = output_of(source, { input="depth_tex" })
	nodes.append({ name="depth_from_height", type="invert", node_position={ x=-300, y=350 }, parameters={} })
	connections.append({ from=from.node, from_port=from.port, to="depth_from_height", to_port=0 })
	connections.append({ from="depth_from_height", from_port=0, to="Material", to_port=material_inputs.keys().find("depth_tex") })
	var s = get_value(shader.get_input("scale"), 1.0)
	parameters.depth_scale = (s[0] if s is Array else s)*source.get("scale", 1.0)

## Sets the parameter of a channel (its value when the input is not
## connected, or the scale of the connected input)
func set_channel_value(channel : Dictionary, value, parameters : Dictionary) -> void:
	if channel.parameter == "":
		# Inputs without parameter (that are 1 when not connected) get a
		# uniform node
		if not is_equal_approx(value[0] if value is Array else value, 1.0):
			connect_constant(channel, value)
		return
	if channel.get("color", false) and channel.parameter == "albedo_color":
		var c : Array = value if value is Array else [ value, value, value ]
		parameters[channel.parameter] = { type="Color", r=c[0], g=c[1], b=c[2], a=1.0 }
	elif channel.input == "normal_tex":
		return
	else:
		parameters[channel.parameter] = value[0] if value is Array else value

## Connects a uniform node that holds a constant value to a Material input
func connect_constant(channel : Dictionary, value) -> void:
	var node_name : String = "%s_value" % channel.input.trim_suffix("_tex")
	var node : Dictionary = { name=node_name, node_position={ x=-300, y=-300+100*nodes.size() } }
	if material_inputs[channel.input] == "f":
		node.type = "uniform_greyscale"
		node.parameters = { color=value[0] if value is Array else value }
	else:
		var c : Array = value if value is Array else [ value, value, value ]
		node.type = "uniform"
		node.parameters = { color={ type="Color", r=c[0], g=c[1], b=c[2], a=1.0 } }
	nodes.append(node)
	connections.append({ from=node_name, from_port=0, to="Material", to_port=material_inputs.keys().find(channel.input) })

static func is_zero(value) -> bool:
	for v in (value if value is Array else [ value ]):
		if not is_zero_approx(v):
			return false
	return true

func is_input_connected(input_name : String) -> bool:
	var port : int = material_inputs.keys().find(input_name)
	for c in connections:
		if c.to == "Material" and c.to_port == port:
			return true
	return false

func disconnect_input(input_name : String) -> void:
	var port : int = material_inputs.keys().find(input_name)
	connections = connections.filter(func(c): return c.to != "Material" or c.to_port != port)
	var constant_name : String = "%s_value" % input_name.trim_suffix("_tex")
	nodes = nodes.filter(func(n): return n.name != constant_name)

## The node output that provides a source to a channel: an Image node (with
## a color space conversion if needed), or a channel of it (decompose)
func output_of(source : Dictionary, channel : Dictionary) -> Dictionary:
	var node_name : String = get_image_node(source.image)
	var single : bool = material_inputs[channel.input] == "f"
	# Colors are sRGB encoded in Material Maker, other channels are linear
	var wants_gamma : bool = channel.get("color", false)
	if source.channel != 3 and source.gamma != wants_gamma:
		node_name = get_conversion_node(node_name, source.gamma)
	if source.channel >= 0 and (single or source.channel == 3):
		return { node=get_decompose_node(node_name), port=source.channel }
	return { node=node_name, port=0 }

func get_image_node(path : String) -> String:
	if not images.has(path):
		var node_name : String = "image_%d" % images.size()
		images[path] = node_name
		nodes.append({ name=node_name, type="image", node_position={ x=-900, y=-300+200*images.size() },
			parameters={ image=path } })
	return images[path]

## A Color Conversion node, from linear to sRGB or the other way around
func get_conversion_node(from_node : String, to_linear : bool) -> String:
	var key : String = "%s:%s" % [ from_node, to_linear ]
	if not conversions.has(key):
		var node_name : String = "%s_%s" % [ from_node, "linear" if to_linear else "srgb" ]
		conversions[key] = node_name
		nodes.append({ name=node_name, type="color_conversion", node_position={ x=-650, y=-300+200*images.size() },
			parameters={ mode=1 if to_linear else 0 } })
		connections.append({ from=from_node, from_port=0, to=node_name, to_port=0 })
	return conversions[key]

func get_decompose_node(from_node : String) -> String:
	if not decomposers.has(from_node):
		var node_name : String = "%s_channels" % from_node
		decomposers[from_node] = node_name
		nodes.append({ name=node_name, type="decompose", node_position={ x=-400, y=-300+200*decomposers.size() }, parameters={} })
		connections.append({ from=from_node, from_port=0, to=node_name, to_port=0 })
	return decomposers[from_node]

## The method that evaluates the output of each supported node
const NODE_EVALUATORS : Dictionary = {
	image="evaluate_image", tiledimage="evaluate_image", UsdUVTexture="evaluate_image",
	gltf_image="evaluate_image", gltf_colorimage="evaluate_image", gltf_normalmap="evaluate_image",
	constant="evaluate_constant", convert="evaluate_passthrough", dot="evaluate_passthrough", extract="evaluate_extract",
	swizzle="evaluate_swizzle", separate2="evaluate_separate", separate3="evaluate_separate", separate4="evaluate_separate",
	multiply="evaluate_multiply", normalmap="evaluate_normalmap"
}

## What an input or node output provides: { value }, or { image, channel,
## gamma, scale, color_scale, strength }, or {} when unsupported (and the
## reason is in unsupported)
func evaluate(input : Element) -> Dictionary:
	if input == null:
		unsupported = "missing input"
		return {}
	if input.attributes.has("value") and not is_connected_input(input):
		return { value=parse_value(input.get_attribute("value")) }
	var node : Element = resolve_connection(input)
	if node == null:
		unsupported = "cannot find the node connected to %s" % input.get_attribute("name")
		return {}
	var output_name : String = input.get_attribute("output")
	if NODE_EVALUATORS.has(node.tag):
		return call(NODE_EVALUATORS[node.tag], node, output_name)
	unsupported = "unsupported MaterialX node %s (%s)" % [ node.get_attribute("name"), node.tag ]
	return {}

func evaluate_image(node : Element, output_name : String) -> Dictionary:
	var file_input : Element = node.get_input("file")
	if file_input == null or file_input.get_attribute("value") == "":
		unsupported = "the image %s has no file" % node.get_attribute("name")
		return {}
	var file : String = file_input.get_attribute("value")
	if file.contains("<UDIM>") or file.contains("<UVTILE>"):
		unsupported = "the image %s uses UDIM tiles" % node.get_attribute("name")
		return {}
	var path : String = get_file_prefix(file_input)+file
	if path.is_relative_path():
		path = base_dir.path_join(path)
	# Color spaces only apply to color images
	var gamma : bool = false
	if node.get_attribute("type") in [ "color3", "color4", "multioutput" ]:
		gamma = get_color_space(file_input).to_lower() in GAMMA_SPACES
	var rv : Dictionary = { image=path.simplify_path(), channel=-1, gamma=gamma }
	match output_name:
		"r", "outr":
			rv.channel = 0
		"g", "outg":
			rv.channel = 1
		"b", "outb":
			rv.channel = 2
		"a", "outa":
			rv.channel = 3
	# Constant factors of glTF and USD images
	var factor_input : Element = node.get_input({ UsdUVTexture="scale", gltf_image="factor", gltf_colorimage="color" }.get(node.tag, ""))
	if factor_input != null:
		var f = get_value(factor_input, 1.0)
		if f is Array and rv.channel >= 0 and rv.channel < f.size():
			rv.scale = f[rv.channel]
		elif f is Array:
			rv.scale = f[0]
			rv.color_scale = f.slice(0, 3)
		else:
			rv.scale = f
	var bias : Element = node.get_input("bias")
	if node.tag == "UsdUVTexture" and bias != null:
		var b = get_value(bias, 0.0)
		var s = rv.get("scale", 1.0)
		if is_equal_approx(b[0] if b is Array else b, -1.0) and is_equal_approx(s, 2.0):
			# Usual decoding of normal maps
			rv.erase("scale")
			rv.erase("color_scale")
		elif not is_equal_approx(b[0] if b is Array else b, 0.0):
			warnings.append("%s: the bias of the texture is ignored" % node.get_attribute("name"))
	# Texture coordinates transforms are not supported
	for t in [ [ "uvtiling", 1.0 ], [ "uvoffset", 0.0 ], [ "rotate", 0.0 ], [ "offset", 0.0 ], [ "realworldimagesize", 1.0 ], [ "realworldtilesize", 1.0 ] ]:
		var transform : Element = node.get_input(t[0])
		if transform != null and not is_connected_input(transform):
			var v = get_value(transform, t[1])
			for c in (v if v is Array else [ v ]):
				if not is_equal_approx(c, t[1]):
					warnings.append("%s: %s is ignored" % [ node.get_attribute("name"), t[0] ])
					break
	if node.tag.begins_with("gltf_"):
		var scale_input : Element = node.get_input("scale")
		if scale_input != null:
			var s = get_value(scale_input, 1.0)
			for c in (s if s is Array else [ s ]):
				if not is_equal_approx(c, 1.0):
					warnings.append("%s: scale is ignored" % node.get_attribute("name"))
					break
	return rv

func evaluate_constant(node : Element, _output_name : String) -> Dictionary:
	return evaluate(node.get_input("value"))

func evaluate_passthrough(node : Element, _output_name : String) -> Dictionary:
	return evaluate(node.get_input("in"))

func evaluate_extract(node : Element, _output_name : String) -> Dictionary:
	var source : Dictionary = evaluate(node.get_input("in"))
	var index : int = int(get_value(node.get_input("index"), 0.0))
	if source.has("image"):
		source.channel = index
	elif source.has("value") and source.value is Array:
		source.value = source.value[index]
	return source

func evaluate_swizzle(node : Element, _output_name : String) -> Dictionary:
	var source : Dictionary = evaluate(node.get_input("in"))
	var channels : String = node.get_input("channels").get_attribute("value", "") if node.get_input("channels") != null else ""
	if source.has("image") and channels.length() == 1:
		source.channel = "rgba".find(channels)
		if source.channel == -1:
			source.channel = "xyzw".find(channels)
	elif source.has("image") and not channels in [ "rgb", "xyz", "rgba", "xyzw" ]:
		unsupported = "swizzle %s (%s)" % [ node.get_attribute("name"), channels ]
		return {}
	return source

func evaluate_separate(node : Element, output_name : String) -> Dictionary:
	var source : Dictionary = evaluate(node.get_input("in"))
	var index : int = [ "outr", "outg", "outb", "outa" ].find(output_name)
	if index == -1:
		index = [ "outx", "outy", "outz", "outw" ].find(output_name)
	if source.has("image"):
		source.channel = index
	elif source.has("value") and source.value is Array and index >= 0:
		source.value = source.value[index]
	return source

func evaluate_multiply(node : Element, _output_name : String) -> Dictionary:
	var a : Dictionary = evaluate(node.get_input("in1"))
	if a.is_empty():
		return {}
	var b : Dictionary = evaluate(node.get_input("in2"))
	if b.is_empty():
		return {}
	for pair in [ [ a, b ], [ b, a ] ]:
		if pair[0].has("image") and pair[1].has("value"):
			var factor = pair[1].value
			var f : float = factor[0] if factor is Array else factor
			pair[0].scale = pair[0].get("scale", 1.0)*f
			if factor is Array and factor.size() >= 3:
				pair[0].color_scale = factor.slice(0, 3)
			return pair[0]
	if a.has("value") and b.has("value") and not a.value is Array and not b.value is Array:
		return { value=a.value*b.value }
	unsupported = "multiply %s of two images" % node.get_attribute("name")
	return {}

func evaluate_normalmap(node : Element, _output_name : String) -> Dictionary:
	var source : Dictionary = evaluate(node.get_input("in"))
	var scale_input : Element = node.get_input("scale")
	if scale_input != null and source.has("image"):
		var s = get_value(scale_input, 1.0)
		source.strength = s[0] if s is Array else s
	return source

## The node an input is connected to (nodename, or a nodegraph's output)
func resolve_connection(input : Element) -> Element:
	if input == null:
		return null
	var scope : Element = input.parent.parent if input.parent != null else document
	if input.parent != null and input.parent.tag == "output":
		scope = input.parent.parent
	if input.attributes.has("nodegraph"):
		var graph : Element = document.find_child(input.get_attribute("nodegraph"))
		if graph == null:
			return null
		var output : Element = graph.find_child(input.get_attribute("output", "out"))
		if output == null:
			# Nodegraphs with a single output
			for c in graph.children:
				if c.tag == "output":
					output = c
					break
		if output == null:
			return null
		return resolve_output(graph, output)
	if input.attributes.has("nodename"):
		var node_name : String = input.get_attribute("nodename")
		var node : Element = scope.find_child(node_name) if scope != null else null
		if node == null:
			node = document.find_child(node_name)
		return node
	if input.attributes.has("interfacename") and scope != null and scope.tag == "nodegraph":
		return resolve_connection(scope.get_input(input.get_attribute("interfacename")))
	return null

## The node an output of a nodegraph is connected to
func resolve_output(graph : Element, output : Element) -> Element:
	if output.attributes.has("nodename"):
		return graph.find_child(output.get_attribute("nodename"))
	if output.attributes.has("interfacename"):
		return resolve_connection(graph.get_input(output.get_attribute("interfacename")))
	return null

func is_connected_input(input : Element) -> bool:
	return input.attributes.has("nodename") or input.attributes.has("nodegraph") or input.attributes.has("interfacename")

## The value of an unconnected input (or default)
func get_value(input : Element, default):
	if input == null or not input.attributes.has("value") or is_connected_input(input):
		return default
	return parse_value(input.get_attribute("value"))

## The fileprefix in effect for an element (inherited from its parents)
func get_file_prefix(e : Element) -> String:
	var prefix : String = ""
	while e != null:
		if e.attributes.has("fileprefix"):
			prefix = e.get_attribute("fileprefix")+prefix
		e = e.parent
	return prefix

## The colorspace in effect for an element (inherited from its parents)
func get_color_space(e : Element) -> String:
	while e != null:
		if e.attributes.has("colorspace"):
			return e.get_attribute("colorspace")
		e = e.parent
	return ""

static func parse_value(s : String):
	var parts : PackedStringArray = s.split(",")
	if parts.size() == 1:
		return float(s) if s.is_valid_float() else (1.0 if s == "true" else 0.0)
	var rv : Array = []
	for p in parts:
		rv.append(float(p.strip_edges()))
	return rv

static func parse(path : String) -> Element:
	var parser : XMLParser = XMLParser.new()
	if parser.open(path) != OK:
		return null
	var root : Element = Element.new()
	root.tag = "#document"
	var current : Element = root
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var e : Element = Element.new()
				e.tag = parser.get_node_name()
				for i in parser.get_attribute_count():
					e.attributes[parser.get_attribute_name(i)] = parser.get_attribute_value(i)
				e.parent = current
				current.children.append(e)
				if not parser.is_empty():
					current = e
			XMLParser.NODE_ELEMENT_END:
				if current.parent != null:
					current = current.parent
	# The materialx element is the document
	for c in root.children:
		if c.tag == "materialx":
			return c
	return null

static func all_elements(e : Element) -> Array[Element]:
	var rv : Array[Element] = [ e ]
	for c in e.children:
		rv.append_array(all_elements(c))
	return rv
