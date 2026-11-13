extends RefCounted


# Bakes the Voxel Material of a graph to the 2D textures of a mesh: the
# position and normal maps of the mesh are baked with the map generator (the
# position map holds (position-aabb.position)/aabb.size, see
# position_vertex.tres), then each texel's position and normal are fed to the
# Voxel Material outputs, as MMVoxelEval does for arrays of points.


const DEFAULT_SIZE : int = 1024
## Texels around the islands that are baked (the others are transparent)
const DILATION : int = 4
const FORMATS : Array[String] = [ "png", "exr" ]
## Files written: suffix, Voxel Material output (MMVoxelEval.MATERIAL_OUTPUTS),
## and how the values are encoded in 8 bit images
const MAPS : Array[Dictionary] = [
	{ suffix="basecolor", name="base_color", encoding="srgb" },
	{ suffix="orm", name="orm", encoding="linear" },
	{ suffix="normal_object", name="normal", encoding="normal" },
	{ suffix="emission", name="emission", encoding="srgb" },
	{ suffix="opacity", name="opacity", encoding="linear" },
]

## The error of the last failed call
static var last_error : String = ""


## Evaluates an output of a generator at the texels of two maps of size x size
## texels: position_tex, whose RGB is mapped to the position in metres by
## position*position_scale+position_offset, and normal_tex, whose RGB is an
## object space normal encoded as 0.5+0.5*n. Returns the size*size RGBA values
## of the output (see MMVoxelEval.evaluate), or an empty array and sets
## last_error. This is a coroutine.
static func evaluate_textures(generator : MMGenBase, output_index : int, position_tex : MMTexture, normal_tex : MMTexture, size : int, position_scale : Vector3 = Vector3.ONE, position_offset : Vector3 = Vector3.ZERO) -> PackedFloat32Array:
	last_error = ""
	var outputs : Array = generator.get_output_defs(true)
	if output_index < 0 or output_index >= outputs.size():
		last_error = "the node has no output %d" % output_index
		return PackedFloat32Array()
	var type : String = outputs[output_index].get("type", "")
	var position : String
	var value : String
	match type:
		"tex3d":
			position = "mm_bake_p(uv)"
			value = "vec4(%s, 1.0)"
		"tex3d_gs":
			position = "mm_bake_p(uv)"
			value = "vec4(vec3(%s), 1.0)"
		"sdf3d":
			position = "mm_bake_p(uv).xyz"
			value = "vec4(vec3(%s), 1.0)"
		"sdf3dc":
			position = "mm_bake_p(uv).xyz"
			value = "vec4((%s).xyy, 1.0)"
		"f", "sdf2d":
			position = "mm_bake_p(uv).xy"
			value = "vec4(vec3(%s), 1.0)"
		"rgb":
			position = "mm_bake_p(uv).xy"
			value = "vec4(%s, 1.0)"
		"rgba":
			position = "mm_bake_p(uv).xy"
			value = "%s"
		_:
			last_error = "outputs of type '%s' cannot be evaluated" % type
			return PackedFloat32Array()
	# Buffers used by the output must be rendered first
	var source : MMGenBase.ShaderCode = generator.get_shader_code(position, output_index, MMGenContext.new())
	await MMVoxelEval.wait_for_buffers(generator, source)
	source = generator.get_shader_code(position, output_index, MMGenContext.new())
	if not source.output_values.has(type):
		last_error = "the output could not be generated"
		return PackedFloat32Array()
	value = value % source.output_values[type]
	# (texels are fetched exactly, whatever the sampler's filtering)
	source.defs = "\n".join([
		"ivec2 mm_bake_texel(vec2 uv) { return ivec2(floor(uv*vec2(%d.0, %d.0))); }" % [ size, size ],
		"vec4 mm_bake_p(vec2 uv) { return vec4(texelFetch(mm_bake_positions, mm_bake_texel(uv), 0).xyz*vec3(%.9f, %.9f, %.9f)+vec3(%.9f, %.9f, %.9f), 0.0); }" % [ position_scale.x, position_scale.y, position_scale.z, position_offset.x, position_offset.y, position_offset.z ],
		"" ])+source.defs
	source.code = "_controlled_variation_ = vec4(normalize(texelFetch(mm_bake_normals, mm_bake_texel(uv), 0).xyz*2.0-vec3(1.0)), 0.0);\n"+source.code
	source.output_values = { rgba=value }
	source.output_type = "rgba"
	var extra : Array[Dictionary] = [
		{ name="mm_bake_positions", type="sampler2D", value=position_tex },
		{ name="mm_bake_normals", type="sampler2D", value=normal_tex },
	]
	var compute : MMComputeShader = MMComputeShader.new()
	if not await compute.set_shader_from_shadercode(source, true, extra):
		last_error = "the shader could not be compiled"
		return PackedFloat32Array()
	var texture : MMTexture = MMTexture.new()
	if not await compute.render_ext([ texture ], Vector2i(size, size)):
		last_error = "the shader could not be run"
		return PackedFloat32Array()
	var image : Image = (await texture.get_texture()).get_image()
	if image.get_format() != Image.FORMAT_RGBAF:
		image.convert(Image.FORMAT_RGBAF)
	return image.get_data().to_float32_array().slice(0, size*size*4)

