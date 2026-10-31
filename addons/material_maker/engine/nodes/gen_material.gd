@tool
extends MMGenShader
class_name MMGenMaterial


var buffer_name_prefix : String

var export_last_target : String = ""

## Outputs of the standard Material node (material.mmg) used by exports, the
## path tracer and runtime packages
const OUTPUT_ALBEDO : int = 0
const OUTPUT_ORM : int = 1
const OUTPUT_EMISSION : int = 2
const OUTPUT_NORMAL : int = 3
const OUTPUT_DEPTH : int = 4
const OUTPUT_SSS : int = 5
const OUTPUT_HEIGHT : int = 8
const OUTPUT_EXTRA : int = 14
const OUTPUT_TRANSMISSION : int = 19
## Inputs of the standard Material node, in port order
const STANDARD_INPUTS : Array[String] = [ "albedo_tex", "metallic_tex", "roughness_tex", "emission_tex", "normal_tex", "ao_tex", "depth_tex", "opacity_tex", "sss_tex", "coat_tex", "coat_roughness_tex", "anisotropy_tex", "sheen_tex", "transmission_tex" ]

## Outputs that are colors (albedo, emission), converted to the export color
## space when OCIO is used
const COLOR_OUTPUTS : Array[int] = [ OUTPUT_ALBEDO, OUTPUT_EMISSION ]
var export_paths : Dictionary = {}
## Export targets last exported with UDIM tiles (for Export again)
var export_udim : Dictionary = {}
var uids = {}

var updating : bool = false
var update_again : bool = false

var preview_material : ShaderMaterial = null
var preview_conditionals : String = ""
var preview_parameters : Dictionary = {}
var preview_textures = {}
var preview_texture_dependencies : Dictionary[String, MMTexture] = {}

var external_previews : Dictionary[Node, Array] = {}
var export_output_def : Dictionary

## Size (as log2) of exports with an explicit size (e.g. --size on the command
## line), followed by buffers sized relatively to the material, or -1
var export_size_override : int = -1


# The minimum allowed texture size as a power-of-two exponent
const TEXTURE_SIZE_MIN : int = 4  # 16x16

# The maximum allowed texture size as a power-of-two exponent
const TEXTURE_SIZE_MAX : int = 13  # 8192x8192

# The default texture size as a power-of-two exponent
const TEXTURE_SIZE_DEFAULT : int = 10  # 1024x1024

# The minimum allowed texture size as a power-of-two exponent
const TEXTURE_FILTERING_LIMIT : int = 256

const EXPORT_OUTPUT_DEF_INDEX : int = 12345


func _ready() -> void:
	preview_material = ShaderMaterial.new()
	preview_material.shader = Shader.new()
	buffer_name_prefix = "material_%d" % get_instance_id()
	mm_deps.create_buffer(buffer_name_prefix, self)
	parameter_changed.connect(on_parameter_changed)
	update()

## Changing a float parameter only updates a uniform, so the preview shader
## is regenerated when the change flips one of its $if conditions
func on_parameter_changed(p : String, _v) -> void:
	if preview_material == null or get_parameter_def(p).get("type") != "float":
		return
	if shader_model.preview_shader.find("$(param:"+p+")") == -1:
		return
	if process_conditionals(shader_model.preview_shader) != preview_conditionals:
		update()

func accept_float_expressions() -> bool:
	return false

func can_be_deleted() -> bool:
	return false

func get_type() -> String:
	return "material_export"

func get_type_name() -> String:
	if shader_model.has("name"):
		return shader_model.name
	return "Material"

func get_output_defs(show_hidden : bool = false) -> Array:
	return super.get_output_defs() if show_hidden else []

func get_preprocessed_output_def(output_index : int):
	if output_index == EXPORT_OUTPUT_DEF_INDEX:
		return export_output_def
	return super.get_preprocessed_output_def(output_index)


## Height of exported images: the size with the material's aspect ratio
## Height of exported images of a given width (by default, the material's
## size), with the material's aspect ratio
func get_image_height(width : int = 0) -> int:
	var size : int = width if width > 0 else get_image_size()
	return MMGenBuffer.aspect_height(size, int(get_parameter("aspect"))) if parameters.has("aspect") else size

func get_image_size() -> int:
	var rv : int
	if parameters.has("size"):
		rv = int(pow(2, parameters.size))
	else:
		rv = int(pow(2, TEXTURE_SIZE_DEFAULT))
	return rv

func update_preview() -> void:
	var graph_edit = self
	while graph_edit is MMGenBase:
		graph_edit = graph_edit.get_parent()
	if graph_edit != null and graph_edit.has_method("send_changed_signal"):
		graph_edit.send_changed_signal()

## Returns the material's output size (as log2), that buffers sized relatively
## to the material follow, or -1 if it has none
func get_output_size() -> int:
	if export_size_override >= 0:
		return export_size_override
	if parameters.has("size"):
		return int(parameters.size)
	return -1

## Makes buffers sized relatively to the material follow an export size (in
## pixels, rounded to a power of 2), or the material's size again (0)
func set_export_size_override(size : int) -> void:
	var size_log2 : int = roundi(log(float(size))/log(2.0)) if size > 0 else -1
	if size_log2 == export_size_override:
		return
	var previous_size : int = get_output_size()
	export_size_override = size_log2
	if get_output_size() != previous_size and get_parent() != null:
		notify_output_size_changed(get_parent())

func set_parameter(p, v) -> void:
	super.set_parameter(p, v)
	# Buffers can be sized relatively to the material's size
	if p == "size" and get_parent() != null:
		notify_output_size_changed(get_parent())

static func notify_output_size_changed(node : Node) -> void:
	for c in node.get_children():
		if c.has_method("on_output_size_changed"):
			c.on_output_size_changed()
		notify_output_size_changed(c)

func source_changed(input_index : int) -> void:
	update()

func all_sources_changed() -> void:
	update()

