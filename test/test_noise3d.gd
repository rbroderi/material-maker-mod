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

static func mix32(x : int) -> int:
	x &= M32
	x ^= x >> 16
	x = (x*0x7FEB352D) & M32
	x ^= x >> 15
	x = (x*0x846CA68B) & M32
	x ^= x >> 16
	return x

static func salt(seed_value : int, n : int) -> int:
	return mix32(mix32(seed_value)+((n*0x9E3779B9) & M32))

static func hash_u(x : int, y : int, z : int, s : int) -> int:
	var h : int = ((x & M32)*374761393) & M32
	h = (h + (((y & M32)*668265263) & M32)) & M32
	h = (h + (((z & M32)*2147483629) & M32)) & M32
	h = (h + mix32(s)) & M32
	return mix32(h)

static func hash3(x : int, y : int, z : int, s : int) -> float:
	return float(hash_u(x, y, z, s) >> 8)*(1.0/16777216.0)

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
		total += value_noise(p*f, salt(s, 0x40000000+o))*amp
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
func render_points(gen : MMGenBase, output_index : int, divisor : float = 1.0, offset : Vector3 = Vector3.ZERO) -> Image:
	var type : String = gen.get_output_defs()[output_index].type
	var uv : String = "mm_pts(uv)"
	if offset != Vector3.ZERO:
		uv = "(mm_pts(uv)+vec4(%f, %f, %f, 0.0))" % [ offset.x, offset.y, offset.z ]
	var source : MMGenBase.ShaderCode = gen.get_shader_code(uv, output_index, MMGenContext.new())
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
	assert_eq(mix32(0), 0x0)
	assert_eq(mix32(1), 0x688990c0)
	assert_eq(mix32(0xdeadbeef), 0xe628c683)
	assert_eq(salt(0, 1), 0x01fce552)
	assert_eq(salt(1, 0), 0x58f54975)
	assert_eq(salt(7, 0x40000000), 0xbe33ce9c)
	assert_eq(salt(123, 22), 0x96c9dd16)
	assert_almost_eq(hash3(3, -5, 7, 1), 0.9888354539871216, 1e-7)
	assert_almost_eq(hash3(-100, 200, -300, 12345), 0.27760225534439087, 1e-7)
	assert_almost_eq(hash3(5, 6, 7, 16777215), 0.9652769565582275, 1e-7)
	assert_almost_eq(hash3(0, 0, 0, 1), 0.3474927544593811, 1e-7)
	assert_almost_eq(hash3(1, 2, 3, 7), 0.5100231170654297, 1e-7)
	assert_almost_eq(hash3(-1, -5, 9, 123), 0.9548677206039429, 1e-7)
	assert_almost_eq(hash3(100000, 0, -3, 0xffffffff), 0.8259028792381287, 1e-7)
	assert_almost_eq(value_noise(Vector3(0.3, -1.7, 2.2), 0), 0.7534249424934387, 1e-6)
	assert_almost_eq(value_noise(Vector3(12.25, -0.5, 3.75), 1), 0.6087192296981812, 1e-6)
	assert_almost_eq(value_noise(Vector3(-40.1, 9.9, 0.01), 12345), 0.41907602548599243, 1e-6)
	assert_almost_eq(value_noise(Vector3(100.5, -200.25, 300.125), 16777215), 0.3896746039390564, 1e-6)
	assert_almost_eq(value_noise(Vector3(1.25, 2.5, -0.75), 7), 0.16156958043575287, 1e-6)
	assert_almost_eq(fbm_noise(Vector3(0.3, -1.7, 2.2), 0, 3, 0.5), 0.7020118832588196, 1e-6)
	assert_almost_eq(fbm_noise(Vector3(12.25, -0.5, 3.75), 7, 3, 0.5), 0.5970460772514343, 1e-6)
	assert_almost_eq(fbm_noise(Vector3(1.25, 2.5, -0.75), 7, 3, 0.5), 0.5378407835960388, 1e-6)

# ---- the seed scheme shared bit for bit with voxkit (ZCity/Tools/voxkit/noise.py), GLSL and HLSL

