extends RefCounted
class_name MMRPackage


# A Material Maker runtime package (.mmr): compute shader passes, embedded
# textures and runtime parameters (see design/runtime_packages.md in the
# Material Maker repository).


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
	var json : JSON = JSON.new()
	if json.parse(zip.read_file("manifest.json").get_string_from_utf8()) != OK or not json.data is Dictionary:
		return "invalid manifest"
	manifest = json.data
	if manifest.get("format") != "mmr":
		return "not a Material Maker runtime package"
	if int(manifest.get("version", 0)) > SUPPORTED_VERSION:
		return "unsupported package version %d" % int(manifest.version)
	for p in manifest.passes:
		shaders[p.name] = zip.read_file("shaders/%s.glsl" % p.name).get_string_from_utf8()
		for i in p.inputs:
			if i.has("texture") and not images.has(i.texture):
				var image : Image = Image.new()
				var data : PackedByteArray = zip.read_file(i.texture)
				var error : Error = image.load_exr_from_buffer(data) if i.texture.get_extension() == "exr" else image.load_png_from_buffer(data)
				if error != OK:
					return "cannot read '%s'" % i.texture
				images[i.texture] = image
	zip.close()
	return ""

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

## Names (and labels) of the parameters that can be changed at runtime
func get_parameter_names() -> PackedStringArray:
	var names : PackedStringArray = PackedStringArray()
	for p in manifest.parameters:
		names.append(p.name)
	return names
