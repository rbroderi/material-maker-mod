extends GutTest

## Tests for the GLSL to HLSL translation (MMGenMaterial.process_option_hlsl_base
## and hlsl_defs.tmpl) and for the HLSL test toolbox (MMTestHlsl).

const UE5_TARGET : String = "res://material_maker/plugins/export_targets/export_targets/material_export_Unreal_Unreal Engine 5 Shader.mme"
const NODES_PATH : String = "res://addons/material_maker/nodes/"

var material : MMGenMaterial

func before_each() -> void:
	material = MMGenMaterial.new()

func after_each() -> void:
	material.free()

## Copy of process_option_hlsl_base as it was before the 3D fixes (replacement
## list only, no declarations)
static func old_hlsl_base(s : String) -> String:
	s = s.replace("ivec2(", "toint2(")
	s = s.replace("ivec3(", "toint3(")
	s = s.replace("ivec4(", "toint4(")
	s = s.replace("vec2(", "tofloat2(")
	s = s.replace("vec3(", "tofloat3(")
	s = s.replace("vec4(", "tofloat4(")
	s = s.replace("ivec2", "int2")
	s = s.replace("ivec3", "int3")
	s = s.replace("ivec4", "int4")
	s = s.replace("vec2", "float2")
	s = s.replace("vec3", "float3")
	s = s.replace("vec4", "float4")
	s = s.replace("mat2(", "tofloat2x2(")
	s = s.replace("mat2", "float2x2")
	s = s.replace("mix", "lerp")
	s = s.replace("fract", "frac")
	s = s.replace("atan", "hlsl_atan")
	var re : RegEx = RegEx.new()
	re.compile("(\\w+)\\s*\\*=\\s*tofloat2x2([^;]+);")
	while true:
		var m : RegExMatch = re.search(s)
		if m == null:
			break
		s = s.replace(m.strings[0], "%s = mul(%s, tofloat2x2%s);" % [ m.strings[1], m.strings[1], m.strings[2] ])
	re.compile("(?:int|float)[234]?\\[\\d*\\]\\((.*)\\);")
	while true:
		var m : RegExMatch = re.search(s)
		if m == null:
			break
		s = s.replace(m.strings[0], "{ %s };" % [ m.strings[1] ])
	return s

func test_new_constructs() -> void:
	var t : String = material.process_option_hlsl_base("uvec3 a = uvec3(1u); mat3 m = mat3(a, b, c); float t = atan(x); float u = atan(y, x);")
	assert_string_contains(t, "uint3 a = touint3(")
	assert_string_contains(t, "float3x3 m = tofloat3x3(")
	assert_string_contains(t, "hlsl_atan(x)")
	assert_string_contains(t, "hlsl_atan(y, x)")
	assert_false(t.contains("utofloat3"))
	var t4 : String = material.process_option_hlsl_base("uvec2 a; uvec4 b = uvec4(1u); mat4 m = mat4(1.0); float r = inversesqrt(x);")
	assert_string_contains(t4, "uint2 a;")
	assert_string_contains(t4, "uint4 b = touint4(1u);")
	assert_string_contains(t4, "float4x4 m = tofloat4x4(1.0);")
	assert_string_contains(t4, "rsqrt(x)")

func test_identifiers_are_not_rewritten() -> void:
	var t : String = material.process_option_hlsl_base("float mat3d = 1.0; float xinversesqrt2 = 2.0; uvec3x y;")
	assert_string_contains(t, "mat3d")
	assert_string_contains(t, "xinversesqrt2")

func collect_strings(value, strings : Array) -> void:
	if value is String:
		strings.append(value)
	elif value is Dictionary:
		for k in value.keys():
			collect_strings(value[k], strings)
	elif value is Array:
		for v in value:
			collect_strings(v, strings)

func test_existing_nodes_are_translated_as_before() -> void:
	var checked : int = 0
	for n in [ "perlin", "bricks", "tex3d_fbm", "tex3d_rotate", "voronoi" ]:
		var data = JSON.parse_string(FileAccess.get_file_as_string(NODES_PATH+n+".mmg"))
		assert_not_null(data, n)
		var strings : Array = []
		collect_strings(data.shader_model, strings)
		for s in strings:
			assert_eq(material.process_option_hlsl_base(s), old_hlsl_base(s), "node "+n)
			checked += 1
	assert_gt(checked, 10)

func test_template_declarations() -> void:
	var d : String = material.process_option_hlsl_base("", true)
	assert_string_contains(d, "touint3(")
	assert_string_contains(d, "tofloat3x3(")
	assert_string_contains(d, "tofloat4x4(")
	assert_string_contains(d, "hlsl_atan(float x)")
	assert_false(d.contains("#define hlsl_atan"))
	assert_false(d.contains("hlsl_hlsl"))

## Translated declarations that dxc can compile (the sampler2D textureLod of
## the template is removed as the unreal5 option does)
func declarations() -> String:
	return material.process_option_unreal5(material.process_option_hlsl_base("", true), true)

func write_text(path : String, text : String) -> String:
	var f : FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return path

