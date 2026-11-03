extends SceneTree

# Renders a runtime package's outputs, changes its parameters and size, and
# compares the result with Material Maker's renders:
#
#	godot --path runtime/godot -s res://tests/runtime_test.gd -- <package.mmr> <output dir> [option ...]
#
# Options, applied in order after the package is rendered once:
#	size=<n>	(first option only) loads the package with n x n outputs
#	<name>=<value>	sets a parameter (name or label, "seed" for the seed)
#	preset=<name>	applies a preset
#	resize=<n>	renders the outputs at n x n
#	ref=<dir>	compares the final outputs with <dir>/<package>_Material_<n>.exr
#			(the files written by material_maker --render --node Material:<n>
#			--format exr), after the same EXR round trip
# Writes runtime_<output>.png, and runtime_<output>_set.png after the options.
# Prints "TEST ..." lines, exits with 1 on error or if an output differs.

## Material node output of each channel
const OUTPUT_INDEX : Dictionary = { albedo=0, orm=1, emission=2, normal=3, height=8 }

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var args : PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 2:
		print("TEST usage: runtime_test.gd -- <package.mmr> <output dir> [option ...]")
		quit(1)
		return
	var out : String = args[1]
	DirAccess.make_dir_recursive_absolute(out)
	var start : int = Time.get_ticks_msec()
	var size : int = 0
	if args.size() > 2 and args[2].begins_with("size="):
		size = int(args[2].substr(5))
		args.remove_at(2)
	var mmr : MMRMaterial = MMRMaterial.load_material(args[0], size)
	if not mmr.is_valid():
		print("TEST error: ", mmr.error_message)
		quit(1)
		return
	print("TEST loaded %s: %d passes in %d ms, parameters=%s, presets=%s, outputs=%s, size=%d" % [ mmr.package.manifest.get("name", ""), mmr.package.manifest.passes.size(), Time.get_ticks_msec()-start, mmr.package.get_parameter_names(), mmr.get_preset_names(), mmr.package.manifest.outputs.keys(), mmr.package.get_output_size() ])
	for o in mmr.package.manifest.outputs.keys():
		save(mmr, o, out.path_join("runtime_%s.png" % o))
	var ref : String = ""
	var changed : bool = false
	var success : bool = true
	for i in range(2, args.size()):
		var nv : PackedStringArray = args[i].split("=", true, 1)
		if nv.size() != 2:
			print("TEST error: invalid option ", args[i])
			success = false
			continue
		start = Time.get_ticks_msec()
		match nv[0]:
			"ref":
				ref = nv[1]
				continue
			"preset":
				var applied : bool = mmr.apply_preset(nv[1])
				print("TEST preset %s: %s" % [ nv[1], applied ])
				success = success and applied
			"resize":
				mmr.set_output_size(int(nv[1]))
				print("TEST resize %s: outputs %d px, rendered in %d ms" % [ nv[1], mmr.package.get_output_size(), Time.get_ticks_msec()-start ])
			_:
				if not mmr.renderer.set_parameter(nv[0], float(nv[1])):
					print("TEST error: unknown parameter ", nv[0])
					success = false
					continue
				var dirty_count : int = mmr.renderer.dirty.size()
				mmr.update()
				print("TEST set %s=%s: re-rendered %d passes in %d ms" % [ nv[0], nv[1], dirty_count, Time.get_ticks_msec()-start ])
		changed = true
	if changed:
		for o in mmr.package.manifest.outputs.keys():
			save(mmr, o, out.path_join("runtime_%s_set.png" % o))
	if ref != "":
		success = compare(mmr, ref) and success
	# The material can be used on a mesh
	var mesh : MeshInstance3D = MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	mesh.material_override = mmr.material
	print("TEST material: albedo_texture=%s normal=%s transparency=%d" % [ mmr.material.albedo_texture != null, mmr.material.normal_enabled, mmr.material.transparency ])
	mesh.free()
	mmr.renderer.free_resources()
	# Renderers that are not freed explicitly free their device when deleted
	mmr = MMRMaterial.load_material(args[0])
	mmr = null
	print("TEST done: ", "success" if success else "FAILED")
	quit(0 if success else 1)

func save(mmr : MMRMaterial, output : String, file_name : String) -> void:
	var image : Image = mmr.renderer.get_image(output)
	image.convert(Image.FORMAT_RGBA8)
	image.save_png(file_name)

## Compares the outputs with Material Maker's EXR renders. Godot's EXR
## writer flushes half float subnormals to 0, so the outputs go through the
## same round trip.
func compare(mmr : MMRMaterial, ref : String) -> bool:
	var identical : bool = true
	for o in mmr.package.manifest.outputs.keys():
		var ref_file : String = ref.path_join("%s_Material_%d.exr" % [ mmr.package.manifest.get("name", ""), OUTPUT_INDEX.get(o, -1) ])
		if not FileAccess.file_exists(ref_file):
			print("TEST compare %s: no reference" % o)
			continue
		var a : Image = Image.new()
		a.load_exr_from_buffer(mmr.renderer.get_image(o).save_exr_to_buffer(false))
		a.convert(Image.FORMAT_RGBAF)
		var b : Image = Image.load_from_file(ref_file)
		b.convert(Image.FORMAT_RGBAF)
		if a.get_size() != b.get_size():
			print("TEST compare %s: DIFFERENT size %s, reference %s" % [ o, a.get_size(), b.get_size() ])
			identical = false
		elif a.get_data() == b.get_data():
			print("TEST compare %s: identical (%s)" % [ o, a.get_size() ])
		else:
			var fa : PackedFloat32Array = a.get_data().to_float32_array()
			var fb : PackedFloat32Array = b.get_data().to_float32_array()
			var count : int = 0
			var max_difference : float = 0.0
			for i in fa.size():
				if fa[i] != fb[i]:
					count += 1
					max_difference = max(max_difference, abs(fa[i]-fb[i]))
			print("TEST compare %s: DIFFERENT %d/%d values, max difference %f" % [ o, count, fa.size(), max_difference ])
			identical = false
	return identical
