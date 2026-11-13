extends GutTest

## Tests for the Material Function export target and the master material
## generator (Voxel master material plugin)

const FUNCTION_TARGET : String = "Unreal/Unreal Engine 5 Voxel Function"
const TARGET_DIR : String = "res://material_maker/plugins/voxel/export_targets"
const STUB : String = "res://test/voxel_unreal_stub.py"
const OUT_DIR : String = "user://voxel_master_test"
const MasterScript = preload("res://material_maker/plugins/voxel_master/voxel_master.gd")

var graphs : Array = []

func before_all() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)

func before_each() -> void:
	mm_loader.get_predefined_generators_from_dir("res://material_maker/plugins/voxel/nodes")
	MMPlugins.load_export_targets(TARGET_DIR)

func after_each() -> void:
	for g in graphs:
		g.queue_free()
	graphs.clear()

## A graph whose albedo is a seeded noise (type tex3d_noise_value or tex3d_noise_voronoi)
func make_graph(noise_type : String) -> MMGenGraph:
	var graph : MMGenGraph = await mm_loader.create_gen({
		nodes=[
			{ name="Material", type="material_voxel" },
			{ name="In", type="voxel_inputs" },
			{ name="Noise", type=noise_type }
		],
		connections=[
			{ from="In", from_port=2, to="Noise", to_port=0 },
			{ from="Noise", from_port=0, to="Material", to_port=0 }
		] })
	add_child(graph)
	graphs.append(graph)
	return graph

func read_file(path : String) -> String:
	return FileAccess.get_file_as_string(path)

func recipe_text(extra_texture : bool = false) -> String:
	var s : String = "struct MMVoxRecipe {\n\tfloat Time;\n\tfloat vox_seed; float vox_age;\n"
	if extra_texture:
		s += "\tTexture2D texture_0;\n\tSamplerState texture_0Sampler;\n"
	s += "\tfloat4 generated_shader(float3 p, float3 n, float _time,\n"
	if extra_texture:
		s += "\t\t\tTexture2D _texture_0, SamplerState _texture_0Sampler,\n"
	s += "\t\t\tout float metallic, out float roughness, out float3 normal, out float3 emission, out float occlusion, out float opacity) {\n"
	if extra_texture:
		s += "\t\ttexture_0 = _texture_0;\n\t\ttexture_0Sampler = _texture_0Sampler;\n"
		s += "\t\tfloat3 c = texture_0.SampleLevel(texture_0Sampler, p.xy, 0).rgb;\n"
	s += "\t\tmetallic = 0.0; roughness = 0.5; normal = n; emission = float3(0.0, 0.0, 0.0); occlusion = 1.0; opacity = 1.0;\n"
	s += "\t\treturn float4(vox_seed, vox_age, 0.0, 1.0);\n\t}\n};\n"
	return s

func test_combine_synthetic_structs() -> void:
	var shader : String = MMVoxelMaster.combine([
			{ name="oak.ptex", id=5, hlsl=recipe_text(true) },
			{ name="brick.ptex", id=2, hlsl=recipe_text() } ], {})
	assert_ne(shader, "")
	assert_string_contains(shader, "struct MMVox_oak {")
	assert_string_contains(shader, "struct MMVox_brick {")
	assert_false(shader.contains("MMVoxRecipe"))
	assert_string_contains(shader, "if (mm_id == 5) {")
	assert_string_contains(shader, "else if (mm_id == 2) {")
	assert_string_contains(shader, "int mm_id = int(MaterialId + 0.5);")
	assert_string_contains(shader, "float4(1.0, 0.0, 1.0, 1.0)")
	assert_false(shader.contains("switch"))
	# the textures are renamed (members, sampler members and the call), parameters of generated_shader are not
	assert_string_contains(shader, "Texture2D tex_oak_0;")
	assert_string_contains(shader, "SamplerState tex_oak_0Sampler;")
	assert_string_contains(shader, "tex_oak_0, tex_oak_0Sampler, metallic")
	assert_null(RegEx.create_from_string("(?<![_\\w])texture_0").search(shader), "texture_0 remains")

