class_name MMVoxelMaster
extends RefCounted


# Master material generator: combines the voxel recipes of several graphs in one
# Unreal Engine 5 material that selects the recipe of each object with an
# integer id (a custom primitive data, a vertex color channel or a UV).
#
# Each graph is exported with the "Unreal/Unreal Engine 5 Voxel Function" target,
# whose .voxel.hlsl file holds a struct named MMVoxRecipe. combine() renames each
# struct and its textures, and writes a dispatcher that calls the struct of the
# object's id (real branches: only one recipe runs per pixel).
#
# The generated Unreal Python script is UNVERIFIED in Unreal.


const TARGET : String = "Unreal/Unreal Engine 5 Voxel Function"
const PLACEHOLDER : String = "MMVoxRecipe"

## Inputs of the Custom node that come from the configuration (the others,
## Position and Normal, come from the geometry and Time from the Time node)
const SCALAR_INPUTS : Array[String] = [ "Seed", "Age", "Upkeep", "Fresh", "Char", "Wet" ]
const VECTOR_INPUTS : Array[String] = [ "Axis", "Origin" ]

const DEFAULT_CONFIG : Dictionary = {
	name = "M_VoxelMaster",
	ids = {},
	id_source = "custom_primitive_data:0",
	inputs = {
		Seed = "custom_primitive_data:1", Age = "custom_primitive_data:2", Upkeep = "custom_primitive_data:3",
		Fresh = "vertex_color:g", Char = "custom_primitive_data:4", Wet = "custom_primitive_data:5",
		Axis = "custom_primitive_data:6", Origin = "custom_primitive_data:9", Footprint = "auto"
	},
	position_scale = 0.01
}


## The configuration with its defaults. Keys of "inputs" that are missing keep
## their default mapping.
static func complete_config(config : Dictionary) -> Dictionary:
	var result : Dictionary = DEFAULT_CONFIG.duplicate(true)
	for k in config.keys():
		if k == "inputs" and config[k] is Dictionary:
			for i in config[k].keys():
				result.inputs[i] = config[k][i]
		else:
			result[k] = config[k]
	return result

## A name as a part of an HLSL identifier
static func sanitize(name : String) -> String:
	var s : String = name.get_file().get_basename()
	var rx : RegEx = RegEx.create_from_string("[^A-Za-z0-9_]")
	s = rx.sub(s, "_", true)
	if s == "":
		s = "recipe"
	return s

## Parses a source ("custom_primitive_data:N", "vertex_color:r|g|b|a",
## "uv<N>:x|y" or "auto"). Returns {} if it is not valid.
static func parse_source(source : String) -> Dictionary:
	if source == "auto":
		return { kind="auto" }
	var parts : PackedStringArray = source.split(":")
	if parts.size() != 2:
		return {}
	var kind : String = parts[0]
	var arg : String = parts[1]
	if kind == "custom_primitive_data" and arg.is_valid_int() and int(arg) >= 0 and int(arg) < 36:
		return { kind="cpd", index=int(arg) }
	if kind == "vertex_color" and arg in [ "r", "g", "b", "a" ]:
		return { kind="vc", channel=arg }
	if kind.begins_with("uv") and kind.substr(2).is_valid_int() and arg in [ "x", "y" ]:
		return { kind="uv", index=int(kind.substr(2)), channel=arg }
	return {}

## Errors of a configuration (an empty array if it is valid)
static func check_config(config : Dictionary) -> Array[String]:
	var errors : Array[String] = []
	var id_source : Dictionary = parse_source(str(config.id_source))
	if id_source.is_empty() or id_source.kind == "auto":
		errors.append("incorrect id_source '%s'" % config.id_source)
	for i in config.inputs.keys():
		var src : Dictionary = parse_source(str(config.inputs[i]))
		if not i in SCALAR_INPUTS+VECTOR_INPUTS+[ "Footprint" ]:
			errors.append("unknown input '%s' (inputs: %s)" % [ i, ", ".join(SCALAR_INPUTS+VECTOR_INPUTS+[ "Footprint" ]) ])
		elif src.is_empty():
			errors.append("incorrect source '%s' for the input %s" % [ config.inputs[i], i ])
		elif src.kind == "auto" and i != "Footprint":
			errors.append("'auto' is only valid for Footprint")
		elif i in VECTOR_INPUTS and src.kind != "cpd":
			errors.append("%s needs a custom_primitive_data source (it has three components)" % i)
	return errors

