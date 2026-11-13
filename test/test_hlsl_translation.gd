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

func test_matrix_constructors_are_column_major() -> void:
	# The columns of the constructor become the columns of the matrix, so that
	# mul(m, v) is GLSL's m*v: mat3(a, b, c)*v = a*v.x+b*v.y+c*v.z
	var d : String = material.process_option_hlsl_base("", true)
	assert_string_contains(d, "float3x3(c0.x, c1.x, c2.x, c0.y, c1.y, c2.y, c0.z, c1.z, c2.z)")

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
