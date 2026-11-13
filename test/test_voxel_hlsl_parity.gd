extends GutTest

# GLSL versus exported-HLSL parity of voxel materials (design/zcity_plan.md, WP10).
#
# Each case is a graph ending in a Voxel Material. It is evaluated twice at the
# same 4096 points (random points of [-2, 2]^3, points next to the lattice planes
# of the noises, random unit normals, random per point fresh):
#   - GLSL: MMVoxelEval.evaluate_material, the generated GLSL of the previews run
#     as a compute shader;
#   - HLSL: the graph is exported with the real "Unreal/Unreal Engine 5 Voxel"
#     target, the exported .shader is put in a compute harness
#     (voxel_parity_harness.hlsl.txt), compiled by DXC to Vulkan SPIR-V and run
#     on the GPU (MMTestHlsl).
#
# Tiers:
#   T0 (headless): the exported text has none of the GLSL-only tokens
#   T1 (headless, needs dxc): the exported text compiles as ps_6_0, -HV 2018 and 2021
#   T2 (GPU, run without --headless, needs dxc): the numeric comparison
#
# Proven: the HLSL written by the exporter, compiled by DXC (Vulkan SDK), computes
# the same values as the GLSL on this GPU.
# Not proven: Unreal's own shader pipeline (its DXC version and flags, FXC under
# SM5, half precision on mobile, the wrapper of Unreal around Custom nodes); the
# Godot spatial shader preview (assumed equal to the compute GLSL, they come from
# the same generated text); other GPUs; the legacy sin-hash nodes (case p6 only
# reports the difference).

const TARGET : String = "Unreal/Unreal Engine 5 Voxel"
const TARGET_DIR : String = "res://material_maker/plugins/voxel/export_targets"
const VOXEL_DIR : String = "res://material_maker/plugins/voxel/nodes"
const HARNESS : String = "res://test/voxel_parity_harness.hlsl.txt"
const OUT_DIR : String = "user://voxel_parity_test"
const COUNT : int = 4096

## Tolerances: pure scalar noise values, then colours and ORM, then the 99.9th percentile
const TOL_NOISE : float = 1e-4
const TOL_COLOR : float = 2e-3
const TOL_P999 : float = 5e-4
const TOL_ANGLE : float = 0.1

const CBUFFER : String = "\tfloat t_seed; float t_age; float t_upkeep; float t_char;\n\tfloat t_wet; float t_footprint; float t_time; float t_pad;\n\tfloat4 t_axis;\n\tfloat4 t_origin;"

const DEFAULT_THINGS : Dictionary = { seed=0, age=0.0, upkeep=0.0, char=0.0, wet=0.0, footprint=0.0, axis=[ 1.0, 0.0, 0.0 ], origin=[ 0.0, 0.0, 0.0 ] }

var graph : MMGenGraph
var material : MMGenMaterial
var points : PackedFloat32Array
var normals : PackedFloat32Array
var fresh : PackedFloat32Array

func before_all() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	make_points()

func before_each() -> void:
	mm_loader.get_predefined_generators_from_dir(VOXEL_DIR)
	MMPlugins.load_export_targets(TARGET_DIR)

func after_each() -> void:
	if graph != null:
		graph.free()
		graph = null

func gpu_available() -> bool:
	return RenderingServer.get_rendering_device() != null

# ---- points

func make_points() -> void:
	var rng : RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 20260511
	points = PackedFloat32Array()
	normals = PackedFloat32Array()
	fresh = PackedFloat32Array()
	for i in COUNT:
		var p : Vector3
		if i < 3072:
			p = Vector3(rng.randf_range(-2, 2), rng.randf_range(-2, 2), rng.randf_range(-2, 2))
		elif i < 3584:
			# next to the lattice planes of the default scale (8), 1e-4 away at most
			p = Vector3(rng.randf_range(-2, 2), rng.randf_range(-2, 2), rng.randf_range(-2, 2))
			for c in 3:
				if rng.randf() < 0.7:
					p[c] = round(p[c]*8.0)/8.0+rng.randf_range(-1e-4, 1e-4)
		else:
			# small coordinates, many negative: the wood and the Voronoi cells near the origin
			p = Vector3(rng.randf_range(-0.5, 0.5), rng.randf_range(-0.5, 0.5), rng.randf_range(-0.5, 0.5))
		var n : Vector3 = Vector3(rng.randfn(), rng.randfn(), rng.randfn()).normalized()
		points.append_array([ p.x, p.y, p.z ])
		normals.append_array([ n.x, n.y, n.z ])
		fresh.append(rng.randf())

