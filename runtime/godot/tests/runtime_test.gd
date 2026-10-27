extends SceneTree

# Renders a runtime package's outputs, before and after changing parameters.
#
#	godot --path runtime/godot -s res://tests/runtime_test.gd -- <package.mmr> <output dir> [size=n] [name=value ...] [preset=name]

func _initialize():
	run.call_deferred()

func run():
	var args : PackedStringArray = OS.get_cmdline_user_args()
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
	print("TEST loaded %d passes in %d ms, parameters=%s, outputs=%s" % [ mmr.package.manifest.passes.size(), Time.get_ticks_msec()-start, mmr.package.get_parameter_names(), mmr.package.manifest.outputs.keys() ])
	for o in mmr.package.manifest.outputs.keys():
		save(mmr, o, out+"/runtime_%s.png" % o)
	for i in range(2, args.size()):
		var nv : PackedStringArray = args[i].split("=")
		start = Time.get_ticks_msec()
		if nv[0] == "preset":
			print("TEST presets %s, apply %s: %s" % [ mmr.get_preset_names(), nv[1], mmr.apply_preset(nv[1]) ])
			continue
		var dirty_count : int = 0
		mmr.renderer.set_parameter(nv[0], float(nv[1]))
		dirty_count = mmr.renderer.dirty.size()
		mmr.update()
		print("TEST set %s=%s: re-rendered %d passes in %d ms" % [ nv[0], nv[1], dirty_count, Time.get_ticks_msec()-start ])
	if args.size() > 2:
		for o in mmr.package.manifest.outputs.keys():
			save(mmr, o, out+"/runtime_%s_set.png" % o)
	# The material can be used on a mesh
	var mesh : MeshInstance3D = MeshInstance3D.new()
	mesh.mesh = BoxMesh.new()
	mesh.material_override = mmr.material
	print("TEST material: albedo_texture=%s normal=%s" % [ mmr.material.albedo_texture != null, mmr.material.normal_enabled ])
	mesh.free()
	mmr.renderer.free_resources()
	print("TEST done")
	quit()

func save(mmr : MMRMaterial, output : String, file_name : String) -> void:
	var image : Image = mmr.renderer.get_image(output)
	image.convert(Image.FORMAT_RGBA8)
	image.save_png(file_name)