func test_dxc_compiles_translated_snippet() -> void:
	if MMTestHlsl.find_tool("dxc") == "":
		pending("dxc not found")
		return
	var glsl : String = """float snippet(float x, float y) {
	uvec3 a = uvec3(1u, 2u, 3u);
	mat3 m = mat3(vec3(1.0, 0.0, 0.0), vec3(0.0, 2.0, 0.0), vec3(0.0, 0.0, 3.0));
	mat4 m4 = mat4(1.0);
	vec3 v = vec3(x, y, atan(x));
	float u = atan(y, x) + float(a.x) + inversesqrt(x*x+1.0) + m[1][1] + m4[0][0];
	vec2 w = atan(vec2(x, y), vec2(y, x));
	return u + v.z + w.x + mix(x, y, fract(x));
}
"""
	var source : String = declarations()+"\n"+material.process_option_hlsl_base(glsl)
	source += "\nfloat4 main(float4 p : SV_Position) : SV_Target { return float4(snippet(p.x, p.y), 0.0, 0.0, 1.0); }\n"
	var path : String = write_text("user://test_hlsl_snippet.hlsl", source)
	for hv in [ "2018", "2021" ]:
		var r : Dictionary = MMTestHlsl.compile_hlsl(path, "ps_6_0", "main", hv)
		assert_true(r.ok, "-HV "+hv+": "+r.output)

func test_matrix_constructors_are_transposed() -> void:
	# HLSL matrices are the transposed GLSL ones: the columns of the constructor
	# become the rows of the matrix (m[i] is the column i in both languages), and
	# GLSL's m*v is mul(v, m)
	var d : String = material.process_option_hlsl_base("", true)
	assert_string_contains(d, "float2x2(v1.x, v1.y, v2.x, v2.y)")
	assert_string_contains(d, "float3x3(c0.x, c0.y, c0.z, c1.x, c1.y, c1.z, c2.x, c2.y, c2.z)")
	assert_string_contains(d, "float3x3(a0, a1, a2, b0, b1, b2, c0, c1, c2)")
	assert_string_contains(d, "float4x4(c0.x, c0.y, c0.z, c0.w, c1.x, c1.y, c1.z, c1.w, c2.x, c2.y, c2.z, c2.w, c3.x, c3.y, c3.z, c3.w)")
	assert_string_contains(d, "hlsl_inverse(float3x3 m)")

## Text of the translated matrix products
func test_matrix_products_text() -> void:
	var cases : Array = [
		# matrix * vector and vector * matrix, constructors and variables
		[ "p = mat3(a, b, c)*p;", "p = mul(p, tofloat3x3(a, b, c));" ],
		[ "q = v * mat3(a, b, c);", "q = mul(tofloat3x3(a, b, c), v);" ],
		[ "mat2 m = mat2(a, b); p = m*p;", "p = mul(p, m);" ],
		[ "mat2 m = mat2(a, b); p *= m;", "p = mul(m, p);" ],
		[ "p *= mat2(a, b);", "p = mul(tofloat2x2(a, b), p);" ],
		[ "mat3 r = mat3(1.0); r *= mat3(a, b, c);", "r = mul(tofloat3x3(a, b, c), r);" ],
		# matrix * matrix, left associative chains, precedence
		[ "mat3 A, B; x = A*B*v;", "x = mul(v, mul(B, A));" ],
		[ "mat3 A, B; x = v*A*B;", "x = mul(B, mul(A, v));" ],
		[ "mat3 A; x = 2.0*A*v + w;", "x = mul(v, 2.0*A) + w;" ],
		[ "mat3 A; x = u + A*v/2.0;", "x = u + mul(v, A)/2.0;" ],
		[ "mat3 A; x = -A*(v+w);", "x = mul((v+w), -A);" ],
		[ "mat3 A; x = (A*v).xy*s;", "x = (mul(v, A)).xy*s;" ],
		[ "mat3 A; x = A[1].z*A[2][0]*s;", "x = A[1].z*A[2][0]*s;" ],
		[ "mat3 A; B = A*0.5;", "B = A*0.5;" ],
		[ "mat3 A; x = transpose(A)*v;", "x = mul(v, transpose(A));" ],
		[ "mat3 A; x = inverse(A)*v;", "x = mul(v, hlsl_inverse(A));" ],
		# scopes: a parameter or local that is not a matrix
		[ "vec2 f(vec2 uv) { mat2 m = mat2(a, b); return m*uv; }\nfloat g(float m, float i) { return i*m; }", "return mul(uv, m);" ],
		[ "vec2 f(vec2 uv) { mat2 m = mat2(a, b); return m*uv; }\nfloat g(float m, float i) { return i*m; }", "return i*m;" ],
		[ "vec3 f(mat3 m, vec3 v) { return m*v; }", "return mul(v, m);" ],
		# no matrix: unchanged
		[ "vec4 m[8]; vec3 s = m[k].rgb * m[k].rgb;", "vec3 s = m[k].rgb * m[k].rgb;".replace("vec3", "float3") ],
	]
	for c in cases:
		assert_string_contains(material.process_option_hlsl_base(c[0]), c[1], c[0])
	# Functions and globals of the declarations
	var t : String = material.process_option_hlsl_base("mat3 m3 = tri(uv); vec3 k = tri(uv)*v; vec3 j = G*v;", false, "mat3 tri(vec2 x) { return mat3(1.0); }\nuniform mat3 G;")
	assert_string_contains(t, "float3 k = mul(v, tri(uv));")
	assert_string_contains(t, "float3 j = mul(v, G);")