# ---- cases

# nodes: name -> [type, parameters]; wires: [from, from_port, to, to_port];
# variants: Array of { things : voxel inputs values, set : { node : { parameter : value } } }
# Material input ports: 0 albedo, 1 metallic, 2 roughness, 3 emission, 4 ao, 5 opacity, 6 bump
# Voxel Inputs output ports: 0 position, 1 normal, 2 seed, 3 age, 4 upkeep, 5 fresh, 6 char, 7 wet, 8 axis, 9 origin, 10 footprint
func make_cases() -> Dictionary:
	var cases : Dictionary = {}
	var noise_params : Dictionary = { scale_x=5.5, scale_y=7.25, scale_z=9.0, offset_x=0.3, offset_y=-0.2, offset_z=0.1, seed_offset=3.0 }
	# P1: value noise, four seeds
	cases["p1_value"] = {
		nodes={ N=[ "tex3d_noise_value", noise_params ] },
		wires=[ [ "In", 2, "N", 0 ], [ "N", 0, "Material", 1 ], [ "N", 0, "Material", 5 ] ],
		variants=[ { things={ seed=0 } }, { things={ seed=1 } }, { things={ seed=12345 } }, { things={ seed=16777215 } } ],
		tol=TOL_NOISE
	}
	cases["p1_value_default"] = {
		nodes={ N=[ "tex3d_noise_value", {} ] },
		wires=[ [ "In", 2, "N", 0 ], [ "N", 0, "Material", 1 ] ],
		variants=[ { things={ seed=7 } } ],
		tol=TOL_NOISE
	}
	cases["p1_value_period"] = {
		nodes={ N=[ "tex3d_noise_value", { period=4.0 } ] },
		wires=[ [ "In", 2, "N", 0 ], [ "N", 0, "Material", 1 ] ],
		variants=[ { things={ seed=99 } } ],
		tol=TOL_NOISE
	}
	cases["p1_perlin"] = {
		nodes={ N=[ "tex3d_noise_perlin", noise_params ] },
		wires=[ [ "In", 2, "N", 0 ], [ "N", 0, "Material", 1 ], [ "N", 0, "Material", 5 ] ],
		variants=[ { things={ seed=0 } }, { things={ seed=12345 } }, { things={ seed=16777215 } } ],
		tol=TOL_NOISE
	}
	cases["p1_perlin_period"] = {
		nodes={ N=[ "tex3d_noise_perlin", { period=4.0 } ] },
		wires=[ [ "In", 2, "N", 0 ], [ "N", 0, "Material", 1 ] ],
		variants=[ { things={ seed=5 } } ],
		tol=TOL_NOISE
	}
	for basis in 2:
		cases["p1_fbm_basis%d" % basis] = {
			nodes={ N=[ "tex3d_noise_fbm", noise_params.merged({ basis=basis, octaves=4.0, gain=0.55, lacunarity=2.03 }) ] },
			wires=[ [ "In", 2, "N", 0 ], [ "N", 0, "Material", 1 ], [ "N", 0, "Material", 5 ] ],
			variants=[ { things={ seed=0 } }, { things={ seed=12345 } }, { things={ seed=16777215 } } ],
			tol=TOL_NOISE
		}
	cases["p1_fbm_period"] = {
		nodes={ N=[ "tex3d_noise_fbm", { period=4.0, octaves=3.0, lacunarity=2.0 } ] },
		wires=[ [ "In", 2, "N", 0 ], [ "N", 0, "Material", 1 ] ],
		variants=[ { things={ seed=21 } } ],
		tol=TOL_NOISE
	}
	cases["p1_voronoi"] = {
		nodes={ N=[ "tex3d_noise_voronoi", noise_params.merged({ jitter=0.8 }) ] },
		wires=[ [ "In", 2, "N", 0 ], [ "N", 0, "Material", 1 ], [ "N", 1, "Material", 2 ], [ "N", 2, "Material", 5 ], [ "N", 3, "Material", 0 ] ],
		variants=[ { things={ seed=0 } }, { things={ seed=12345 } }, { things={ seed=16777215 } } ],
		tol=TOL_NOISE
	}
	cases["p1_voronoi_default"] = {
		nodes={ N=[ "tex3d_noise_voronoi", {} ] },
		wires=[ [ "In", 2, "N", 0 ], [ "N", 0, "Material", 1 ], [ "N", 1, "Material", 2 ], [ "N", 2, "Material", 5 ], [ "N", 3, "Material", 0 ] ],
		variants=[ { things={ seed=4 } } ],
		tol=TOL_NOISE
	}
	cases["p1_domain_warp"] = {
		nodes={ V=[ "tex3d_noise_value", {} ], W=[ "tex3d_domain_warp", { scale_x=3.0, scale_y=3.0, scale_z=3.0, amount=0.15, octaves=3.0 } ] },
		wires=[ [ "In", 2, "V", 0 ], [ "V", 0, "W", 0 ], [ "In", 2, "W", 1 ], [ "W", 0, "Material", 0 ] ],
		variants=[ { things={ seed=0 } }, { things={ seed=12345 } } ],
		tol=TOL_COLOR
	}
	# gradient (bump path): fbm height, forward and central differences
	for mode in 2:
		cases["p1_gradient_mode%d" % mode] = {
			nodes={ F=[ "tex3d_noise_fbm", { octaves=3.0 } ], G=[ "tex3d_gradient", { mode=mode, strength=1.0 } ] },
			mat={ bump=0.05 },
			wires=[ [ "In", 2, "F", 0 ], [ "F", 0, "G", 0 ], [ "G", 0, "Material", 6 ], [ "In", 1, "Material", 3 ] ],
			variants=[ { things={ seed=3 } }, { things={ seed=12345 } } ],
			tol=TOL_COLOR
		}
	# P2: fbm (Perlin basis), Voronoi, domain warp and the gradient bump in one material
	cases["p2_combined"] = {
		nodes={
			F=[ "tex3d_noise_fbm", { basis=1, octaves=4.0, scale_x=6.0, scale_y=6.0, scale_z=6.0 } ],
			V=[ "tex3d_noise_voronoi", { scale_x=4.0, scale_y=4.0, scale_z=4.0 } ],
			W=[ "tex3d_domain_warp", { amount=0.1 } ],
			G=[ "tex3d_gradient", { mode=1 } ]
		},
		mat={ bump=0.03 },
		wires=[ [ "In", 2, "F", 0 ], [ "In", 2, "V", 0 ], [ "In", 2, "W", 1 ], [ "V", 3, "W", 0 ], [ "W", 0, "Material", 0 ],
				[ "F", 0, "Material", 2 ], [ "V", 0, "Material", 1 ], [ "V", 1, "Material", 4 ], [ "F", 0, "G", 0 ], [ "G", 0, "Material", 6 ] ],
		variants=[ { things={ seed=0 } }, { things={ seed=777 } }, { things={ seed=16777215 } } ],
		tol=TOL_COLOR
	}
	# P3: every output of Voxel Inputs wired into a channel
	cases["p3_inputs_a"] = {
		wires=[ [ "In", 0, "Material", 0 ], [ "In", 1, "Material", 3 ], [ "In", 2, "Material", 1 ], [ "In", 3, "Material", 2 ], [ "In", 4, "Material", 4 ], [ "In", 5, "Material", 5 ] ],
		variants=[ { things={ seed=321, age=0.3, upkeep=0.45 } } ],
		tol=TOL_NOISE
	}
	cases["p3_inputs_b"] = {
		wires=[ [ "In", 8, "Material", 0 ], [ "In", 9, "Material", 3 ], [ "In", 6, "Material", 1 ], [ "In", 7, "Material", 2 ], [ "In", 10, "Material", 5 ], [ "In", 4, "Material", 4 ] ],
		variants=[ { things={ seed=5, upkeep=0.2, char=0.6, wet=0.7, footprint=0.002, axis=[ 0.3, -0.5, 0.8 ], origin=[ 0.1, -0.2, 0.3 ] } },
				{ things={ char=1.0, wet=0.0, footprint=0.01, axis=[ 0.0, 0.0, 0.0 ], origin=[ -1.0, 2.0, 0.5 ] } } ],
		tol=TOL_NOISE
	}
	# P4: existing nodes without a hash: rotate, colorize with a gradient, blend (all modes), tones step
	var blend_variants : Array = []
	for b in 11:
		blend_variants.append({ things={ seed=2 }, set={ B={ blend_type=b } } })
	cases["p4_chain"] = {
		nodes={
			R=[ "tex3d_rotate", { ax=20.0, ay=-35.0, az=70.0 } ],
			C=[ "tex3d_colorize", { g={ type="Gradient", interpolation=1, points=[
					{ a=1, r=0.1, g=0.0, b=0.4, pos=0.0 }, { a=1, r=0.9, g=0.5, b=0.1, pos=0.45 }, { a=1, r=0.2, g=0.8, b=0.3, pos=1.0 } ] } } ],
			B=[ "tex3d_blend", { amount=0.6 } ],
			T=[ "tex3d_tones_step", { value=0.4, width=0.3 } ],
			T2=[ "tex3d_tones_step", { value=0.5, width=0.0, invert=true } ],
			V=[ "tex3d_noise_value", {} ]
		},
		wires=[ [ "In", 0, "R", 0 ], [ "R", 0, "C", 0 ], [ "C", 0, "B", 0 ], [ "R", 0, "B", 1 ], [ "In", 2, "V", 0 ], [ "V", 0, "B", 2 ],
				[ "B", 0, "T", 0 ], [ "T", 0, "Material", 0 ], [ "B", 0, "T2", 0 ], [ "T2", 0, "Material", 3 ] ],
		variants=blend_variants,
		tol=TOL_COLOR
	}
	var math_variants : Array = []
	for op in [ 0, 1, 2, 3, 6, 12, 15, 16, 20, 21, 23, 24, 26, 32 ]:
		math_variants.append({ things={ seed=11 }, set={ M={ op=op, default_in2=0.7 } } })
	cases["p4_math"] = {
		nodes={ V=[ "tex3d_noise_value", {} ], M=[ "tex3d_math", {} ] },
		wires=[ [ "In", 2, "V", 0 ], [ "V", 0, "M", 0 ], [ "M", 0, "Material", 1 ], [ "M", 0, "Material", 2 ] ],
		variants=math_variants,
		tol=TOL_NOISE
	}
	# P5: the voxel wood node, wired as in test_voxel_wood.gd
	var wood_wires : Array = [ [ "In", 2, "W", 0 ], [ "In", 1, "W", 1 ], [ "In", 8, "W", 2 ], [ "In", 9, "W", 3 ], [ "In", 3, "W", 4 ], [ "In", 5, "W", 5 ], [ "In", 10, "W", 6 ],
			[ "W", 0, "Material", 0 ], [ "W", 1, "Material", 6 ], [ "W", 2, "Material", 2 ], [ "W", 3, "Material", 1 ], [ "W", 4, "Material", 4 ] ]
	cases["p5_wood"] = {
		nodes={ W=[ "voxel_wood", {} ] },
		mat={ bump=1.0 },
		wires=wood_wires,
		variants=[
			{ things={ seed=777, age=0.1, footprint=0.0005 } },
			{ things={ seed=12345, age=0.6, axis=[ 0.0, 1.0, 0.0 ], origin=[ 0.1, -0.05, 0.2 ], footprint=0.002 } },
			{ things={ seed=31, age=0.3, axis=[ 0.0, 0.0, 1.0 ] }, set={ W={ ring_porous=false } } },
			{ things={ seed=16777215, age=1.0, axis=[ 0.6, 0.0, 0.8 ], origin=[ 0.5, 0.5, 0.5 ] } } ],
		tol=TOL_COLOR
	}
	# P7: the default sRGB decoding (linear_albedo=false) of albedos that are negative or
	# around the 0.04045 threshold (the HLSL used to give NaN below -0.055)
	cases["p7_srgb_position"] = {
		mat={ linear_albedo=false },
		wires=[ [ "In", 0, "Material", 0 ] ],
		variants=[ { things={} } ],
		tol=TOL_COLOR
	}
	var srgb_variants : Array = []
	for o : Array in [ [ -0.3, 0.04045, 0.04 ], [ 0.04044, 0.04046, -0.056 ], [ -0.06, 0.5, 2.0 ], [ 0.0, -1.0, 0.0404 ], [ 0.0405, 0.9, -0.0001 ] ]:
		srgb_variants.append({ things={ origin=o } })
	cases["p7_srgb_threshold"] = {
		mat={ linear_albedo=false, albedo_color={ r=0.9, g=0.6, b=0.3, a=1.0, type="Color" } },
		wires=[ [ "In", 9, "Material", 0 ] ],
		variants=srgb_variants,
		tol=TOL_COLOR
	}
	# P8: non-default material parameters (colour, metallic, roughness, emission, ao and bump
	# scale the corresponding inputs)
	cases["p8_material_params"] = {
		nodes={ N=[ "tex3d_noise_value", {} ], F=[ "tex3d_noise_fbm", { octaves=3.0 } ], G=[ "tex3d_gradient", { mode=1 } ] },
		mat={ linear_albedo=false, albedo_color={ r=0.8, g=0.5, b=0.2, a=1.0, type="Color" }, metallic=0.7, roughness=0.4, emission_energy=0.6, ao=0.5, bump=0.04 },
		wires=[ [ "In", 2, "N", 0 ], [ "In", 2, "F", 0 ], [ "F", 0, "G", 0 ], [ "N", 0, "Material", 0 ], [ "F", 0, "Material", 1 ], [ "N", 0, "Material", 2 ],
				[ "F", 0, "Material", 3 ], [ "N", 0, "Material", 4 ], [ "G", 0, "Material", 6 ] ],
		variants=[ { things={ seed=5 } }, { things={ seed=12345 }, set={ Material={ ao=0.0 } } }, { things={ seed=9 }, set={ Material={ ao=1.0, metallic=0.0, emission_energy=0.0 } } } ],
		tol=TOL_COLOR
	}
	# P6, informational: the legacy node, hashed with sin
	cases["p6_legacy_fbm"] = {
		nodes={ L=[ "tex3d_fbm", {} ] },
		wires=[ [ "L", 0, "Material", 1 ] ],
		variants=[ { things={} } ],
		tol=TOL_NOISE,
		informational=true
	}
	return cases