## A map of the map generator as an RGBAF image
static func map_image(texture : MMTexture) -> Image:
	var image : Image = (await texture.get_texture()).get_image()
	if image.get_format() != Image.FORMAT_RGBAF:
		image.convert(Image.FORMAT_RGBAF)
	return image

## Bakes the maps of a Voxel Material of the graph to <prefix>_basecolor,
## _orm, _normal_object, _emission and _opacity (.png, or .exr that keeps
## the linear values; normals are 0.5+0.5*n in both). Texels outside the UV
## islands (extended by DILATION texels) are transparent. unit_scale is the number of
## metres of a mesh unit. Returns { files : Array[String], position_scale,
## position_offset } or { error }. This is a coroutine.
static func bake(graph : MMGenBase, mesh : Mesh, size : int, prefix : String, unit_scale : float = 1.0, format : String = "png") -> Dictionary:
	if not format in FORMATS:
		return { error="unknown format '%s' (formats: %s)" % [ format, ", ".join(FORMATS) ] }
	var materials : Array = MMVoxelEval.find_voxel_materials(graph)
	if materials.is_empty():
		return { error="the graph has no Voxel Material node" }
	if mesh == null or size <= 0:
		return { error="no mesh or incorrect size" }
	var single : Mesh = MMMapGenerator.get_single_surface_mesh(mesh)
	if single.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV] == null:
		return { error="the mesh has no UVs" }
	# The maps are baked once per mesh and size (the position map holds the
	# position relative to the bounding box of the mesh)
	var position_map : MMTexture = await MMMapGenerator.get_map(mesh, "position", size)
	var normal_map : MMTexture = await MMMapGenerator.get_map(mesh, "normal", size)
	var position_image : Image = await map_image(position_map)
	var normal_image : Image = await map_image(normal_map)
	if position_image.get_width() != size or normal_image.get_width() != size:
		return { error="the position and normal maps could not be baked" }
	var aabb : AABB = single.get_aabb()
	var position_scale : Vector3 = aabb.size*unit_scale
	var position_offset : Vector3 = aabb.position*unit_scale
	# (the maps are copied so that they keep their full precision)
	var position_tex : MMTexture = MMTexture.from_image(position_image)
	var normal_tex : MMTexture = MMTexture.from_image(normal_image)
	var count : int = size*size
	var mask : PackedByteArray = island_mask(single, size, DILATION)
	var results : Dictionary = {}
	for o in MMVoxelEval.MATERIAL_OUTPUTS:
		var rgba : PackedFloat32Array = await evaluate_textures(materials[0], o.output, position_tex, normal_tex, size, position_scale, position_offset)
		if rgba.size() != count*4:
			return { error=last_error if last_error != "" else "the evaluation failed" }
		results[o.name] = rgba
	var files : Array[String] = []
	for m in MAPS:
		var file_name : String = "%s_%s.%s" % [ prefix, m.suffix, format ]
		var image : Image = make_image(results[m.name], mask, size, m.encoding, format == "exr", MMVoxelEval.MATERIAL_OUTPUTS.filter(func(o): return o.name == m.name)[0].channels)
		var error : Error = image.save_exr(file_name) if format == "exr" else image.save_png(file_name)
		if error != OK:
			return { error="cannot write '%s' (%s)" % [ file_name, error_string(error) ] }
		files.append(file_name)
	return { files=files, position_scale=position_scale, position_offset=position_offset }

