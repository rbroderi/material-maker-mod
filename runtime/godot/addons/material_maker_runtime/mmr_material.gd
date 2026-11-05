extends RefCounted
class_name MMRMaterial


# A StandardMaterial3D rendered from a runtime package, whose parameters can
# be changed at runtime:
#
#	var mmr : MMRMaterial = MMRMaterial.load_material("res://bricks.mmr")
#	$MeshInstance3D.material_override = mmr.material
#	mmr.set_parameter("Hue", 0.3)
#
# The textures can be rendered at another size than the exported one
# (load_material("res://bricks.mmr", 512), or set_output_size(512)), and
# materials with random nodes have a "seed" parameter.


var package : MMRPackage
var renderer : MMRRenderer
var material : StandardMaterial3D = StandardMaterial3D.new()
var textures : Dictionary = {}
var error_message : String = ""


static func load_material(path : String, size : int = 0) -> MMRMaterial:
	var mmr : MMRMaterial = MMRMaterial.new()
	mmr.package = MMRPackage.load_package(path)
	if not mmr.package.is_valid():
		mmr.error_message = mmr.package.error_message
		push_error("%s: %s" % [ path, mmr.error_message ])
		return mmr
	if size > 0:
		mmr.package.set_output_size(size)
	mmr.renderer = MMRRenderer.new(mmr.package)
	if not mmr.renderer.is_valid():
		mmr.error_message = mmr.renderer.error_message
		push_error("%s: %s" % [ path, mmr.error_message ])
		return mmr
	mmr.setup_material()
	mmr.update()
	return mmr

func is_valid() -> bool:
	return error_message == ""

## Material settings, as in Material Maker's Godot 4 Standard export
func setup_material() -> void:
	var values : Dictionary = package.manifest.material
	var outputs : Dictionary = package.manifest.outputs
	var c : Array = values.get("albedo_color", [ 1, 1, 1, 1 ])
	material.albedo_color = Color(c[0], c[1], c[2], c[3])
	material.metallic = values.get("metallic", 0.0 if not outputs.has("orm") else 1.0)
	material.roughness = values.get("roughness", 1.0)
	if outputs.has("orm"):
		material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
		material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		material.ao_enabled = true
		material.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		material.ao_light_affect = values.get("ao", 1.0)
	if outputs.has("normal"):
		material.normal_enabled = true
		material.normal_scale = values.get("normal", 1.0)
	if outputs.has("emission"):
		material.emission_enabled = true
		material.emission = Color(0, 0, 0)
		material.emission_energy_multiplier = values.get("emission_energy", 1.0)
	if outputs.has("height"):
		material.heightmap_enabled = true
		material.heightmap_scale = 25.0*values.get("depth_scale", 0.5)
		material.heightmap_deep_parallax = true
		material.heightmap_min_layers = 8
		material.heightmap_max_layers = 32

## Sets a runtime parameter (by name or label) and updates the textures
func set_parameter(parameter_name : String, value) -> bool:
	if not is_valid() or not renderer.set_parameter(parameter_name, value):
		return false
	update()
	return true

## Names of the presets of the package
func get_preset_names() -> PackedStringArray:
	return PackedStringArray(package.manifest.presets.keys())

## Applies a preset (saved parameter values) of the package
func apply_preset(preset_name : String) -> bool:
	if not package.manifest.presets.has(preset_name):
		push_error("Unknown preset %s" % preset_name)
		return false
	return set_parameters(package.manifest.presets[preset_name])

func set_parameters(values : Dictionary) -> bool:
	if not is_valid():
		return false
	for k in values.keys():
		if not renderer.set_parameter(k, values[k]):
			return false
	update()
	return true

## Renders the textures at another size (size x size pixels), keeping the
## current parameter values
func set_output_size(size : int) -> void:
	if not is_valid():
		return
	renderer.set_output_size(size)
	update()

## Renders the passes that changed and updates the material's textures
func update() -> void:
	if not renderer.render():
		return
	for output in package.manifest.outputs.keys():
		var image : Image = renderer.get_image(output)
		if output in [ "albedo", "emission" ]:
			# Color textures are sRGB (as in Material Maker's exports), the
			# material converts them to linear when they are 8 bit
			image.convert(Image.FORMAT_RGBA8)
		if textures.has(output):
			if textures[output].get_size() == Vector2(image.get_size()):
				textures[output].update(image)
			else:
				textures[output].set_image(image)
		else:
			textures[output] = ImageTexture.create_from_image(image)
			match output:
				"albedo":
					material.albedo_texture = textures[output]
					# Transparent if the material is and its opacity is used
					if package.manifest.material.get("flags_transparent", false) and image.detect_alpha() != Image.ALPHA_NONE:
						material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				"orm":
					material.metallic_texture = textures[output]
					material.roughness_texture = textures[output]
					material.ao_texture = textures[output]
				"normal":
					material.normal_texture = textures[output]
				"emission":
					material.emission_texture = textures[output]
				"height":
					material.heightmap_texture = textures[output]

func get_texture(output : String) -> Texture2D:
	return textures.get(output)
