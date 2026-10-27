extends RefCounted


# Exports a material graph as a runtime package (.mmr): the compute shader
# passes needed to render the material's outputs, with the parameters that
# can be changed at runtime. See design/runtime_packages.md.


const FORMAT_VERSION : int = 1

## Material outputs that are exported (when one of their inputs is connected)
const CHANNELS : Array[Dictionary] = [
	{ name="albedo", output=MMGenMaterial.OUTPUT_ALBEDO, inputs=[ "albedo_tex", "opacity_tex" ] },
	{ name="orm", output=MMGenMaterial.OUTPUT_ORM, inputs=[ "ao_tex", "roughness_tex", "metallic_tex" ] },
	{ name="emission", output=MMGenMaterial.OUTPUT_EMISSION, inputs=[ "emission_tex" ] },
	{ name="normal", output=MMGenMaterial.OUTPUT_NORMAL, inputs=[ "normal_tex" ] },
	{ name="height", output=MMGenMaterial.OUTPUT_HEIGHT, inputs=[ "depth_tex" ] },
]

## Material parameters stored in the manifest, for engines to build materials
const MATERIAL_PARAMETERS : Array[String] = [ "albedo_color", "metallic", "roughness", "emission_energy", "normal", "ao", "depth_scale", "flags_transparent" ]

var passes : Array[Dictionary] = []
var shaders : Dictionary = {}
var spirv : Dictionary = {}
var textures : Dictionary = {}
var pass_by_texture : Dictionary = {}
var file_by_texture : Dictionary = {}
var buffer_by_texture : Dictionary = {}
var errors : PackedStringArray = PackedStringArray()


## Exports a runtime package, whose outputs are size x size pixels (or size x
## height when height is not 0), returns the errors
func do_export(graph : MMGenGraph, path : String, size : int = 0, height : int = 0) -> PackedStringArray:
	var material : MMGenBase = MMCliTools.find_material_node(graph)
	if material == null:
		errors.append("the graph has no material node")
		return errors
	if size <= 0:
		size = material.get_image_size()
		if height <= 0:
			height = material.get_image_height()
	collect_buffers(graph)
	var input_indexes : Dictionary = {}
	var input_defs : Array = material.get_input_defs()
	for i in input_defs.size():
		input_indexes[input_defs[i].name] = i
	var outputs : Dictionary = {}
	for channel in CHANNELS:
		if not channel.inputs.any(func(n): return input_indexes.has(n) and material.get_source(input_indexes[n]) != null):
			continue
		var compute_shader : MMComputeShader = await material.create_output_compute_shader(channel.output)
		if compute_shader == null:
			errors.append("cannot compile the %s output" % channel.name)
			continue
		outputs[channel.name] = await add_pass(compute_shader, Vector2i(size, height if height > 0 else size))
	var material_parameters : Dictionary = {}
	for p in MATERIAL_PARAMETERS:
		material_parameters[p] = to_json_value(material.get_parameter(p))
	var parameter_info : Dictionary = get_runtime_parameters(graph)
	var manifest : Dictionary = {
		format="mmr",
		version=FORMAT_VERSION,
		generator="Material Maker %s" % ProjectSettings.get_setting("application/config/actual_release", ""),
		name=path.get_file().get_basename(),
		passes=passes,
		outputs=outputs,
		material=material_parameters,
		parameters=parameter_info.parameters,
		presets=get_presets(graph, parameter_info.parameters),
		baked_parameters=parameter_info.baked
	}
	var zip : ZIPPacker = ZIPPacker.new()
	if zip.open(path) != OK:
		errors.append("cannot write '%s'" % path)
		return errors
	write_zip_file(zip, "manifest.json", JSON.stringify(manifest, "\t").to_utf8_buffer())
	for s in shaders.keys():
		write_zip_file(zip, "shaders/%s.glsl" % s, shaders[s].to_utf8_buffer())
	# SPIR-V, for runtimes that don't have a GLSL compiler
	for s in spirv.keys():
		write_zip_file(zip, "shaders/%s.spv" % s, spirv[s])
	for t in textures.keys():
		write_zip_file(zip, t, textures[t])
	zip.close()
	return errors

static func write_zip_file(zip : ZIPPacker, file_name : String, data : PackedByteArray) -> void:
	zip.start_file(file_name)
	zip.write_file(data)
	zip.close_file()

## Finds buffers in the graph, its subgraphs, and the automatic buffers of
## shader nodes (that are their children)
func collect_buffers(generator : Node) -> void:
	for b in MMCliTools.collect_generators(generator, func(g): return g is MMGenBuffer):
		buffer_by_texture[b.texture] = b