func set_shader_model(data: Dictionary) -> void:
	var has_externals : bool = false
	var export_names = data.exports.keys()
	var external_export_targets : Dictionary = {}
	if data.has("exports") and is_template():
		for k in export_names:
			var e = data.exports[k]
			if e.has("external") and e.external:
				e.material = get_template_name()
				e.erase("external")
				data.exports.erase(k)
				external_export_targets[k] = e
	if ! external_export_targets.is_empty():
		mm_loader.update_external_export_targets(get_template_name(), external_export_targets)
	super.set_shader_model(data)
	update()

var update_scheduled : bool = false

func update_shaders() -> void:
	if update_scheduled:
		return
	update_scheduled = true
	await get_tree().process_frame
	update_scheduled = false
	for t in preview_textures.keys():
		var preview_texture : Dictionary = preview_textures[t]
		preview_texture.shader_compute = MMShaderCompute.new()
		var context : MMGenContext = MMGenContext.new()
		var source : ShaderCode = get_shader_code("uv", preview_texture.output, context)
		await preview_texture.shader_compute.set_shader_from_shadercode(source, false)
		mm_deps.buffer_create_compute_material(preview_texture.buffer, preview_texture.shader_compute)
	mm_deps.update()

func on_dep_update_value(buffer_name, parameter_name, value) -> bool:
	if value == null:
		return false
	if buffer_name == buffer_name_prefix:
		preview_parameters[parameter_name] = value
		for ppn in external_previews.keys():
			for p in external_previews[ppn]:
				if value is MMTexture:
					var texture = await value.get_texture()
					p.set_shader_parameter(parameter_name, texture)
					preview_texture_dependencies[parameter_name] = value
				else:
					p.set_shader_parameter(parameter_name, value)
	else:
		var texture_name : String = buffer_name.right(-(buffer_name_prefix.length()+1))
		preview_textures[texture_name].shader_compute.set_parameter(parameter_name, value)
	return false

func on_dep_update_buffer(buffer_name) -> bool:
	if buffer_name == buffer_name_prefix:
		await get_tree().process_frame
		mm_deps.dependency_update(buffer_name, null, true)
		return true
	var texture_name : String = buffer_name.right(-(buffer_name_prefix.length()+1))
	if ! preview_textures.has(texture_name) or ! preview_textures[texture_name].has("shader_compute"):
		print("Cannot update ", buffer_name)
		print(preview_textures[texture_name])
		return false
	var size = get_image_size()
	await preview_textures[texture_name].shader_compute.render(preview_textures[texture_name].texture, size)
	mm_deps.dependency_update(preview_textures[texture_name].buffer, preview_textures[texture_name].texture, true)
	for ppn in external_previews.keys():
		for p in external_previews[ppn]:
			p.set_shader_parameter(texture_name, await preview_textures[texture_name].texture.get_texture())
	if size <= TEXTURE_FILTERING_LIMIT:
		pass
		#preview_textures[texture_name].texture.flags &= ~Texture2D.FLAG_FILTER
	else:
		pass
		#preview_textures[texture_name].texture.flags |= Texture2D.FLAG_FILTER
	return true

func update_materials(material_list, sequential : bool = false) -> void:
	for m in material_list:
		update_material(m, sequential)

func update_material(m, sequential : bool = false) -> void:
	if m is ShaderMaterial:
		m.shader = preview_material.shader
		for t in preview_textures.keys():
			m.set_shader_parameter(t, await preview_textures[t].texture.get_texture())
		for t in preview_texture_dependencies.keys():
			# Textures of inputs (such as Image nodes) are MMTextures
			var texture = preview_texture_dependencies[t]
			m.set_shader_parameter(t, await texture.get_texture() if texture is MMTexture else texture)
		for p in preview_parameters.keys():
			m.set_shader_parameter(p, preview_parameters[p])
			if preview_parameters[p] is MMTexture:
				m.set_shader_parameter(p, await preview_parameters[p].get_texture())
			else:
				m.set_shader_parameter(p, preview_parameters[p])

func update_external_previews() -> void:
	for ppn in external_previews.keys():
		for p in external_previews[ppn]:
			update_material(p)

func update() -> void:
	if preview_material == null:
		return
	var processed_preview_shader : String = process_conditionals(shader_model.preview_shader)
	preview_conditionals = processed_preview_shader
	if MMOpenPBRPreview.is_enabled():
		processed_preview_shader = MMOpenPBRPreview.apply(processed_preview_shader, shader_model.preview_shader)
	var result = process_shader(processed_preview_shader)
	result.shader_code = MMGenBase.remove_constant_declarations(result.shader_code)
	mm_deps.buffer_create_shader_material(buffer_name_prefix, MMShaderMaterial.new(preview_material), result.shader_code)
	preview_texture_dependencies = {}
	for u in result.uniforms:
		if u.value:
			if u.type == "sampler2D":
				preview_texture_dependencies[u.name] = u.value
				var texture = await u.value.get_texture()
				preview_material.set_shader_parameter(u.name, texture)
			else:
				preview_material.set_shader_parameter(u.name, u.value)
				preview_parameters[u.name] = u.value
	update_shaders()
	update_external_previews()

class CustomOptions:
	extends RefCounted

func check_custom_script(custom_script : String) -> bool:
	for s in [ "OS", "DirAccess", "FileAccess" ]:
		if custom_script.find(s) != -1:
			print("Invalid custom script (found '%s')" % s)
			return false
	return true

func apply_gen_options(s : String, gen_options : Array, custom_options, definitions : String, is_definitions : bool = false):
	var found_option : bool = false
	for o in gen_options:
		for so in [ self, custom_options ]:
			var method_name : String = "process_option_"+o
			var params : int = 0
			for m in so.get_method_list():
				if m.name == method_name:
					params = m.args.size()
					break
			match params:
				2:
					s = so.call(method_name, s, is_definitions)
					found_option = true
					break
				3:
					s = so.call(method_name, s, is_definitions, definitions)
					found_option = true
					break
		if ! found_option:
			print("No implementation of option '%s'" % o)
	return s