## Texture indices ("Texture2D texture_<n>;") of the struct text of a recipe
static func texture_indices(hlsl : String) -> Array[int]:
	var result : Array[int] = []
	var rx : RegEx = RegEx.create_from_string("Texture2D\\s+texture_(\\d+)\\s*;")
	for m in rx.search_all(hlsl):
		result.append(int(m.get_string(1)))
	return result

## The struct text of a recipe with its struct renamed MMVox_<name> and its
## textures texture_<n> renamed tex_<name>_<n>
static func rename_recipe(hlsl : String, name : String) -> String:
	var rx : RegEx = RegEx.new()
	rx.compile("\\b%s\\b" % PLACEHOLDER)
	var s : String = rx.sub(hlsl, "MMVox_"+name, true)
	rx.compile("\\btexture_(\\d+)Sampler\\b")
	s = rx.sub(s, "tex_%s_$1Sampler" % name, true)
	rx.compile("\\btexture_(\\d+)\\b")
	return rx.sub(s, "tex_%s_$1" % name, true)

## Unique sanitised names of recipes {name, id, hlsl}
static func unique_names(recipes : Array) -> Array[String]:
	var names : Array[String] = []
	for r in recipes:
		var n : String = sanitize(str(r.name))
		if n in names:
			n = "%s_%d" % [ n, int(r.id) ]
		while n in names:
			n += "_"
		names.append(n)
	return names

## Combines recipes ({name, id, hlsl}) in the code of the master Custom node.
## Returns { shader : String, recipes : [ { name, struct, id, textures : [ { index, input } ] } ] }
## or { error : String }.
static func build(recipes : Array, config : Dictionary = {}) -> Dictionary:
	config = complete_config(config)
	var errors : Array[String] = check_config(config)
	if not errors.is_empty():
		return { error=errors[0] }
	var names : Array[String] = unique_names(recipes)
	var ids : Array = []
	var structs : PackedStringArray = PackedStringArray()
	var branches : PackedStringArray = PackedStringArray()
	var info : Array = []
	for i in recipes.size():
		var r : Dictionary = recipes[i]
		var id : int = int(r.id)
		if id in ids:
			return { error="the id %d is used by two recipes" % id }
		ids.append(id)
		var n : String = names[i]
		if not str(r.hlsl).contains(PLACEHOLDER):
			return { error="the HLSL of %s has no %s struct" % [ r.name, PLACEHOLDER ] }
		structs.append(rename_recipe(str(r.hlsl), n).strip_edges())
		var textures : Array = []
		var call_textures : String = ""
		for t in texture_indices(str(r.hlsl)):
			textures.append({ index=t, input="tex_%s_%d" % [ n, t ] })
			call_textures += "tex_%s_%d, tex_%s_%dSampler, " % [ n, t, n, t ]
		var branch : String = "if (mm_id == %d) {\n" % id if i == 0 else "else if (mm_id == %d) {\n" % id
		branch += "\tMMVox_%s mm_f;\n" % n
		branch += "\tmm_f.vox_seed = Seed; mm_f.vox_age = Age; mm_f.vox_upkeep = Upkeep; mm_f.vox_fresh = Fresh; mm_f.vox_char = Char; mm_f.vox_wet = Wet; mm_f.vox_footprint = Footprint;\n"
		branch += "\tmm_f.vox_axis = Axis; mm_f.vox_origin = Origin;\n"
		branch += "\tmm_rv = mm_f.generated_shader(Position, normalize(Normal), Time, %smetallic, roughness, normal, emission, occlusion, opacity);\n}" % call_textures
		branches.append(branch)
		info.append({ name=n, struct="MMVox_"+n, id=id, textures=textures })
	var shader : String = "\n".join(structs)+"\n\n"
	shader += "// Recipe selected by the integer id MaterialId\n"
	shader += "int mm_id = int(MaterialId + 0.5);\n"
	shader += "float4 mm_rv = float4(1.0, 0.0, 1.0, 1.0); /* magenta for unknown ids */\n"
	shader += "metallic = 0.0; roughness = 0.5; normal = normalize(Normal); emission = float3(0.0, 0.0, 0.0); occlusion = 1.0; opacity = 1.0;\n"
	shader += "\n".join(branches)+"\n"
	shader += "return mm_rv;\n"
	return { shader=shader, recipes=info }