## The texels covered by the UV triangles of a mesh (255, else 0), extended by
## dilation texels. The map generator already extends the islands (its maps
## hold valid values around them), so the extended texels are baked.
static func island_mask(mesh : Mesh, size : int, dilation : int) -> PackedByteArray:
	var mask : PackedByteArray = PackedByteArray()
	mask.resize(size*size)
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays : Array = mesh.surface_get_arrays(s)
		var uvs : PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var indices : PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(uvs.size()))
		for t in indices.size()/3:
			var a : Vector2 = uvs[indices[3*t]]*size
			var b : Vector2 = uvs[indices[3*t+1]]*size
			var c : Vector2 = uvs[indices[3*t+2]]*size
			var area : float = (b-a).cross(c-a)
			if absf(area) < 1e-9:
				continue
			# (a texel is covered when its center is in the triangle, with a
			# small tolerance for texels on the edges)
			var min_x : int = maxi(0, int(floor(minf(a.x, minf(b.x, c.x)))))
			var max_x : int = mini(size-1, int(ceil(maxf(a.x, maxf(b.x, c.x)))))
			var min_y : int = maxi(0, int(floor(minf(a.y, minf(b.y, c.y)))))
			var max_y : int = mini(size-1, int(ceil(maxf(a.y, maxf(b.y, c.y)))))
			for y in range(min_y, max_y+1):
				for x in range(min_x, max_x+1):
					var p : Vector2 = Vector2(x+0.5, y+0.5)
					var w0 : float = (b-p).cross(c-p)/area
					var w1 : float = (c-p).cross(a-p)/area
					var w2 : float = 1.0-w0-w1
					if w0 >= -1e-4 and w1 >= -1e-4 and w2 >= -1e-4:
						mask[y*size+x] = 255
	if dilation > 0:
		# (a square of 2*dilation+1 texels, in two passes)
		for vertical in [ false, true ]:
			var source : PackedByteArray = mask.duplicate()
			var step : int = size if vertical else 1
			for y in size:
				for x in size:
					var i : int = y*size+x
					if source[i] != 0:
						continue
					var position : int = y if vertical else x
					for k in range(maxi(0, position-dilation), mini(size-1, position+dilation)+1):
						if source[i+(k-position)*step] != 0:
							mask[i] = 255
							break
	return mask

static func srgb(v : float) -> float:
	v = clampf(v, 0.0, 1.0)
	return v*12.92 if v <= 0.0031308 else 1.055*pow(v, 1.0/2.4)-0.055

## An image from RGBA float values, with the alpha channel from mask. Images
## are encoded for 8 bit files (encoding is "srgb", "linear" or "normal");
## channels is the number of meaningful channels (1 is repeated in R, G, B).
static func make_image(rgba : PackedFloat32Array, mask : PackedByteArray, size : int, encoding : String, float_image : bool, channels : int) -> Image:
	var count : int = size*size
	if float_image:
		var data : PackedFloat32Array = PackedFloat32Array()
		data.resize(count*4)
		for i in count:
			for c in 3:
				var v : float = rgba[4*i+c]
				data[4*i+c] = 0.5+0.5*v if encoding == "normal" else v
			data[4*i+3] = mask[i]/255.0
		return Image.create_from_data(size, size, false, Image.FORMAT_RGBAF, data.to_byte_array())
	var bytes : PackedByteArray = PackedByteArray()
	bytes.resize(count*4)
	for i in count:
		for c in 3:
			var v : float = rgba[4*i+c]
			match encoding:
				"srgb":
					v = srgb(v)
				"normal":
					v = 0.5+0.5*v
			bytes[4*i+c] = int(clampf(v, 0.0, 1.0)*255.0+0.5)
		bytes[4*i+3] = mask[i]
	return Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, bytes)
