extends Window


@export_multiline var shader : String = "" # (String, MULTILINE)


var generator
var output : int

@onready var value_size = $VBox/Settings/Size
@onready var value_begin = $VBox/Settings/Begin
@onready var value_end = $VBox/Settings/End
@onready var value_images = $VBox/Settings/Images
@onready var value_spritesheet : OptionButton = $VBox/Settings/Spritesheet

@onready var image_begin = $VBox/Images/HBox/Begin/SubViewport/Image
@onready var image_end = $VBox/Images/HBox/End/SubViewport/Image
@onready var image_diff = $VBox/Images/HBox/Animated/Diff
@onready var image_anim = $VBox/Images/HBox/Animated
@onready var buffer_images : Array = [ image_begin, image_end, image_anim ]

@onready var animation_player = $VBox/Images/HBox/Animated/AnimationPlayer
@onready var timer = $VBox/Images/HBox/Animated/Timer


const BUFFER_NAMES = [ "export_animation_buffer_begin", "export_animation_buffer_end", "export_animation_buffer_anim" ]


func _ready():
	content_scale_factor = mm_globals.ui_scale_factor()
	min_size = $VBox.get_combined_minimum_size() * content_scale_factor
	for i in range(BUFFER_NAMES.size()):
		mm_deps.create_buffer(BUFFER_NAMES[i], self)

	if mm_globals.get_config("remember_anim_export"):
		if mm_globals.has_config("export_animation_size"):
			value_size.selected = mm_globals.get_config("export_animation_size")
			value_size.emit_signal("item_selected", value_size.selected)
		if mm_globals.has_config("export_animation_begin"):
			value_begin.value = mm_globals.get_config("export_animation_begin")
		if mm_globals.has_config("export_animation_end"):
			value_end.value = mm_globals.get_config("export_animation_end")
		if mm_globals.has_config("export_animation_images"):
			value_images.value = mm_globals.get_config("export_animation_images")
		if mm_globals.has_config("export_animation_spritesheet"):
			value_spritesheet.selected = mm_globals.get_config("export_animation_spritesheet")


func set_source(g, o):
	generator = g
	output = o
	var context : MMGenContext = MMGenContext.new()
	var source = generator.get_shader_code("uv", output, context)
	if source.output_type == "":
		source = MMGenBase.get_default_generated_shader()
	var code = MMGenBase.generate_preview_shader(source, source.output_type, shader)
	var ends_code = code;
	ends_code = ends_code.replace("varying float elapsed_time;", "uniform float elapsed_time;");
	ends_code = ends_code.replace("elapsed_time = TIME;", "");
	var ends_shader : Shader = Shader.new()
	ends_shader.code = ends_code
	image_begin.material.shader = ends_shader
	image_end.material.shader = ends_shader
	var anim_code = code;
	anim_code = anim_code.replace("varying float elapsed_time;", "uniform float begin;\nuniform float end;\nvarying float elapsed_time;");
	anim_code = anim_code.replace("elapsed_time = TIME;", "elapsed_time = (begin == end) ? begin : begin+sign(end-begin)*mod(TIME, abs(end-begin));");
	var anim_shader : Shader = Shader.new()
	anim_shader.code = anim_code
	image_anim.material.shader = anim_shader
	for u in source.uniforms:
		image_begin.material.set_shader_parameter(u.name, u.value)
		image_anim.material.set_shader_parameter(u.name, u.value)
		image_end.material.set_shader_parameter(u.name, u.value)
	for image_index in range(BUFFER_NAMES.size()):
		var i = buffer_images[image_index]
		var b : String = BUFFER_NAMES[image_index]
		# Get parameter values from the shader code
		mm_deps.buffer_create_shader_material(b, MMShaderMaterial.new(i.material), i.material.shader.code)
	var begin : float = value_begin.value
	var end : float = value_end.value
	image_begin.material.set_shader_parameter("elapsed_time", begin)
	image_end.material.set_shader_parameter("elapsed_time", end)
	image_anim.material.set_shader_parameter("begin", begin)
	image_anim.material.set_shader_parameter("end", end)

