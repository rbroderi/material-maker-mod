extends RefCounted
class_name MMRRenderer


# Renders the passes of a runtime package on a local rendering device, and
# re-renders the passes affected by parameter changes. Passes use the same
# bindings as Material Maker's compute shaders (set 0: output image, set 1:
# parameters, set 2: inputs, set 3: first row of the chunk), so they render
# the same textures.


## Unlocked seeds are offset by the golden ratio times the seed (modulo 1),
## as Material Maker's --seed does
const SEED_OFFSET : float = 0.6180339887

const FORMATS : Dictionary = {
	r16f={ data=RenderingDevice.DATA_FORMAT_R16_SFLOAT, image=Image.FORMAT_RH },
	rgba16f={ data=RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, image=Image.FORMAT_RGBAH },
	r32f={ data=RenderingDevice.DATA_FORMAT_R32_SFLOAT, image=Image.FORMAT_RF },
	rgba32f={ data=RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, image=Image.FORMAT_RGBAF },
	r8={ data=RenderingDevice.DATA_FORMAT_R8_UNORM, image=Image.FORMAT_R8 },
	rgba8={ data=RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, image=Image.FORMAT_RGBA8 },
}

## Maximum number of pixels rendered by a single dispatch
const MAX_PIXELS_PER_DISPATCH : int = 2048*2048

var package : MMRPackage
var rd : RenderingDevice
var sampler : RID
var shaders : Dictionary = {}
var output_textures : Dictionary = {}
var input_textures : Dictionary = {}
var parameter_data : Dictionary = {}
## Parameter buffers of the package, by pass name
var exported_parameter_data : Dictionary = {}
## GPU state of each pass: { pipeline, parameters (buffer), sets (0 to 2),
## chunks ({ buffer, set, y, rows }) }
var pass_states : Dictionary = {}
## Passes that must be rendered
var dirty : Dictionary = {}
var error_message : String = ""


func _init(new_package : MMRPackage) -> void:
	package = new_package
	rd = RenderingServer.create_local_rendering_device()
	if rd == null:
		error_message = "compute shaders are not available (a Forward+ or Mobile renderer is needed)"
		return
	var sampler_state : RDSamplerState = RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler = rd.sampler_create(sampler_state)
	for p in package.manifest.passes:
		if not FORMATS.has(p.format):
			error_message = "pass %s: unsupported format %s" % [ p.name, p.format ]
			return
		if not compile_pass(p):
			return
		exported_parameter_data[p.name] = Marshalls.base64_to_raw(p.parameter_data)
		parameter_data[p.name] = exported_parameter_data[p.name].duplicate()
	for file_name in package.images.keys():
		input_textures[file_name] = create_input_texture(package.images[file_name])
	create_pass_states()

func is_valid() -> bool:
	return error_message == ""

## The local rendering device is freed with the renderer (methods of the
## renderer cannot be called when it is deleted, static functions can)
func _notification(what : int) -> void:
	if what == NOTIFICATION_PREDELETE and rd != null:
		free_rids(rd, get_pass_rids(pass_states, output_textures)+shaders.values()+input_textures.values()+[ sampler ])
		rd.free()
		rd = null

## Frees the GPU resources and the local rendering device
func free_resources() -> void:
	if rd == null:
		return
	free_pass_states()
	free_rids(rd, shaders.values()+input_textures.values()+[ sampler ])
	shaders.clear()
	input_textures.clear()
	rd.free()
	rd = null

## Frees the textures of the passes and the GPU objects that use them
func free_pass_states() -> void:
	free_rids(rd, get_pass_rids(pass_states, output_textures))
	pass_states.clear()
	output_textures.clear()

## The GPU objects of the passes, uniform sets first (they must be freed
## before the buffers, pipelines and textures they use)
static func get_pass_rids(states : Dictionary, textures : Dictionary) -> Array:
	var sets : Array = []
	var others : Array = []
	for state in states.values():
		sets.append_array(state.sets)
		others.append_array([ state.pipeline, state.parameters ])
		for c in state.chunks:
			sets.append(c.set)
			others.append(c.buffer)
	return sets+others+textures.values()

