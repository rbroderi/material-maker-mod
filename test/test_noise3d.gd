extends GutTest

# Tests of the seeded 3D noise nodes and of the 3D gradient node (design/zcity_plan.md, WP2)

const M32 : int = 0xFFFFFFFF
const NODE_TYPES : Array[String] = [
	"tex3d_noise_value", "tex3d_noise_perlin", "tex3d_noise_fbm", "tex3d_noise_voronoi", "tex3d_domain_warp", "tex3d_gradient"
]
const FORBIDDEN : String = "\\b(mat[234]|uvec[234]|lessThan|dFdx)\\b"

var graph : MMGenGraph

func after_each() -> void:
	if graph != null:
		graph.free()
		graph = null

# ---- GDScript port of voxkit's hash, value noise and fbm (64-bit ints masked to 32 bits)

static func hash_u(x : int, y : int, z : int, s : int) -> int:
	var h : int = ((x & M32)*374761393) & M32
	h = (h + (((y & M32)*668265263) & M32)) & M32
	h = (h + (((z & M32)*2147483629) & M32)) & M32
	h = (h + (((s & M32)*974711) & M32)) & M32
	h = ((h ^ (h >> 13))*1274126177) & M32
	h = ((h ^ (h >> 16))*374761393) & M32
	return h ^ (h >> 15)

static func hash3(x : int, y : int, z : int, s : int) -> float:
	return float(hash_u(x, y, z, s))/4294967296.0

static func wrap_index(i : int, period : int) -> int:
	return i if period <= 0 else posmod(i, period)

static func value_noise(p : Vector3, s : int, period : int = 0) -> float:
	var c : Vector3 = p.floor()
	var f : Vector3 = p-c
	f = f*f*(Vector3(3, 3, 3)-2.0*f)
	var x0 : int = int(c.x)
	var y0 : int = int(c.y)
	var z0 : int = int(c.z)
	var rv : float = 0.0
	for dx in 2:
		var wx : float = f.x if dx == 1 else 1.0-f.x
		for dy in 2:
			var wy : float = f.y if dy == 1 else 1.0-f.y
			for dz in 2:
				var wz : float = f.z if dz == 1 else 1.0-f.z
				rv += hash3(wrap_index(x0+dx, period), wrap_index(y0+dy, period), wrap_index(z0+dz, period), s)*wx*wy*wz
	return rv

static func fbm_noise(p : Vector3, s : int, octaves : int, gain : float, lacunarity : float = 2.03) -> float:
	var total : float = 0.0
	var amp : float = 1.0
	var norm : float = 0.0
	var f : float = 1.0
	for o in octaves:
		total += value_noise(p*f, s+101*o)*amp
		norm += amp
		amp *= gain
		f *= lacunarity
	return total/norm

# Points tested on the GPU: coordinates are multiples of 1/(64*divisor), negative ones included,
# and one point out of two is within 1e-4 of a lattice plane
const POINT_FUNCTION : String = """vec4 mm_pts(vec2 uv) {
	int idx = int(floor(uv.y*64.0))*64+int(floor(uv.x*64.0));
	int a = idx*37+11;
	int b = idx*91+13;
	int c = idx*173+7;
	int ix = a-4096*(a/4096)-2048;
	int iy = b-4096*(b/4096)-2048;
	int iz = c-4096*(c/4096)-2048;
	vec3 p = vec3(float(ix), float(iy), float(iz))/(64.0*%s);
	int m = idx-4*(idx/4);
	if (m == 0) {
		p = floor(p+0.5)+vec3(0.0001220703125);
	}
	if (m == 1) {
		p = floor(p+0.5)-vec3(0.0001220703125);
	}
	return vec4(p, 0.0);
}
"""

static func point_at(idx : int, divisor : float) -> Vector3:
	var ix : int = (idx*37+11) % 4096-2048
	var iy : int = (idx*91+13) % 4096-2048
	var iz : int = (idx*173+7) % 4096-2048
	var p : Vector3 = Vector3(ix, iy, iz)/(64.0*divisor)
	match idx % 4:
		0:
			p = (p+Vector3(0.5, 0.5, 0.5)).floor()+Vector3(1, 1, 1)*0.0001220703125
		1:
			p = (p+Vector3(0.5, 0.5, 0.5)).floor()-Vector3(1, 1, 1)*0.0001220703125
	return p

# ---- helpers

func make_graph(nodes : Array, connections : Array = []) -> void:
	graph = await mm_loader.create_gen({ nodes=nodes, connections=connections })
	add_child(graph)

func make_node(type : String, parameters : Dictionary = {}) -> MMGenBase:
	await make_graph([ { name="n", type=type, parameters=parameters } ])
	return graph.get_node("n")

func all_text(source : MMGenBase.ShaderCode) -> String:
	var rv : String = source.defs+source.code+source.get_globals_string()
	for k in source.output_values.keys():
		rv += str(source.output_values[k])
	return rv

