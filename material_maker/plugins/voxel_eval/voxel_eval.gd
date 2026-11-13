extends RefCounted
class_name MMVoxelEval


# Evaluates the outputs of a graph at arbitrary points of space: the points
# (and, for voxel materials, the normal and the "fresh" value of each point)
# are packed in float textures and read by a compute shader, in the same way
# as VolumeExport.render_volume samples a regular grid.
#
# Per point values (see design/zcity_plan.md, D1): the position is the tex3d
# coordinate, the normal is _controlled_variation_.xyz and fresh is
# _controlled_variation_.w. Seed, age, upkeep, char, wet, axis, origin and
# footprint are parameters of the Voxel Inputs nodes (see apply_params).


## Points are stored in rows of at most this width
const MAX_WIDTH : int = 2048
## The outputs of a Voxel Material (get_output_defs(true)) and their channels
const MATERIAL_OUTPUTS : Array[Dictionary] = [
	{ name="base_color", output=0, channels=3 },
	{ name="orm", output=1, channels=3 },
	{ name="emission", output=2, channels=3 },
	{ name="normal", output=3, channels=3 },
	{ name="opacity", output=4, channels=1 },
]
## Short names of the parameters of the Voxel Inputs nodes
const VOXEL_PARAMETERS : Array[String] = [ "seed", "age", "upkeep", "fresh", "char", "wet", "footprint", "axis_x", "axis_y", "axis_z", "origin_x", "origin_y", "origin_z" ]

## The error of the last failed call
static var last_error : String = ""


## Evaluates an output of a generator at N points. points holds 3N floats
## (x, y, z in metres), normals 3N floats (object space unit normals, empty
## for none) and fresh N floats (empty for 0). Returns 4N floats: the RGBA
## value of the output (a tex3d output has alpha 1, tex3d_gs outputs are
## repeated in r, g and b). Returns an empty array and sets last_error on
## failure. This is a coroutine.
static func evaluate(generator : MMGenBase, output_index : int, points : PackedFloat32Array, normals : PackedFloat32Array = PackedFloat32Array(), fresh : PackedFloat32Array = PackedFloat32Array()) -> PackedFloat32Array:
	last_error = ""
	var count : int = points.size()/3
	if points.size() % 3 != 0:
		last_error = "the points array must hold a multiple of 3 floats"
		return PackedFloat32Array()
	if count == 0:
		return PackedFloat32Array()
	if not normals.is_empty() and normals.size() != points.size():
		last_error = "there must be as many normals as points (%d), not %d" % [ count, normals.size()/3 ]
		return PackedFloat32Array()
	if not fresh.is_empty() and fresh.size() != count:
		last_error = "there must be as many fresh values as points (%d), not %d" % [ count, fresh.size() ]
		return PackedFloat32Array()
	var outputs : Array = generator.get_output_defs(true)
	if output_index < 0 or output_index >= outputs.size():
		last_error = "the node has no output %d" % output_index
		return PackedFloat32Array()
	var type : String = outputs[output_index].get("type", "")
	var position : String
	var value : String
	match type:
		"tex3d":
			position = "mm_eval_p(uv)"
			value = "vec4(%s, 1.0)"
		"tex3d_gs":
			position = "mm_eval_p(uv)"
			value = "vec4(vec3(%s), 1.0)"
		"sdf3d":
			position = "mm_eval_p(uv).xyz"
			value = "vec4(vec3(%s), 1.0)"
		"sdf3dc":
			position = "mm_eval_p(uv).xyz"
			value = "vec4((%s).xyy, 1.0)"
		"f", "sdf2d":
			position = "mm_eval_p(uv).xy"
			value = "vec4(vec3(%s), 1.0)"
		"rgb":
			position = "mm_eval_p(uv).xy"
			value = "vec4(%s, 1.0)"
		"rgba":
			position = "mm_eval_p(uv).xy"
			value = "%s"
		_:
			last_error = "outputs of type '%s' cannot be evaluated" % type
			return PackedFloat32Array()
	# Buffers used by the output must be rendered first
	var source : MMGenBase.ShaderCode = generator.get_shader_code(position, output_index, MMGenContext.new())
	await wait_for_buffers(generator, source)
	source = generator.get_shader_code(position, output_index, MMGenContext.new())
	if not source.output_values.has(type):
		last_error = "the output could not be generated"
		return PackedFloat32Array()
	value = value % source.output_values[type]
	# The points and normals, in RGBA32F images of width x height texels
	var width : int = mini(count, MAX_WIDTH)
	var height : int = (count+width-1)/width
	var point_data : PackedFloat32Array = PackedFloat32Array()
	point_data.resize(width*height*4)
	var normal_data : PackedFloat32Array = PackedFloat32Array()
	normal_data.resize(width*height*4)
	var has_normals : bool = not normals.is_empty()
	var has_fresh : bool = not fresh.is_empty()
	for i in count:
		var o : int = i*4
		var p : int = i*3
		point_data[o] = points[p]
		point_data[o+1] = points[p+1]
		point_data[o+2] = points[p+2]
		if has_fresh:
			point_data[o+3] = fresh[i]
		if has_normals:
			normal_data[o] = normals[p]
			normal_data[o+1] = normals[p+1]
			normal_data[o+2] = normals[p+2]
	var point_texture : MMTexture = MMTexture.from_image(Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, point_data.to_byte_array()))
	var normal_texture : MMTexture = MMTexture.from_image(Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, normal_data.to_byte_array()))
	# (texels are fetched exactly, whatever the sampler's filtering)
	source.defs = "\n".join([
		"ivec2 mm_eval_texel(vec2 uv) { return ivec2(floor(uv*vec2(%d.0, %d.0))); }" % [ width, height ],
		"vec4 mm_eval_p(vec2 uv) { return vec4(texelFetch(mm_eval_points, mm_eval_texel(uv), 0).xyz, 0.0); }",
		"" ])+source.defs
	source.code = "_controlled_variation_ = vec4(texelFetch(mm_eval_normals, mm_eval_texel(uv), 0).xyz, texelFetch(mm_eval_points, mm_eval_texel(uv), 0).w);\n"+source.code
	source.output_values = { rgba=value }
	source.output_type = "rgba"
	var extra : Array[Dictionary] = [
		{ name="mm_eval_points", type="sampler2D", value=point_texture },
		{ name="mm_eval_normals", type="sampler2D", value=normal_texture },
	]
	var compute : MMComputeShader = MMComputeShader.new()
	if not await compute.set_shader_from_shadercode(source, true, extra):
		last_error = "the shader could not be compiled"
		return PackedFloat32Array()
	var texture : MMTexture = MMTexture.new()
	if not await compute.render_ext([ texture ], Vector2i(width, height)):
		last_error = "the shader could not be run"
		return PackedFloat32Array()
	var image : Image = (await texture.get_texture()).get_image()
	if image.get_format() != Image.FORMAT_RGBAF:
		image.convert(Image.FORMAT_RGBAF)
	return image.get_data().to_float32_array().slice(0, count*4)