func build(c : Dictionary) -> void:
	var nodes : Array = [ { name="Material", type="material_voxel", parameters={ linear_albedo=true }.merged(c.get("mat", {}), true) }, { name="In", type="voxel_inputs" } ]
	for k : String in c.get("nodes", {}).keys():
		nodes.append({ name=k, type=c.nodes[k][0], parameters=c.nodes[k][1] })
	var connections : Array = []
	for w : Array in c.wires:
		connections.append({ from=w[0], from_port=w[1], to=w[2], to_port=w[3] })
	graph = await mm_loader.create_gen({ nodes=nodes, connections=connections })
	add_child(graph)
	material = graph.get_node("Material")

func apply_variant(v : Dictionary) -> Dictionary:
	var things : Dictionary = DEFAULT_THINGS.merged(v.get("things", {}), true)
	var errors : PackedStringArray = MMVoxelEval.apply_params(graph, things)
	assert_eq(errors.size(), 0, str(errors))
	var set : Dictionary = v.get("set", {})
	for node_name : String in set.keys():
		var gen : MMGenBase = graph.get_node(node_name)
		for param : String in set[node_name].keys():
			gen.set_parameter(param, set[node_name][param])
	return things

# ---- export and harness

func export_shader(name : String) -> String:
	var prefix : String = ProjectSettings.globalize_path(OUT_DIR).path_join(name)
	await material.export_material(prefix, TARGET, 0, true)
	return FileAccess.get_file_as_string(prefix+".shader")