# Renders an output of a generator at the 4096 test points (64x64 pixels) and returns the image
func render_points(gen : MMGenBase, output_index : int, divisor : float = 1.0) -> Image:
	var type : String = gen.get_output_defs()[output_index].type
	var source : MMGenBase.ShaderCode = gen.get_shader_code("mm_pts(uv)", output_index, MMGenContext.new())
	var value : String = source.output_values[type]
	match type:
		"tex3d":
			value = "vec4(%s, 1.0)" % value
		_:
			value = "vec4(vec3(%s), 1.0)" % value
	source.defs = (POINT_FUNCTION % ("%f" % divisor))+source.defs
	source.output_values = { rgba=value }
	source.output_type = "rgba"
	var compute : MMComputeShader = MMComputeShader.new()
	if not await compute.set_shader_from_shadercode(source, true):
		return null
	var texture : MMTexture = MMTexture.new()
	if not await compute.render_ext([ texture ], Vector2i(64, 64)):
		return null
	var image : Image = (await texture.get_texture()).get_image()
	if image.get_format() != Image.FORMAT_RGBAF:
		image.convert(Image.FORMAT_RGBAF)
	return image

func gpu_available() -> bool:
	return RenderingServer.get_rendering_device() != null

# ---- port against voxkit reference values (computed with ZCity/Tools/voxkit/noise.py)

func test_port_matches_voxkit() -> void:
	assert_eq(hash3(0, 0, 0, 0), 0.0)
	assert_almost_eq(hash3(3, -5, 7, 1), 0.4510839879512787, 1e-7)
	assert_almost_eq(hash3(-100, 200, -300, 12345), 0.5639797449111938, 1e-7)
	assert_almost_eq(hash3(5, 6, 7, 16777215), 0.3259371817111969, 1e-7)
	assert_almost_eq(value_noise(Vector3(0.3, -1.7, 2.2), 0), 0.4030616581439972, 1e-6)
	assert_almost_eq(value_noise(Vector3(12.25, -0.5, 3.75), 1), 0.4326256215572357, 1e-6)
	assert_almost_eq(value_noise(Vector3(-40.1, 9.9, 0.01), 12345), 0.24739059805870056, 1e-6)
	assert_almost_eq(value_noise(Vector3(100.5, -200.25, 300.125), 16777215), 0.4990517497062683, 1e-6)
	assert_almost_eq(fbm_noise(Vector3(0.3, -1.7, 2.2), 0, 3, 0.5), 0.36861756443977356, 1e-6)
	assert_almost_eq(fbm_noise(Vector3(12.25, -0.5, 3.75), 7, 3, 0.5), 0.5283356308937073, 1e-6)

# ---- headless: instantiation and generated code

func test_nodes_instantiate() -> void:
	for t in NODE_TYPES:
		var gen : MMGenBase = await make_node(t)
		assert_not_null(gen, t)
		if gen != null:
			assert_gt(gen.get_output_defs().size(), 0, t)
		graph.free()
		graph = null

func test_generated_code() -> void:
	var regex : RegEx = RegEx.new()
	regex.compile(FORBIDDEN)
	for t in NODE_TYPES:
		if t == "tex3d_gradient":
			# The gradient of a noise: the noise functions are in the generated code
			await make_graph([ { name="f", type="tex3d_noise_fbm", parameters={ basis=1 } }, { name="n", type=t, parameters={ mode=1 } } ],
					[ { from="f", from_port=0, to="n", to_port=0 } ])
		else:
			await make_graph([ { name="n", type=t, parameters={ basis=1 } if t == "tex3d_noise_fbm" else {} } ])
		var gen : MMGenBase = graph.get_node("n")
		for i in gen.get_output_defs().size():
			var source : MMGenBase.ShaderCode = gen.get_shader_code("vec4(0.0)", i, MMGenContext.new())
			var text : String = all_text(source)
			assert_eq(text.find("$"), -1, "%s output %d has a $ left" % [ t, i ])
			assert_null(regex.search(text), "%s output %d has code outside of the HLSL safe subset" % [ t, i ])
			var globals : String = source.get_globals_string()
			assert_true(globals.find("mm_n3_hash_u") != -1, "%s output %d has the hash" % [ t, i ])
		graph.free()
		graph = null

func test_all_functions_are_hlsl_safe() -> void:
	var regex : RegEx = RegEx.new()
	regex.compile(FORBIDDEN)
	var globals : String = mm_loader.get_predefined_global("mm_noise3d")
	assert_ne(globals, "")
	assert_null(regex.search(globals))
	for bad in [ "vec2", "mat2", "mix" ]:
		# New identifiers must not contain the words the translator replaces
		for m in RegEx.create_from_string("\\b(\\w*mm_n3_\\w*)\\b").search_all(globals):
			assert_eq(m.get_string().find(bad), -1, "identifier %s contains %s" % [ m.get_string(), bad ])