## The code of the master Custom node (see build)
static func combine(recipes : Array, config : Dictionary = {}) -> String:
	return build(recipes, config).get("shader", "")


# Exporting graphs


## Exports the Voxel Material of a graph with the Function target in a
## temporary directory. Returns { hlsl : String, textures : [ index ],
## directory : String } or { error : String }. The caller deletes the directory.
static func export_recipe(graph : MMGenBase, directory : String) -> Dictionary:
	var material : MMGenBase = MMCliTools.find_material_node(graph)
	if material == null or not material.get_export_profiles().has(TARGET):
		return { error="the graph has no Voxel Material (or the target %s is not loaded)" % TARGET }
	DirAccess.make_dir_recursive_absolute(directory)
	var prefix : String = directory.path_join("recipe")
	await material.export_material(prefix, TARGET, 0, true)
	var path : String = prefix+".voxel.hlsl"
	if not FileAccess.file_exists(path):
		return { error="the export wrote no %s" % path }
	var hlsl : String = FileAccess.get_file_as_string(path)
	return { hlsl=hlsl, textures=texture_indices(hlsl), prefix=prefix }

static func remove_directory(directory : String) -> void:
	for f in DirAccess.get_files_at(directory):
		DirAccess.remove_absolute(directory.path_join(f))
	DirAccess.remove_absolute(directory)

## Exports the graphs and writes <name>.shader, <name>.py, <name>.master.json
## and the textures of the recipes in output_dir. graphs is an array of
## { graph : MMGenBase, file : String }. Returns an array of error messages.
static func generate(graphs : Array, config : Dictionary, output_dir : String) -> Array[String]:
	config = complete_config(config)
	var errors : Array[String] = check_config(config)
	if not errors.is_empty():
		return errors
	var recipes : Array = []
	var temp : String = OS.get_user_data_dir().path_join("voxel_master_tmp")
	var exports : Array = []
	for g in graphs:
		var file_name : String = str(g.file).get_file()
		var id = config.ids.get(file_name, config.ids.get(file_name.get_basename(), null))
		if id == null:
			errors.append("%s: no id in the configuration (ids: %s)" % [ file_name, JSON.stringify(config.ids) ])
			continue
		var directory : String = temp.path_join("r%d" % recipes.size())
		var exported : Dictionary = await export_recipe(g.graph, directory)
		if exported.has("error"):
			errors.append("%s: %s" % [ file_name, exported.error ])
			remove_directory(directory)
			continue
		recipes.append({ name=file_name, id=int(id), hlsl=exported.hlsl })
		exports.append(exported)
	if not errors.is_empty():
		return errors
	var built : Dictionary = build(recipes, config)
	if built.has("error"):
		return [ built.error ]
	DirAccess.make_dir_recursive_absolute(output_dir)
	var name : String = config.name
	var base : String = output_dir.path_join(name)
	var texture_files : Dictionary = {}
	for i in recipes.size():
		for t in built.recipes[i].textures:
			var target : String = output_dir.path_join("%s_texture_%d.exr" % [ built.recipes[i].name, t.index ])
			if DirAccess.copy_absolute("%s_texture_%d.exr" % [ exports[i].prefix, t.index ], target) != OK:
				errors.append("cannot write %s" % target)
			texture_files[t.input] = target
	for e in exports:
		remove_directory(e.prefix.get_base_dir())
	DirAccess.remove_absolute(temp)
	var files : Dictionary = {
		(base+".shader"): built.shader,
		(base+".py"): material_script(built, config, base+".shader", texture_files),
		(base+".master.json"): JSON.stringify(master_info(built, config, texture_files), "\t", true)+"\n"
	}
	for path in files.keys():
		var file : FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			errors.append("cannot write %s" % path)
			continue
		file.store_string(files[path])
		file.close()
	return errors