func custom_inputs() -> Array:
	var inputs : Array = []
	for n in [ "Position", "Normal" ]:
		inputs.append({ name=n, type="float3" })
	for n in [ "Seed", "Age", "Upkeep", "Fresh", "Char", "Wet" ]:
		inputs.append({ name=n, type="float" })
	inputs.append({ name="Axis", type="float3" })
	inputs.append({ name="Origin", type="float3" })
	inputs.append({ name="Footprint", type="float" })
	inputs.append({ name="Time", type="float" })
	return inputs

func custom_outputs() -> Array:
	return [ { name="metallic", type="float" }, { name="roughness", type="float" },
			{ name="normal", type="float3" }, { name="emission", type="float3" },
			{ name="occlusion", type="float" }, { name="opacity", type="float" } ]

func write_text(path : String, text : String) -> void:
	var f : FileAccess = FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func check_tokens(full_shader : String, label : String) -> void:
	assert_ne(full_shader, "", label+": empty export")
	# (comments of the definitions mention GLSL names)
	var shader : String = RegEx.create_from_string("//[^\\r\\n]*").sub(full_shader, "", true)
	assert_null(RegEx.create_from_string("p_o\\d+_vox_").search(shader), label+": uniform names of Voxel Inputs remain")
	for forbidden in [ "\\bvec[234]\\b", "\\bmat[234]\\b", "\\buvec[234]\\b", "\\bivec[234]\\b", "\\bmix\\(", "\\bfract\\(", "\\blessThan\\(", "\\bdFdx\\(", "\\bfwidth\\(", "\\btexelFetch\\(", "uniform ", "\\$" ]:
		var m : RegExMatch = RegEx.create_from_string(forbidden).search(shader)
		assert_null(m, "%s: found %s in the exported shader: %s" % [ label, forbidden, m.get_string() if m != null else "" ])