func test_ue5_export_of_an_example_compiles() -> void:
	var dxc : String = MMTestHlsl.find_tool("dxc")
	if dxc == "":
		pending("dxc not found")
		return
	var target = JSON.parse_string(FileAccess.get_file_as_string(UE5_TARGET))
	assert_not_null(target)
	var template : String = ""
	for f in target.files:
		if f.file_name.ends_with(".shader"):
			template = f.template
	assert_ne(template, "")
	for example in [ "bricks", "mandelbrot" ]:
		var gen = await mm_loader.load_gen("res://material_maker/examples/%s.ptex" % example)
		assert_not_null(gen, example)
		# A graph without a parent cannot get its seed
		var holder : Node = Node.new()
		holder.add_child(gen)
		var mat : MMGenMaterial = null
		for c in gen.get_children():
			if c is MMGenMaterial:
				mat = c
		assert_not_null(mat, example+" has a material node")
		if mat == null:
			holder.free()
			continue
		var shader_path : String = "user://test_hlsl_%s.shader" % example
		assert_eq(mat.create_file_from_template(template, shader_path, mat.get_connections_and_parameters_context()), OK)
		var shader : String = FileAccess.get_file_as_string(shader_path)
		var inputs : Array = [ { name="TexCoords", type="float2" }, { name="Time", type="float" } ]
		var re : RegEx = RegEx.create_from_string("Texture2D (texture_\\d+);")
		for m in re.search_all(shader):
			inputs.append({ name=m.strings[1], type="Texture2D" })
		var outputs : Array = [ { name="metallic", type="float" }, { name="roughness", type="float" },
				{ name="normal", type="float3" }, { name="emission", type="float3" },
				{ name="occlusion", type="float" }, { name="opacity", type="float" } ]
		var path : String = write_text("user://test_hlsl_%s.hlsl" % example, MMTestHlsl.wrap_custom_node(shader, inputs, outputs))
		for hv in [ "2018", "2021" ]:
			var r : Dictionary = MMTestHlsl.compile_hlsl(path, "ps_6_0", "main", hv)
			assert_true(r.ok, "%s -HV %s: %s" % [ example, hv, r.output ])
		holder.free()

const COMPUTE_TEST : String = """
[[vk::binding(0, 0)]] StructuredBuffer<float> input_data;
[[vk::binding(1, 0)]] RWStructuredBuffer<float> output_data;
cbuffer Params : register(b2) { float4 params; };

[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
	output_data[id.x] = input_data[id.x]*params.x+params.y;
}
"""

func test_run_spirv_compute() -> void:
	if RenderingServer.get_rendering_device() == null:
		pending("no rendering device")
		return
	if MMTestHlsl.find_tool("dxc") == "":
		pending("dxc not found")
		return
	var src : String = write_text("user://test_hlsl_compute.hlsl", COMPUTE_TEST)
	var spv : String = "user://test_hlsl_compute.spv"
	var r : Dictionary = MMTestHlsl.compile_to_spirv(src, spv)
	assert_true(r.ok, r.output)
	var input : PackedFloat32Array = PackedFloat32Array()
	for i in 100:
		input.append(float(i))
	var out : PackedFloat32Array = MMTestHlsl.run_spirv_compute(spv, input, PackedFloat32Array([ 2.0, 0.5, 0.0, 0.0 ]), 100)
	assert_eq(out.size(), 100, MMTestHlsl.last_error)
	if out.size() == 100:
		for i in 100:
			assert_almost_eq(out[i], float(i)*2.0+0.5, 0.0001)
	gut.p("SPIR-V of dxc was accepted by Godot through: "+MMTestHlsl.last_spirv_path)

# ---- GLSL versus translated HLSL on the GPU: matrices

const MATRIX_THREADS : int = 256

## Functions of the matrix test (the declarations of the body)
const MATRIX_FUNCTIONS : String = """
mat3 rot(float t) {
	float c = cos(t);
	float s = sin(t);
	return mat3(vec3(c, s, 0.0), vec3(-s, c, 0.0), vec3(0.0, 0.0, 1.0));
}
vec3 apply(mat3 m, vec3 v) {
	return m*v;
}
float shadow(float m3, vec3 v) {
	return m3*v.x;
}
mat2 twice(mat2 m) {
	mat2 r = m;
	r *= mat2(2.0);
	return r;
}
"""