# Vectors of the shader (uint ones are output as two floats, high and low 16 bits, which are exact)
const UINT_EXPECTED : Array = [ 0x0, 0x688990c0, 0xe628c683, 0x01fce552, 0x58f54975, 0xbe33ce9c, 0x96c9dd16 ]
const HASH_EXPECTED : Array = [ 0.3474927544593811, 0.5100231170654297, 0.9548677206039429, 0.8259028792381287 ]
const NOISE_EXPECTED : float = 0.16156958043575287
const FBM_EXPECTED : float = 0.5378407835960388

const VECTOR_GLSL : String = """vec4 mm_vu(uint x) {
	return vec4(float(x >> 16u), float(x & 65535u), 0.0, 0.0);
}
vec4 mm_vec(int i) {
	if (i == 0) { return mm_vu(mm_n3_lowbias32(0u)); }
	if (i == 1) { return mm_vu(mm_n3_lowbias32(1u)); }
	if (i == 2) { return mm_vu(mm_n3_lowbias32(3735928559u)); }
	if (i == 3) { return mm_vu(mm_n3_salt(0u, 1u)); }
	if (i == 4) { return mm_vu(mm_n3_salt(1u, 0u)); }
	if (i == 5) { return mm_vu(mm_n3_salt(7u, 1073741824u)); }
	if (i == 6) { return mm_vu(mm_n3_salt(123u, 22u)); }
	if (i == 7) { return vec4(mm_n3_hash(0, 0, 0, 1u), 0.0, 0.0, 0.0); }
	if (i == 8) { return vec4(mm_n3_hash(1, 2, 3, 7u), 0.0, 0.0, 0.0); }
	if (i == 9) { return vec4(mm_n3_hash(-1, -5, 9, 123u), 0.0, 0.0, 0.0); }
	if (i == 10) { return vec4(mm_n3_hash(100000, 0, -3, 4294967295u), 0.0, 0.0, 0.0); }
	if (i == 11) { return vec4(mm_n3_value(vec3(1.25, 2.5, -0.75), 7u), 0.0, 0.0, 0.0); }
	if (i == 12) { return vec4(mm_n3_fbm(vec3(1.25, 2.5, -0.75), 7u, 3, 0.5, 2.03), 0.0, 0.0, 0.0); }
	if (i == 13) { return vec4(mm_n3_hash(0, 0, 0, 0u), 0.0, 0.0, 0.0); }
	return vec4(0.0);
}
"""

# Checks the 14 vectors of mm_vec (4 floats each)
func check_vectors(v : PackedFloat32Array, label : String) -> void:
	assert_eq(v.size(), 14*4, label+": size")
	if v.size() != 14*4:
		return
	for i in UINT_EXPECTED.size():
		var got : int = (int(v[i*4]) << 16) | int(v[i*4+1])
		assert_eq(got, UINT_EXPECTED[i], "%s: uint vector %d is %x, expected %x" % [ label, i, got, UINT_EXPECTED[i] ])
	for i in HASH_EXPECTED.size():
		assert_eq(v[(7+i)*4], PackedFloat32Array([ HASH_EXPECTED[i] ])[0], "%s: hash3 vector %d" % [ label, i ])
	assert_almost_eq(v[11*4], NOISE_EXPECTED, 2e-7, label+": noise3")
	assert_almost_eq(v[12*4], FBM_EXPECTED, 2e-7, label+": fbm")
	assert_eq(v[13*4], 0.0, label+": hash3(0,0,0,0) is 0")

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

## The gradient of a linear height (x, y or z) is a unit vector: with an epsilon
## that does not grow with the distance, float32 positions at kilometre
## coordinates would give 0 or 1.3 (the quantisation step is 1e-3 at 8 km)
func test_gradient_large_coordinates_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	for mode in [ 0, 1 ]:
		for channel in 3:
			await make_graph([
				{ name="uv", type="tex3d_uv" },
				{ name="d", type="tex3d_decompose" },
				{ name="g", type="tex3d_gradient", parameters={ eps=0.00074, strength=1.0, mode=mode } } ],
				[ { from="uv", from_port=0, to="d", to_port=0 }, { from="d", from_port=channel, to="g", to_port=0 } ])
			var gen : MMGenBase = graph.get_node("g")
			for centre in [ 0.0, 1000.0, 8000.0, -8000.0 ]:
				var image : Image = await render_points(gen, 0, 32.0, Vector3(centre, -centre, centre))
				assert_not_null(image)
				if image == null:
					return
				var max_diff : float = 0.0
				for idx in 4096:
					var c : Color = image.get_pixel(idx % 64, idx/64)
					var expected : Vector3 = Vector3()
					expected[channel] = 1.0
					var d : Vector3 = (Vector3(c.r, c.g, c.b)-expected).abs()
					max_diff = maxf(max_diff, maxf(d.x, maxf(d.y, d.z)))
				assert_lt(max_diff, 0.03, "gradient of a linear height, mode %d, axis %d, around %f" % [ mode, channel, centre ])
			graph.free()
			graph = null