## Adds a pass (after the passes it depends on) and returns its name
func add_pass(compute_shader : MMComputeShader, size : Vector2i) -> String:
	var inputs : Array = []
	for t in compute_shader.input_textures:
		var input : Dictionary = { name=t.name }
		if buffer_by_texture.has(t.texture):
			input["pass"] = await add_buffer_pass(buffer_by_texture[t.texture])
		else:
			input.texture = await embed_texture(t.texture, t.name)
		inputs.append(input)
	var parameters : Dictionary = {}
	for p in compute_shader.parameters.keys():
		var parameter : MMPipeline.Parameter = compute_shader.parameters[p]
		parameters[p] = { type=parameter.type, offset=parameter.offset, array_size=parameter.array_size }
	var pass_name : String = "p%d" % passes.size()
	shaders[pass_name] = compute_shader.compiled_sources.compute
	if compute_shader.compiled_spirv.has("compute"):
		spirv[pass_name] = compute_shader.compiled_spirv.compute
	passes.append({
		name=pass_name,
		size=[ size.x, size.y ],
		format=MMPipeline.TEXTURE_TYPE[compute_shader.output_textures[0].type].decl,
		local_size=compute_shader.local_size,
		parameters=parameters,
		parameter_data=Marshalls.raw_to_base64(get_parameter_data(compute_shader)),
		inputs=inputs
	})
	return pass_name

## The parameter buffer of a pass, with the time ($time) set to 0
static func get_parameter_data(compute_shader : MMComputeShader) -> PackedByteArray:
	var data : PackedByteArray = compute_shader.parameter_values.duplicate()
	if compute_shader.parameters.has("elapsed_time"):
		data.encode_float(compute_shader.parameters.elapsed_time.offset, 0.0)
	return data

func add_buffer_pass(buffer : MMGenBuffer) -> String:
	if not pass_by_texture.has(buffer.texture):
		var compute_shader : MMComputeShader = buffer.shader_compute.compute_shader
		if not compute_shader.compiled_sources.has("compute"):
			# Not compiled (yet): use its current content
			return ""
		pass_by_texture[buffer.texture] = await add_pass(compute_shader, buffer.get_buffer_dimensions())
	return pass_by_texture[buffer.texture]

## Saves a texture that is not rendered by an exported pass (EXR for float
## formats, PNG otherwise)
func embed_texture(texture : MMTexture, uniform_name : String) -> String:
	if file_by_texture.has(texture):
		return file_by_texture[texture]
	var image : Image = null
	if texture != null:
		var t : Texture2D = await texture.get_texture()
		if t != null:
			image = t.get_image()
	if image == null:
		image = Image.create(1, 1, false, Image.FORMAT_RGBAH)
		push_warning("Texture %s is empty" % uniform_name)
	var file_name : String
	if image.get_format() in [ Image.FORMAT_RH, Image.FORMAT_RGBAH, Image.FORMAT_RF, Image.FORMAT_RGBAF, Image.FORMAT_RGH, Image.FORMAT_RGF, Image.FORMAT_RGBH, Image.FORMAT_RGBF ]:
		file_name = "textures/t%d.exr" % textures.size()
		textures[file_name] = image.save_exr_to_buffer(image.get_format() in [ Image.FORMAT_RH, Image.FORMAT_RF ])
	else:
		file_name = "textures/t%d.png" % textures.size()
		textures[file_name] = image.save_png_to_buffer()
	file_by_texture[texture] = file_name
	return file_name