## Body of the matrix test: a, b, c, d are inputs, o[] the outputs
const MATRIX_BODY : String = """
	mat2 m2 = mat2(a.xy, a.zw);
	mat2 m2b = mat2(b.xy, c.zw);
	mat3 m3 = mat3(a.xyz, b.xyz, c.xyz);
	mat3 m3b = mat3(d.xyz, a.zxy, b.yzx);
	mat4 m4 = mat4(a, b, c, d);
	mat4 m4b = mat4(d, c, b, a);
	vec2 v2 = d.xy;
	vec3 v3 = d.xyz;
	vec4 v4 = d.wzyx;
	o[0] = vec4(m2*v2, v2*m2);
	o[1] = vec4(m3*v3, 1.0);
	o[2] = vec4(v3*m3, 1.0);
	o[3] = m4*v4;
	o[4] = v4*m4;
	o[5] = vec4((m3*m3b)*v3, 0.0);
	o[6] = vec4(m3*m3b*v3, 0.0);
	o[7] = vec4(v3*m3*m3b, 0.0);
	o[8] = m4*m4b*v4;
	o[9] = vec4((m2*m2b)[0], (m2*m2b)[1]);
	vec3 w = v3;
	w *= m3;
	o[10] = vec4(w, 0.0);
	mat3 mm = m3;
	mm *= m3b;
	o[11] = vec4(mm[0], mm[2].y);
	o[12] = vec4(mm[1], mm[2].z);
	o[13] = vec4(m3[1].z, m3[2][0], m4[3].y, m4[1][2]);
	mat3 ms = mat3(2.5);
	mat3 m9 = mat3(a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z);
	o[14] = vec4(ms*v3, (m9*v3).x);
	o[15] = vec4(m9[1], m9[2].x);
	o[16] = vec4(mat2(a.x, a.y, b.x, b.y)*v2, mat2(1.5)*v2);
	o[17] = vec4(rot(a.x)*v3, rot(a.y)[1].x);
	o[18] = vec4(apply(m3, v3), determinant(m3));
	o[19] = vec4(transpose(m3)*v3, determinant(m4));
	mat3 m3i = m3+mat3(4.0);
	mat4 m4i = m4+mat4(5.0);
	mat2 m2i = m2+mat2(3.0);
	o[20] = vec4(inverse(m3i)*v3, 0.0);
	o[21] = inverse(m4i)*v4;
	o[22] = vec4(inverse(m2i)*v2, transpose(m2)*v2);
	o[23] = vec4((2.0*m3)*v3, 0.0)+vec4((m3*0.5)*v3, 0.0);
	o[24] = vec4(-m3*v3, 0.0);
	o[25] = vec4(m3*v3*2.0 + v3*m3/2.0, 0.0);
	o[26] = vec4(mat3(m4)*v3, 0.0);
	o[27] = mat4(m3)*v4;
	mat2 ma[2];
	ma[0] = m2;
	ma[1] = m2b;
	o[28] = vec4(ma[1]*v2, ma[0][1]);
	o[29] = vec4(shadow(a.x, v3), (inverse(m3i)*m3i)[1]);
	vec2 p = v2;
	for (int i = 0; i < 3; i++) {
		p = m2*p;
		p *= m2b;
	}
	o[30] = vec4(p, (twice(m2)*v2));
	o[31] = vec4((m3*(v3+1.0)).xy, (m3[0]*2.0).z, (m3*v3).x*(m3*v3).y);
	o[32] = vec4((m3*v3).x*m3*v3, 0.0);
	o[33] = vec4(m3*m3b[1], dot(m3[2], v3));
	o[34] = vec4(2.0*m3*v3 - (m3b*m3)*v3, 0.0);
	mat3 big = m3*m3b;
	o[35] = vec4(big*v3 + transpose(big)*v3, 0.0);
"""

const MATRIX_OUTPUTS : int = 36

const GLSL_HARNESS : String = """#version 450
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
layout(set = 0, binding = 0, std430) restrict readonly buffer InBuffer { float data_in[]; };
layout(set = 0, binding = 1, std430) restrict writeonly buffer OutBuffer { float data_out[]; };
@FUNCTIONS@
void main() {
	uint id = gl_GlobalInvocationID.x;
	vec4 a = vec4(data_in[id*16u], data_in[id*16u+1u], data_in[id*16u+2u], data_in[id*16u+3u]);
	vec4 b = vec4(data_in[id*16u+4u], data_in[id*16u+5u], data_in[id*16u+6u], data_in[id*16u+7u]);
	vec4 c = vec4(data_in[id*16u+8u], data_in[id*16u+9u], data_in[id*16u+10u], data_in[id*16u+11u]);
	vec4 d = vec4(data_in[id*16u+12u], data_in[id*16u+13u], data_in[id*16u+14u], data_in[id*16u+15u]);
	vec4 o[@N@];
	@BODY@
	for (int k = 0; k < @N@; k++) {
		data_out[id*@N@u*4u+uint(k)*4u] = o[k].x;
		data_out[id*@N@u*4u+uint(k)*4u+1u] = o[k].y;
		data_out[id*@N@u*4u+uint(k)*4u+2u] = o[k].z;
		data_out[id*@N@u*4u+uint(k)*4u+3u] = o[k].w;
	}
}
"""

const HLSL_HARNESS : String = """[[vk::binding(0, 0)]] StructuredBuffer<float> data_in;
[[vk::binding(1, 0)]] RWStructuredBuffer<float> data_out;
@DEFINITIONS@
@FUNCTIONS@
[numthreads(64, 1, 1)]
void main(uint3 gid : SV_DispatchThreadID) {
	uint id = gid.x;
	float4 a = float4(data_in[id*16u], data_in[id*16u+1u], data_in[id*16u+2u], data_in[id*16u+3u]);
	float4 b = float4(data_in[id*16u+4u], data_in[id*16u+5u], data_in[id*16u+6u], data_in[id*16u+7u]);
	float4 c = float4(data_in[id*16u+8u], data_in[id*16u+9u], data_in[id*16u+10u], data_in[id*16u+11u]);
	float4 d = float4(data_in[id*16u+12u], data_in[id*16u+13u], data_in[id*16u+14u], data_in[id*16u+15u]);
	float4 o[@N@];
	@BODY@
	for (int k = 0; k < @N@; k++) {
		data_out[id*@N@u*4u+uint(k)*4u] = o[k].x;
		data_out[id*@N@u*4u+uint(k)*4u+1u] = o[k].y;
		data_out[id*@N@u*4u+uint(k)*4u+2u] = o[k].z;
		data_out[id*@N@u*4u+uint(k)*4u+3u] = o[k].w;
	}
}
"""