func process_shader(shader_text : String, custom_script : String = "", force_uniforms_init : bool = false):
	var custom_options = CustomOptions.new()
	if custom_script != "" and check_custom_script(custom_script):
		print("Using custom script")
		var custom_options_script = GDScript.new()
		custom_options_script.source_code = "extends RefCounted\n\n"+custom_script
		custom_options_script.reload()
		custom_options.set_script(custom_options_script)
	var rv : ShaderCode = ShaderCode.new()
	var shader_code = ""
	for t in preview_textures.keys():
		mm_deps.delete_buffer(preview_textures[t].buffer)
	preview_textures = {}
	var context : MMGenContext = MMGenContext.new()
	var texture_regexp : RegEx = RegEx.new()
	texture_regexp.compile("uniform\\s+sampler2D\\s+([\\w_]+).*output\\((\\d+)\\)")
	var variables : Dictionary = get_common_replace_variables("UV", rv)
	process_parameters(rv, variables, true)
	process_inputs(rv, variables, context, true)
	# Generate shader
	var generating : bool = false
	var gen_buffer : String = ""
	var gen_options : Array = []
	for l in shader_text.split("\n"):
		if generating:
			if l == "$end_generate":
				# Each block is generated on its own (it may use other UVs and
				# be in another scope): its code does not include the code of
				# previous blocks. A child context generates the code again,
				# while functions are only defined once (by the parent context).
				rv.code = ""
				var subst_code = replace_variables(gen_buffer, variables, rv, MMGenContext.new(context))
				# Add generated code
				var new_code : String = rv.code+"\n"
				new_code += subst_code+"\n"
				var definitions : String = ""
				if force_uniforms_init:
					definitions += rv.uniforms_as_strings("uniform", true)
				else:
					definitions += rv.uniforms_as_strings("uniform", false)
				for d in rv.globals:
					definitions += "// #globals: %s\n" % d.source
					definitions += d.code+"\n"
				definitions += rv.defs+"\n"
				shader_code += apply_gen_options(new_code, gen_options, custom_options, definitions)
				generating = false
			else:
				gen_buffer += l+"\n"
		elif l.find("$begin_generate") != -1:
			generating = true
			gen_buffer = ""
			gen_options = l.replace(" ", "").replace("$begin_generate", "").split(",", false)
		else:
			var result = texture_regexp.search(l)
			if result:
				var buffer_name = "%s_%s" % [ buffer_name_prefix, result.strings[1] ]
				preview_textures[result.strings[1]] = {
					output=result.strings[2].to_int(),
					texture=MMTexture.new(),
					buffer=buffer_name
				}
				mm_deps.create_buffer(buffer_name, self)
			shader_code += l+"\n"
	var definitions : String = get_template_text("glsl_defs.tmpl")+"\n"
	if force_uniforms_init:
		definitions += rv.uniforms_as_strings("uniform", true)
	else:
		definitions += rv.uniforms_as_strings("uniform", false)
	for d in rv.globals:
		definitions += "// #globals: %s\n" % d.source
		definitions += d.code+"\n"
	definitions += rv.defs+"\n"
	
	shader_text = shader_code
	shader_code = ""
	for l in shader_text.split("\n"):
		if l.find("$definitions") != -1:
			var processed_definitions = definitions
			gen_options = l.replace(" ", "").replace("$definitions", "").split(",", false)
			processed_definitions = apply_gen_options(processed_definitions, gen_options, custom_options, definitions, true)
			for dl in processed_definitions.split("\n"):
				if dl.replace(" ", "") != "":
					shader_code += dl
					shader_code += "\n"
		else:
			shader_code += l
			shader_code += "\n"
	return { shader_code = shader_code, uniforms = rv.uniforms }

func set_3d_previews(previews : Dictionary[Node, Array]):
	for k in previews:
		external_previews[k] = previews[k]
	update_external_previews()

# Export filters

func process_option_hlsl_base(s : String, is_declaration : bool = false) -> String:
	s = s.replace("ivec2(", "toint2(")
	s = s.replace("ivec3(", "toint3(")
	s = s.replace("ivec4(", "toint4(")
	s = s.replace("vec2(", "tofloat2(")
	s = s.replace("vec3(", "tofloat3(")
	s = s.replace("vec4(", "tofloat4(")
	s = s.replace("ivec2", "int2")
	s = s.replace("ivec3", "int3")
	s = s.replace("ivec4", "int4")
	s = s.replace("vec2", "float2")
	s = s.replace("vec3", "float3")
	s = s.replace("vec4", "float4")
	s = s.replace("mat2(", "tofloat2x2(")
	s = s.replace("mat2", "float2x2")
	s = s.replace("mix", "lerp")
	s = s.replace("fract", "frac")
	s = s.replace("atan", "hlsl_atan")
	var re : RegEx = RegEx.new()
	re.compile("(\\w+)\\s*\\*=\\s*tofloat2x2([^;]+);")
	while true:
		var m : RegExMatch = re.search(s)
		if m == null:
			break
		s = s.replace(m.strings[0], "%s = mul(%s, tofloat2x2%s);" % [ m.strings[1], m.strings[1], m.strings[2] ])
	re.compile("(?:int|float)[234]?\\[\\d*\\]\\((.*)\\);")
	while true:
		var m : RegExMatch = re.search(s)
		if m == null:
			break
		s = s.replace(m.strings[0], "{ %s };" % [ m.strings[1] ])
	if is_declaration:
		s = get_template_text("hlsl_defs.tmpl")+"\n\n// EngineSpecificDefinitions\n\n\n"+s
	return s

func process_option_hlsl(s : String, is_declaration : bool = false) -> String:
	s = process_option_hlsl_base(s, is_declaration)
	s = s.replace("uniform float", "static const float")
	s = s.replace("uniform vec4", "static const vec4")
	s = s.replace("uniform int", "static const int")
	return s

func process_option_float_uniform_to_const(s : String, is_declaration : bool = false) -> String:
	s = s.replace("uniform float", "const float")
	s = s.replace("uniform vec4", "const vec4")
	s = s.replace("uniform int", "const int")
	return s

## Uniforms become global variables (for shading languages, such as MaterialX's
## GLSL functions, that cannot declare uniforms). Textures (samplers) are
## removed: templates map them to their own inputs ($(buffer_name)).
func process_option_uniform_to_global(s : String, is_declaration : bool = false) -> String:
	s = RegEx.create_from_string("(?m)^uniform\\s+sampler2D\\s[^;\\n]*;[ \\t]*\\n?").sub(s, "", true)
	return RegEx.create_from_string("(?m)^uniform\\s+").sub(s, "", true)