func test_voxkit_vectors_gpu() -> void:
	if not gpu_available():
		pending("no rendering device (headless)")
		return
	var gen : MMGenBase = await make_node("tex3d_noise_value")
	var source : MMGenBase.ShaderCode = gen.get_shader_code("vec4(0.0)", 0, MMGenContext.new())
	source.defs = VECTOR_GLSL+source.defs
	source.output_values = { rgba="mm_vec(int(floor(uv.x*16.0)))" }
	source.output_type = "rgba"
	var compute : MMComputeShader = MMComputeShader.new()
	assert_true(await compute.set_shader_from_shadercode(source, true), "the vector shader compiles")
	var texture : MMTexture = MMTexture.new()
	assert_true(await compute.render_ext([ texture ], Vector2i(16, 1)), "the vector shader runs")
	var image : Image = (await texture.get_texture()).get_image()
	if image.get_format() != Image.FORMAT_RGBAF:
		image.convert(Image.FORMAT_RGBAF)
	var v : PackedFloat32Array = PackedFloat32Array()
	for i in 14:
		var c : Color = image.get_pixel(i, 0)
		v.append_array([ c.r, c.g, c.b, c.a ])
	check_vectors(v, "GLSL")

const VECTOR_HARNESS : String = """[[vk::binding(0, 0)]] StructuredBuffer<float4> In;
[[vk::binding(1, 0)]] RWStructuredBuffer<float4> Out;

@SHADER@

[numthreads(64, 1, 1)]
void main(uint3 id : SV_DispatchThreadID) {
	if (id.x < 14u) {
		Out[id.x] = mm_vec(int(id.x));
	}
}
"""

func test_voxkit_vectors_hlsl() -> void:
	if MMTestHlsl.find_tool("dxc") == "":
		pending("dxc not found")
		return
	if not gpu_available():
		pending("needs a GPU (run without --headless)")
		return
	var material : MMGenMaterial = MMGenMaterial.new()
	var decl : String = material.process_option_unreal5(material.process_option_hlsl_base("", true), true)
	var hlsl : String = decl+"\n"+material.process_option_hlsl_base(mm_loader.get_predefined_global("mm_noise3d")+"\n"+VECTOR_GLSL)
	material.free()
	DirAccess.make_dir_recursive_absolute("user://noise3d_test")
	var hlsl_path : String = "user://noise3d_test/vectors.hlsl"
	var spv_path : String = "user://noise3d_test/vectors.spv"
	var f : FileAccess = FileAccess.open(hlsl_path, FileAccess.WRITE)
	f.store_string(VECTOR_HARNESS.replace("@SHADER@", hlsl))
	f.close()
	# -O0 only: the optimised SPIR-V of DXC hangs on this machine's AMD driver
	var r : Dictionary = MMTestHlsl.compile_hlsl(hlsl_path, "cs_6_0", "main", "2021", [
			"-spirv", "-fspv-target-env=vulkan1.1", "-fvk-use-dx-layout", "-O0", "-Fo", ProjectSettings.globalize_path(spv_path) ])
	assert_true(r.ok, "dxc: "+r.output)
	if not r.ok:
		return
	var out : PackedFloat32Array = MMTestHlsl.run_spirv_compute(spv_path, PackedFloat32Array([ 0.0, 0.0, 0.0, 0.0 ]), PackedFloat32Array(), 14*4, 14)
	assert_eq(out.size(), 14*4, "the compute shader ran: "+MMTestHlsl.last_error)
	check_vectors(out, "HLSL")

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