func show_diff():
	if ! animation_player.is_playing() and ! image_diff.visible:
		animation_player.play("show")
	timer.stop()
	timer.start(0)

func _on_Begin_value_changed(value):
	image_begin.material.set_shader_parameter("elapsed_time", value)
	image_anim.material.set_shader_parameter("begin", value)
	show_diff()

func _on_End_value_changed(value):
	image_end.material.set_shader_parameter("elapsed_time", value)
	image_anim.material.set_shader_parameter("end", value)
	show_diff()

func _on_Timer_timeout():
	animation_player.play_backwards("show")


func _on_Export_pressed():
	var dialog = preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
	dialog.min_size = Vector2(500, 500)
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dialog.add_filter("*.png;PNG image files")
	var files = await dialog.select_files()
	if files.size() > 0:
		var filename : String = files[0]
		var size : int = 1 << value_size.size_value
		var begin : float = value_begin.value
		var end : float = value_end.value
		var images : int = value_images.value
		var spritesheet_lines : int = value_spritesheet.get_item_id(value_spritesheet.selected) 
		if spritesheet_lines > 500:
			spritesheet_lines = 1000-spritesheet_lines
		var spritesheet_columns : int
		var renderer = await mm_renderer.request(self)
		image_anim.material.set_shader_parameter("begin", begin)
		image_anim.material.set_shader_parameter("end", begin)
		var spritesheet : Image
		var filename_fmt
		if spritesheet_lines != 0:
			if spritesheet_lines > 0:
				spritesheet_columns = (images-1)/spritesheet_lines+1
			else:
				spritesheet_columns = -spritesheet_lines
				spritesheet_lines = (images-1)/spritesheet_columns+1
			spritesheet = Image.create(size * spritesheet_columns, size * spritesheet_lines, false, Image.FORMAT_RGBA8)
		else:
			var regex : RegEx = RegEx.new()
			regex.compile("#+")
			var regex_match : Array = regex.search_all(filename)
			if regex_match.size() > 1:
				renderer.release(self)
				return
			elif regex_match.size() == 1:
				filename_fmt = filename.replace(regex_match[0].strings[0], "%0"+str(regex_match[0].strings[0].length())+"d")
			else:
				filename_fmt = filename.get_basename()+"_%d."+filename.get_extension()
		var dependencies : Array[String] = get_animation_dependencies()
		var animated_buffers : Array = get_animated_buffers(dependencies)
		for i in range(0, images):
			var time : float = begin+(end-begin)*float(i)/float(images)
			image_anim.material.set_shader_parameter("begin", time)
			image_anim.material.set_shader_parameter("end", time)
			if not animated_buffers.is_empty():
				MMComputeShader.fixed_time = time
				await render_buffers(animated_buffers, dependencies)
			renderer = await renderer.render_material(self, image_anim.material, size, false)
			if spritesheet_lines > 0:
				var image : Image = renderer.get_image()
				spritesheet.blit_rect(image, Rect2(0, 0, size, size), Vector2(size*(i%spritesheet_columns), size*(i/spritesheet_columns)))
			else:
				renderer.save_to_file(filename_fmt % (i+1))
		renderer.release(self)
		if not animated_buffers.is_empty():
			# Render the buffers at the current time again
			MMComputeShader.fixed_time = -1.0
			invalidate_buffers(animated_buffers)
		if spritesheet_lines > 0:
			spritesheet.save_png(filename)
		image_anim.material.set_shader_parameter("begin", begin)
		image_anim.material.set_shader_parameter("end", end)
		image_anim.material.set_shader_parameter("mm_chunk_size", 1.0)
		image_anim.material.set_shader_parameter("mm_chunk_offset", Vector2(0.0, 0.0))
		
		mm_steam.unlock_achievement("ACH_IT_S_ALIVE")

	if mm_globals.get_config("remember_anim_export"):
		mm_globals.set_config("export_animation_size", value_size.selected)
		mm_globals.set_config("export_animation_begin", value_begin.value)
		mm_globals.set_config("export_animation_end", value_end.value)
		mm_globals.set_config("export_animation_images", value_images.value)
		mm_globals.set_config("export_animation_spritesheet", value_spritesheet.selected)

