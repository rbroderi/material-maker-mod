extends RefCounted
class_name MMMaterialXImporter


# Imports MaterialX materials (.mtlx) as Material Maker graphs: the inputs of
# the material's surface shader (standard_surface, open_pbr_surface,
# UsdPreviewSurface or gltf_pbr) become inputs and parameters of a Material
# node. Images become Image nodes, and the common nodes that select, convert
# or scale them (constant, multiply, convert, extract, swizzle, separate,
# normalmap) are followed. Procedural MaterialX nodes are not translated: the
# inputs they drive are reported and left unconnected.


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


## Material node channels: the Material input, the parameter that scales it,
## and the names of the matching input of each surface shader
const CHANNELS : Array[Dictionary] = [
	{ input="albedo_tex", parameter="albedo_color", color=true,
		names={ standard_surface="base_color", open_pbr_surface="base_color", UsdPreviewSurface="diffuseColor", gltf_pbr="base_color" } },
	{ input="metallic_tex", parameter="metallic",
		names={ standard_surface="metalness", open_pbr_surface="base_metalness", UsdPreviewSurface="metallic", gltf_pbr="metallic" } },
	{ input="roughness_tex", parameter="roughness",
		names={ standard_surface="specular_roughness", open_pbr_surface="specular_roughness", UsdPreviewSurface="roughness", gltf_pbr="roughness" } },
	{ input="emission_tex", parameter="emission_energy",
		names={ standard_surface="emission_color", open_pbr_surface="emission_color", UsdPreviewSurface="emissiveColor", gltf_pbr="emissive" } },
	{ input="normal_tex", parameter="normal",
		names={ standard_surface="normal", open_pbr_surface="geometry_normal", UsdPreviewSurface="normal", gltf_pbr="normal" } },
	{ input="ao_tex", parameter="ao",
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

const MATERIAL_INPUTS : Array[String] = [ "albedo_tex", "metallic_tex", "roughness_tex", "emission_tex", "normal_tex", "ao_tex", "depth_tex", "opacity_tex", "sss_tex", "coat_tex", "coat_roughness_tex", "anisotropy_tex", "sheen_tex", "transmission_tex" ]

## Color spaces of images that hold linear colors (converted to sRGB by the
## Image node, Material Maker's colors are sRGB encoded)
const LINEAR_SPACES : Array[String] = [ "lin_rec709", "lin_srgb", "linear", "acescg", "lin_ap1", "scene-linear rec.709-srgb", "linear rec.709 (srgb)" ]

var document : Element
var base_dir : String
var nodes : Array = []
var connections : Array = []
var images : Dictionary = {}
var decomposers : Dictionary = {}
var warnings : PackedStringArray = PackedStringArray()


## The graph of the first material of a MaterialX file (or of the material
## with the given name), as a dictionary for mm_loader.create_gen(), with the
## import warnings in "warnings". Returns an empty dictionary on errors.
static func import_file(path : String, material_name : String = "") -> Dictionary:
	var importer : MMMaterialXImporter = MMMaterialXImporter.new()
	return importer.do_import(path, material_name)

func do_import(path : String, material_name : String) -> Dictionary:
	base_dir = path.get_base_dir()
	document = parse(path)
	if document == null:
		push_error("Cannot read MaterialX file %s" % path)
		return {}
	var material : Element = null
	for e in all_elements(document):
		if e.tag == "surfacematerial" and (material_name == "" or e.get_attribute("name") == material_name):
			material = e
			break
	if material == null:
		push_error("No material in %s" % path)
		return {}
	var shader_input : Element = material.get_input("surfaceshader")
	var shader : Element = resolve_connection(shader_input) if shader_input != null else null
	if shader == null:
		push_error("The material %s has no surface shader" % material.get_attribute("name"))
		return {}
	var shader_type : String = shader.tag
	var parameters : Dictionary = { size=11 }
	for channel in CHANNELS:
		var input_name : String = channel.names.get(shader_type, "")
		if input_name == "":
			continue
		var input : Element = shader.get_input(input_name)
		if input == null:
			continue
		import_channel(channel, input, parameters, shader_type)
	# Emission strength
	var emission_weight : Element = shader.get_input({ standard_surface="emission", open_pbr_surface="emission_luminance" }.get(shader_type, ""))
	if emission_weight != null and emission_weight.attributes.has("value") and not is_connected_input(emission_weight):
		var weight : float = float(emission_weight.get_attribute("value"))
		if shader_type == "open_pbr_surface":
			weight /= 1000.0
		parameters.emission_energy = parameters.get("emission_energy", 1.0)*weight
	# The material's size is the size of its largest texture (2048 if there is
	# no texture), so maps are not resampled
	var largest : int = 0
	for key in images.keys():
		var image : Image = Image.load_from_file(key.rsplit(":", true, 1)[0])
		if image != null:
			largest = max(largest, image.get_width(), image.get_height())
	if largest > 0:
		parameters.size = clampi(roundi(log(largest)/log(2.0)), 4, 14)
	nodes.push_front({ name="Material", type="material", node_position={ x=0, y=0 }, parameters=parameters })
	return { nodes=nodes, connections=connections, warnings=warnings, label=material.get_attribute("name") }

## Imports a shader input: a value (Material parameter) or a connection to
## images (Material input, and the parameter as a scale)
func import_channel(channel : Dictionary, input : Element, parameters : Dictionary, shader_type : String) -> void:
	if input.attributes.has("value") and not is_connected_input(input):
		set_channel_value(channel, parse_value(input.get_attribute("value")), parameters, false)
		return
	var source : Dictionary = evaluate(input)
	if source.is_empty():
		warnings.append("%s: unsupported nodes, the input is not imported" % channel.input)
		return
	if source.has("value"):
		set_channel_value(channel, source.value, parameters, false)
		return
	var from : Dictionary = output_of(source, channel)
	if from.is_empty():
		return
	if channel.input == "normal_tex":
		# Material Maker's normal convention, from OpenGL tangent space normal maps
		var convert_name : String = "normal_from_opengl"
		nodes.append({ name=convert_name, type="normal_map_convert", node_position={ x=-300, y=100 }, parameters={ op=0 } })
		connections.append({ from=from.node, from_port=from.port, to=convert_name, to_port=0 })
		from = { node=convert_name, port=0 }
		if source.has("scale"):
			parameters.normal = source.scale
	elif source.has("color_scale") and channel.get("color", false):
		set_channel_value(channel, source.color_scale, parameters, true)
	elif source.has("scale"):
		set_channel_value(channel, source.scale, parameters, true)
	connections.append({ from=from.node, from_port=from.port, to="Material", to_port=MATERIAL_INPUTS.find(channel.input) })

## Sets the parameter of a channel: its value when the input is not connected,
## or the scale of the connected input
func set_channel_value(channel : Dictionary, value, parameters : Dictionary, connected : bool) -> void:
	if channel.parameter == "":
		return
	if channel.get("color", false):
		var c : Array = value if value is Array else [ value, value, value ]
		parameters[channel.parameter] = { type="Color", r=c[0], g=c[1], b=c[2], a=1.0 }
	elif channel.input == "normal_tex":
		return
	else:
		var v : float = value[0] if value is Array else value
		if channel.input == "metallic_tex" and not connected:
			# The Material node's metallic input defaults to the metallic
			# parameter, so an unconnected metallic is the parameter squared
			v = sqrt(max(v, 0.0))
		parameters[channel.parameter] = v

## The node output that provides a source to a channel: an Image node, or a
## channel of it (decompose)
func output_of(source : Dictionary, channel : Dictionary) -> Dictionary:
	if not source.has("image"):
		return {}
	var image_node : String = get_image_node(source.image, source.get("linear", false))
	var single : bool = MATERIAL_INPUTS.find(channel.input) != -1 and channel.input not in [ "albedo_tex", "emission_tex", "normal_tex" ]
	if source.get("channel", -1) >= 0 and (single or source.channel == 3):
		return { node=get_decompose_node(image_node), port=source.channel }
	return { node=image_node, port=0 }

func get_image_node(path : String, linear : bool) -> String:
	var key : String = "%s:%s" % [ path, linear ]
	if not images.has(key):
		var node_name : String = "image_%d" % images.size()
		images[key] = node_name
		nodes.append({ name=node_name, type="image", node_position={ x=-600, y=-300+150*images.size() },
			parameters={ image=path, color_space=1 if linear else 0 } })
	return images[key]

func get_decompose_node(image_node : String) -> String:
	if not decomposers.has(image_node):
		var node_name : String = "%s_channels" % image_node
		decomposers[image_node] = node_name
		var position : Dictionary = { x=-350, y=-300+150*decomposers.size() }
		nodes.append({ name=node_name, type="decompose", node_position=position, parameters={} })
		connections.append({ from=image_node, from_port=0, to=node_name, to_port=0 })
	return decomposers[image_node]

## What an input or node output provides: { value }, or { image, channel,
## scale, linear }, or {} when unsupported
func evaluate(input : Element) -> Dictionary:
	if input.attributes.has("value") and not is_connected_input(input):
		return { value=parse_value(input.get_attribute("value")) }
	var node : Element = resolve_connection(input)
	if node == null:
		return {}
	var output_name : String = input.get_attribute("output")
	match node.tag:
		"image", "tiledimage", "UsdUVTexture", "gltf_image":
			var file_input : Element = node.get_input("file")
			if file_input == null:
				return {}
			var file : String = file_input.get_attribute("value")
			var prefix : String = get_file_prefix(file_input)
			var path : String = (prefix+file) if prefix != "" else file
			if path.is_relative_path():
				path = base_dir.path_join(path)
			var color_space : String = file_input.get_attribute("colorspace", get_color_space(file_input)).to_lower()
			var rv : Dictionary = { image=path.simplify_path(), channel=-1, linear=color_space in LINEAR_SPACES }
			match output_name:
				"r":
					rv.channel = 0
				"g":
					rv.channel = 1
				"b":
					rv.channel = 2
				"a":
					rv.channel = 3
			# Images can be scaled (UsdUVTexture) by a constant factor
			var scale_input : Element = node.get_input("scale")
			if scale_input != null and scale_input.attributes.has("value"):
				var s = parse_value(scale_input.get_attribute("value"))
				rv.scale = s[0] if s is Array else s
			return rv
		"constant":
			var value_input : Element = node.get_input("value")
			return evaluate(value_input) if value_input != null else {}
		"convert", "dot":
			var in_input : Element = node.get_input("in")
			return evaluate(in_input) if in_input != null else {}
		"extract":
			var source : Dictionary = evaluate(node.get_input("in"))
			var index_input : Element = node.get_input("index")
			if source.has("image"):
				source.channel = int(index_input.get_attribute("value", "0")) if index_input != null else 0
			elif source.has("value") and source.value is Array:
				source.value = source.value[int(index_input.get_attribute("value", "0")) if index_input != null else 0]
			return source
		"swizzle":
			var source : Dictionary = evaluate(node.get_input("in"))
			var channels : String = node.get_input("channels").get_attribute("value", "") if node.get_input("channels") != null else ""
			if source.has("image") and channels.length() == 1:
				source.channel = "rgba".find(channels)
				if source.channel == -1:
					source.channel = "xyzw".find(channels)
			return source
		"separate2", "separate3", "separate4":
			var source : Dictionary = evaluate(node.get_input("in"))
			if source.has("image"):
				source.channel = [ "outr", "outg", "outb", "outa" ].find(output_name)
				if source.channel == -1:
					source.channel = [ "outx", "outy", "outz", "outw" ].find(output_name)
			return source
		"multiply":
			var a : Dictionary = evaluate(node.get_input("in1")) if node.get_input("in1") != null else {}
			var b : Dictionary = evaluate(node.get_input("in2")) if node.get_input("in2") != null else {}
			for pair in [ [ a, b ], [ b, a ] ]:
				if pair[0].has("image") and pair[1].has("value"):
					var factor = pair[1].value
					var f : float = factor[0] if factor is Array else factor
					pair[0].scale = pair[0].get("scale", 1.0)*f
					if factor is Array and factor.size() >= 3:
						pair[0].color_scale = factor
					return pair[0]
			if a.has("value") and b.has("value") and not a.value is Array and not b.value is Array:
				return { value=a.value*b.value }
			return {}
		"normalmap":
			var source : Dictionary = evaluate(node.get_input("in"))
			var scale_input : Element = node.get_input("scale")
			if scale_input != null and scale_input.attributes.has("value") and source.has("image"):
				source.scale = float(scale_input.get_attribute("value"))
			return source
	warnings.append("unsupported MaterialX node %s (%s)" % [ node.get_attribute("name"), node.tag ])
	return {}

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
			return null
		return graph.find_child(output.get_attribute("nodename")) if output.attributes.has("nodename") else null
	if input.attributes.has("nodename"):
		var node_name : String = input.get_attribute("nodename")
		var node : Element = scope.find_child(node_name) if scope != null else null
		if node == null:
			node = document.find_child(node_name)
		return node
	if input.attributes.has("interfacename") and scope != null and scope.tag == "nodegraph":
		return resolve_connection(scope.get_input(input.get_attribute("interfacename")))
	return null

func is_connected_input(input : Element) -> bool:
	return input.attributes.has("nodename") or input.attributes.has("nodegraph") or input.attributes.has("interfacename")

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
