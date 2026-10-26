extends SceneTree

# Calibrates the cost model of automatic buffers against measured GPU times:
# - library shader nodes are rendered alone, and their time is compared to
#   their estimated cost (time per cost unit, and fixed time per pass)
# - a node sampling a buffer K times gives the time of a texture fetch
# Results are written as CSV lines prefixed with "CAL". Run with a window (not
# --headless), and fit the results with fit_costs.py:
#
#	godot --path . -s res://test/calibration/calibrate_costs.gd > calibration.log
#	python test/calibration/fit_costs.py calibration.log
#
# CAL_FETCH_ONLY=1 only measures texture fetches. Fetches use offsets spread
# over the image: use the results for up to 16 fetches (nearby texels).

const SIZES : Array[int] = [ 1024, 4096 ]
const REPEATS : int = 5

var shader_script = null

func _initialize():
	run.call_deferred()

func frames(n : int = 10) -> void:
	for i in n:
		await process_frame

## Median times (in microseconds) of rendering a shader code at SIZES
func time_shader_code(source) -> Array:
	var compute = load("res://addons/material_maker/engine/pipeline/compute_shader.gd").new()
	# Same conversion as MMGenBase.render_output_to_texture
	if source.output_type == "f":
		source.output_type = "rgba"
	if not source.output_values.has("rgba"):
		var types : Dictionary = root.get_node("mm_io_types").types
		var original_type : String = source.output_values.keys()[0]
		if not types.has(original_type):
			return []
		var preview_code : String = types[original_type].preview
		preview_code = preview_code.replace("uniform", "const").replace("const sampler2D", "uniform sampler2D").replace("preview_size", "64")
		preview_code = preview_code.replace("$(code)", source.code).replace("$(value)", source.output_values[original_type])
		source.defs += preview_code
		source.code = ""
		source.output_values.rgba = "preview_2d(uv)"
		source.output_type = "rgba"
	if not await compute.set_shader_from_shadercode(source, false):
		return []
	var texture = load("res://addons/material_maker/engine/pipeline/texture.gd").new()
	var textures : Array = Array([ texture ], TYPE_OBJECT, &"RefCounted", texture.get_script())
	var renderer = root.get_node("mm_renderer")
	var rv : Array = []
	for size in SIZES:
		var times : Array[float] = []
		for i in REPEATS:
			var t = await renderer.thread_run(func(c, tx, sz):
				var start : int = Time.get_ticks_usec()
				c.in_thread_render_ext(tx, Vector2i(sz, sz))
				return Time.get_ticks_usec()-start, [ compute, textures, size ])
			if t is int:
				times.append(float(t))
		times.sort()
		if times.is_empty():
			return []
		rv.append(times[times.size()/2])
	return rv

func run():
	await frames(30)
	var loader = root.get_node("mm_loader")
	var shader_class = load("res://addons/material_maker/engine/nodes/gen_shader.gd")
	var context_class = load("res://addons/material_maker/engine/nodes/gen_context.gd") if ResourceLoader.exists("res://addons/material_maker/engine/nodes/gen_context.gd") else null
	var graph = await loader.create_gen({ nodes=[], connections=[] })
	root.add_child(graph)
	# 1. Library shader nodes, alone
	var library : Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://material_maker/library/base.json"))
	var count : int = 0
	for item in ([] if OS.get_environment("CAL_FETCH_ONLY") != "" else library.lib):
		if not item.has("type") or item.type in [ "material", "buffer", "iterate_buffer", "image", "text", "svg" ]:
			continue
		var data : Dictionary = item.duplicate(true)
		data.name = "n%d" % count
		var gen = await loader.create_gen(data)
		if gen == null or not gen.get_script() == shader_class or gen.get_output_defs().is_empty():
			if gen != null:
				gen.free()
			continue
		graph.add_generator(gen)
		var cost : float = shader_class.estimate_cost(gen.OutputPort.new(gen, 0), {})
		var source = gen.get_shader_code("uv", 0, MMGenContext.new())
		if not source.output_type in [ "f", "rgb", "rgba" ]:
			graph.remove_child(gen)
			gen.free()
			continue
		var t : Array = await time_shader_code(source)
		if t.size() == 2:
			print("CAL,node,%s,%f,%f,%f" % [ item.tree_item, cost, t[0], t[1] ])
		graph.remove_child(gen)
		gen.free()
		count += 1
		if count >= 130:
			break
	# 2. Texture fetches: a buffer sampled K times
	var buffer = await loader.create_gen({ name="buf", type="buffer", version=2, parameters={ size=11 } })
	graph.add_generator(buffer)
	var noise = await loader.create_gen({ name="noise", type="fbm2" })
	if noise == null:
		noise = await loader.create_gen({ name="noise", type="perlin" })
	graph.add_generator(noise)
	graph.connect_children(noise, 0, buffer, 0)
	await frames(60)
	for k in [ 1, 4, 16, 64, 128 ]:
		var sampler = shader_class.new()
		sampler.name = "sampler%d" % k
		sampler.set_shader_model({
			inputs=[ { name="in", type="rgba", function=true, default="vec4(0.0)" } ],
			outputs=[ { rgba="$(name)_fetch($uv)", type="rgba" } ],
			instance=("vec4 $(name)_fetch(vec2 uv) {\nvec4 s = vec4(0.0);\nfor (int i = 0; i < %d; ++i) {\nvec2 p = fract(uv+vec2(float(i)*0.0137, float(i)*0.0071));\ns += $in(p);\n}\nreturn s/%d.0;\n}") % [ k, k ],
			parameters=[], code=""
		})
		graph.add_generator(sampler)
		graph.connect_children(buffer, 0, sampler, 0)
		await frames(10)
		var t : Array = await time_shader_code(sampler.get_shader_code("uv", 0, MMGenContext.new()))
		if t.size() == 2:
			print("CAL,fetch,%d,%f,%f" % [ k, t[0], t[1] ])
	print("CAL,done")
	quit()