func gpu_ready() -> bool:
	if MMTestHlsl.find_tool("dxc") == "":
		pending("dxc not found")
		return false
	if RenderingServer.get_rendering_device() == null:
		pending("needs a GPU (run without --headless)")
		return false
	return true

## Compiles a GLSL compute shader with a local rendering device, runs it
func run_glsl_compute(source : String, name : String, input : PackedFloat32Array, output_count : int, threads : int) -> PackedFloat32Array:
	var rd : RenderingDevice = RenderingServer.create_local_rendering_device()
	var shader_source : RDShaderSource = RDShaderSource.new()
	shader_source.language = RenderingDevice.SHADER_LANGUAGE_GLSL
	shader_source.source_compute = source
	var spirv : RDShaderSPIRV = rd.shader_compile_spirv_from_source(shader_source)
	rd.free()
	assert_eq(spirv.compile_error_compute, "", name+": GLSL")
	if spirv.compile_error_compute != "":
		return PackedFloat32Array()
	var path : String = "user://test_hlsl_%s_glsl.spv" % name
	var f : FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(spirv.bytecode_compute)
	f.close()
	return MMTestHlsl.run_spirv_compute(path, input, PackedFloat32Array(), output_count, threads)

## Compiles an HLSL compute shader with dxc (-O0: optimised SPIR-V of DXC hangs
## loops on some drivers), runs it
func run_hlsl_compute(source : String, name : String, input : PackedFloat32Array, output_count : int, threads : int) -> PackedFloat32Array:
	var path : String = write_text("user://test_hlsl_%s.hlsl" % name, source)
	var spv : String = "user://test_hlsl_%s_hlsl.spv" % name
	var r : Dictionary = MMTestHlsl.compile_hlsl(path, "cs_6_0", "main", "2021", [
			"-spirv", "-fspv-target-env=vulkan1.1", "-fvk-use-dx-layout", "-O0", "-Fo", ProjectSettings.globalize_path(spv) ])
	assert_true(r.ok, name+": dxc: "+r.output)
	if not r.ok:
		return PackedFloat32Array()
	return MMTestHlsl.run_spirv_compute(spv, input, PackedFloat32Array(), output_count, threads)

func test_matrices_glsl_hlsl_parity_on_gpu() -> void:
	if not gpu_ready():
		return
	var rng : RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 20261113
	var input : PackedFloat32Array = PackedFloat32Array()
	for i in MATRIX_THREADS*16:
		input.append(rng.randf_range(-1.0, 1.0))
	var count : int = MATRIX_THREADS*MATRIX_OUTPUTS*4
	var glsl_source : String = GLSL_HARNESS.replace("@FUNCTIONS@", MATRIX_FUNCTIONS).replace("@BODY@", MATRIX_BODY).replace("@N@", str(MATRIX_OUTPUTS))
	var hlsl_functions : String = material.process_option_hlsl_base(MATRIX_FUNCTIONS)
	var hlsl_body : String = material.process_option_hlsl_base(MATRIX_BODY, false, MATRIX_FUNCTIONS)
	var hlsl_source : String = HLSL_HARNESS.replace("@DEFINITIONS@", declarations()).replace("@FUNCTIONS@", hlsl_functions).replace("@BODY@", hlsl_body).replace("@N@", str(MATRIX_OUTPUTS))
	var glsl : PackedFloat32Array = run_glsl_compute(glsl_source, "matrices", input, count, MATRIX_THREADS)
	var hlsl : PackedFloat32Array = run_hlsl_compute(hlsl_source, "matrices", input, count, MATRIX_THREADS)
	assert_eq(glsl.size(), count, "GLSL did not run: "+MMTestHlsl.last_error)
	assert_eq(hlsl.size(), count, "HLSL did not run: "+MMTestHlsl.last_error)
	if glsl.size() != count or hlsl.size() != count:
		return
	var worst : PackedFloat32Array = PackedFloat32Array()
	worst.resize(MATRIX_OUTPUTS)
	var spread : PackedFloat32Array = PackedFloat32Array()
	spread.resize(MATRIX_OUTPUTS)
	for t in MATRIX_THREADS:
		for k in MATRIX_OUTPUTS:
			for c in 4:
				var i : int = (t*MATRIX_OUTPUTS+k)*4+c
				var e : float = absf(glsl[i]-hlsl[i])/maxf(1.0, absf(glsl[i]))
				worst[k] = maxf(worst[k], e if not is_nan(e) else 1e9)
				spread[k] = maxf(spread[k], absf(glsl[i]-glsl[k*4+c]))
	var max_all : float = 0.0
	for k in MATRIX_OUTPUTS:
		max_all = maxf(max_all, worst[k])
		assert_lt(worst[k], 1e-4, "o[%d]: GLSL and HLSL differ by %s" % [ k, String.num_scientific(worst[k]) ])
		assert_gt(spread[k], 1e-3, "o[%d] is constant, the comparison proves nothing" % k)
	var line : String = "matrices: %d outputs x %d threads, max relative difference %s" % [ MATRIX_OUTPUTS, MATRIX_THREADS, String.num_scientific(max_all) ]
	print(line)
	gut.p(line)
	# The old translation (matrices stored as they are, products not rewritten)
	# would differ: the test detects a wrong translation
	var wrong : String = hlsl_source.replace("mul(v3, m3)", "mul(m3, v3)")
	assert_ne(wrong, hlsl_source)
	var bad : PackedFloat32Array = run_hlsl_compute(wrong, "matrices_wrong", input, count, MATRIX_THREADS)
	var bad_max : float = 0.0
	for i in mini(bad.size(), count):
		bad_max = maxf(bad_max, absf(glsl[i]-bad[i]))
	assert_gt(bad_max, 1e-2, "control: a swapped product is detected")