# Runs the exported shader at the test points: 16 floats per point
func run_hlsl(shader : String, things : Dictionary, name : String) -> PackedFloat32Array:
	var template : String = FileAccess.get_file_as_string(HARNESS)
	var text : String = template.replace("@INPUTS@", CBUFFER).replace("@SHADER@", shader)
	var hlsl_path : String = OUT_DIR.path_join(name+"_harness.hlsl")
	var spv_path : String = OUT_DIR.path_join(name+".spv")
	write_text(hlsl_path, text)
	# -O0: the optimised SPIR-V of DXC (-O1 and up) makes the loops of the noises hang the
	# AMD Radeon 780M Vulkan driver (device lost); the unoptimised code runs and keeps the
	# semantics of the HLSL, which is what is compared here
	var r : Dictionary = MMTestHlsl.compile_hlsl(hlsl_path, "cs_6_0", "main", "2021", [
			"-spirv", "-fspv-target-env=vulkan1.1", "-fvk-use-dx-layout", "-O0", "-Fo", ProjectSettings.globalize_path(spv_path) ])
	assert_true(r.ok, name+": dxc: "+r.output)
	if not r.ok:
		return PackedFloat32Array()
	var input : PackedFloat32Array = PackedFloat32Array()
	input.resize(COUNT*8)
	for i in COUNT:
		input[i*8] = points[i*3]
		input[i*8+1] = points[i*3+1]
		input[i*8+2] = points[i*3+2]
		input[i*8+3] = fresh[i]
		input[i*8+4] = normals[i*3]
		input[i*8+5] = normals[i*3+1]
		input[i*8+6] = normals[i*3+2]
	var axis : Array = things.axis
	var origin : Array = things.origin
	var uniforms : PackedFloat32Array = PackedFloat32Array([
		float(things.seed), things.age, things.upkeep, things.char,
		things.wet, things.footprint, 0.0, 0.0,
		axis[0], axis[1], axis[2], 0.0,
		origin[0], origin[1], origin[2], 0.0 ])
	return MMTestHlsl.run_spirv_compute(spv_path, input, uniforms, COUNT*16, COUNT)

