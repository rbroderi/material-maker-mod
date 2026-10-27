extends RefCounted
class_name MMRRenderer


# Renders the passes of a runtime package on a local rendering device, and
# re-renders the passes affected by parameter changes.


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
		if not compile_pass(p):
			return
		dirty[p.name] = true
	for file_name in package.images.keys():
		input_textures[file_name] = create_input_texture(package.images[file_name])

func is_valid() -> bool:
	return error_message == ""

func free_resources() -> void:
	if rd == null:
		return
	for rid in shaders.values()+output_textures.values()+input_textures.values()+[ sampler ]:
		if rid.is_valid():
			rd.free_rid(rid)
	rd.free()
	rd = null

func compile_pass(p : Dictionary) -> bool:
	var source : RDShaderSource = RDShaderSource.new()
	source.source_compute = package.shaders[p.name]
	var spirv : RDShaderSPIRV = rd.shader_compile_spirv_from_source(source)
	if spirv.compile_error_compute != "":
		error_message = "pass %s: %s" % [ p.name, spirv.compile_error_compute ]
		return false
	shaders[p.name] = rd.shader_create_from_spirv(spirv)
	var format : RDTextureFormat = RDTextureFormat.new()
	format.width = int(p.size[0])
	format.height = int(p.size[1])
	format.format = FORMATS[p.format].data
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	output_textures[p.name] = rd.texture_create(format, RDTextureView.new())
	parameter_data[p.name] = Marshalls.base64_to_raw(p.parameter_data)
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

## Sets a runtime parameter (by name or label) and marks the passes that
## depend on it. Colors can be Color or [ r, g, b, a ].
func set_parameter(parameter_name : String, value) -> bool:
	var parameter : Dictionary = package.get_parameter(parameter_name)
	if parameter.is_empty():
		push_error("Unknown parameter %s" % parameter_name)
		return false
	for target in parameter.targets:
		var p : Dictionary = package.get_pass(target["pass"])
		var layout : Dictionary = p.parameters[target.parameter]
		if parameter.type == "seed":
			# As Material Maker's --seed: unlocked seeds are offset by the
			# golden ratio times the seed, modulo 1
			var sum : float = 0.0
			for term in target.terms:
				sum += float(term[0]) if term[1] else fmod(float(term[0])+0.6180339887*float(value), 1.0)
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
		if p.inputs.any(func(i): return i.get("pass") == pass_name):
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

## Renders all the passes that need it. Returns false on error.
func render() -> bool:
	if not is_valid():
		return false
	# Uniform sets are freed before the buffers and pipelines they use
	var created_sets : Array[RID] = []
	var created : Array[RID] = []
	for p in package.manifest.passes:
		if not dirty.has(p.name):
			continue
		var shader : RID = shaders[p.name]
		var pipeline : RID = rd.compute_pipeline_create(shader)
		created.append(pipeline)
		var image_uniform : RDUniform = RDUniform.new()
		image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		image_uniform.binding = 0
		image_uniform.add_id(output_textures[p.name])
		var set_0 : RID = rd.uniform_set_create([ image_uniform ], shader, 0)
		created_sets.append(set_0)
		var set_1 : RID = RID()
		if not p.parameters.is_empty():
			var buffer : RID = rd.storage_buffer_create(parameter_data[p.name].size(), parameter_data[p.name])
			created.append(buffer)
			set_1 = create_buffer_set(shader, 1, buffer)
			created_sets.append(set_1)
		var set_2 : RID = RID()
		if not p.inputs.is_empty():
			var sampler_uniforms : Array[RDUniform] = []
			for i in p.inputs.size():
				var input : Dictionary = p.inputs[i]
				var uniform : RDUniform = RDUniform.new()
				uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
				uniform.binding = i
				uniform.add_id(sampler)
				uniform.add_id(output_textures[input["pass"]] if input.has("pass") else input_textures[input.texture])
				sampler_uniforms.append(uniform)
			set_2 = rd.uniform_set_create(sampler_uniforms, shader, 2)
			created_sets.append(set_2)
		var width : int = int(p.size[0])
		var height : int = int(p.size[1])
		var local_size : int = int(p.local_size)
		var chunk_height : int = clamp(MAX_PIXELS_PER_DISPATCH/width, 1, height)
		var y : int = 0
		while y < height:
			var chunk : PackedByteArray = PackedByteArray()
			chunk.resize(4)
			chunk.encode_s32(0, y)
			var chunk_buffer : RID = rd.storage_buffer_create(4, chunk)
			var set_3 : RID = create_buffer_set(shader, 3, chunk_buffer)
			created.append(chunk_buffer)
			created_sets.append(set_3)
			var compute_list : int = rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
			rd.compute_list_bind_uniform_set(compute_list, set_0, 0)
			if set_1.is_valid():
				rd.compute_list_bind_uniform_set(compute_list, set_1, 1)
			if set_2.is_valid():
				rd.compute_list_bind_uniform_set(compute_list, set_2, 2)
			rd.compute_list_bind_uniform_set(compute_list, set_3, 3)
			rd.compute_list_dispatch(compute_list, (width+local_size-1)/local_size, min(chunk_height, height-y), 1)
			rd.compute_list_end()
			y += chunk_height
	rd.submit()
	rd.sync()
	for rid in created_sets+created:
		rd.free_rid(rid)
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
	if p.is_empty():
		return null
	var data : PackedByteArray = rd.texture_get_data(output_textures[pass_name], 0)
	return Image.create_from_data(int(p.size[0]), int(p.size[1]), false, FORMATS[p.format].image, data)