## Renders the buffers an output reads (and only these), as
## MMCliTools.render_output_texture does
static func wait_for_buffers(generator : MMGenBase, source : MMGenBase.ShaderCode) -> void:
	if not generator.is_inside_tree():
		return
	var buffer_names : Array = []
	for u in source.uniforms:
		if mm_deps.buffers.has(u.name):
			buffer_names.append(u.name)
	if buffer_names.is_empty():
		return
	mm_deps.set_render_only(buffer_names)
	await MMCliTools.wait_for_renders(generator.get_tree(), buffer_names)
	mm_deps.set_render_only([])

## Evaluates the five outputs of a Voxel Material node at N points (see
## evaluate). Returns { base_color : 3N floats (linear), orm : 3N (ambient
## occlusion, roughness, metallic), emission : 3N, normal : 3N (the bumped
## normal, in object space), opacity : N }, or an empty dictionary on failure.
static func evaluate_material(material : MMGenBase, points : PackedFloat32Array, normals : PackedFloat32Array = PackedFloat32Array(), fresh : PackedFloat32Array = PackedFloat32Array()) -> Dictionary:
	var rv : Dictionary = {}
	for o in MATERIAL_OUTPUTS:
		var rgba : PackedFloat32Array = await evaluate(material, o.output, points, normals, fresh)
		if rgba.is_empty() and points.size() > 0:
			return {}
		rv[o.name] = extract_channels(rgba, o.channels)
	return rv

## The first channels of an array of RGBA values
static func extract_channels(rgba : PackedFloat32Array, channels : int) -> PackedFloat32Array:
	if channels == 4:
		return rgba
	var count : int = rgba.size()/4
	var rv : PackedFloat32Array = PackedFloat32Array()
	rv.resize(count*channels)
	for i in count:
		for c in channels:
			rv[i*channels+c] = rgba[i*4+c]
	return rv

## The Voxel Material nodes of a graph
static func find_voxel_materials(graph : MMGenBase) -> Array:
	return MMCliTools.collect_generators(graph, func(g): return g.model == "material_voxel")

## Sets parameters before an evaluation: params maps names to values.
## Names are "node/path:parameter" (as for --set), the names or labels of the
## parameters of the graph's remote nodes, or short forms that set the
## parameter of every Voxel Inputs node: seed, age, upkeep, fresh, char, wet,
## footprint, axis_x, axis_y, axis_z, origin_x, origin_y, origin_z (with or
## without the vox_ prefix), and axis and origin that take 3 values. Returns
## the list of errors.
static func apply_params(graph : MMGenBase, params : Dictionary) -> PackedStringArray:
	var errors : PackedStringArray = PackedStringArray()
	var inputs : Array = MMCliTools.collect_generators(graph, func(g): return g.model == "voxel_inputs")
	for k : String in params.keys():
		var value = params[k]
		if value is String:
			value = MMCliTools.parse_value(value)
		elif value is Dictionary:
			value = MMType.deserialize_value(value)
		var short : String = k.trim_prefix("vox_") if not k.contains(":") else ""
		if short in [ "axis", "origin" ]:
			if not (value is Array and value.size() == 3):
				errors.append("'%s' needs 3 values" % k)
				continue
			if inputs.is_empty():
				errors.append("the graph has no Voxel Inputs node for '%s'" % k)
				continue
			for g in inputs:
				for c in 3:
					g.set_parameter("vox_%s_%s" % [ short, "xyz"[c] ], float(value[c]))
		elif short in VOXEL_PARAMETERS:
			if not (value is float or value is int or value is bool):
				errors.append("'%s' needs a number" % k)
				continue
			if inputs.is_empty():
				errors.append("the graph has no Voxel Inputs node for '%s'" % k)
				continue
			for g in inputs:
				g.set_parameter("vox_"+short, float(value))
		else:
			var error : String = MMCliTools.set_parameter_by_name(graph, k, value)
			if error != "":
				errors.append(error)
	return errors

