extends GutTest

## Tests for the Voxel plugin nodes: Voxel Material and Voxel Inputs

var graph : MMGenGraph
var material : MMGenMaterial
var inputs : MMGenShader

func before_each() -> void:
	mm_loader.get_predefined_generators_from_dir("res://material_maker/plugins/voxel/nodes")
	graph = await mm_loader.create_gen({
		nodes=[
			{ name="Material", type="material_voxel" },
			{ name="In", type="voxel_inputs" }
		],
		connections=[
			{ from="In", from_port=5, to="Material", to_port=2 },
			{ from="In", from_port=1, to="Material", to_port=0 }
		]
	})
	add_child(graph)
	material = graph.get_node("Material")
	inputs = graph.get_node("In")

func after_each() -> void:
	graph.queue_free()

func all_code(sc) -> String:
	var s : String = sc.defs+"\n"+sc.code+"\n"
	for g in sc.globals:
		s += g.code+"\n"
	for k in sc.output_values.keys():
		s += str(sc.output_values[k])+"\n"
	return s

func test_input_names_in_material() -> void:
	var names : Array = []
	for i in material.get_input_defs():
		names.push_back(i.name)
	assert_eq(names, [ "albedo_tex", "metallic_tex", "roughness_tex", "emission_tex", "ao_tex", "opacity_tex", "bump_tex" ])

func test_inputs_node_uniforms() -> void:
	var sc = inputs.get_shader_code("uv", 2, MMGenContext.new())
	var found : bool = false
	for u in sc.uniforms:
		if u.name.begins_with("p_o") and u.name.ends_with("_vox_seed"):
			found = true
	assert_true(found, "vox_seed uniform: "+all_code(sc))

func test_inputs_node_outputs() -> void:
	var defs : Array = inputs.get_output_defs()
	assert_eq(defs.size(), 11)
	var sc = inputs.get_shader_code("uv", 1, MMGenContext.new())
	assert_string_contains(all_code(sc), "_controlled_variation_.x")
	assert_string_contains(all_code(sc), "mm_vox_normal")

func test_preview_shader() -> void:
	var template : String = material.process_conditionals(material.shader_model.preview_shader)
	var r : Dictionary = material.process_shader(template)
	var code : String = r.shader_code
	assert_string_contains(code, "_controlled_variation_ = vec4(")
	assert_string_contains(code, "mm_nb")
	assert_false(code.contains("$"), "unresolved $ in preview shader")
	# linear_albedo is false by default: the albedo is decoded
	assert_string_contains(code, "mm_alb = mm_vox_lin(mm_alb);")
	# the opacity input is not connected
	assert_false(code.contains("ALPHA"))

func test_hidden_outputs() -> void:
	assert_eq(material.get_output_defs(true).size(), 5)
	assert_eq(material.get_output_defs().size(), 0)
	for i in range(5):
		var sc = material.get_shader_code("uv", i, MMGenContext.new())
		assert_not_null(sc)
		assert_false(all_code(sc).contains("$"), "unresolved $ in output %d" % i)
	assert_string_contains(all_code(material.get_shader_code("uv", 0, MMGenContext.new())), "false ? ")
	assert_string_contains(all_code(material.get_shader_code("uv", 3, MMGenContext.new())), "_controlled_variation_.x")
