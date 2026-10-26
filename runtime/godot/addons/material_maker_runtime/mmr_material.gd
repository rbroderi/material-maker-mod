extends RefCounted
class_name MMRMaterial


# A StandardMaterial3D rendered from a runtime package, whose parameters can
# be changed at runtime:
#
#	var mmr : MMRMaterial = MMRMaterial.load_material("res://bricks.mmr")
#	$MeshInstance3D.material_override = mmr.material
#	mmr.set_parameter("Hue", 0.3)


var package : MMRPackage
var renderer : MMRRenderer
var material : StandardMaterial3D = StandardMaterial3D.new()
var textures : Dictionary = {}
var error_message : String = ""


static func load_material(path : String) -> MMRMaterial:
	var mmr : MMRMaterial = MMRMaterial.new()
	mmr.package = MMRPackage.load_package(path)
	if not mmr.package.is_valid():
		mmr.error_message = mmr.package.error_message
		push_error("%s: %s" % [ path, mmr.error_message ])
		return mmr
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
	if values.get("flags_transparent", false):
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	if outputs.has("orm"):
		material.metallic = values.get("metallic", 1.0)
		material.roughness = values.get("roughness", 1.0)
		material.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
		material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		material.ao_enabled = true
		material.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		material.ao_light_affect = values.get("ao", 1.0)
	else:
		material.metallic = 0.0
		material.roughness = values.get("roughness", 1.0)
	if outputs.has("normal"):
		material.normal_enabled = true
		material.normal_scale = values.get("normal", 1.0)
	if outputs.has("emission"):
		material.emission_enabled = true
		material.emission_energy_multiplier = values.get("emission_energy", 1.0)
	if outputs.has("height"):
		material.heightmap_enabled = true
		material.heightmap_scale = 25.0*values.get("depth_scale", 0.5)
		material.heightmap_deep_parallax = true

## Sets a runtime parameter (by name or label) and updates the textures
func set_parameter(parameter_name : String, value) -> bool:
	if not is_valid() or not renderer.set_parameter(parameter_name, value):
		return false
	update()
	return true

func set_parameters(values : Dictionary) -> bool:
	if not is_valid():
		return false
	for k in values.keys():
		if not renderer.set_parameter(k, values[k]):
			return false
	update()
	return true

## Renders the passes that changed and updates the material's textures
func update() -> void:
	if not renderer.render():
		return
	for output in package.manifest.outputs.keys():
		var image : Image = renderer.get_image(output)
		if textures.has(output):
			textures[output].update(image)
		else:
			textures[output] = ImageTexture.create_from_image(image)
			match output:
				"albedo":
					material.albedo_texture = textures[output]
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