## Remote parameters that only drive shader uniforms can be changed at runtime
func get_runtime_parameters(graph : MMGenGraph) -> Dictionary:
	var parameters : Array = []
	var baked : Array = []
	for remote in graph.get_children():
		if not remote is MMGenRemote:
			continue
		var defs : Dictionary = {}
		for d in remote.get_parameter_defs():
			defs[d.name] = d
		for w in remote.widgets:
			var label : String = w.get("label", "")
			var description : String = "%s (%s)" % [ w.name, label ] if label != "" else w.name
			if w.type != "linked_control" or not defs.has(w.name):
				baked.append("%s: not a linked control" % description)
				continue
			var def : Dictionary = defs[w.name]
			if not def.type in [ "float", "color" ]:
				baked.append("%s: %s parameters change the shader" % [ description, def.type ])
				continue
			var targets : Array = []
			var missing : PackedStringArray = PackedStringArray()
			for lw in w.linked_widgets:
				var node : MMGenBase = graph.get_node_or_null(NodePath(lw.node)) as MMGenBase
				if node == null:
					continue
				for target in resolve_parameter(node, lw.widget):
					var uniform_name : String = "p_o%d_%s" % [ target[0].get_instance_id(), target[1] ]
					var uniform_targets : Array = targets_for(uniform_name)
					targets.append_array(uniform_targets)
					if uniform_targets.is_empty():
						missing.append("%s:%s" % [ target[0].name, target[1] ])
			if not missing.is_empty() or targets.is_empty():
				baked.append("%s: %s not a shader uniform" % [ description, ", ".join(missing) if not missing.is_empty() else "no target is" ])
				continue
			var parameter : Dictionary = {
				name=w.name, label=label, type=def.type,
				default=to_json_value(remote.get_parameter(w.name)),
				targets=targets
			}
			for k in [ "min", "max", "step" ]:
				if def.has(k):
					parameter[k] = def[k]
			parameters.append(parameter)
	# Animated materials ($time) have a time parameter, in seconds
	var time_targets : Array = []
	for p in passes:
		# The uniform is always declared, it is only used if it appears again
		if p.parameters.has("elapsed_time") and shaders[p.name].count("elapsed_time") > 1:
			time_targets.append({ "pass": p.name, "parameter": "elapsed_time" })
	if not time_targets.is_empty():
		parameters.append({ name="time", label="Time", type="float", default=0.0, min=0.0, max=60.0, step=0.01, targets=time_targets })
	# Materials with random nodes have a seed parameter, that changes their
	# seeds as --seed does (see MMCliTools.reseed)
	var seed_targets : Array = []
	add_seed_targets(graph, graph, seed_targets)
	if not seed_targets.is_empty():
		parameters.append({ name="seed", label="Seed", type="seed", default=0, min=0, max=1000, step=1, targets=seed_targets })
	return { parameters=parameters, baked=baked }

## Seed uniforms of a generator and its children: each is the sum of the
## seed of its node and of the parents it inherits seeds from (terms are
## [ seed, locked ], locked seeds and the seed of the top graph do not change)
func add_seed_targets(generator : Node, top : Node, targets : Array) -> void:
	for c in generator.get_children():
		if not c is MMGenBase:
			continue
		var uniform_name : String = "seed_o%d" % c.get_instance_id()
		var terms : Array = []
		var node : Node = c
		while node is MMGenBase:
			terms.append([ node.seed_value, node == top or not node.has_randomness() or node.is_seed_locked() ])
			if node.is_seed_locked() or node.get_parent().get("transmits_seed") == null or not node.get_parent().transmits_seed:
				break
			node = node.get_parent()
		targets.append_array(targets_for(uniform_name, { terms=terms }))
		add_seed_targets(c, top, targets)

## Parameter targets of a uniform: the passes that declare it
func targets_for(uniform_name : String, extra : Dictionary = {}) -> Array:
	var targets : Array = []
	for p in passes:
		if p.parameters.has(uniform_name):
			targets.append({ "pass": p.name, "parameter": uniform_name }.merged(extra))
	return targets

## Presets of the remote nodes, restricted to the runtime parameters
func get_presets(graph : MMGenGraph, parameters : Array) -> Dictionary:
	var names : Array = parameters.map(func(p): return p.name)
	var presets : Dictionary = {}
	for remote in graph.get_children():
		if not remote is MMGenRemote:
			continue
		for preset_name in remote.presets.keys():
			var values : Dictionary = presets.get(preset_name, {})
			for k in remote.presets[preset_name].keys():
				if k in names:
					values[k] = to_json_value(MMType.deserialize_value(remote.presets[preset_name][k]))
			if not values.is_empty():
				presets[preset_name] = values
	return presets

## Returns the [ generator, parameter ] pairs that a parameter drives,
## following the parameters of subgraphs to the nodes they are linked to
static func resolve_parameter(generator : MMGenBase, parameter : String) -> Array:
	if generator is MMGenGraph:
		var rv : Array = []
		for c in generator.get_children():
			if c is MMGenRemote:
				for w in c.widgets:
					if w.name == parameter and w.type == "linked_control":
						for lw in w.linked_widgets:
							var node : MMGenBase = generator.get_node_or_null(NodePath(lw.node)) as MMGenBase
							if node != null:
								rv.append_array(resolve_parameter(node, lw.widget))
		return rv
	return [ [ generator, parameter ] ]

static func to_json_value(value):
	if value is Color:
		return [ value.r, value.g, value.b, value.a ]
	if value is Object:
		return MMType.serialize_value(value)
	return value