# ---- GLSL versus the exported HLSL of real nodes (Unreal Engine 5 Voxel export)

const VOXEL_TARGET : String = "Unreal/Unreal Engine 5 Voxel"
const VOXEL_TARGET_DIR : String = "res://material_maker/plugins/voxel/export_targets"
const VOXEL_NODES_DIR : String = "res://material_maker/plugins/voxel/nodes"
const NODE_OUT_DIR : String = "user://hlsl_translation_nodes"
const NODE_POINTS : int = 2048
const NODE_TOL : float = 1e-4

const NODE_CBUFFER : String = "\tfloat t_seed; float t_age; float t_upkeep; float t_char;\n\tfloat t_wet; float t_footprint; float t_time; float t_pad;\n\tfloat4 t_axis;\n\tfloat4 t_origin;"

const NODE_HARNESS : String = """[[vk::binding(0, 0)]] StructuredBuffer<float4> In;
[[vk::binding(1, 0)]] RWStructuredBuffer<float4> Out;
[[vk::binding(2, 0)]] cbuffer Things {
@INPUTS@
};

float4 mm_custom(float3 Position, float3 Normal, float Seed, float Age, float Upkeep, float Fresh, float Char, float Wet, float3 Axis, float3 Origin, float Footprint, float Time, out float metallic, out float roughness, out float3 normal, out float3 emission, out float occlusion, out float opacity) {
@SHADER@
}

[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
	float4 a = In[id.x*2];
	float4 b = In[id.x*2+1];
	float metallic;
	float roughness;
	float3 normal;
	float3 emission;
	float occlusion;
	float opacity;
	float4 col = mm_custom(a.xyz, b.xyz, t_seed, t_age, t_upkeep, a.w, t_char, t_wet, t_axis.xyz, t_origin.xyz, t_footprint, t_time, metallic, roughness, normal, emission, occlusion, opacity);
	Out[id.x*4] = float4(col.rgb, 0.0);
	Out[id.x*4+1] = float4(occlusion, roughness, metallic, 0.0);
	Out[id.x*4+2] = float4(emission, 0.0);
	Out[id.x*4+3] = float4(normal, opacity);
}
"""

## A test-only node that shows a 2D output (of type type) as a 3D texture, on
## the square -2..2 of the voxel positions
func probe_2d_model(type : String) -> Dictionary:
	var value : String = "$in($uv.xy*0.25+vec2(0.5))"
	var defaults : Dictionary = { f="0.0", rgb="vec3(0.0)", rgba="vec4(0.0)" }
	var tex3d : String = { f="vec3("+value+")", rgb=value, rgba=value+".rgb" }[type]
	return {
		name="Probe", shortdesc="Probe", longdesc="Test probe", code="", global="", instance="", parameters=[],
		inputs=[ { name="in", type=type, label="", default=defaults[type], shortdesc="Input", longdesc="" } ],
		outputs=[ { type="tex3d", tex3d=tex3d, shortdesc="Output", longdesc="" } ]
	}

## A test-only 2D node: a color that depends on the position
func source_2d_model() -> Dictionary:
	return {
		name="Source", shortdesc="Source", longdesc="Test source", code="", global="", instance="", parameters=[], inputs=[],
		outputs=[ { type="rgba", rgba="vec4(fract($uv.x*1.7), fract($uv.y*1.3), 0.5+0.4*sin($uv.x*5.0+$uv.y*3.0), 1.0)", shortdesc="Output", longdesc="" } ]
	}

## A test-only node that shows the distance of an SDF as a 3D texture
func probe_sdf_model() -> Dictionary:
	return {
		name="Probe", shortdesc="Probe", longdesc="Test probe", code="", global="", instance="", parameters=[],
		inputs=[ { name="in", type="sdf3d", label="", default="100.0", shortdesc="Input", longdesc="" } ],
		outputs=[ { type="tex3d", tex3d="vec3(clamp($in($uv.xyz)*0.5+0.5, 0.0, 1.0), clamp($in($uv.xyz)*2.0+0.5, 0.0, 1.0), 0.0)", shortdesc="Output", longdesc="" } ]
	}