static func master_info(built : Dictionary, config : Dictionary, texture_files : Dictionary) -> Dictionary:
	var recipes : Array = []
	for r in built.recipes:
		var textures : Array = []
		for t in r.textures:
			textures.append({ input=t.input, file=texture_files.get(t.input, "").get_file() })
		recipes.append({ name=r.name, struct=r.struct, id=r.id, textures=textures })
	return { name=config.name, id_source=config.id_source, inputs=config.inputs, position_scale=config.position_scale, recipes=recipes }


# The Unreal Python script


static func py_str(s : String) -> String:
	return "'"+s.replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n")+"'"

## Adds the nodes of a scalar source, returns [ node variable, output pin ]
static func emit_scalar(lines : PackedStringArray, src : Dictionary, tag : String, y : int, scale : float = 1.0) -> Array:
	var result : Array = []
	match src.kind:
		"cpd":
			lines.append("CPD_%s = mat.add_node('CustomPrimitiveData', -900, %d)" % [ tag, y ])
			lines.append("CPD_%s.set_editor_property('primitive_data_index', %d)" % [ tag, src.index ])
			result = [ "CPD_"+tag, "" ]
		"vc":
			lines.append("VC_%s = mat.add_node('VertexColor', -900, %d)" % [ tag, y ])
			result = [ "VC_"+tag, src.channel.to_upper() ]
		"uv":
			lines.append("UV_%s = mat.add_node('TextureCoordinate', -1100, %d)" % [ tag, y ])
			lines.append("UV_%s.set_editor_property('coordinate_index', %d)" % [ tag, src.index ])
			lines.append("Mask_%s = mat.add_node('ComponentMask', -900, %d)" % [ tag, y ])
			lines.append("Mask_%s.set_editor_property('%s', True)" % [ tag, "r" if src.channel == "x" else "g" ])
			lines.append("mat.connect_nodes(UV_%s, '', Mask_%s, '')" % [ tag, tag ])
			result = [ "Mask_"+tag, "" ]
	if scale != 1.0:
		lines.append("Scale_%s = mat.add_node('Multiply', -700, %d)" % [ tag, y ])
		lines.append("Scale_%s.set_editor_property('const_b', %s)" % [ tag, str(scale) ])
		lines.append("mat.connect_nodes(%s, %s, Scale_%s, 'A')" % [ result[0], py_str(result[1]), tag ])
		result = [ "Scale_"+tag, "" ]
	return result

static func normal_transform_lines() -> PackedStringArray:
	# (the same helper as the Unreal Engine 5 Voxel export target)
	return PackedStringArray([
		"# Normals are transformed with the inverse transpose of the local to world matrix M, so",
		"# that they stay perpendicular to the surface under a non-uniform object scale:",
		"# n_local = M^T n_world and n_world = M^-T n_local. Component i of both is the dot",
		"# product of the normal with a basis vector transformed by the vector Transform",
		"# (local to world for M^T, world to local for M^-T), which needs no scale value.",
		"def normal_transform(vec, pin, basis_source, basis_target, x, y):",
		"    dots = []",
		"    for i, e in enumerate([(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)]):",
		"        c = mat.add_node('Constant3Vector', x, y+120*i)",
		"        c.set_editor_property('constant', unreal.LinearColor(e[0], e[1], e[2], 0.0))",
		"        t = mat.add_node('Transform', x+200, y+120*i)",
		"        t.set_editor_property('transform_source_type', basis_source)",
		"        t.set_editor_property('transform_type', basis_target)",
		"        d = mat.add_node('DotProduct', x+400, y+120*i)",
		"        mat.connect_nodes(c, '', t, '')",
		"        mat.connect_nodes(t, '', d, 'A')",
		"        mat.connect_nodes(vec, pin, d, 'B')",
		"        dots.append(d)",
		"    a = mat.add_node('AppendVector', x+600, y)",
		"    mat.connect_nodes(dots[0], '', a, 'A')",
		"    mat.connect_nodes(dots[1], '', a, 'B')",
		"    b = mat.add_node('AppendVector', x+700, y)",
		"    mat.connect_nodes(a, '', b, 'A')",
		"    mat.connect_nodes(dots[2], '', b, 'B')",
		"    n = mat.add_node('Normalize', x+800, y)",
		"    mat.connect_nodes(b, '', n, '')",
		"    return n",
	])

