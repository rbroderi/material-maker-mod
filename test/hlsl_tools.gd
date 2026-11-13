class_name MMTestHlsl
extends RefCounted

## Test toolbox for the HLSL that Material Maker exports: finds dxc, compiles
## HLSL, wraps a Unreal Custom node body, and runs DXC's SPIR-V in a compute
## shader on a local RenderingDevice. Not a test (no test_ prefix).

## How run_spirv_compute last obtained its shader: "direct" (Godot accepted the
## SPIR-V of DXC), "spirv-cross" (fallback through GLSL), or "" (none worked)
static var last_spirv_path : String = ""
## Text explaining the last failure of run_spirv_compute
static var last_error : String = ""

## Returns the path of a tool of the Vulkan SDK (VULKAN_SDK/Bin, then PATH), or ""
static func find_tool(tool_name : String) -> String:
	var sdk : String = OS.get_environment("VULKAN_SDK")
	if sdk != "":
		for ext in [ ".exe", "" ]:
			var candidate : String = sdk.path_join("Bin").path_join(tool_name+ext)
			if FileAccess.file_exists(candidate):
				return candidate
	var output : Array = []
	var finder : String = "where" if OS.get_name() == "Windows" else "which"
	if OS.execute(finder, [ tool_name ], output, true) == 0 and not output.is_empty():
		var lines : PackedStringArray = str(output[0]).strip_edges().split("\n", false)
		if not lines.is_empty():
			return lines[0].strip_edges()
	return ""

## Runs dxc -T <profile> -E <entry> -HV <hv> <extra...> <source_path>
## Returns { ok : bool, output : String }
static func compile_hlsl(source_path : String, profile : String = "ps_6_0", entry : String = "main", hv : String = "2021", extra : Array = []) -> Dictionary:
	var dxc : String = find_tool("dxc")
	if dxc == "":
		return { ok=false, output="dxc not found" }
	var args : Array = [ "-T", profile, "-E", entry, "-HV", hv ]
	args.append_array(extra)
	args.append(ProjectSettings.globalize_path(source_path))
	var output : Array = []
	var code : int = OS.execute(dxc, args, output, true)
	return { ok=(code == 0), output="\n".join(PackedStringArray(output)) }

## Compiles an HLSL compute shader (cs_6_0) to Vulkan SPIR-V.
## Returns { ok : bool, output : String }
static func compile_to_spirv(source_path : String, out_path : String, entry : String = "main") -> Dictionary:
	return compile_hlsl(source_path, "cs_6_0", entry, "2021", [
		"-spirv", "-fspv-target-env=vulkan1.1", "-fvk-use-dx-layout",
		"-Fo", ProjectSettings.globalize_path(out_path) ])

## Emulates the Custom node of Unreal Engine: the body of the node is the text
## of the .shader file, in a function with typed parameters. inputs is an array
## of { name, type } (a Texture2D input also gets its <name>Sampler), outputs an
## array of { name, type } (out parameters). The function returns float4. A
## pixel shader main calls it with zero (or 0.5 for float inputs) arguments.
static func wrap_custom_node(shader_text : String, inputs : Array, outputs : Array) -> String:
	var params : PackedStringArray = PackedStringArray()
	var globals : String = ""
	var args : PackedStringArray = PackedStringArray()
	var locals : String = ""
	for i in inputs:
		if i.type == "Texture2D":
			params.append("Texture2D %s" % i.name)
			params.append("SamplerState %sSampler" % i.name)
			globals += "Texture2D g_%s;\nSamplerState g_%sSampler;\n" % [ i.name, i.name ]
			args.append("g_%s" % i.name)
			args.append("g_%sSampler" % i.name)
		else:
			params.append("%s %s" % [ i.type, i.name ])
			args.append("(%s)0.5" % i.type)
	for o in outputs:
		params.append("out %s %s" % [ o.type, o.name ])
		locals += "\t%s o_%s;\n" % [ o.type, o.name ]
		args.append("o_%s" % o.name)
	var code : String = globals
	code += "float4 custom_node_body(%s) {\n" % ", ".join(params)
	code += shader_text
	code += "\n}\n\n"
	code += "float4 main(float4 sv_position : SV_Position) : SV_Target {\n"
	code += locals
	code += "\treturn custom_node_body(%s);\n}\n" % ", ".join(args)
	return code