func node_graph(type : String, params : Dictionary, output : int, output_type : String) -> Dictionary:
	var nodes : Array = [ { name="Material", type="material_voxel", parameters={ linear_albedo=true } },
		{ name="N", type=type, parameters=params, seed_int=1234 } ]
	var wires : Array = []
	if output_type == "sdf3d":
		nodes.append_array([ { name="Sphere", type="sdf3d_sphere", parameters={ r=1.2 } }, { name="Probe", type="shader", shader_model=probe_sdf_model() } ])
		wires.append({ from="Sphere", from_port=0, to="N", to_port=0 })
	else:
		nodes.append({ name="Probe", type="shader", shader_model=probe_2d_model(output_type) })
	if type == "convert_colorspace":
		nodes.append({ name="Source", type="shader", shader_model=source_2d_model() })
		wires.append({ from="Source", from_port=0, to="N", to_port=0 })
	wires.append_array([ { from="N", from_port=output, to="Probe", to_port=0 }, { from="Probe", from_port=0, to="Material", to_port=0 } ])
	return { nodes=nodes, connections=wires }

func node_points() -> Array:
	var rng : RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 7041
	var points : PackedFloat32Array = PackedFloat32Array()
	var normals : PackedFloat32Array = PackedFloat32Array()
	var fresh : PackedFloat32Array = PackedFloat32Array()
	for i in NODE_POINTS:
		var p : Vector3 = Vector3(rng.randf_range(-2, 2), rng.randf_range(-2, 2), rng.randf_range(-2, 2))
		var n : Vector3 = Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		points.append_array([ p.x, p.y, p.z ])
		normals.append_array([ n.x, n.y, n.z ])
		fresh.append(rng.randf())
	return [ points, normals, fresh ]

## Swaps the operands of every mul() (the wrong translation, for the controls)
func swap_products(s : String) -> String:
	var starts : Array[int] = []
	var at : int = s.find("mul(")
	while at != -1:
		if at == 0 or not (s[at-1] == "_" or s[at-1].is_valid_identifier()):
			starts.append(at)
		at = s.find("mul(", at+1)
	starts.reverse()
	for i : int in starts:
		var close : int = MMGenBase.find_matching_parenthesis(s, i+3)
		if close == -1:
			continue
		var inner : String = s.substr(i+4, close-i-4)
		var depth : int = 0
		var comma : int = -1
		for k in inner.length():
			if inner[k] in "([":
				depth += 1
			elif inner[k] in ")]":
				depth -= 1
			elif inner[k] == "," and depth == 0:
				comma = k
				break
		if comma == -1:
			continue
		s = s.left(i)+"mul("+inner.substr(comma+1).strip_edges()+", "+inner.left(comma).strip_edges()+")"+s.substr(close+1)
	return s

## Returns { max, p999, exceed, spread, shader, glsl } or {}
func run_node_case(label : String, type : String, params : Dictionary, output : int, output_type : String, data : Array) -> Dictionary:
	var graph : MMGenBase = await mm_loader.create_gen(node_graph(type, params, output, output_type))
	add_child(graph)
	var mat : MMGenMaterial = graph.get_node("Material")
	var glsl : Dictionary = await MMVoxelEval.evaluate_material(mat, data[0], data[1], data[2])
	assert_false(glsl.is_empty(), label+": GLSL evaluation failed: "+MMVoxelEval.last_error)
	var prefix : String = ProjectSettings.globalize_path(NODE_OUT_DIR).path_join(label)
	await mat.export_material(prefix, VOXEL_TARGET, 0, true)
	graph.free()
	var shader : String = FileAccess.get_file_as_string(prefix+".shader")
	assert_ne(shader, "", label+": empty export")
	if glsl.is_empty() or shader == "":
		return {}
	var stats : Dictionary = shader_stats(label, shader, glsl, data)
	if not stats.is_empty():
		stats.shader = shader
		stats.glsl = glsl
	return stats

## Runs the exported shader on the GPU and compares its base color with the GLSL one
func shader_stats(label : String, shader : String, glsl : Dictionary, data : Array) -> Dictionary:
	var hlsl_path : String = write_text(NODE_OUT_DIR.path_join(label+"_harness.hlsl"), NODE_HARNESS.replace("@INPUTS@", NODE_CBUFFER).replace("@SHADER@", shader))
	var spv : String = NODE_OUT_DIR.path_join(label+".spv")
	var r : Dictionary = MMTestHlsl.compile_hlsl(hlsl_path, "cs_6_0", "main", "2021", [
			"-spirv", "-fspv-target-env=vulkan1.1", "-fvk-use-dx-layout", "-O0", "-Fo", ProjectSettings.globalize_path(spv) ])
	assert_true(r.ok, label+": dxc: "+r.output)
	if not r.ok:
		return {}
	var input : PackedFloat32Array = PackedFloat32Array()
	input.resize(NODE_POINTS*8)
	for i in NODE_POINTS:
		for c in 3:
			input[i*8+c] = data[0][i*3+c]
			input[i*8+4+c] = data[1][i*3+c]
		input[i*8+3] = data[2][i]
	var uniforms : PackedFloat32Array = PackedFloat32Array([ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 ])
	var hlsl : PackedFloat32Array = MMTestHlsl.run_spirv_compute(spv, input, uniforms, NODE_POINTS*16, NODE_POINTS)
	assert_eq(hlsl.size(), NODE_POINTS*16, label+": the compute shader did not run: "+MMTestHlsl.last_error)
	if hlsl.size() != NODE_POINTS*16:
		return {}
	var diffs : PackedFloat32Array = PackedFloat32Array()
	var exceed : int = 0
	var lo : float = 1e9
	var hi : float = -1e9
	for i in NODE_POINTS:
		var bad : bool = false
		for c in 3:
			var g : float = glsl.base_color[i*3+c]
			var d : float = absf(g-hlsl[i*16+c])
			if is_nan(d):
				d = 1e9
			diffs.append(d)
			bad = bad or d > NODE_TOL
			lo = minf(lo, g)
			hi = maxf(hi, g)
		if bad:
			exceed += 1
	diffs.sort()
	return { max=diffs[diffs.size()-1], p999=diffs[int(diffs.size()*0.999)], exceed=exceed, spread=hi-lo }

