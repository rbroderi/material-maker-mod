extends SubViewportContainer

const CAMERA_DISTANCE_MIN = 0.5
const CAMERA_DISTANCE_MAX = 150.0
const CAMERA_FOV_MIN = 10
const CAMERA_FOV_MAX = 90


@onready var objects_pivot = $MaterialPreview/Preview3d/ObjectsPivot
@onready var objects = $MaterialPreview/Preview3d/ObjectsPivot/Objects
@onready var current_object = objects.get_child(0)

@onready var camera_controller = $MaterialPreview/Preview3d/CameraController
@onready var camera = $MaterialPreview/Preview3d/Camera3D
@onready var sun = $MaterialPreview/Preview3d/Sun

@onready var environment : Environment = $MaterialPreview/Preview3d/WorldEnvironment.environment
@onready var camera_attributes : CameraAttributesPractical = $MaterialPreview/Preview3d/WorldEnvironment.camera_attributes

var trigger_on_right_click = true

var moving = false

var _mouse_start_position : Vector2 = Vector2.ZERO

var clear_background := true
var current_environment : int = mm_globals.get_config("ui_3d_preview_environment")

@onready var main_menu := $MainMenu


signal need_update(me)


func _enter_tree():
	mm_deps.create_buffer("preview_"+str(get_instance_id()), self)


func _exit_tree():
	mm_deps.delete_buffer("preview_"+str(get_instance_id()))


func _ready() -> void:
	# Delay setting the sun shadow by one frame. Otherwise, the large 3D preview
	# attempts to read the setting before the configuration file is loaded.
	await get_tree().process_frame
	sun.shadow_enabled = mm_globals.get_config("ui_3d_preview_sun_shadow")


func reattach_menu(node:Node) -> Node:
	main_menu.get_parent().remove_child(main_menu)
	node.add_child(main_menu)
	return main_menu


func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		set_environment.call_deferred(current_environment)


func set_model(id : int, custom_model_path : String = "") -> bool:
	if id == objects.get_child_count()-1:
		if custom_model_path == "":
			var dialog = preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
			dialog.min_size = Vector2(500, 500)
			dialog.access = FileDialog.ACCESS_FILESYSTEM
			dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
			for f in MMMeshLoader.get_file_dialog_filters():
				dialog.add_filter(f)
			dialog.current_dir = mm_globals.config.get_value("path", "mesh", mm_globals.get_home_directory())
			var files = await dialog.select_files()
			if files.size() == 1:
				custom_model_path = files[0]
			else:
				return false
		do_load_custom_mesh(custom_model_path)
	select_object(id)
	return true


func do_load_custom_mesh(file_path) -> void:
	mm_globals.config.set_value("path", "mesh", file_path.get_base_dir())
	var id = objects.get_child_count()-1
	var mesh : Mesh = null
	mesh = MMMeshLoader.load_mesh(file_path)
	if mesh != null:
		var object : MeshInstance3D = objects.get_child(id)
		object.mesh = mesh
		mm_globals.main_window.set_current_mesh(mesh)
		select_object(id)

func get_current_model_path() -> String:
	if current_object.mesh.has_meta("file_path"):
		return current_object.mesh.get_meta("file_path")
	return ""

func select_object(id) -> void:
	current_object.visible = false
	current_object = objects.get_child(id)
	if current_object.has_method("update_mesh"):
		current_object.update_mesh()
	current_object.visible = true
	emit_signal("need_update", [ self ])
	var aabb : AABB = current_object.get_aabb()
	current_object.transform.origin = -(aabb.position+0.5*aabb.size)

func _on_Environment_item_selected(id) -> void:
	set_environment(id)

func set_environment(id:int) -> void:
	if id >= 0:
		current_environment = id

	var environment_manager = get_node("/root/MainWindow/EnvironmentManager")
	if current_environment > environment_manager.get_environment_list().size() - 1:
		current_environment = 0
	if clear_background:
		$MaterialPreview.transparent_bg = true
		environment_manager.apply_environment(current_environment, environment, sun, Color.TRANSPARENT, true)
	else:
		$MaterialPreview.transparent_bg = false
		environment_manager.apply_environment(current_environment, environment, sun)


func configure_model() -> void:
	var popup = preload("res://material_maker/panels/preview_3d/mesh_config_popup.tscn").instantiate()
	popup.hide()
	add_child(popup)
	popup.configure_mesh(current_object)