## Uniform arrays become constants (Godot shaders cannot have default values
## for uniform arrays), other uniforms keep their values as defaults
func process_option_array_uniform_to_const(s : String, is_declaration : bool = false) -> String:
	var re : RegEx = RegEx.create_from_string("(?m)^uniform(\\s+\\w+\\s+\\w+\\s*\\[\\d*\\]\\s*=)")
	return re.sub(s, "const$1", true)

func process_option_rename_buffers(s : String, is_declaration : bool = false) -> String:
	var index : int = 1
	for t in preview_texture_dependencies.keys():
		s = s.replace(t, "texture_%d" % index)
		index += 1
	return s

func process_option_unity(s : String, is_declaration : bool = false) -> String:
	s = s.replace("elapsed_time", "_Time.y")
	return s

func process_option_unreal(s : String, is_declaration : bool = false) -> String:
	s = s.replace("elapsed_time", "Time")
	s = s.replace("uniform sampler2D", "// uniform sampler2D ")
	if is_declaration:
		s = s.replace("// EngineSpecificDefinitions", "#define textureLod(t, uv, lod) t.SampleLevel(t##Sampler, uv, lod)");
	return s

func sort_fct_longest_name(a, b) -> bool:
	var la : int = a.strings[2].length()
	var lb : int = b.strings[2].length()
	return lb<la

func preprocess_option_unreal5(s : String) -> Array:
	var unreal5_decls : Array
	var re = RegEx.new()
	re.compile("(?:uniform|const)\\s+([\\w_]+)\\s+([\\w_]+)((?:\\[\\d+\\])?)\\s*=\\s*([^;]+);")
	for d in split_glsl(s):
		d = process_option_hlsl_base(d)
		var extracted = re.search_all(d)
		unreal5_decls.append_array(extracted)
	unreal5_decls.sort_custom(Callable(self, "sort_fct_longest_name"))
	return unreal5_decls

func process_option_unreal5(s : String, is_declaration : bool = false, declarations : String = "") -> String:
	s = s.replace("elapsed_time", "Time")
	s = s.replace("uniform sampler2D", "// uniform sampler2D ")
	if is_declaration:
		# textureLod is a macro that uses the texture's sampler (the DX9 style
		# function of hlsl_defs.tmpl does not compile in Unreal 5)
		s = RegEx.create_from_string("inline\\s+float4\\s+textureLod\\s*\\([^)]*\\)\\s*\\{[^}]*\\}").sub(s, "")
		s = s.replace("// EngineSpecificDefinitions", "#define textureLod(t, uv, lod) t.SampleLevel(t##Sampler, uv, lod)");
		# Definitions are member functions of a struct, and FXC (Shader Model
		# 5) rejects member functions whose body starts with a block (as
		# the functions of 2 point curves do)
		s = RegEx.create_from_string("(\\)\\s*\\{[ \\t]*\\n)(\\s*\\{)").sub(s, "$1;$2", true)
		for d in preprocess_option_unreal5(s):
			s = s.replace(d.strings[0], d.strings[1]+" "+d.strings[2]+d.strings[3]+";")
	else:
		var initializations : String = ""
		for d in preprocess_option_unreal5(declarations):
			if d.strings[3] == "":
				initializations += d.strings[2]+" = "+d.strings[4]+";\n"
			else:
				var array_size = d.strings[3].trim_prefix("[").trim_suffix("]").to_int()
				var values: Array = Array(d.strings[4].replace("{", "").replace("}", "").strip_edges().split(","))
				for i in array_size:
					var value : String = ""
					while true:
						if values.is_empty():
							break
						if value != "":
							value += ","
						value += values.pop_front()
						if value.count("(") == value.count(")"):
							break
					initializations += d.strings[2]+"["+str(i)+"] = "+value.strip_edges()+";\n"
		# Declarations are renamed with the buffers, so are their initializations
		s = process_option_rename_buffers(initializations)+s
	s = s.replace("sampler2D", "sampler")
	return s

# Export

func get_export_profiles() -> Array:
	var export_profiles : Array = []
	if shader_model.has("exports"):
		export_profiles = shader_model.exports.keys()
	if get_template_name() != null:
		for k in mm_loader.get_external_export_targets(get_template_name()).keys():
			if export_profiles.find(k) == -1:
				export_profiles.append(k)
	export_profiles.sort()
	return export_profiles

func get_export(profile : String) -> Dictionary:
	if get_template_name() != null:
		var external_export_targets = mm_loader.get_external_export_targets(get_template_name())
		if external_export_targets.has(profile):
			return external_export_targets[profile]
	if shader_model.has("exports") and shader_model.exports.has(profile):
		return shader_model.exports[profile]
	return {}

func get_export_extension(profile : String) -> String:
	var export_profile : Dictionary = get_export(profile)
	if export_profile.has("export_extension"):
		return export_profile.export_extension
	return ""

func get_last_export_target() -> String:
	return export_last_target

func get_export_path(profile : String) -> String:
	if export_paths.has(profile):
		return export_paths[profile]
	return ""

static func subst_string(s : String, export_context : Dictionary) -> String:
	var modified : bool = true
	while modified:
		modified = false
		for k in export_context.keys():
			var new_s = s.replace(k, export_context[k])
			if new_s != s:
				s = new_s
				modified = true
	var search_position = 0
	while (true):
		var search_string = "$(expr:"
		var position = s.find(search_string, search_position)
		if position == -1:
			break
		search_position = position+1
		var parenthesis_level = 0
		var expr_begin = position+search_string.length()
		for i in range(expr_begin, s.length()):
			if s[i] == '(':
				parenthesis_level += 1
			elif s[i] == ')':
				if parenthesis_level == 0:
					var expression = s.substr(expr_begin, i-expr_begin)
					var expr = Expression.new()
					var error = expr.parse(expression, [])
					if error == OK:
						s = s.replace(s.substr(position, i+1-position), str(expr.execute()))
					elif false:
						print("EXPRESSION ERROR ("+expression+")")
						print("error: "+str(error))
						s = s.replace(s.substr(position, i+1-position), "EXPRESSION ERROR ("+expression+")")
					break
				parenthesis_level -= 1
	return s