## Reads the arrays of an evaluation: { points, normals, fresh } (packed float
## arrays, normals and fresh being empty when not given), or { error }.
## Points and normals are (N, 3) or flat arrays, fresh is (N) or (N, 1).
static func load_arrays(points_path : String, normals_path : String = "", fresh_path : String = "") -> Dictionary:
	var points : Dictionary = MMNpy.load(points_path)
	if points.has("error"):
		return points
	var shape : Array = points.shape
	if points.data.size() % 3 != 0 or (shape.size() == 2 and shape[1] != 3) or shape.size() > 2:
		return { error="the points must be an array of shape (N, 3), not %s" % str(shape) }
	var count : int = points.data.size()/3
	var rv : Dictionary = { points=points.data, normals=PackedFloat32Array(), fresh=PackedFloat32Array() }
	if normals_path != "":
		var normals : Dictionary = MMNpy.load(normals_path)
		if normals.has("error"):
			return normals
		if normals.data.size() != points.data.size() or normals.shape.size() > 2 or (normals.shape.size() == 2 and normals.shape[1] != 3):
			return { error="the normals must be an array of shape (%d, 3), not %s" % [ count, str(normals.shape) ] }
		rv.normals = normals.data
	if fresh_path != "":
		var fresh : Dictionary = MMNpy.load(fresh_path)
		if fresh.has("error"):
			return fresh
		if fresh.data.size() != count or fresh.shape.size() > 2 or (fresh.shape.size() == 2 and fresh.shape[1] != 1):
			return { error="the fresh values must be an array of shape (%d) or (%d, 1), not %s" % [ count, count, str(fresh.shape) ] }
		rv.fresh = fresh.data
	return rv

## Evaluates files for the command line mode and the RPC method. node is
## "node[:output]" (writes output, or output + ".npy", an array of shape
## (N, 4)), or empty to evaluate the Voxel Material of the graph (writes
## <output>_base_color.npy, _orm, _emission, _normal and _opacity, output
## being a prefix that may end with ".npy"). Returns { files : Array[String] },
## or { error }. This is a coroutine.
static func evaluate_files(graph : MMGenBase, points_path : String, normals_path : String, fresh_path : String, node : String, params : Dictionary, output : String) -> Dictionary:
	var arrays : Dictionary = load_arrays(points_path, normals_path, fresh_path)
	if arrays.has("error"):
		return arrays
	var errors : PackedStringArray = apply_params(graph, params)
	if not errors.is_empty():
		return { error="; ".join(errors) }
	var files : Array[String] = []
	var count : int = arrays.points.size()/3
	if node != "":
		var resolved : Dictionary = MMCliTools.resolve_node_output(graph, node)
		if resolved.has("error"):
			return resolved
		var rgba : PackedFloat32Array = await evaluate(resolved.generator, resolved.output, arrays.points, arrays.normals, arrays.fresh)
		if rgba.size() != count*4:
			return { error=last_error if last_error != "" else "the evaluation failed" }
		var file_name : String = output if output.get_extension().to_lower() == "npy" else output+".npy"
		var error : Error = MMNpy.save(file_name, [ count, 4 ], rgba)
		if error != OK:
			return { error="cannot write '%s' (%s)" % [ file_name, error_string(error) ] }
		files.append(file_name)
	else:
		var materials : Array = find_voxel_materials(graph)
		if materials.is_empty():
			return { error="the graph has no Voxel Material node (use --node to evaluate another output)" }
		var results : Dictionary = await evaluate_material(materials[0], arrays.points, arrays.normals, arrays.fresh)
		if results.is_empty():
			return { error=last_error if last_error != "" else "the evaluation failed" }
		var prefix : String = output.trim_suffix(".npy")
		for o in MATERIAL_OUTPUTS:
			var file_name : String = "%s_%s.npy" % [ prefix, o.name ]
			var shape : Array = [ count, o.channels ] if o.channels > 1 else [ count ]
			var error : Error = MMNpy.save(file_name, shape, results[o.name])
			if error != OK:
				return { error="cannot write '%s' (%s)" % [ file_name, error_string(error) ] }
			files.append(file_name)
	return { files=files }