func set_rotate_model_speed(speed: float) -> void:
	var object_rotate = $MaterialPreview/Preview3d/ObjectRotate
	object_rotate.speed_scale = speed
	if speed == 0:
		object_rotate.stop(false)
	else:
		object_rotate.play("rotate")


func get_materials() -> Array:
	# Update 3D scale
	$MaterialPreview.scaling_3d_scale = mm_globals.main_window.preview_rendering_scale_factor
	# Return materials
	if current_object != null and current_object.get_material() != null:
		return [ current_object.get_material() ]
	return []


## Applies an OpenColorIO display/view transform ("display / view") to the
## 3D view, or removes it (empty view). The viewport then renders in HDR
## (linear, unclamped), and the transform is applied when drawing it.
## Returns true if a transform is applied.
func set_ocio_view(view : String) -> bool:
	var lut : ImageTexture3D = null
	if view != "":
		lut = MMColorManagement.get_view_lut(view, MMColorManagement.get_scene_linear_space())
	if lut == null:
		material = null
		$MaterialPreview.use_hdr_2d = false
		return false
	var shader : Shader = Shader.new()
	shader.code = "shader_type canvas_item;\n"+MMColorManagement.get_view_shader_code(true)
	shader.code += "void fragment() {\n\tvec4 c = texture(TEXTURE, UV);\n\tCOLOR = vec4(mm_ocio_view(c.rgb), c.a);\n}\n"
	var shader_material : ShaderMaterial = ShaderMaterial.new()
	shader_material.shader = shader
	shader_material.set_shader_parameter("mm_ocio_lut", lut)
	material = shader_material
	$MaterialPreview.use_hdr_2d = true
	return true

func get_preview_settings() -> Dictionary:
	var settings : Dictionary = {}
	settings.object_mesh = current_object.mesh
	settings.object_material = current_object.get_active_material(0)
	settings.object_transform = current_object.global_transform
	settings.camera_transform = camera.global_transform
	settings.camera_fov = camera.fov
	settings.camera_near = camera.near
	settings.camera_far = camera.far
	return settings


func on_dep_update_value(_buffer_name, parameter_name, value) -> bool:
	var preview_material = current_object.get_material()
	preview_material.set_shader_parameter(parameter_name, value)
	return false


func zoom(amount : float):
	camera.position.z = clamp(camera.position.z*amount, CAMERA_DISTANCE_MIN, CAMERA_DISTANCE_MAX)


func on_gui_input(event : InputEvent) -> void:
	if camera_controller.process_event(event, get_viewport()):
		accept_event()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_MIDDLE:
			# Don't stop rotating the preview on mouse wheel usage (zoom change).
			pass
			#$MaterialPreview/Preview3d/ObjectRotate.stop(false)
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if event.is_command_or_control_pressed():
					camera.fov = clamp(camera.fov + 1, CAMERA_FOV_MIN, CAMERA_FOV_MAX)
				else:
					zoom(1.0 / (1.01 if event.shift_pressed else 1.1))
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.is_command_or_control_pressed():
					camera.fov = clamp(camera.fov - 1, CAMERA_FOV_MIN, CAMERA_FOV_MAX)
				else:
					zoom(1.01 if event.shift_pressed else 1.1)
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT:
				var mask : int = Input.get_mouse_button_mask()
				var lpressed : bool = (mask & MOUSE_BUTTON_MASK_LEFT) != 0
				var rpressed : bool = (mask & MOUSE_BUTTON_MASK_RIGHT) != 0

				if event.pressed and lpressed != rpressed: # xor
					Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
					_mouse_start_position = event.global_position
					moving = true
				elif not lpressed and not rpressed:
					Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN) # allow and hide cursor warp
					get_viewport().warp_mouse(_mouse_start_position)
					Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
					moving = false
				if event.button_index == MOUSE_BUTTON_RIGHT:
					if event.pressed:
						trigger_on_right_click = true
					elif trigger_on_right_click:
						trigger_on_right_click = false
						on_right_click()
	elif moving and event is InputEventMouseMotion:
		trigger_on_right_click = false
		if event.pressure != 0.0:
			Input.set_mouse_mode(Input.MOUSE_MODE_HIDDEN)
		var motion = event.relative
		if motion.length() > 200:
			return
		if Input.is_key_pressed(KEY_ALT):
			zoom(1.0+motion.y*0.01)
		else:
			motion *= 0.01
			if abs(motion.y) > abs(motion.x):
				motion.x = 0
			else:
				motion.y = 0
			var camera_basis = camera.global_transform.basis
			var objects_rotation : int = -1 if Input.is_key_pressed(KEY_CTRL) else 0
			if event.button_mask & MOUSE_BUTTON_MASK_LEFT:
				objects_pivot.rotate(camera_basis.x.normalized(), objects_rotation * motion.y)
				objects_pivot.rotate(camera_basis.y.normalized(), objects_rotation * motion.x)
			elif event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
				objects_pivot.rotate(camera_basis.z.normalized(), objects_rotation * motion.x)