## The names of the buffers the exported animation depends on, directly or not
func get_animation_dependencies() -> Array[String]:
	var rv : Array[String] = []
	var to_visit : Array = mm_deps.buffers[BUFFER_NAMES[2]].dependencies.duplicate()
	while not to_visit.is_empty():
		var buffer_name : String = to_visit.pop_back()
		if rv.has(buffer_name) or not mm_deps.buffers.has(buffer_name):
			continue
		rv.append(buffer_name)
		to_visit.append_array(mm_deps.buffers[buffer_name].dependencies)
		# The output of an Iterate Buffer depends on its other buffers
		var object : Object = mm_deps.buffers[buffer_name].object
		if object is MMGenIterateBuffer:
			to_visit.append_array([ object.buffer_name_init_input, object.buffer_name_loop_input ])
		elif object is MMGenIterateBufferV2:
			to_visit.append_array([ object.buffer_name_init, object.buffer_name_loop ])
	return rv

## The buffer nodes (Buffer, Iterate Buffer, Iterate Buffer v2, FX-Map and
## GPU reductions such as Statistics) among the given buffers whose inputs
## use $time: they are rendered again for each frame
func get_animated_buffers(buffer_names : Array[String]) -> Array:
	var rv : Array = []
	for buffer_name in buffer_names:
		var generator : Object = mm_deps.buffers[buffer_name].object
		if not rv.has(generator) and is_animated_buffer(generator):
			rv.append(generator)
	return rv

## True if generator is a buffer node (that is not paused) and one of its
## inputs uses $time
static func is_animated_buffer(generator : Object) -> bool:
	if not (generator is MMGenBuffer or generator is MMGenIterateBuffer or generator is MMGenIterateBufferV2 or generator is MMGenGpuReduction or generator is MMGenSbsFxMap):
		return false
	if generator.get("is_paused") == true:
		return false
	for i in generator.get_input_defs().size():
		var source : MMGenBase.OutputPort = generator.get_source(i)
		if source == null:
			continue
		var code : MMGenBase.ShaderCode = source.generator.get_shader_code("uv", source.output_index, MMGenContext.new())
		var code_string : String = code.defs+code.code+str(code.output_values.values())
		for g in code.globals:
			code_string += g.code
		if code_string.contains("elapsed_time"):
			return true
	return false

## Invalidates buffer nodes, so they are rendered again (iterations start
## again)
static func invalidate_buffers(generators : Array) -> void:
	for generator in generators:
		if generator is MMGenIterateBuffer:
			generator.set_current_iteration(0)
			mm_deps.buffer_invalidate(generator.buffer_name_init_input)
		elif generator is MMGenIterateBufferV2:
			generator.set_current_iteration(0)
			mm_deps.buffer_invalidate(generator.buffer_name_init)
		else:
			for buffer_name in mm_deps.buffers.keys():
				if mm_deps.buffers[buffer_name].object == generator:
					mm_deps.buffer_invalidate(buffer_name)

## Renders the given buffers again (at MMComputeShader.fixed_time), and the
## buffers of the animation that depend on them, and updates their textures
## in the animation's material
func render_buffers(generators : Array, buffer_names : Array[String]) -> void:
	invalidate_buffers(generators)
	while true:
		await get_tree().process_frame
		var rendering : bool = false
		for buffer_name in buffer_names:
			var buffer = mm_deps.buffers.get(buffer_name)
			# Buffers waiting for a buffer that failed are not rendered
			if buffer != null and (buffer.status == buffer.Updating or buffer.status == buffer.UpdatingInvalidated or (buffer.status == buffer.Invalidated and buffer.pending_dependencies == 0)):
				rendering = true
				break
		if not rendering:
			break
	for parameter in mm_deps.buffers[BUFFER_NAMES[2]].dependencies:
		var value = mm_deps.dependencies_values.get(parameter)
		if value is MMTexture:
			image_anim.material.set_shader_parameter(parameter, await value.get_texture())


func _on_VBox_minimum_size_changed():
	size = $VBox.size+Vector2(4, 4)