func test_combine_errors() -> void:
	var r : Dictionary = MMVoxelMaster.build([ { name="a", id=1, hlsl=recipe_text() }, { name="b", id=1, hlsl=recipe_text() } ], {})
	assert_true(r.has("error"), "duplicate ids")
	r = MMVoxelMaster.build([ { name="a", id=1, hlsl="float x;" } ], {})
	assert_true(r.has("error"), "no struct")
	r = MMVoxelMaster.build([ { name="a", id=1, hlsl=recipe_text() } ], { id_source="nonsense" })
	assert_true(r.has("error"), "bad id_source")
	r = MMVoxelMaster.build([ { name="a", id=1, hlsl=recipe_text() } ], { inputs={ Axis="vertex_color:r" } })
	assert_true(r.has("error"), "vector from a vertex color")

func test_same_names_get_distinct_structs() -> void:
	var shader : String = MMVoxelMaster.combine([ { name="a/x.ptex", id=1, hlsl=recipe_text() }, { name="b/x.ptex", id=2, hlsl=recipe_text() } ], {})
	assert_string_contains(shader, "struct MMVox_x {")
	assert_string_contains(shader, "struct MMVox_x_2 {")

func test_parse_source() -> void:
	assert_eq(MMVoxelMaster.parse_source("custom_primitive_data:3").index, 3)
	assert_eq(MMVoxelMaster.parse_source("vertex_color:g").channel, "g")
	assert_eq(MMVoxelMaster.parse_source("uv1:y").index, 1)
	assert_eq(MMVoxelMaster.parse_source("auto").kind, "auto")
	assert_true(MMVoxelMaster.parse_source("vertex_color:x").is_empty())
	assert_true(MMVoxelMaster.parse_source("uv:x").is_empty())

func test_function_target_files() -> void:
	var graph : MMGenGraph = await make_graph("tex3d_noise_value")
	var material : MMGenBase = graph.get_node("Material")
	assert_true(material.get_export_profiles().has(FUNCTION_TARGET))
	var prefix : String = ProjectSettings.globalize_path(OUT_DIR).path_join("function")
	await material.export_material(prefix, FUNCTION_TARGET, 0, true)
	var hlsl : String = read_file(prefix+".voxel.hlsl")
	assert_string_contains(hlsl, "struct MMVoxRecipe {")
	assert_string_contains(hlsl, "float4 generated_shader(float3 p, float3 n")
	assert_false(hlsl.contains("Functions f;"), "the struct has no trailing call")
	assert_false(hlsl.contains("f.generated_shader"))
	assert_null(RegEx.create_from_string("p_o\\d+_vox_").search(hlsl))
	var py : String = read_file(prefix+"_function.py")
	assert_string_contains(py, "UNVERIFIED in Unreal")
	assert_string_contains(py, "MF_function")
	assert_string_contains(py, "MaterialFunctionFactoryNew")
	assert_string_contains(py, "create_material_expression_in_function")
	assert_string_contains(py, "update_material_function")
	assert_string_contains(py, prefix+".voxel.hlsl")
	assert_false(py.contains("$("), "unresolved template variable in the script")
	var output : Array = []
	var code : int = OS.execute("python", [ ProjectSettings.globalize_path(STUB), prefix+"_function.py" ], output, true)
	if code == -1:
		pending("python not found")
		return
	assert_eq(code, 0, str(output))
	assert_eq(String(output[0]).strip_edges(), "OK", str(output))

func wrap_for_dxc(shader : String, path : String) -> void:
	var inputs : Array = []
	for n in [ "Position", "Normal" ]:
		inputs.append({ name=n, type="float3" })
	for n in [ "Seed", "Age", "Upkeep", "Fresh", "Char", "Wet" ]:
		inputs.append({ name=n, type="float" })
	inputs.append({ name="Axis", type="float3" })
	inputs.append({ name="Origin", type="float3" })
	for n in [ "Footprint", "Time", "MaterialId" ]:
		inputs.append({ name=n, type="float" })
	var outputs : Array = [ { name="metallic", type="float" }, { name="roughness", type="float" },
			{ name="normal", type="float3" }, { name="emission", type="float3" },
			{ name="occlusion", type="float" }, { name="opacity", type="float" } ]
	var f : FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(MMTestHlsl.wrap_custom_node(shader, inputs, outputs))
	f.close()

