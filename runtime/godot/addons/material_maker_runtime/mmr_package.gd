extends RefCounted
class_name MMRPackage


# A Material Maker runtime package (.mmr): compute shader passes, embedded
# textures and runtime parameters, as written by Material Maker's runtime
# export plugin (File > Export runtime package, or --export-mmr).


const SUPPORTED_VERSION : int = 1

var manifest : Dictionary = {}
## Shader sources, by pass name
var shaders : Dictionary = {}
## Embedded images, by file name
var images : Dictionary = {}
var error_message : String = ""


static func load_package(path : String) -> MMRPackage:
	var package : MMRPackage = MMRPackage.new()
	package.error_message = package.read(path)
	return package

func is_valid() -> bool:
	return error_message == ""

func read(path : String) -> String:
	var zip : ZIPReader = ZIPReader.new()
	if zip.open(path) != OK:
		return "cannot open '%s'" % path
	var message : String = read_zip(zip)
	zip.close()
	return message

func read_zip(zip : ZIPReader) -> String:
	if not zip.file_exists("manifest.json"):
		return "not a Material Maker runtime package"
	var json : JSON = JSON.new()
	if json.parse(zip.read_file("manifest.json").get_string_from_utf8()) != OK or not json.data is Dictionary:
		return "invalid manifest"
	manifest = json.data
	if manifest.get("format") != "mmr":
		return "not a Material Maker runtime package"
	if int(manifest.get("version", 0)) > SUPPORTED_VERSION:
		return "unsupported package version %d" % int(manifest.version)
	if not manifest.get("passes") is Array or not manifest.get("outputs") is Dictionary:
		return "invalid manifest"
	for key in [ "parameters", "baked_parameters" ]:
		if not manifest.get(key) is Array:
			manifest[key] = []
	for key in [ "material", "presets" ]:
		if not manifest.get(key) is Dictionary:
			manifest[key] = {}
	for p in manifest.passes:
		var shader_file : String = "shaders/%s.glsl" % p.name
		if not zip.file_exists(shader_file):
			return "missing '%s'" % shader_file
		shaders[p.name] = zip.read_file(shader_file).get_string_from_utf8()
		for i in p.inputs:
			if i.has("texture") and not images.has(i.texture):
				if not zip.file_exists(i.texture):
					return "missing '%s'" % i.texture
				var image : Image = Image.new()
				var data : PackedByteArray = zip.read_file(i.texture)
				var error : Error = image.load_exr_from_buffer(data) if i.texture.get_extension() == "exr" else image.load_png_from_buffer(data)
				if error != OK:
					return "cannot read '%s'" % i.texture
				images[i.texture] = image
	return ""

## Size of the outputs (the largest output pass)
func get_output_size() -> int:
	var size : int = 0
	for o in manifest.outputs.values():
		var p : Dictionary = get_pass(o)
		if not p.is_empty():
			size = max(size, int(p.size[0]), int(p.size[1]))
	return size

## Sets the size of the output passes (size x size pixels, or the largest
## side for non-square outputs), as Material Maker's export size does.
## Buffers keep their own size (it is a parameter of their Buffer node, and
## the shaders that read them depend on it). Changes are applied when a
## renderer is created, or with MMRRenderer.update_sizes().
func set_output_size(size : int) -> void:
	if size <= 0:
		return
	for o in manifest.outputs.values():
		var p : Dictionary = get_pass(o)
		if not p.is_empty():
			var largest : float = max(int(p.size[0]), int(p.size[1]))
			p.size = [ max(1, roundi(int(p.size[0])*size/largest)), max(1, roundi(int(p.size[1])*size/largest)) ]

func get_pass(pass_name : String) -> Dictionary:
	for p in manifest.passes:
		if p.name == pass_name:
			return p
	return {}

func get_parameter(parameter_name : String) -> Dictionary:
	for p in manifest.parameters:
		if p.name == parameter_name or p.get("label", "") == parameter_name:
			return p
	return {}

## Names of the parameters that can be changed at runtime (parameters can
## also be set by label)
func get_parameter_names() -> PackedStringArray:
	var names : PackedStringArray = PackedStringArray()
	for p in manifest.parameters:
		names.append(p.name)
	return names