# ---- comparison

# Returns { max, p999, exceed (points with a channel over tol), angle (max, degrees), angle_exceed }
func compare(glsl : Dictionary, hlsl : PackedFloat32Array, tol : float) -> Dictionary:
	var diffs : PackedFloat32Array = PackedFloat32Array()
	var exceed : int = 0
	var angle_max : float = 0.0
	var angle_exceed : int = 0
	var signal_max : float = 0.0
	var signal_sum : float = 0.0
	var signal_min : float = 1e30
	for i in COUNT:
		var bad : bool = false
		var channels : Array = []
		for c in 3:
			channels.append([ glsl.base_color[i*3+c], hlsl[i*16+c] ])
			channels.append([ glsl.orm[i*3+c], hlsl[i*16+4+c] ])
			channels.append([ glsl.emission[i*3+c], hlsl[i*16+8+c] ])
		channels.append([ glsl.opacity[i], hlsl[i*16+15] ])
		for ch in channels:
			var d : float = abs(ch[0]-ch[1])
			signal_max = maxf(signal_max, ch[0])
			signal_sum += ch[0]
			signal_min = minf(signal_min, ch[0])
			if is_nan(d):
				d = 1e9
			diffs.append(d)
			if d > tol:
				bad = true
		if bad:
			exceed += 1
		var a : Vector3 = Vector3(glsl.normal[i*3], glsl.normal[i*3+1], glsl.normal[i*3+2])
		var b : Vector3 = Vector3(hlsl[i*16+12], hlsl[i*16+13], hlsl[i*16+14])
		a = a.normalized()
		b = b.normalized()
		var angle : float = rad_to_deg(atan2(a.cross(b).length(), a.dot(b)))
		if is_nan(angle):
			angle = 180.0
		angle_max = maxf(angle_max, angle)
		if angle > TOL_ANGLE:
			angle_exceed += 1
	diffs.sort()
	return { max=diffs[diffs.size()-1], p999=diffs[int(diffs.size()*0.999)], exceed=exceed, angle=angle_max, angle_exceed=angle_exceed, smin=signal_min, smax=signal_max, sum=signal_sum }