## The Unreal Python script of the master material (see the plan, WP11)
static func material_script(built : Dictionary, config : Dictionary, shader_path : String, texture_files : Dictionary) -> String:
	var lines : PackedStringArray = PackedStringArray()
	lines.append("import unreal")
	lines.append("import sys")
	lines.append("sys.path.append(%s)" % py_str(MMPaths.get_resource_dir().replace("\\", "/")+"/export"))
	lines.append("import mm")
	lines.append("from importlib import reload")
	lines.append("reload(mm)")
	lines.append("# UNVERIFIED in Unreal: written from memory of the Unreal Python API, not run")
	lines.append("# in an Unreal session. Check it in the editor before use.")
	lines.append("# Master voxel material generated by Material Maker: one Custom node holds all")
	lines.append("# the recipes and selects one with MaterialId. Set the mapping of the inputs")
	lines.append("# in the configuration (see %s.master.json)." % config.name)
	lines.append("mat = mm.Material(%s, True)" % py_str(config.name))
	lines.append("mat.clear()")
	lines.append_array(normal_transform_lines())
	lines.append("Custom_0 = mat.add_node('Custom', -264, 80)")
	lines.append("Custom_0.set_editor_property('code', mm.read_text_file(%s))" % py_str(shader_path.replace("\\", "/")))
	lines.append("Custom_0.set_editor_property('output_type', unreal.CustomMaterialOutputType.CMOT_FLOAT4)")
	lines.append("Custom_0.set_editor_property('additional_outputs', [ mm.custom_output('metallic', 1), mm.custom_output('roughness', 1), mm.custom_output('normal', 3), mm.custom_output('emission', 3), mm.custom_output('occlusion', 1), mm.custom_output('opacity', 1)])")
	lines.append("inputs = [mm.custom_input(n) for n in ['Position', 'Normal', 'Seed', 'Age', 'Upkeep', 'Fresh', 'Char', 'Wet', 'Axis', 'Origin', 'Footprint', 'Time', 'MaterialId']]")
	var inputs_of_textures : Array = []
	for r in built.recipes:
		for t in r.textures:
			inputs_of_textures.append(t.input)
			lines.append("inputs.append(mm.custom_input(%s))" % py_str(t.input))
	lines.append("Custom_0.set_editor_property('inputs', inputs)")
	# Position: world position to local space, scaled to metres
	lines.append("# Position: world position to local space, scaled to metres")
	lines.append("WorldPosition_0 = mat.add_node('WorldPosition', -1100, 0)")
	lines.append("TransformPosition_0 = mat.add_node('TransformPosition', -900, 0)")
	lines.append("TransformPosition_0.set_editor_property('transform_source_type', unreal.MaterialPositionTransformSource.TRANSFORMPOSSOURCE_WORLD)")
	lines.append("TransformPosition_0.set_editor_property('transform_type', unreal.MaterialPositionTransformSource.TRANSFORMPOSSOURCE_LOCAL)")
	lines.append("Multiply_0 = mat.add_node('Multiply', -700, 0)")
	lines.append("Multiply_0.set_editor_property('const_b', %s)" % str(float(config.position_scale)))
	lines.append("mat.connect_nodes(WorldPosition_0, '', TransformPosition_0, '')")
	lines.append("mat.connect_nodes(TransformPosition_0, '', Multiply_0, 'A')")
	lines.append("mat.connect_nodes(Multiply_0, '', Custom_0, 'Position')")
	lines.append("# Normal: world normal to local space (inverse transpose, see normal_transform)")
	lines.append("VertexNormal_0 = mat.add_node('VertexNormalWS', -1100, 120)")
	lines.append("NormalToLocal_0 = normal_transform(VertexNormal_0, '', unreal.MaterialVectorCoordTransformSource.TRANSFORMSOURCE_LOCAL, unreal.MaterialVectorCoordTransform.TRANSFORM_WORLD, -1700, 400)")
	lines.append("mat.connect_nodes(NormalToLocal_0, '', Custom_0, 'Normal')")
	# Per-thing values and the id, from the configured sources
	lines.append("# Per-thing values and the recipe id")
	var y : int = 240
	for n in SCALAR_INPUTS:
		y += 100
		var src : Dictionary = parse_source(str(config.inputs.get(n, "")))
		if src.is_empty():
			lines.append("%s_0 = mat.add_node('ScalarParameter', -700, %d)" % [ n, y ])
			lines.append("%s_0.set_editor_property('parameter_name', '%s')" % [ n, n ])
			lines.append("%s_0.set_editor_property('default_value', 0.0)" % n)
			lines.append("mat.connect_nodes(%s_0, '', Custom_0, '%s')" % [ n, n ])
		else:
			var e : Array = emit_scalar(lines, src, n, y)
			lines.append("mat.connect_nodes(%s, %s, Custom_0, '%s')" % [ e[0], py_str(e[1]), n ])
	for n in VECTOR_INPUTS:
		y += 100
		var src : Dictionary = parse_source(str(config.inputs.get(n, "")))
		if src.is_empty():
			lines.append("%s_0 = mat.add_node('VectorParameter', -700, %d)" % [ n, y ])
			lines.append("%s_0.set_editor_property('parameter_name', '%s')" % [ n, n ])
			lines.append("%s_0.set_editor_property('default_value', unreal.LinearColor(%s, 0.0, 0.0, 0.0))" % [ n, "1.0" if n == "Axis" else "0.0" ])
			lines.append("mat.connect_nodes(%s_0, '', Custom_0, '%s')" % [ n, n ])
		else:
			# three consecutive custom primitive data floats
			var comps : Array = []
			for c in 3:
				var cs : Dictionary = { kind="cpd", index=src.index+c }
				comps.append(emit_scalar(lines, cs, "%s%d" % [ n, c ], y+30*c))
			lines.append("AppendA_%s = mat.add_node('AppendVector', -500, %d)" % [ n, y ])
			lines.append("mat.connect_nodes(%s, '', AppendA_%s, 'A')" % [ comps[0][0], n ])
			lines.append("mat.connect_nodes(%s, '', AppendA_%s, 'B')" % [ comps[1][0], n ])
			lines.append("AppendB_%s = mat.add_node('AppendVector', -400, %d)" % [ n, y ])
			lines.append("mat.connect_nodes(AppendA_%s, '', AppendB_%s, 'A')" % [ n, n ])
			lines.append("mat.connect_nodes(%s, '', AppendB_%s, 'B')" % [ comps[2][0], n ])
			lines.append("mat.connect_nodes(AppendB_%s, '', Custom_0, '%s')" % [ n, n ])
	y += 100
	var footprint : Dictionary = parse_source(str(config.inputs.get("Footprint", "auto")))
	if footprint.kind == "auto":
		lines.append("# Footprint: length(ddx(Position)) + length(ddy(Position))")
		lines.append("DDX_0 = mat.add_node('DDX', -500, %d)" % y)
		lines.append("DDY_0 = mat.add_node('DDY', -500, %d)" % (y+100))
		lines.append("Zero_0 = mat.add_node('Constant3Vector', -500, %d)" % (y+200))
		lines.append("Zero_0.set_editor_property('constant', unreal.LinearColor(0.0, 0.0, 0.0, 0.0))")
		lines.append("DistanceX_0 = mat.add_node('Distance', -300, %d)" % y)
		lines.append("DistanceY_0 = mat.add_node('Distance', -300, %d)" % (y+100))
		lines.append("Footprint_0 = mat.add_node('Add', -100, %d)" % y)
		lines.append("mat.connect_nodes(Multiply_0, '', DDX_0, '')")
		lines.append("mat.connect_nodes(Multiply_0, '', DDY_0, '')")
		lines.append("mat.connect_nodes(DDX_0, '', DistanceX_0, 'A')")
		lines.append("mat.connect_nodes(Zero_0, '', DistanceX_0, 'B')")
		lines.append("mat.connect_nodes(DDY_0, '', DistanceY_0, 'A')")
		lines.append("mat.connect_nodes(Zero_0, '', DistanceY_0, 'B')")
		lines.append("mat.connect_nodes(DistanceX_0, '', Footprint_0, 'A')")
		lines.append("mat.connect_nodes(DistanceY_0, '', Footprint_0, 'B')")
		lines.append("mat.connect_nodes(Footprint_0, '', Custom_0, 'Footprint')")
	else:
		var e : Array = emit_scalar(lines, footprint, "Footprint", y)
		lines.append("mat.connect_nodes(%s, %s, Custom_0, 'Footprint')" % [ e[0], py_str(e[1]) ])
	y += 300
	lines.append("Time_0 = mat.add_node('Time', -700, %d)" % y)
	lines.append("mat.connect_nodes(Time_0, '', Custom_0, 'Time')")
	var id_src : Dictionary = parse_source(str(config.id_source))
	var id_scale : float = 255.0 if id_src.kind == "vc" else 1.0
	var id_e : Array = emit_scalar(lines, id_src, "MaterialId", y+100, id_scale)
	lines.append("mat.connect_nodes(%s, %s, Custom_0, 'MaterialId')" % [ id_e[0], py_str(id_e[1]) ])
	# Textures of the recipes
	var ty : int = 110
	for input in inputs_of_textures:
		lines.append("%s_object = mat.add_node('TextureObject', -456, %d)" % [ input, ty ])
		lines.append("%s_asset = mm.import_texture(%s, '/Game/Textures')" % [ input, py_str(str(texture_files.get(input, "")).replace("\\", "/")) ])
		lines.append("%s_asset.set_editor_property('srgb', False)" % input)
		lines.append("%s_asset.set_editor_property('compression_settings', unreal.TextureCompressionSettings.TC_HDR)" % input)
		lines.append("%s_asset.set_editor_property('mip_gen_settings', unreal.TextureMipGenSettings.TMGS_NO_MIPMAPS)" % input)
		lines.append("unreal.EditorAssetLibrary.save_loaded_asset(%s_asset)" % input)
		lines.append("%s_object.set_editor_property('texture', %s_asset)" % [ input, input ])
		lines.append("mat.connect_nodes(%s_object, '', Custom_0, %s)" % [ input, py_str(input) ])
		ty += 170
	lines.append("# The normal is in object space: back to world space for the material (inverse transpose)")
	lines.append("NormalToWorld_0 = normal_transform(Custom_0, 'normal', unreal.MaterialVectorCoordTransformSource.TRANSFORMSOURCE_WORLD, unreal.MaterialVectorCoordTransform.TRANSFORM_LOCAL, 300, 600)")
	lines.append("mat.set_editor_property('tangent_space_normal', False)")
	lines.append("mat.connect_property(Custom_0, 'return', unreal.MaterialProperty.MP_BASE_COLOR)")
	lines.append("mat.connect_property(Custom_0, 'metallic', unreal.MaterialProperty.MP_METALLIC)")
	lines.append("mat.connect_property(Custom_0, 'roughness', unreal.MaterialProperty.MP_ROUGHNESS)")
	lines.append("mat.connect_property(NormalToWorld_0, '', unreal.MaterialProperty.MP_NORMAL)")
	lines.append("mat.connect_property(Custom_0, 'emission', unreal.MaterialProperty.MP_EMISSIVE_COLOR)")
	lines.append("mat.connect_property(Custom_0, 'occlusion', unreal.MaterialProperty.MP_AMBIENT_OCCLUSION)")
	if config.get("translucent", false):
		lines.append("mat.set_editor_property('blend_mode', unreal.BlendMode.BLEND_TRANSLUCENT)")
		lines.append("mat.connect_property(Custom_0, 'opacity', unreal.MaterialProperty.MP_OPACITY)")
	lines.append("mat.save()")
	return "\n".join(lines)+"\n"