static func get_template_text(template : String) -> String:
	var file_path : String = MMPaths.STD_GENDEF_PATH+"/"+template
	var in_file : FileAccess = FileAccess.open(file_path, FileAccess.READ)
	if in_file == null:
		return template
	return in_file.get_as_text()

const CONDITIONAL_DIRECTIVES : Array[String] = [ "$if", "$elif", "$else", "$fi" ]

## Returns the conditional directive ($if, $elif, $else or $fi) a template
## line starts with (after optional indentation), or an empty string
static func get_conditional_directive(line : String) -> String:
	var stripped : String = line.strip_edges(true, false)
	for d in CONDITIONAL_DIRECTIVES:
		if stripped.begins_with(d) and (stripped.length() == d.length() or stripped[d.length()] in [ " ", "\t", "\r" ]):
			return d
	return ""

## Evaluates the condition of an $if or $elif directive. A condition that
## cannot be parsed is reported and considered false.
static func evaluate_condition(condition : String, context : Dictionary) -> bool:
	condition = subst_string(condition.strip_edges(), context)
	var expr = Expression.new()
	var error = expr.parse(condition, [])
	if error != OK:
		print("Error in expression "+condition+": "+expr.get_error_text())
		return false
	return true if expr.execute() else false

## Keeps the lines of a template that are selected by its $if / $elif /
## $else / $fi blocks. Blocks can be nested and directives can be indented.
func process_conditionals(template : String) -> String:
	var context = get_connections_and_parameters_context()
	var processed : String = ""
	# For each open block, whether the lines around it are kept and whether
	# one of its branches has already been selected
	var blocks : Array[Dictionary] = []
	var keep : bool = true
	for l in template.split("\n"):
		if l == "":
			continue
		var directive : String = get_conditional_directive(l)
		if directive == "":
			if keep:
				processed += l
				processed += "\n"
		elif directive == "$if":
			var block : Dictionary = { outer = keep, selected = false }
			if keep:
				keep = evaluate_condition(l.strip_edges(true, false).right(-3), context)
				block.selected = keep
			blocks.push_back(block)
		elif blocks.is_empty():
			print("Template error: "+directive+" without $if")
		else:
			var block : Dictionary = blocks.back()
			match directive:
				"$elif":
					keep = false
					if block.outer and not block.selected:
						keep = evaluate_condition(l.strip_edges(true, false).right(-5), context)
						block.selected = keep
				"$else":
					keep = block.outer and not block.selected
					block.selected = true
				"$fi":
					keep = block.outer
					blocks.pop_back()
	if not blocks.is_empty():
		print("Template error: missing $fi")
	return processed

static func process_template(template : String, export_context : Dictionary) -> String:
	var processed : String = ""
	var skip_state : Array = [ false ]
	for l in template.split("\n"):
		if l == "":
			continue
		processed += subst_string(l, export_context)
		processed += "\n"
	return processed

func process_buffers(template : String) -> String:
	var processed : String = ""
	var generating : bool = false
	var gen_buffer : String = ""
	var gen_options : Array = []
	for l in template.split("\n"):
		if generating:
			if l == "$end_buffers":
				var index : int = 1
				for t in preview_texture_dependencies.keys():
					processed += subst_string(gen_buffer, { "$(buffer_index)":str(index), "$(buffer_name)":t })
					index += 1
				generating = false
			else:
				gen_buffer += l+"\n"
		elif l == "$begin_buffers":
			generating = true
			gen_buffer = ""
		else:
			processed += l+"\n"
	return processed

func reset_uids() -> void:
	uids = {}

func get_uid(index : int) -> String:
	if ! uids.has(index):
		var uid : String = ""
		var r = []
		for _k in range(16):
			r.append(randi() & 255)
		r[6] = (r[6] & 0x0f) | 0x40
		r[8] = (r[8] & 0x3f) | 0x80
		for k in range(16):
			@warning_ignore("unassigned_variable_op_assign")
			uid += '%02x' % r[k]
		uids[index] = uid
	return uids[index]

func process_uids(template : String) -> String:
	var uid_regexp : RegEx = RegEx.new()
	uid_regexp.compile("\\$uid\\((\\w+)\\)")
	while true:
		var result = uid_regexp.search(template)
		if ! result:
			break
		var uid = get_uid(int(result.strings[1]))
		template = template.replace(result.strings[0], uid)
	return template

## Generates the code of an export template. Templates with a $inline_buffers
## line are fully procedural: buffers generate their input's code instead of
## being textures (iterate buffers are still textures).
func process_export_shader(template : String, custom_script : String) -> Dictionary:
	# process_shader deletes the preview's textures and creates those of the
	# template (export templates have none): keep the preview's textures
	var saved_preview_textures : Dictionary = preview_textures
	preview_textures = {}
	var inline_buffers : bool = template.contains("$inline_buffers\n")
	MMGenBuffer.inline_buffers = inline_buffers
	var result : Dictionary = process_shader(template.replace("$inline_buffers\n", ""), custom_script, true)
	MMGenBuffer.inline_buffers = false
	for t in preview_textures.keys():
		mm_deps.delete_buffer(preview_textures[t].buffer)
	preview_textures = saved_preview_textures
	return result

func create_file_from_template(template : String, file_name : String, export_context : Dictionary) -> Error:
	template = get_template_text(template)
	var processed_template : String = process_uids(process_buffers(process_conditionals(process_template(template, export_context))))
	var custom_script = ""
	if export_context.has("@mm_custom_script"):
		custom_script = export_context["@mm_custom_script"]
	processed_template = process_export_shader(processed_template, custom_script).shader_code
	if file_name == "clipboard":
		DisplayServer.clipboard_set("\n".join(processed_template.split("\n", false)))
	else:
		DirAccess.remove_absolute(file_name)
		var out_file = FileAccess.open(file_name, FileAccess.WRITE)
		if FileAccess.get_open_error() != OK:
			print("Cannot write file '"+file_name+"' ("+str(FileAccess.get_open_error())+")")
			return FileAccess.get_open_error()
		out_file.store_string(processed_template)
	return OK