func on_right_click():
	pass


func do_generate_map(file_name : String, map : String, image_size : int) -> void:
	var id = objects.get_child_count()-1
	var object : MeshInstance3D = objects.get_child(id)
	var t : MMTexture = await MMMapGenerator.get_map(object.mesh, map, image_size)
	t.save_to_file(file_name)
	DisplayServer.clipboard_set("{\"name\":\"image\",\"parameters\":{\"image\":\"%s\"},\"type\":\"image\"}" % file_name)


## A path traced render of the current object, from the current view, saved
## to a PNG (tone mapped) or EXR (linear) file. Returns an error message, or
## an empty string.
func render_path_traced(file_name : String, image_size : Vector2i, samples : int, transparent_background : bool = false, progress : Callable = Callable(), thin_walled : bool = false) -> String:
	var project = mm_globals.main_window.get_current_project() if mm_globals.main_window != null else null
	var material = project.get_material_node() if project != null and project.has_method("get_material_node") else null
	if material == null:
		return "No material to render"
	var object_rotate : AnimationPlayer = $MaterialPreview/Preview3d/ObjectRotate
	var was_playing : bool = object_rotate.is_playing()
	object_rotate.pause()
	var tracer : MMPathTracer = MMPathTracer.new()
	var error : String = ""
	if not await tracer.setup(current_object, material, camera, environment, image_size, transparent_background, true, thin_walled):
		error = "Cannot prepare the path tracer"
	else:
		var done : int = 0
		while done < samples:
			var count : int = min(8, samples-done)
			if not await tracer.render_samples(count):
				error = "Path tracing failed"
				break
			done += count
			if progress.is_valid():
				progress.call(done, samples)
			await get_tree().process_frame
	if error == "":
		var image : Image
		if file_name.get_extension().to_lower() == "exr":
			image = await tracer.get_hdr_image()
			if image.save_exr(file_name) != OK:
				error = "Cannot save "+file_name
		else:
			image = await tracer.get_image()
			if image.save_png(file_name) != OK:
				error = "Cannot save "+file_name
	if was_playing:
		object_rotate.play()
	return error

## Images of a full turn of the current object, rendered by the preview
func render_turntable(frame_count : int, image_size : Vector2i = Vector2i()) -> Array[Image]:
	var object_rotate : AnimationPlayer = $MaterialPreview/Preview3d/ObjectRotate
	var was_playing : bool = object_rotate.is_playing()
	object_rotate.pause()
	var pivot : Node3D = $MaterialPreview/Preview3d/ObjectsPivot
	var saved_rotation : Vector3 = pivot.rotation_degrees
	var viewport : SubViewport = $MaterialPreview
	var saved_stretch : bool = stretch
	var saved_size : Vector2i = viewport.size
	if image_size != Vector2i():
		stretch = false
		viewport.size = image_size
	var images : Array[Image] = []
	for i in frame_count:
		pivot.rotation_degrees = Vector3(saved_rotation.x, saved_rotation.y+360.0*i/frame_count, saved_rotation.z)
		for f in 3:
			await RenderingServer.frame_post_draw
		images.append(viewport.get_texture().get_image())
	pivot.rotation_degrees = saved_rotation
	if image_size != Vector2i():
		viewport.size = saved_size
		stretch = saved_stretch
	if was_playing:
		object_rotate.play()
	return images

## Saves turntable images as a PNG sequence (when the file name contains #,
## replaced by the frame number) or a sprite sheet
static func save_turntable(images : Array[Image], file_name : String) -> String:
	if images.is_empty():
		return "No image"
	if file_name.contains("#"):
		var digits : int = file_name.count("#")
		var pattern : String = "#".repeat(digits)
		for i in images.size():
			var frame_file : String = file_name.replace(pattern, str(i).pad_zeros(digits)).replace("#", "")
			if images[i].save_png(frame_file) != OK:
				return "Cannot save "+frame_file
		return ""
	if images[0].get_format() != Image.FORMAT_RGBA8:
		images[0].convert(Image.FORMAT_RGBA8)
	var sheet : Image = MMCliTools.make_sprite_sheet(images)
	return "" if sheet.save_png(file_name) == OK else "Cannot save "+file_name
