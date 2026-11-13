extends GutTest

const ParamSchema = preload("res://material_maker/plugins/param_schema/param_schema.gd")

var graph : MMGenGraph

func before_each() -> void:
	graph = await mm_loader.create_gen({
		nodes=[
			{ name="perlin", type="perlin", parameters={ scale_x=6, scale_y=4, iterations=3, persistence=0.5 } },
			{ name="remote", type="remote", parameters={ param0=8 },
				widgets=[ { name="param0", label="Scale", type="linked_control", linked_widgets=[ { node="perlin", widget="scale_x" } ] } ] },
			{ name="Material", type="material", parameters={ size=10 } },
		],
		connections=[ { from="perlin", from_port=0, to="Material", to_port=0 } ]
	})
	add_child(graph)

func after_each() -> void:
	graph.queue_free()

func find_by(list : Array, key : String, value) -> Dictionary:
	for e in list:
		if e.get(key) == value:
			return e
	return {}

func test_header_and_material() -> void:
	var s : Dictionary = ParamSchema.build(graph)
	assert_eq(s.format, "mm-param-schema")
	assert_eq(s.version, 1)
	assert_eq(s.material.type, "material")
	assert_gt(s.material.inputs.size(), 0)
	assert_true(s.material.inputs[0].connected)
	assert_eq(s.voxel_inputs, [])

func test_parameters() -> void:
	var s : Dictionary = ParamSchema.build(graph)
	var scale_x : Dictionary
	for p in s.parameters:
		if p.node == "perlin" and p.name == "scale_x":
			scale_x = p
	assert_false(scale_x.is_empty())
	assert_eq(scale_x.node_type, "perlin")
	assert_eq(scale_x.type, "float")
	assert_eq(scale_x.value, 8) # the remote sets it
	assert_true(scale_x.has("min") and scale_x.has("max") and scale_x.has("default"))
	assert_lt(scale_x.min, scale_x.max)

func test_remote() -> void:
	var s : Dictionary = ParamSchema.build(graph)
	assert_eq(s.remotes.size(), 1)
	var r : Dictionary = s.remotes[0]
	assert_eq(r.name, "param0")
	assert_eq(r.label, "Scale")
	assert_eq(r.linked, ["perlin:scale_x"])
	assert_eq(r.type, "float")
	assert_eq(r.value, 8)
	assert_true(r.has("min") and r.has("max"))

func test_deterministic_and_valid_json() -> void:
	var a : String = ParamSchema.to_json(ParamSchema.build(graph))
	var b : String = ParamSchema.to_json(ParamSchema.build(graph))
	assert_eq(a, b)
	var parsed = JSON.parse_string(a)
	assert_true(parsed is Dictionary)
	assert_eq(parsed.format, "mm-param-schema")

func test_colors_are_arrays() -> void:
	assert_eq(ParamSchema.convert_value(Color(0.1, 0.2, 0.3, 0.4)).size(), 4)