func get_connections_and_parameters_context() -> Dictionary:
	var context : Dictionary = {}
	for i in range(shader_model.inputs.size()):
		var input = shader_model.inputs[i]
		context["$(connected:"+input.name+")"] = "true" if get_source(i) != null else "false"
	for p in shader_model.parameters:
		var value = p.default
		if parameters.has(p.name):
			value = parameters[p.name]
		match p.type:
			"float", "size":
				context["$(param:"+p.name+")"] = str(value)
			"boolean":
				context["$(param:"+p.name+")"] = str(value).to_lower()
			"color":
				context["$(param:"+p.name+".r)"] = str(value.r)
				context["$(param:"+p.name+".g)"] = str(value.g)
				context["$(param:"+p.name+".b)"] = str(value.b)
				context["$(param:"+p.name+".a)"] = str(value.a)
	return context

## Textures (buffers) used by the shader code that templates of an export
## generate ($begin_generate), or null if no template generates code
func get_generated_texture_dependencies(export_profile : Dictionary, export_context : Dictionary):
	var dependencies = null
	for f in export_profile.files:
		if f.type != "template":
			continue
		var template : String = get_template_text(f.template)
		if template.find("$begin_generate") == -1:
			continue
		if dependencies == null:
			dependencies = {}
		var custom_script : String = export_context.get("@mm_custom_script", "")
		var result = process_export_shader(process_conditionals(process_template(template, export_context)), custom_script)
		for u in result.uniforms:
			if u.type == "sampler2D" and u.value is MMTexture:
				dependencies[u.name] = u.value
	return dependencies

## Exports the material with a target (profile), with size x size textures (or
## size x height when height is not 0). With UDIM tiles, textures are exported
## for each tile (see export_texture_file).
func export_material(prefix : String, profile : String, size : int = 0, command_line : bool = false, height : int = 0, tiles : PackedInt32Array = PackedInt32Array()) -> void:
	mm_deps.set_exporting(true)
	# Buffers sized relatively to the material follow an explicit export size
	set_export_size_override(size)
	await export_material_with_profile(prefix, profile, size, command_line, height, tiles)
	set_export_size_override(0)
	mm_deps.set_exporting(false)

func export_material_with_profile(prefix : String, profile : String, size : int = 0, command_line : bool = false, height : int = 0, tiles : PackedInt32Array = PackedInt32Array()) -> void:
	# Buffers that are rendered can be released before the export renders more
	mm_deps.release_unused_buffers()
	# Exports that generate shader code (procedural materials) export the
	# buffers their code uses instead of the textures of the preview
	var export_profile = get_export(profile)
	var export_context : Dictionary = get_connections_and_parameters_context()
	if export_profile.has("custom"):
		export_context["@mm_custom_script"] = export_profile.custom
	var generated_dependencies = get_generated_texture_dependencies(export_profile, export_context)
	if generated_dependencies == null:
		await do_export_material(prefix, profile, size, command_line, height, tiles)
		await MMPlugins.call_export_hooks(self, prefix, profile)
		return
	var saved_dependencies : Dictionary[String, MMTexture] = preview_texture_dependencies
	preview_texture_dependencies = {}
	for t in generated_dependencies.keys():
		preview_texture_dependencies[t] = generated_dependencies[t]
	await do_export_material(prefix, profile, size, command_line, height, tiles)
	preview_texture_dependencies = saved_dependencies
	await MMPlugins.call_export_hooks(self, prefix, profile)

## Waits until the render queue is empty. The queue's size does not change
## while iterate buffers iterate, so this does not stop when it is stable
## (that exported textures of unfinished iterate buffers), but only gives up
## when it does not change for a long time (a buffer that never finishes).
func wait_for_render_queue() -> void:
	const STUCK_TIMEOUT_MS : int = 60000
	var render_queue_size : int = mm_deps.get_render_queue_size()
	var render_progress : int = mm_deps.render_progress
	var last_change : int = Time.get_ticks_msec()
	while render_queue_size > 0:
		mm_deps.update()
		# Poll instead of awaiting mm_deps.updated: an update loop that is
		# replaced (e.g. when a buffer being rendered is deleted) never emits it
		await mm_deps.get_tree().process_frame
		if render_queue_size != mm_deps.get_render_queue_size() or render_progress != mm_deps.render_progress:
			# Slow buffers (e.g. Iterate Buffers with many iterations) keep
			# the queue size, but make progress
			render_queue_size = mm_deps.get_render_queue_size()
			render_progress = mm_deps.render_progress
			last_change = Time.get_ticks_msec()
		elif Time.get_ticks_msec()-last_change > STUCK_TIMEOUT_MS:
			push_warning("Exporting while %d buffer(s) are still rendering" % render_queue_size)
			break

## The file name of a UDIM tile: <UDIM> is replaced by the tile number, or the
## number is inserted before the extension (albedo.png -> albedo.1001.png)
static func udim_file_name(file_name : String, tile : int) -> String:
	if tile == 0:
		return file_name.replace("<UDIM>", "1001")
	if file_name.contains("<UDIM>"):
		return file_name.replace("<UDIM>", str(tile))
	return "%s.%d.%s" % [ file_name.get_basename(), tile, file_name.get_extension() ]

## The UDIM tiles of the graph that contains the material: those of the meshes
## of its Mesh Map and High Poly Bake nodes, and of its Image nodes' tile files
## (sorted, empty if it only uses tile 1001)
func get_graph_udim_tiles() -> PackedInt32Array:
	var tiles : Dictionary = {}
	var pending : Array = [ get_parent() ]
	while not pending.is_empty():
		var node = pending.pop_back()
		for c in node.get_children():
			if c is MMGenBase:
				for t in c.get_udim_tiles():
					tiles[t] = true
				if c is MMGenGraph:
					pending.push_back(c)
	var rv : PackedInt32Array = PackedInt32Array(tiles.keys())
	rv.sort()
	return PackedInt32Array() if rv.size() == 0 or rv == PackedInt32Array([ 1001 ]) else rv