func stats_line(label : String, stats : Dictionary) -> String:
	return "%s max_abs=%s p99.9=%s over_tol=%d value_spread=%s" % [ label, String.num_scientific(stats.max), String.num_scientific(stats.p999), stats.exceed, String.num_scientific(stats.spread) ]

func test_matrix_nodes_glsl_hlsl_parity_on_gpu() -> void:
	if not gpu_ready():
		return
	DirAccess.make_dir_recursive_absolute(NODE_OUT_DIR)
	mm_loader.get_predefined_generators_from_dir(VOXEL_NODES_DIR)
	MMPlugins.load_export_targets(VOXEL_TARGET_DIR)
	var data : Array = node_points()
	# label: [ type, parameters, output, output type, text the export must contain, control ]
	# control: "strict" when the swapped products must change the output, "none" when this
	# output does not go through a product (only checked for no regression)
	var cases : Dictionary = {
		box_rotated=[ "box", { rx=25.0, ry=-40.0, rz=70.0, sx=0.3, sy=0.2, sz=0.25 }, 0, "f", "mul(tofloat3x3(", "strict" ],
		box_flat=[ "box", { rx=0.0, ry=0.0, rz=30.0 }, 0, "f", "mul(", "strict" ],
		yuv_from_rgb=[ "convert_colorspace", { colorspace=2, direction=0 }, 0, "rgba", "mul(tofloat3x3(", "strict" ],
		yuv_to_rgb=[ "convert_colorspace", { colorspace=2, direction=1 }, 0, "rgba", "mul(tofloat3x3(", "strict" ],
		# randomness 0: the sin hash of rand2 differs between the GLSL and HLSL compiles
		voronoi_triangle_edge=[ "voronoi_triangle", { randomness=0.0 }, 0, "f", "_m3[0].yz", "none" ],
		voronoi_triangle_dist=[ "voronoi_triangle", { randomness=0.0 }, 1, "f", "_m3[0].x", "strict" ],
		voronoi_triangle_normal=[ "voronoi_triangle", { randomness=0.0 }, 4, "rgb", "_m3[1].y", "strict" ],
		# Exact rotates the octaves with an expanded vec3 sum, the mat3 is only in the Legacy function
		sdf3d_fbm_exact=[ "sdf3d_fbm", { hash=1, mode=0, iterations=3, smoothness=0.2 }, 0, "sdf3d", "mul(p, tofloat3x3(", "none" ],
		sdf3d_fbm_legacy=[ "sdf3d_fbm", { hash=0, mode=0, iterations=3, smoothness=0.2 }, 0, "sdf3d", "mul(p, tofloat3x3(", "legacy" ],
	}
	for label : String in cases.keys():
		var c : Array = cases[label]
		var stats : Dictionary = await run_node_case(label, c[0], c[1], c[2], c[3], data)
		if stats.is_empty():
			continue
		var line : String = stats_line(label, stats)
		print(line)
		gut.p(line)
		assert_string_contains(stats.shader, c[4], label+": the export has the translated matrix code")
		assert_gt(stats.spread, 0.05, label+": the output is flat, the comparison proves nothing")
		# Control: the products with swapped operands (the transposed matrices) differ
		var wrong : Dictionary = {}
		if stats.shader.contains("mul("):
			wrong = shader_stats(label+"_wrong", swap_products(stats.shader), stats.glsl, data)
			line = stats_line(label+" (control, swapped products)", wrong)
			print(line)
			gut.p(line)
		if c[5] == "legacy":
			# Legacy hashes with sin(), whose values differ between the GLSL and the HLSL
			# compilations (as other legacy nodes, informational): only checks that the
			# control is further away than the correct translation
			assert_false(wrong.is_empty(), label+": control ran")
			if not wrong.is_empty():
				assert_gt(wrong.exceed, stats.exceed, label+": the correct translation is closer than the control")
			continue
		assert_lte(stats.exceed, NODE_POINTS/1000, "%s: %d points over %s (max %s)" % [ label, stats.exceed, String.num_scientific(NODE_TOL), String.num_scientific(stats.max) ])
		assert_lt(stats.p999, NODE_TOL, label+": 99.9th percentile")
		if c[5] == "strict":
			assert_false(wrong.is_empty(), label+": control ran")
			if not wrong.is_empty():
				assert_gt(wrong.max, 1e-2, label+": control, swapped products are detected")