# ---- GPU

func test_value_noise_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	for seed_value in [ 0, 1, 12345, 16777215 ]:
		var gen : MMGenBase = await make_node("tex3d_noise_value", { scale_x=1, scale_y=1, scale_z=1 })
		gen.set_parameter("seed_offset", float(seed_value))
		var image : Image = await render_points(gen, 0)
		assert_not_null(image)
		if image == null:
			return
		var max_diff : float = 0.0
		for idx in 4096:
			var expected : float = value_noise(point_at(idx, 1.0), seed_value)
			max_diff = maxf(max_diff, absf(image.get_pixel(idx % 64, idx/64).r-expected))
		assert_lt(max_diff, 1e-5, "value noise, seed %d" % seed_value)
		graph.free()
		graph = null

func test_fbm_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	var gen : MMGenBase = await make_node("tex3d_noise_fbm", { scale_x=1, scale_y=1, scale_z=1, octaves=3, gain=0.5, lacunarity=2.03 })
	gen.set_parameter("seed_offset", 12345.0)
	var image : Image = await render_points(gen, 0, 8.0)
	assert_not_null(image)
	if image == null:
		return
	var max_diff : float = 0.0
	for idx in 4096:
		var expected : float = fbm_noise(point_at(idx, 8.0), 12345, 3, 0.5)
		max_diff = maxf(max_diff, absf(image.get_pixel(idx % 64, idx/64).r-expected))
	assert_lt(max_diff, 1e-4, "fbm")

func test_period_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	# With scale 4 and period 4, moving by one metre (4 cells) along x gives the same values
	var params : Dictionary = { scale_x=4, scale_y=4, scale_z=4, period=4 }
	var gen : MMGenBase = await make_node("tex3d_noise_value", params)
	var a : Image = await render_points(gen, 0, 8.0)
	gen.set_parameter("offset_x", 4.0)
	var b : Image = await render_points(gen, 0, 8.0)
	assert_not_null(a)
	assert_not_null(b)
	if a == null or b == null:
		return
	var max_diff : float = 0.0
	for idx in 4096:
		max_diff = maxf(max_diff, absf(a.get_pixel(idx % 64, idx/64).r-b.get_pixel(idx % 64, idx/64).r))
	assert_lt(max_diff, 1e-6, "period")
	# And it matches the periodic port
	var port_diff : float = 0.0
	for idx in 4096:
		var p : Vector3 = point_at(idx, 8.0)*4.0
		port_diff = maxf(port_diff, absf(a.get_pixel(idx % 64, idx/64).r-value_noise(p, 0, 4)))
	assert_lt(port_diff, 1e-5, "periodic port")

func test_gradient_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	var eps : float = 0.01
	await make_graph([
		{ name="f", type="tex3d_noise_fbm", parameters={ scale_x=4, scale_y=4, scale_z=4, octaves=2, gain=0.5, lacunarity=2.03, seed_offset=5 } },
		{ name="n", type="tex3d_gradient", parameters={ eps=eps, strength=1.0, mode=0 } } ],
		[ { from="f", from_port=0, to="n", to_port=0 } ])
	var gen : MMGenBase = graph.get_node("n")
	var image : Image = await render_points(gen, 0, 32.0)
	assert_not_null(image)
	if image == null:
		return
	var e32 : float = PackedFloat32Array([ eps ])[0]
	var max_diff : float = 0.0
	for idx in 4096:
		var p : Vector3 = point_at(idx, 32.0)
		var h0 : float = fbm_noise(p*4.0, 5, 2, 0.5)
		var expected : Vector3 = Vector3(
			fbm_noise((p+Vector3(e32, 0, 0))*4.0, 5, 2, 0.5)-h0,
			fbm_noise((p+Vector3(0, e32, 0))*4.0, 5, 2, 0.5)-h0,
			fbm_noise((p+Vector3(0, 0, e32))*4.0, 5, 2, 0.5)-h0)/e32
		var c : Color = image.get_pixel(idx % 64, idx/64)
		var d : Vector3 = (Vector3(c.r, c.g, c.b)-expected).abs()
		max_diff = maxf(max_diff, maxf(d.x, maxf(d.y, d.z)))
	assert_lt(max_diff, 1e-3, "gradient of fbm")

func test_all_outputs_compile_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	for type in NODE_TYPES:
		await make_graph([ { name="n", type=type, parameters={} } ])
		var gen : MMGenBase = graph.get_node("n")
		for i in gen.get_output_defs().size():
			var image : Image = await render_points(gen, i)
			assert_not_null(image, "%s output %d compiles" % [ type, i ])
			if image != null:
				for idx in [ 0, 1, 2, 3, 100, 4095 ]:
					var c : Color = image.get_pixel(idx % 64, idx/64)
					assert_true(is_finite(c.r) and is_finite(c.g) and is_finite(c.b), "%s output %d is finite" % [ type, i ])
		graph.free()
		graph = null