## Runs a compute shader given as DXC SPIR-V (entry point main). One thread per
## output float unless thread_count is given. Bindings (set 0): 0 = input
## storage buffer (float), 1 = output storage buffer (float), 2 = uniform buffer
## (only bound when uniform_floats is not empty). Workgroup size must be 64.
## Returns the output floats, or an empty array when no local rendering device
## or no usable shader (see last_error and last_spirv_path).
static func run_spirv_compute(spv_path : String, input_floats : PackedFloat32Array, uniform_floats : PackedFloat32Array, output_float_count : int, thread_count : int = -1) -> PackedFloat32Array:
	last_spirv_path = ""
	last_error = ""
	var empty : PackedFloat32Array = PackedFloat32Array()
	var rd : RenderingDevice = RenderingServer.create_local_rendering_device()
	if rd == null:
		last_error = "no local rendering device"
		return empty
	var bytecode : PackedByteArray = FileAccess.get_file_as_bytes(spv_path)
	if bytecode.is_empty():
		last_error = "cannot read "+spv_path
		rd.free()
		return empty
	var spirv : RDShaderSPIRV = RDShaderSPIRV.new()
	spirv.bytecode_compute = bytecode
	var shader : RID = rd.shader_create_from_spirv(spirv, "mmtest_dxc")
	if shader.is_valid():
		last_spirv_path = "direct"
	else:
		shader = _shader_through_spirv_cross(rd, spv_path)
		if shader.is_valid():
			last_spirv_path = "spirv-cross"
	if not shader.is_valid():
		rd.free()
		return empty
	var in_bytes : PackedByteArray = input_floats.to_byte_array()
	if in_bytes.size() < 16:
		in_bytes.resize(16)
	var out_bytes : PackedByteArray = PackedByteArray()
	out_bytes.resize(maxi(output_float_count*4, 16))
	var rids : Array[RID] = []
	var in_buffer : RID = rd.storage_buffer_create(in_bytes.size(), in_bytes)
	var out_buffer : RID = rd.storage_buffer_create(out_bytes.size(), out_bytes)
	rids.append_array([ in_buffer, out_buffer ])
	var uniforms : Array[RDUniform] = []
	for u in [ [ 0, in_buffer ], [ 1, out_buffer ] ]:
		var uniform : RDUniform = RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = u[0]
		uniform.add_id(u[1])
		uniforms.append(uniform)
	if not uniform_floats.is_empty():
		var u_bytes : PackedByteArray = uniform_floats.to_byte_array()
		if u_bytes.size() % 16 != 0:
			u_bytes.resize((u_bytes.size()/16+1)*16)
		var u_buffer : RID = rd.uniform_buffer_create(u_bytes.size(), u_bytes)
		rids.append(u_buffer)
		var uniform : RDUniform = RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
		uniform.binding = 2
		uniform.add_id(u_buffer)
		uniforms.append(uniform)
	var uniform_set : RID = rd.uniform_set_create(uniforms, shader, 0)
	var result : PackedFloat32Array = empty
	if uniform_set.is_valid():
		rids.append(uniform_set)
		var pipeline : RID = rd.compute_pipeline_create(shader)
		if pipeline.is_valid():
			rids.append(pipeline)
			var threads : int = thread_count if thread_count >= 0 else output_float_count
			var list : int = rd.compute_list_begin()
			rd.compute_list_bind_compute_pipeline(list, pipeline)
			rd.compute_list_bind_uniform_set(list, uniform_set, 0)
			rd.compute_list_dispatch(list, maxi((threads+63)/64, 1), 1, 1)
			rd.compute_list_end()
			rd.submit()
			rd.sync()
			result = rd.buffer_get_data(out_buffer).to_float32_array().slice(0, output_float_count)
		else:
			last_error = "cannot create the compute pipeline"
	else:
		last_error = "cannot create the uniform set"
	# Freed in reverse order of creation (the set and pipeline depend on the rest)
	rids.reverse()
	for r in rids:
		rd.free_rid(r)
	rd.free_rid(shader)
	rd.free()
	return result

## Converts the SPIR-V to GLSL with spirv-cross and compiles that for Godot
static func _shader_through_spirv_cross(rd : RenderingDevice, spv_path : String) -> RID:
	var cross : String = find_tool("spirv-cross")
	if cross == "":
		last_error = "Godot rejected the SPIR-V and spirv-cross was not found"
		return RID()
	var output : Array = []
	var code : int = OS.execute(cross, [ "--version", "450", "--vulkan-semantics", ProjectSettings.globalize_path(spv_path) ], output, false)
	if code != 0:
		last_error = "spirv-cross failed: "+"\n".join(PackedStringArray(output))
		return RID()
	var source : RDShaderSource = RDShaderSource.new()
	source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	source.source_compute = "\n".join(PackedStringArray(output))
	var spirv : RDShaderSPIRV = rd.shader_compile_spirv_from_source(source)
	if spirv.compile_error_compute != "":
		last_error = "GLSL from spirv-cross does not compile: "+spirv.compile_error_compute
		return RID()
	return rd.shader_create_from_spirv(spirv, "mmtest_dxc_cross")