func test_generate_and_compile() -> void:
	var g1 : MMGenGraph = await make_graph("tex3d_noise_value")
	var g2 : MMGenGraph = await make_graph("tex3d_noise_voronoi")
	var out : String = ProjectSettings.globalize_path(OUT_DIR).path_join("master")
	var config : Dictionary = { name="M_VoxelMaster", ids={ "oak.ptex": 5, "brick.ptex": 2 } }
	var errors : Array[String] = await MasterScript.generate([ { graph=g1, file="oak.ptex" }, { graph=g2, file="brick.ptex" } ], config, out)
	assert_eq(errors, [] as Array[String])
	for ext in [ "shader", "py", "master.json" ]:
		assert_true(FileAccess.file_exists(out.path_join("M_VoxelMaster."+ext)), ext)
	var shader : String = read_file(out.path_join("M_VoxelMaster.shader"))
	assert_string_contains(shader, "struct MMVox_oak {")
	assert_string_contains(shader, "struct MMVox_brick {")
	assert_false(shader.contains("MMVoxRecipe"))
	var info = JSON.parse_string(read_file(out.path_join("M_VoxelMaster.master.json")))
	assert_eq(info.recipes.size(), 2)
	assert_eq(int(info.recipes[0].id), 5)
	# the script
	var output : Array = []
	var code : int = OS.execute("python", [ "-m", "py_compile", out.path_join("M_VoxelMaster.py") ], output, true)
	if code == -1:
		pending("python not found")
	else:
		assert_eq(code, 0, str(output))
		output = []
		code = OS.execute("python", [ ProjectSettings.globalize_path(STUB), out.path_join("M_VoxelMaster.py") ], output, true)
		assert_eq(code, 0, str(output))
		assert_eq(String(output[0]).strip_edges(), "OK", str(output))
	# HLSL
	if MMTestHlsl.find_tool("dxc") == "":
		pending("dxc not found")
		return
	var path : String = OUT_DIR.path_join("master.hlsl")
	wrap_for_dxc(shader, path)
	for hv in [ "2018", "2021" ]:
		var r : Dictionary = MMTestHlsl.compile_hlsl(path, "ps_6_0", "main", hv)
		assert_true(r.ok, "-HV %s: %s" % [ hv, r.output ])

func test_generate_reports_missing_id() -> void:
	var g1 : MMGenGraph = await make_graph("tex3d_noise_value")
	var errors : Array[String] = await MasterScript.generate([ { graph=g1, file="oak.ptex" } ], { ids={} }, ProjectSettings.globalize_path(OUT_DIR).path_join("noid"))
	assert_eq(errors.size(), 1)
	assert_string_contains(errors[0], "no id")

## Saves the two graphs as .ptex files, for the command line run of the plan
## (the files are written in the test directory)
func test_write_ptex_files() -> void:
	var g1 : MMGenGraph = await make_graph("tex3d_noise_value")
	var g2 : MMGenGraph = await make_graph("tex3d_noise_voronoi")
	var dir : String = OUT_DIR.path_join("cli")
	DirAccess.make_dir_recursive_absolute(dir)
	for p in [ [ g1, "oak.ptex" ], [ g2, "brick.ptex" ] ]:
		var f : FileAccess = FileAccess.open(dir.path_join(p[1]), FileAccess.WRITE)
		f.store_string(JSON.stringify(p[0].serialize(), "\t", true))
		f.close()
		assert_true(FileAccess.file_exists(dir.path_join(p[1])))
	var f : FileAccess = FileAccess.open(dir.path_join("config.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({ name="M_VoxelMaster", ids={ "oak.ptex": 5, "brick.ptex": 2 }, id_source="custom_primitive_data:0" }, "\t"))
	f.close()