static func free_rids(device : RenderingDevice, rids : Array) -> void:
	for rid in rids:
		if rid.is_valid():
			device.free_rid(rid)

func compile_pass(p : Dictionary) -> bool:
	var source : RDShaderSource = RDShaderSource.new()
	source.source_compute = package.shaders[p.name]
	var spirv : RDShaderSPIRV = rd.shader_compile_spirv_from_source(source)
	if spirv.compile_error_compute != "":
		error_message = "pass %s: %s" % [ p.name, spirv.compile_error_compute ]
		return false
	shaders[p.name] = rd.shader_create_from_spirv(spirv)
	return true

func create_input_texture(image : Image) -> RID:
	image = image.duplicate()
	image.convert(Image.FORMAT_RGBAF)
	var format : RDTextureFormat = RDTextureFormat.new()
	format.width = image.get_width()
	format.height = image.get_height()
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	return rd.texture_create(format, RDTextureView.new(), [ image.get_data() ])

## Creates the textures of the passes (at their current size) and the GPU
## state of each pass, and marks all passes to be rendered
func create_pass_states() -> void:
	for p in package.manifest.passes:
		var format : RDTextureFormat = RDTextureFormat.new()
		format.width = int(p.size[0])
		format.height = int(p.size[1])
		format.format = FORMATS[p.format].data
		format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		output_textures[p.name] = rd.texture_create(format, RDTextureView.new())
	for p in package.manifest.passes:
		pass_states[p.name] = create_pass_state(p)
		dirty[p.name] = true

## Applies the pass sizes of the package (after MMRPackage.set_output_size())
func update_sizes() -> void:
	if not is_valid():
		return
	free_pass_states()
	create_pass_states()

## Sets the size of the outputs (buffers keep their size), see
## MMRPackage.set_output_size()
func set_output_size(size : int) -> void:
	package.set_output_size(size)
	update_sizes()

## Sets a runtime parameter (by name or label) and marks the passes that
## depend on it. Colors can be Color or [ r, g, b, a ].
func set_parameter(parameter_name : String, value) -> bool:
	var parameter : Dictionary = package.get_parameter(parameter_name)
	if parameter.is_empty():
		push_error("Unknown parameter %s" % parameter_name)
		return false
	for target in parameter.targets:
		var p : Dictionary = package.get_pass(target["pass"])
		var layout = p.get("parameters", {}).get(target.parameter)
		if layout == null:
			continue
		if parameter.type == "seed":
			var sum : float = exported_parameter_data[p.name].decode_float(int(layout.offset))
			# Seed 0 is the package's seeds, others change them as
			# Material Maker's --seed does
			if int(value) != 0:
				sum = 0.0
				for term in target.terms:
					# Terms are [ seed, locked ]
					sum += float(term[0]) if term[1] else fmod(float(term[0])+SEED_OFFSET*int(value), 1.0)
			encode_value(parameter_data[p.name], int(layout.offset), layout.type, sum)
		else:
			encode_value(parameter_data[p.name], int(layout.offset), layout.type, value)
		mark_dirty(p.name)
	return true

func mark_dirty(pass_name : String) -> void:
	if dirty.has(pass_name):
		return
	dirty[pass_name] = true
	# Passes that use this one must be rendered again
	for p in package.manifest.passes:
		if p.inputs.any(func(i): return i.get("pass", "") == pass_name):
			mark_dirty(p.name)

static func encode_value(buffer : PackedByteArray, offset : int, type : String, value) -> void:
	if value is Color:
		value = [ value.r, value.g, value.b, value.a ]
	match type:
		"float":
			buffer.encode_float(offset, float(value))
		"int", "bool":
			buffer.encode_s32(offset, int(value))
		"vec2", "vec3", "vec4":
			for i in int(type.right(1)):
				buffer.encode_float(offset+4*i, float(value[i]))

