extends GutTest

## Tests for the Unreal Engine 5 Voxel export target of the Voxel plugin

const TARGET : String = "Unreal/Unreal Engine 5 Voxel"
const TARGET_DIR : String = "res://material_maker/plugins/voxel/export_targets"
const STUB : String = "res://test/voxel_unreal_stub.py"
const OUT_DIR : String = "user://voxel_export_test"

var graph : MMGenGraph
var material : MMGenMaterial

func before_all() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

func before_each() -> void:
	mm_loader.get_predefined_generators_from_dir("res://material_maker/plugins/voxel/nodes")
	MMPlugins.load_export_targets(TARGET_DIR)

func after_each() -> void:
	if graph != null:
		graph.queue_free()
		graph = null

## The graph of the plan: fbm seeded by Inputs:2 as albedo, its gradient as bump,
## roughness from Inputs:3 (Age). With a second Voxel Inputs node, its Wet output
## is the metallic.
func make_graph(second_inputs : bool = false) -> void:
	var nodes : Array = [
		{ name="Material", type="material_voxel" },
		{ name="In", type="voxel_inputs" },
		{ name="Fbm", type="tex3d_noise_fbm" },
		{ name="Grad", type="tex3d_gradient" }
	]
	var connections : Array = [
		{ from="In", from_port=2, to="Fbm", to_port=0 },
		{ from="Fbm", from_port=0, to="Material", to_port=0 },
		{ from="Fbm", from_port=0, to="Grad", to_port=0 },
		{ from="Grad", from_port=0, to="Material", to_port=6 },
		{ from="In", from_port=3, to="Material", to_port=2 }
	]
	if second_inputs:
		nodes.append({ name="In2", type="voxel_inputs" })
		connections.append({ from="In2", from_port=7, to="Material", to_port=1 })
	graph = await mm_loader.create_gen({ nodes=nodes, connections=connections })
	add_child(graph)
	material = graph.get_node("Material")

## Exports with the target, returns the path prefix
func do_export(name : String) -> String:
	var prefix : String = ProjectSettings.globalize_path(OUT_DIR).path_join(name)
	await material.export_material(prefix, TARGET, 0, true)
	return prefix

func read_file(path : String) -> String:
	return FileAccess.get_file_as_string(path)

func test_target_is_registered() -> void:
	await make_graph()
	assert_true(material.get_export_profiles().has(TARGET), str(material.get_export_profiles()))

func check_shader(shader : String) -> void:
	assert_string_contains(shader, "float3 p, float3 n")
	assert_string_contains(shader, "f.vox_seed = Seed;")
	var function_start : int = shader.find("generated_shader(")
	assert_gt(function_start, -1)
	assert_true(shader.find("vox_age", function_start) > -1, "vox_age used inside generated_shader")
	assert_null(RegEx.create_from_string("p_o\\d+_vox_").search(shader), "uniform names of the Voxel Inputs node remain")
	for forbidden in [ "\\bvec[234]\\b", "\\bmix\\(", "\\bfract\\(", "uniform ", "\\$" ]:
		var m : RegExMatch = RegEx.create_from_string(forbidden).search(shader)
		assert_null(m, "found %s in the shader: %s" % [ forbidden, m.get_string() if m != null else "" ])

func test_shader_text() -> void:
	await make_graph()
	var prefix : String = await do_export("text")
	var shader : String = read_file(prefix+".shader")
	assert_ne(shader, "")
	check_shader(shader)
	# the sRGB decode of the default (non linear) albedo and the bump
	assert_string_contains(shader, "pow((mm_alb+float3(0.055")
	assert_string_contains(shader, "normal = normalize(n - ")
	assert_string_contains(shader, "float3 vox_axis; float3 vox_origin;")

func test_linear_albedo_has_no_srgb_decode() -> void:
	await make_graph()
	material.set_parameter("linear_albedo", true)
	var prefix : String = await do_export("linear")
	var shader : String = read_file(prefix+".shader")
	assert_false(shader.contains("pow((mm_alb+float3(0.055"))
	check_shader(shader)

func test_py_template() -> void:
	await make_graph()
	var prefix : String = await do_export("py")
	var py : String = read_file(prefix+".py")
	assert_string_contains(py, "UNVERIFIED in Unreal")
	assert_string_contains(py, "'Position', 'Normal', 'Seed'")
	assert_false(py.contains("$("), "unresolved template variable in the script")
	assert_string_contains(py, prefix+".shader")

func test_second_inputs_node_exports_to_the_same_members() -> void:
	await make_graph(true)
	var prefix : String = await do_export("two")
	var shader : String = read_file(prefix+".shader")
	check_shader(shader)
	assert_eq(shader.count("float vox_seed;"), 1)
	assert_eq(shader.count("float vox_wet;"), 1)
	var function_start : int = shader.find("generated_shader(")
	assert_true(shader.find("vox_wet", function_start) > -1, "vox_wet used inside generated_shader")

func test_dxc_compiles_both_hlsl_versions() -> void:
	if MMTestHlsl.find_tool("dxc") == "":
		pending("dxc not found")
		return
	await make_graph(true)
	var prefix : String = await do_export("dxc")
	var shader : String = read_file(prefix+".shader")
	var inputs : Array = []
	for n in [ "Position", "Normal" ]:
		inputs.append({ name=n, type="float3" })
	for n in [ "Seed", "Age", "Upkeep", "Fresh", "Char", "Wet" ]:
		inputs.append({ name=n, type="float" })
	inputs.append({ name="Axis", type="float3" })
	inputs.append({ name="Origin", type="float3" })
	inputs.append({ name="Footprint", type="float" })
	inputs.append({ name="Time", type="float" })
	var outputs : Array = [ { name="metallic", type="float" }, { name="roughness", type="float" },
			{ name="normal", type="float3" }, { name="emission", type="float3" },
			{ name="occlusion", type="float" }, { name="opacity", type="float" } ]
	var path : String = OUT_DIR.path_join("dxc.hlsl")
	var f : FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(MMTestHlsl.wrap_custom_node(shader, inputs, outputs))
	f.close()
	for hv in [ "2018", "2021" ]:
		var r : Dictionary = MMTestHlsl.compile_hlsl(path, "ps_6_0", "main", hv)
		assert_true(r.ok, "-HV %s: %s" % [ hv, r.output ])

func test_python_stub_runs_the_script() -> void:
	await make_graph()
	var prefix : String = await do_export("stub")
	var output : Array = []
	var code : int = OS.execute("python", [ ProjectSettings.globalize_path(STUB), prefix+".py" ], output, true)
	if code == -1:
		pending("python not found")
		return
	assert_eq(code, 0, str(output))
	assert_eq(String(output[0]).strip_edges(), "OK", str(output))