## Makes the nodes of a graph (and its subgraphs) generate a UDIM tile (0 to
## go back to their own settings)
static func set_graph_udim_tile(graph : Node, tile : int) -> void:
	if graph == null:
		return
	for c in graph.get_children():
		if c is MMGenBase:
			await c.set_udim_tile(tile)
			if c is MMGenGraph:
				await set_graph_udim_tile(c, tile)

## Renders and saves a texture file of an export target (for a UDIM tile if
## tile is not 0). Files with a layer are added to layers (by file name) and
## saved later, all layers in a file.
func export_texture_file(f : Dictionary, export_context : Dictionary, image_size : Vector2i, tile : int, layers : Dictionary) -> Error:
	await wait_for_render_queue()
	var file_name : String = subst_string(f.file_name, export_context)
	if tile != 0 or file_name.contains("<UDIM>"):
		file_name = udim_file_name(file_name, tile)
	var output_index : int
	if f.has("output"):
		output_index = f.output
	elif f.has("expression"):
		var type = "rgba"
		var expression = f.expression
		var equal_position = expression.find("=")
		if equal_position != -1:
			var type_string = expression.left(equal_position)
			type_string = type_string.strip_edges()
			if type_string == "f" or type_string == "rgb" or type_string == "rgba":
				type = type_string
				expression = expression.right(-(equal_position+1))
		export_output_def = { type: expression, "type":type }
		output_index = EXPORT_OUTPUT_DEF_INDEX
	else:
		return FAILED
	var result : MMTexture = await render_output_to_texture(output_index, image_size)
	# Options of the image format (formats added by plugins), color maps
	# being sRGB encoded by default
	var options : Dictionary = f.get("options", {}).duplicate()
	if not options.has("srgb"):
		options.srgb = output_index in COLOR_OUTPUTS
	# Rendered textures are RGBA: formats that can store fewer channels use
	# the output's type
	var output_type : String = "rgba"
	if output_index == EXPORT_OUTPUT_DEF_INDEX:
		output_type = export_output_def.type
	elif output_index < shader_model.outputs.size():
		output_type = shader_model.outputs[output_index].get("type", "rgba")
	if not options.has("grayscale"):
		options.grayscale = output_type == "f"
	if not options.has("alpha"):
		options.alpha = output_type == "rgba"
	var image : Image = null
	var export_space : String = MMColorManagement.get_export_space()
	if export_space != "" and output_index in COLOR_OUTPUTS:
		# Color maps are converted from the working space (OCIO)
		image = MMColorManagement.convert_image_to((await result.get_texture()).get_image(), export_space)
		options.srgb = false
	if f.has("layer"):
		if image == null:
			image = (await result.get_texture()).get_image()
		if not layers.has(file_name):
			layers[file_name] = []
		layers[file_name].append({ name=f.layer, image=image, options=options })
		return OK
	if image != null:
		return await MMTexture.save_image_rounded(image, file_name, options)
	return await result.save_to_file(file_name, options)