func report(name : String, stats : Dictionary, tol : float) -> void:
	var line : String = "%s max_abs=%s p99.9=%s over_tol(%s)=%d normal_max_angle=%s deg angle_over=%d glsl_range=[%s, %s] glsl_sum=%s" % [
			name, String.num_scientific(stats.max), String.num_scientific(stats.p999), String.num_scientific(tol), stats.exceed, String.num_scientific(stats.angle), stats.angle_exceed, str(snappedf(stats.smin, 0.001)), str(snappedf(stats.smax, 0.001)), str(snappedf(stats.sum, 0.01)) ]
	gut.p(line)

func run_case(case_name : String) -> void:
	if MMTestHlsl.find_tool("dxc") == "":
		pending("dxc not found")
		return
	if not gpu_available():
		pending("needs a GPU (run without --headless)")
		return
	var c : Dictionary = make_cases()[case_name]
	await build(c)
	var index : int = 0
	for v : Dictionary in c.variants:
		var label : String = "%s#%d" % [ case_name, index ]
		var things : Dictionary = apply_variant(v)
		var glsl : Dictionary = await MMVoxelEval.evaluate_material(material, points, normals, fresh)
		assert_false(glsl.is_empty(), label+": GLSL evaluation failed: "+MMVoxelEval.last_error)
		var shader : String = await export_shader(label.replace("#", "_"))
		check_tokens(shader, label)
		var hlsl : PackedFloat32Array = run_hlsl(shader, things, label.replace("#", "_"))
		assert_eq(hlsl.size(), COUNT*16, label+": the compute shader did not run: "+MMTestHlsl.last_error)
		if glsl.is_empty() or hlsl.size() != COUNT*16:
			index += 1
			continue
		var tol : float = c.tol
		var stats : Dictionary = compare(glsl, hlsl, tol)
		report(label, stats, tol)
		if not c.get("informational", false):
			var allowed : int = COUNT/1000
			assert_lte(stats.exceed, allowed, "%s: %d points over %s (max %s)" % [ label, stats.exceed, tol, stats.max ])
			assert_lt(stats.p999, minf(tol, TOL_P999), label+": 99.9th percentile")
			assert_lte(stats.angle_exceed, allowed, "%s: %d normals over %s degrees (max %s)" % [ label, stats.angle_exceed, TOL_ANGLE, stats.angle ])
		index += 1
	if graph != null:
		graph.free()
		graph = null

# ---- T0 and T1 (headless)