## The pipeline, buffers and uniform sets of a pass
func create_pass_state(p : Dictionary) -> Dictionary:
	var shader : RID = shaders[p.name]
	var state : Dictionary = { pipeline=rd.compute_pipeline_create(shader), parameters=RID(), sets=[ RID(), RID(), RID() ], chunks=[] }
	var image_uniform : RDUniform = RDUniform.new()
	image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image_uniform.binding = 0
	image_uniform.add_id(output_textures[p.name])
	state.sets[0] = rd.uniform_set_create([ image_uniform ], shader, 0)
	if not p.parameters.is_empty():
		state.parameters = rd.storage_buffer_create(parameter_data[p.name].size(), parameter_data[p.name])
		state.sets[1] = create_buffer_set(shader, 1, state.parameters)
	if not p.inputs.is_empty():
		var sampler_uniforms : Array[RDUniform] = []
		for i in p.inputs.size():
			var input : Dictionary = p.inputs[i]
			var uniform : RDUniform = RDUniform.new()
			uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			uniform.binding = i
			uniform.add_id(sampler)
			uniform.add_id(output_textures[input["pass"]] if input.get("pass", "") != "" else input_textures[input.texture])
			sampler_uniforms.append(uniform)
		state.sets[2] = rd.uniform_set_create(sampler_uniforms, shader, 2)
	# Rows are rendered in chunks, the first row of each chunk is in set 3
	var width : int = int(p.size[0])
	var height : int = int(p.size[1])
	var chunk_height : int = clamp(MAX_PIXELS_PER_DISPATCH/width, 1, height)
	var y : int = 0
	while y < height:
		var chunk : PackedByteArray = PackedByteArray()
		chunk.resize(4)
		chunk.encode_s32(0, y)
		var buffer : RID = rd.storage_buffer_create(4, chunk)
		state.chunks.append({ buffer=buffer, set=create_buffer_set(shader, 3, buffer), y=y, rows=min(chunk_height, height-y) })
		y += chunk_height
	return state

## Renders all the passes that need it. Returns false on error.
func render() -> bool:
	if not is_valid():
		return false
	for p in package.manifest.passes:
		if not dirty.has(p.name):
			continue
		var state : Dictionary = pass_states[p.name]
		if state.parameters.is_valid():
			rd.buffer_update(state.parameters, 0, parameter_data[p.name].size(), parameter_data[p.name])
		var local_size : int = int(p.local_size)
		var groups_x : int = (int(p.size[0])+local_size-1)/local_size
		for chunk in state.chunks:
			var compute_list : int = rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(compute_list, state.pipeline)
			for set_index in 3:
				if state.sets[set_index].is_valid():
					rd.compute_list_bind_uniform_set(compute_list, state.sets[set_index], set_index)
			rd.compute_list_bind_uniform_set(compute_list, chunk.set, 3)
			rd.compute_list_dispatch(compute_list, groups_x, chunk.rows, 1)
			rd.compute_list_end()
	rd.submit()
	rd.sync()
	dirty.clear()
	return true

func create_buffer_set(shader : RID, set_index : int, buffer : RID) -> RID:
	var uniform : RDUniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = 0
	uniform.add_id(buffer)
	return rd.uniform_set_create([ uniform ], shader, set_index)

## Returns the content of a pass (or of an output, by channel name)
func get_image(name : String) -> Image:
	var pass_name : String = package.manifest.outputs.get(name, name)
	var p : Dictionary = package.get_pass(pass_name)
	if p.is_empty() or not output_textures.has(pass_name):
		return null
	var data : PackedByteArray = rd.texture_get_data(output_textures[pass_name], 0)
	return Image.create_from_data(int(p.size[0]), int(p.size[1]), false, FORMATS[p.format].image, data)