func do_export_material(prefix : String, profile : String, size : int = 0, command_line : bool = false, height : int = 0, tiles : PackedInt32Array = PackedInt32Array()) -> void:
	reset_uids()
	if size == 0:
		size = get_image_size()
	# Without a height (e.g. --size <width> on the command line), the height
	# follows the material's aspect ratio
	if height == 0:
		height = get_image_height(size)
	export_last_target = profile
	export_paths[profile] = prefix
	if tiles.is_empty():
		export_udim.erase(profile)
	else:
		export_udim[profile] = true
	var export_context : Dictionary = get_connections_and_parameters_context()
	export_context["$(path_prefix)"] = prefix
	export_context["$(file_prefix)"] = prefix.get_file()
	export_context["$(dir_prefix)"] = prefix.get_base_dir()
	export_context["$(material_maker_path)"] = MMPaths.get_resource_dir()
	export_context["$(path_separator)"] = "/"
	# Templates write texture file names with $(udim_suffix), that is the
	# tile number placeholder in UDIM exports (USD), and $(udim_suffix_xml)
	# in XML files (MaterialX)
	export_context["$(udim_suffix)"] = ".<UDIM>" if not tiles.is_empty() else ""
	export_context["$(udim_suffix_xml)"] = ".&lt;UDIM&gt;" if not tiles.is_empty() else ""
	var exported_files : Array = []
	var overwrite_files : Array = []
	var export_profile = get_export(profile)
	if export_profile.has("custom"):
		export_context["@mm_custom_script"] = export_profile.custom
	for f in export_profile.files:
		if f.has("conditions"):
			var condition = subst_string(f.conditions, export_context)
			var expr = Expression.new()
			var error = expr.parse(condition, [])
			if error != OK:
				print("Error in expression: "+expr.get_error_text())
				continue
			if !expr.execute():
				continue
		if f.has("prompt_overwrite") and f.prompt_overwrite:
			var file_name = subst_string(f.file_name, export_context)
			if FileAccess.file_exists(file_name):
				overwrite_files.push_back(f)
				continue
		exported_files.push_back(f)
	if not command_line and not overwrite_files.is_empty():
		var dialog = load("res://material_maker/windows/accept_dialog/accept_dialog.tscn").instantiate()
		dialog.dialog_text = "Overwrite existing files?"
		for f in overwrite_files:
			var file_name = subst_string(f.file_name, export_context)
			dialog.dialog_text += "\n- "+file_name.get_file()
		dialog.add_cancel_button("Keep existing file(s)");
		mm_globals.main_window.add_child(dialog)
		var result = await dialog.ask()
		if result == "ok":
			exported_files.append_array(overwrite_files)
	var progress_dialog = null
	var dim_color_rect = null
	if not command_line:
		var progress_dialog_scene = load("res://material_maker/windows/progress_window/progress_window.tscn")
		if progress_dialog_scene != null:
			progress_dialog = progress_dialog_scene.instantiate()
		dim_color_rect = ColorRect.new()
		dim_color_rect.modulate = Color(0.05, 0.05, 0.05, 0.5)
		mm_globals.main_window.add_child(dim_color_rect)
	if progress_dialog:
		get_tree().get_root().add_child(progress_dialog)
		progress_dialog.set_text("Exporting material")
		progress_dialog.set_progress(0)
	var texture_files : Array = exported_files.filter(func(f): return f.type == "texture")
	var tile_list : Array = Array(tiles) if not tiles.is_empty() else [ 0 ]
	var total_files : int = texture_files.size()*tile_list.size()
	for f in exported_files:
		match f.type:
			"template":
				total_files += 1
			"buffers", "buffer_templates":
				total_files += preview_texture_dependencies.size()
	var processed_files = 0
	var error_files = 0
	# Textures, for each UDIM tile, then the layers of layered files
	var layers : Dictionary = {}
	for tile in tile_list:
		if tile != 0:
			await set_graph_udim_tile(get_parent(), tile)
		for f in texture_files:
			if await export_texture_file(f, export_context, Vector2i(size, height if height > 0 else size), tile, layers) != OK:
				error_files += 1
			processed_files += 1
			if progress_dialog:
				progress_dialog.set_progress(float(processed_files)/float(total_files))
	if not tiles.is_empty():
		await set_graph_udim_tile(get_parent(), 0)
	for file_name in layers.keys():
		if MMPlugins.save_layered_image(file_name, layers[file_name]) != OK:
			error_files += 1
	for f in exported_files:
		#print("Exporting ", f)
		var e: Error = OK
		match f.type:
			"template":
				var file_export_context = export_context.duplicate()
				if f.has("file_params"):
					for p in f.file_params.keys():
						file_export_context["$(file_param:"+p+")"] = f.file_params[p]
				var file_name = subst_string(f.file_name, export_context)
				e = create_file_from_template(f.template, file_name, file_export_context)
				if e != OK:
					error_files += 1
				processed_files += 1
				if progress_dialog:
					progress_dialog.set_progress(float(processed_files)/float(total_files))
			"buffers":
				await wait_for_render_queue()
				var index : int = 1
				for t in preview_texture_dependencies.keys():
					var file_name = subst_string(f.file_name, export_context)
					file_name = file_name.replace("$(buffer_index)", str(index))
					var texture : Texture2D = await preview_texture_dependencies[t].get_texture()
					var image : Image = texture.get_image()
					if image:
						# PNG files (8 bits), or the format of the file name
						# (e.g. EXR to keep the precision of iterate buffers)
						if file_name.get_extension().to_lower() == "png":
							e = await MMTexture.save_image_rounded(image, file_name)
						else:
							if image.get_format() < Image.FORMAT_RF:
								image.convert(Image.FORMAT_RGBAH)
							e = MMTexture.save_image(image, file_name)
						if e != OK:
							error_files += 1
					else:
						print("No image for texture file ", file_name)
						print(preview_texture_dependencies[t])
						error_files += 1
					index += 1
					processed_files += 1
					if progress_dialog:
						progress_dialog.set_progress(float(processed_files)/float(total_files))
			"buffer_templates":
				var index : int = 1
				for t in preview_texture_dependencies.keys():
					var file_export_context = export_context.duplicate()
					file_export_context["$(buffer_index)"] = str(index)
					if f.has("file_params"):
						for p in f.file_params.keys():
							file_export_context["$(file_param:"+p+")"] = f.file_params[p]
					var file_name = subst_string(f.file_name, export_context)
					file_name = file_name.replace("$(buffer_index)", str(index))
					e = create_file_from_template(f.template, file_name, file_export_context)
					if e != OK:
						error_files += 1
					index += 1
					processed_files += 1
					if progress_dialog:
						progress_dialog.set_progress(float(processed_files)/float(total_files))
	if progress_dialog != null:
		progress_dialog.queue_free()
	if dim_color_rect != null:
		dim_color_rect.queue_free()
	if error_files == 0:
		mm_globals.set_tip_text("Files succesfully exported as \"%s\"" % prefix, 5, 1)
		return
	if error_files >= total_files:
		if command_line:
			print("Could not export files to \"%s\"" % prefix.get_base_dir())
		else:
			mm_globals.main_window.accept_dialog("Could not export files to \"%s\"" % prefix.get_base_dir(), false, true)
		return
	if error_files < total_files:
		mm_globals.set_tip_text("%d errors encountered when exporting files" % error_files, 5, 1)
		return

func _serialize_data(data: Dictionary) -> Dictionary:
	data = super._serialize_data(data)
	if export_last_target != "":
		data.export_last_target = export_last_target
	# Export paths are saved relative to the project (see MMPaths.encode_path)
	# so "Export again" still works after the project folder is moved
	data.export_paths = {}
	for p in export_paths.keys():
		var path = export_paths[p]
		data.export_paths[p] = MMPaths.encode_path(path) if path is String else path
	if not export_udim.is_empty():
		data.export_udim = export_udim
	return data

func _serialize(data: Dictionary) -> Dictionary:
	super._serialize(data)
	data.export = {}
	return data

func _deserialize(data : Dictionary) -> void:
	super._deserialize(data)
	if data.has("export_last_target") and data.export_last_target != null:
		export_last_target = data.export_last_target
	if data.has("export_paths"):
		export_paths = {}
		for p in data.export_paths.keys():
			var path = data.export_paths[p]
			export_paths[p] = MMPaths.decode_path(path) if path is String else path
	if data.has("export_udim"):
		export_udim = data.export_udim.duplicate()

func get_shader_model_for_edit():
	var edit_shader_model = shader_model.duplicate()
	edit_shader_model.exports = edit_shader_model.exports.duplicate() if edit_shader_model.has("exports") else {}
	var template_name = get_template_name()
	if template_name != null:
		edit_shader_model.template_name = template_name
		var external_export_targets = mm_loader.get_external_export_targets(template_name)
		for e in external_export_targets.keys():
			edit_shader_model.exports[e] = external_export_targets[e]
			edit_shader_model.exports[e].external = true
	return edit_shader_model

func edit(node, tab : String = "") -> void:
	do_edit(node, load("res://material_maker/windows/material_editor/material_editor.tscn"), tab)

func edit_export_targets(node) -> void:
	do_edit(node, load("res://material_maker/windows/material_editor/export_editor.tscn"))