func test_t0_t1_all_cases_export_and_compile() -> void:
	var dxc : bool = MMTestHlsl.find_tool("dxc") != ""
	var cases : Dictionary = make_cases()
	for case_name : String in cases.keys():
		var c : Dictionary = cases[case_name]
		await build(c)
		# first and last variant (the variants of a case differ in constants only)
		for vi in [ 0, c.variants.size()-1 ]:
			var label : String = "%s#%d" % [ case_name, vi ]
			apply_variant(c.variants[vi])
			var shader : String = await export_shader("t0_"+case_name)
			check_tokens(shader, label)
			if dxc:
				var path : String = OUT_DIR.path_join("t1_%s.hlsl" % case_name)
				write_text(path, MMTestHlsl.wrap_custom_node(shader, custom_inputs(), custom_outputs()))
				for hv in [ "2018", "2021" ]:
					var r : Dictionary = MMTestHlsl.compile_hlsl(path, "ps_6_0", "main", hv)
					assert_true(r.ok, "%s -HV %s: %s" % [ label, hv, r.output ])
			if c.variants.size() == 1:
				break
		graph.free()
		graph = null
	if not dxc:
		pending("dxc not found: T0 only")

# ---- T2 (GPU)

# Negative control: the comparison must see a difference when the HLSL gets another seed
func test_control_detects_a_different_seed() -> void:
	if MMTestHlsl.find_tool("dxc") == "":
		pending("dxc not found")
		return
	if not gpu_available():
		pending("needs a GPU (run without --headless)")
		return
	var c : Dictionary = make_cases()["p1_value"]
	await build(c)
	var things : Dictionary = apply_variant({ things={ seed=12345 } })
	var glsl : Dictionary = await MMVoxelEval.evaluate_material(material, points, normals, fresh)
	var shader : String = await export_shader("control")
	things = things.duplicate()
	things.seed = 12346
	var hlsl : PackedFloat32Array = run_hlsl(shader, things, "control")
	assert_eq(hlsl.size(), COUNT*16)
	var stats : Dictionary = compare(glsl, hlsl, TOL_NOISE)
	report("control (other seed)", stats, TOL_NOISE)
	assert_gt(stats.exceed, COUNT/2, "the comparison does not notice another seed")

func test_p1_value() -> void:
	await run_case("p1_value")

func test_p1_value_default() -> void:
	await run_case("p1_value_default")

func test_p1_value_period() -> void:
	await run_case("p1_value_period")

func test_p1_perlin() -> void:
	await run_case("p1_perlin")

func test_p1_perlin_period() -> void:
	await run_case("p1_perlin_period")

func test_p1_fbm_value_basis() -> void:
	await run_case("p1_fbm_basis0")

func test_p1_fbm_perlin_basis() -> void:
	await run_case("p1_fbm_basis1")

func test_p1_fbm_period() -> void:
	await run_case("p1_fbm_period")

func test_p1_voronoi() -> void:
	await run_case("p1_voronoi")

func test_p1_voronoi_default() -> void:
	await run_case("p1_voronoi_default")

func test_p1_domain_warp() -> void:
	await run_case("p1_domain_warp")

func test_p1_gradient_forward() -> void:
	await run_case("p1_gradient_mode0")

func test_p1_gradient_central() -> void:
	await run_case("p1_gradient_mode1")

func test_p2_combined() -> void:
	await run_case("p2_combined")

func test_p3_inputs_a() -> void:
	await run_case("p3_inputs_a")

func test_p3_inputs_b() -> void:
	await run_case("p3_inputs_b")

func test_p4_chain() -> void:
	await run_case("p4_chain")

func test_p4_math() -> void:
	await run_case("p4_math")

func test_p5_wood() -> void:
	if not mm_loader.predefined_generators.has("voxel_wood"):
		pending("voxel_wood is not available")
		return
	await run_case("p5_wood")

func test_p7_srgb_position_default_decode() -> void:
	await run_case("p7_srgb_position")

func test_p7_srgb_threshold_default_decode() -> void:
	await run_case("p7_srgb_threshold")

func test_p8_material_params() -> void:
	await run_case("p8_material_params")

func test_p6_legacy_fbm_informational() -> void:
	await run_case("p6_legacy_fbm")
