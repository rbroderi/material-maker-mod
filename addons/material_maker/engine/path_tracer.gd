extends RefCounted
class_name MMPathTracer


# Progressive path tracer for presentation renders of the 3D preview: the
# previewed object (with its current transform) is put in a BVH, the Material
# node's maps are rendered, and the camera and environment panorama are those
# of the preview. Each call of render_samples() adds samples to the average.


const MAP_SIZE : int = 1024
## Material outputs: albedo, ORM, emission, normal (OpenGL), coat/coat
## roughness/anisotropy/sheen, transmission and subsurface scattering
const MAPS : Dictionary = { albedo_tex=MMGenMaterial.OUTPUT_ALBEDO, orm_tex=MMGenMaterial.OUTPUT_ORM, emission_tex=MMGenMaterial.OUTPUT_EMISSION,
	normal_tex=MMGenMaterial.OUTPUT_NORMAL, extra_tex=MMGenMaterial.OUTPUT_EXTRA, transmission_tex=MMGenMaterial.OUTPUT_TRANSMISSION,
	sss_tex=MMGenMaterial.OUTPUT_SSS }
## Default mean free path of subsurface scattering, relative to the size of the
## scene
const SSS_RADIUS : float = 0.03
## Size of the depth map used for displacement
const DEPTH_MAP_SIZE : int = 512
## Displaced meshes are subdivided up to about this number of triangles (the
## BVH is built in GDScript)
const DISPLACEMENT_TRIANGLES : int = 60000
## Displacement depth for a depth_scale of 1, as the preview's parallax and
## the Static PBR Material Displacement node
const DISPLACEMENT_SCALE : float = 0.2
## Frames without pending renders after which the graph is considered rendered
const IDLE_FRAMES : int = 10

var compute : MMComputeShader
var accumulation : Array[MMTexture] = [ MMTexture.new(), MMTexture.new() ]
var image_size : Vector2i
var sample_count : int = 0
var dummy : MMTexture


## Positions (in world space) of the faces of all surfaces of a mesh, and per
## face attributes: for each vertex, (normal, u), (tangent), (v, 0, 0, 0).
## With a depth map, the mesh is subdivided and displaced (see displace()).
static func prepare_mesh(mesh : Mesh, transform : Transform3D, depth : Image = null, depth_scale : float = 0.0, uv_scale : Vector2 = Vector2(1, 1)) -> Dictionary:
	var vertices : PackedVector3Array = PackedVector3Array()
	var indices : PackedInt32Array = PackedInt32Array()
	var attributes : PackedFloat32Array = PackedFloat32Array()
	var normal_basis : Basis = transform.basis.inverse().transposed()
	for s in mesh.get_surface_count():
		var primitive : int = mesh.surface_get_primitive_type(s) if mesh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES
		if primitive != Mesh.PRIMITIVE_TRIANGLES and primitive != Mesh.PRIMITIVE_TRIANGLE_STRIP:
			continue
		var arrays : Array = mesh.surface_get_arrays(s)
		if arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_VERTEX].is_empty():
			continue
		if primitive == Mesh.PRIMITIVE_TRIANGLE_STRIP:
			arrays[Mesh.ARRAY_INDEX] = strip_to_triangles(arrays[Mesh.ARRAY_INDEX], arrays[Mesh.ARRAY_VERTEX].size())
		elif arrays[Mesh.ARRAY_NORMAL] == null or arrays[Mesh.ARRAY_TANGENT] == null:
			var surface_tool : SurfaceTool = SurfaceTool.new()
			surface_tool.create_from(mesh, s)
			if arrays[Mesh.ARRAY_NORMAL] == null:
				surface_tool.generate_normals()
			if arrays[Mesh.ARRAY_TEX_UV] != null:
				surface_tool.generate_tangents()
			arrays = surface_tool.commit_to_arrays()
		var surface_vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals = arrays[Mesh.ARRAY_NORMAL]
		var tangents = arrays[Mesh.ARRAY_TANGENT]
		var uvs = arrays[Mesh.ARRAY_TEX_UV]
		var surface_indices = arrays[Mesh.ARRAY_INDEX]
		if surface_indices == null:
			surface_indices = PackedInt32Array(range(surface_vertices.size()))
		var offset : int = vertices.size()
		for v in surface_vertices:
			vertices.append(transform*v)
		for f in surface_indices.size()/3:
			for k in 3:
				var i : int = surface_indices[3*f+k]
				indices.append(offset+i)
				var n : Vector3 = (normal_basis*normals[i]).normalized() if normals != null else Vector3(0, 1, 0)
				var uv : Vector2 = uvs[i] if uvs != null else Vector2()
				var t : Vector3 = Vector3(1, 0, 0)
				var sign : float = 1.0
				if tangents != null:
					t = (transform.basis*Vector3(tangents[4*i], tangents[4*i+1], tangents[4*i+2])).normalized()
					sign = tangents[4*i+3]
				attributes.append_array([ n.x, n.y, n.z, uv.x, t.x, t.y, t.z, sign, uv.y, 0.0, 0.0, 0.0 ])
	if indices.is_empty():
		return {}
	if depth != null and depth_scale > 0.0:
		var displaced : Array = displace(vertices, indices, attributes, depth, depth_scale*transform.basis.get_scale().x, uv_scale)
		vertices = displaced[0]
		indices = displaced[1]
		attributes = displaced[2]
	var merged : ArrayMesh = ArrayMesh.new()
	var merged_arrays : Array = []
	merged_arrays.resize(Mesh.ARRAY_MAX)
	merged_arrays[Mesh.ARRAY_VERTEX] = vertices
	merged_arrays[Mesh.ARRAY_INDEX] = indices
	merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged_arrays)
	# Attributes are read by the shader from an RGBA float image, in rows of
	# 4096 texels
	var texel_count : int = max(1, attributes.size()/4)
	var width : int = min(texel_count, 4096)
	var height : int = (texel_count+width-1)/width
	attributes.resize(width*height*4)
	return { mesh=merged, attributes=Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, attributes.to_byte_array()), aabb=merged.get_aabb() }

## Subdivides triangles (attributes are 12 floats per face vertex: normal, u,
## tangent, sign, v, unused) and moves vertices inside along their normal by the
## depth map (white is deepest) times depth_scale
static func displace(vertices : PackedVector3Array, indices : PackedInt32Array, attributes : PackedFloat32Array, depth : Image, depth_scale : float, uv_scale : Vector2) -> Array:
	var triangles : Array = []
	for f in indices.size()/3:
		var triangle : Array = []
		for k in 3:
			var a : int = 12*(3*f+k)
			triangle.append([ vertices[indices[3*f+k]], attributes.slice(a, a+12) ])
		triangles.append(triangle)
	while triangles.size()*4 <= DISPLACEMENT_TRIANGLES:
		var subdivided : Array = []
		for t in triangles:
			var m01 : Array = midpoint(t[0], t[1])
			var m12 : Array = midpoint(t[1], t[2])
			var m20 : Array = midpoint(t[2], t[0])
			subdivided.append_array([ [ t[0], m01, m20 ], [ m01, t[1], m12 ], [ m20, m12, t[2] ], [ m01, m12, m20 ] ])
		triangles = subdivided
	# The depth map is filtered down to about the size of the triangles, so
	# details smaller than them do not show as spikes
	var uv_edges : float = 0.0
	for t in triangles:
		uv_edges += (Vector2(t[0][1][3], t[0][1][8])-Vector2(t[1][1][3], t[1][1][8])).length()
	var mean_uv_edge : float = max(uv_edges/triangles.size()*max(uv_scale.x, uv_scale.y), 0.000001)
	var filtered_size : int = clampi(nearest_po2(int(1.0/mean_uv_edge)), 4, depth.get_width())
	if filtered_size < depth.get_width():
		depth = depth.duplicate()
		depth.resize(filtered_size, filtered_size, Image.INTERPOLATE_TRILINEAR)
	# Corners at the same position (e.g. on both sides of a UV seam or of a box
	# edge) move together, along their average normal by their average depth,
	# so the surface does not crack open. Each distinct (normal, UV) of a
	# position counts once, however many triangles share it.
	var welded : Dictionary = {}
	for t in triangles:
		for corner in t:
			var key : Vector3i = Vector3i((corner[0]*100000.0).round())
			if not welded.has(key):
				welded[key] = {}
			var a : PackedFloat32Array = corner[1]
			var normal : Vector3 = Vector3(a[0], a[1], a[2])
			var uv : Vector2 = Vector2(a[3], a[8])
			welded[key][[ Vector3i((normal*10000.0).round()), Vector2i((uv*100000.0).round()) ]] = [ normal, uv ]
	var displacements : Dictionary = {}
	for key in welded.keys():
		var normal : Vector3 = Vector3()
		var d : float = 0.0
		for corner in welded[key].values():
			normal += corner[0]
			d += sample_bilinear(depth, corner[1]*uv_scale)
		displacements[key] = -normal.normalized()*(d/welded[key].size())*depth_scale
	var new_vertices : PackedVector3Array = PackedVector3Array()
	var new_indices : PackedInt32Array = PackedInt32Array()
	var new_attributes : PackedFloat32Array = PackedFloat32Array()
	for t in triangles:
		for corner in t:
			new_indices.append(new_vertices.size())
			new_vertices.append(corner[0]+displacements[Vector3i((corner[0]*100000.0).round())])
			new_attributes.append_array(corner[1])
	return [ new_vertices, new_indices, new_attributes ]

## Bilinear sample of the red channel of a tiling image
static func sample_bilinear(image : Image, uv : Vector2) -> float:
	var size : Vector2i = image.get_size()
	var p : Vector2 = uv*Vector2(size)-Vector2(0.5, 0.5)
	var p0 : Vector2 = p.floor()
	var f : Vector2 = p-p0
	var x0 : int = posmod(int(p0.x), size.x)
	var y0 : int = posmod(int(p0.y), size.y)
	var x1 : int = (x0+1)%size.x
	var y1 : int = (y0+1)%size.y
	var top : float = lerpf(image.get_pixel(x0, y0).r, image.get_pixel(x1, y0).r, f.x)
	var bottom : float = lerpf(image.get_pixel(x0, y1).r, image.get_pixel(x1, y1).r, f.x)
	return lerpf(top, bottom, f.y)

## The middle of a triangle edge (position and attributes)
static func midpoint(a : Array, b : Array) -> Array:
	var attributes : PackedFloat32Array = PackedFloat32Array()
	attributes.resize(12)
	for i in 12:
		attributes[i] = 0.5*(a[1][i]+b[1][i])
	var n : Vector3 = Vector3(attributes[0], attributes[1], attributes[2]).normalized()
	attributes[0] = n.x
	attributes[1] = n.y
	attributes[2] = n.z
	return [ 0.5*(a[0]+b[0]), attributes ]

## Triangle indices of a triangle strip (degenerate triangles are skipped)
static func strip_to_triangles(strip_indices, vertex_count : int) -> PackedInt32Array:
	if strip_indices == null:
		strip_indices = PackedInt32Array(range(vertex_count))
	var rv : PackedInt32Array = PackedInt32Array()
	for i in strip_indices.size()-2:
		var a : int = strip_indices[i]
		var b : int = strip_indices[i+1]
		var c : int = strip_indices[i+2]
		if a == b or b == c or a == c:
			continue
		if i%2 == 0:
			rv.append_array([ a, b, c ])
		else:
			rv.append_array([ b, a, c ])
	return rv

static func make_texture(image : Image) -> MMTexture:
	var texture : MMTexture = MMTexture.new()
	texture.set_texture(ImageTexture.create_from_image(image))
	return texture

## Waits until the graph's buffers are rendered
static func wait_for_renders(tree : SceneTree, max_frames : int = 6000) -> void:
	var idle_frames : int = 0
	for i in max_frames:
		await tree.process_frame
		idle_frames = idle_frames+1 if mm_deps.get_render_queue_size() == 0 else 0
		if idle_frames >= IDLE_FRAMES:
			return

## A float parameter of a material, or a default value for material nodes
## that do not have it
static func get_float_parameter(material : MMGenBase, parameter : String, default : float) -> float:
	if material.parameters.has(parameter) or not material.get_parameter_def(parameter).is_empty():
		return float(material.get_parameter(parameter))
	return default

## Whether an input of a node is connected
static func is_input_connected(node : MMGenBase, input_name : String) -> bool:
	var inputs : Array = node.get_input_defs()
	for i in inputs.size():
		if inputs[i].name == input_name:
			return node.get_source(i) != null
	return false

## Prepares a render of a mesh instance with a Material node's maps, seen from
## a camera, lit by an environment and the brightest directional light of the
## object's scene. Generated preview meshes are replaced by their (much
## lighter) fallback meshes, and their UV scale is used. With displacement,
## the mesh is displaced by the depth map. Transmissive surfaces are solids
## that refract light, or with thin_walled, thin sheets that let diffuse light
## through (as leaves or paper). Subsurface scattered light travels about
## sss_radius (relative to the size of the object) inside solids, times the
## red, green and blue components of sss_color for each color.
func setup(object : MeshInstance3D, material : MMGenBase, camera : Camera3D, environment : Environment, size : Vector2i, transparent_background : bool = false, displacement : bool = false, thin_walled : bool = false, sss_radius : float = SSS_RADIUS, sss_color : Color = Color(1, 1, 1)) -> bool:
	image_size = size
	sample_count = 0
	# Only materials with texture outputs (not the dynamic, raymarching or
	# unlit ones) can be rendered
	var output_count : int = material.get_output_defs(true).size()
	if output_count <= MMGenMaterial.OUTPUT_NORMAL:
		return false
	var mesh : Mesh = object.mesh
	if object.get("fallback_mesh") != null:
		mesh = object.fallback_mesh
	var uv_scale : Vector2 = object.uv_scale if object.get("uv_scale") is Vector2 else Vector2(1, 1)
	await wait_for_renders(material.get_tree())
	var depth : Image = null
	var depth_scale : float = 0.0
	if displacement and is_input_connected(material, "depth_tex"):
		depth_scale = DISPLACEMENT_SCALE*get_float_parameter(material, "depth_scale", 0.0)
	if depth_scale > 0.0:
		depth = (await (await material.render_output_to_texture(MMGenMaterial.OUTPUT_DEPTH, Vector2i(DEPTH_MAP_SIZE, DEPTH_MAP_SIZE))).get_texture()).get_image()
		depth.convert(Image.FORMAT_RF)
	var prepared : Dictionary = prepare_mesh(mesh, object.global_transform, depth, depth_scale, uv_scale)
	if prepared.is_empty():
		return false
	var bvh : MMTexture = MMTexture.new()
	bvh.set_texture(MMBvhGenerator.generate(prepared.mesh))
	# Maps that the material node does not have (e.g. coat or transmission) are
	# black
	dummy = make_texture(Image.create(1, 1, false, Image.FORMAT_RGBAH))
	var maps : Dictionary = {}
	for m in MAPS.keys():
		maps[m] = await material.render_output_to_texture(MAPS[m], Vector2i(MAP_SIZE, MAP_SIZE)) if MAPS[m] < output_count else dummy
	# Environment: the sky's panorama lights the object. Camera rays that miss
	# it show the panorama, or the background color as the preview does.
	var env_image : Image = null
	var env_energy : float = 1.0
	var background_color : Color = Color(0, 0, 0, 0)
	if environment != null:
		env_energy = environment.background_energy_multiplier
		if environment.sky != null and environment.sky.sky_material is PanoramaSkyMaterial and environment.sky.sky_material.panorama != null:
			env_image = environment.sky.sky_material.panorama.get_image()
			env_energy *= environment.sky.sky_material.energy_multiplier
		else:
			env_image = Image.create(1, 1, false, Image.FORMAT_RGBAF)
			env_image.fill(environment.background_color.srgb_to_linear())
		if environment.background_mode == Environment.BG_COLOR:
			background_color = environment.background_color.srgb_to_linear()
			background_color.a = 1.0
	if env_image == null:
		env_image = Image.create(1, 1, false, Image.FORMAT_RGBAF)
		env_image.fill(Color(0.5, 0.5, 0.5))
	env_image = env_image.duplicate()
	if env_image.is_compressed():
		env_image.decompress()
	env_image.convert(Image.FORMAT_RGBAH)
	var environment_texture : MMTexture = make_texture(env_image)
	var basis : Basis = camera.global_transform.basis.orthonormalized()
	var sun : Dictionary = find_sun(object)
	var sss_radii : Vector3 = Vector3(maxf(sss_color.r, 0.01), maxf(sss_color.g, 0.01), maxf(sss_color.b, 0.01))*maxf(sss_radius, 0.0001)
	var albedo_color = MMType.deserialize_value(material.get_parameter("albedo_color")) if not material.get_parameter_def("albedo_color").is_empty() else null
	compute = MMComputeShader.new()
	compute.clear()
	for t in [ [ "bvh_data", bvh ], [ "attribute_data", make_texture(prepared.attributes) ], [ "env_texture", environment_texture ], [ "accumulation", dummy ] ]:
		compute.add_parameter_or_texture(t[0], "sampler2D", t[1])
	for m in maps.keys():
		compute.add_parameter_or_texture(m, "sampler2D", maps[m])
	var values : Array = [
		[ "sample_index", "int", 0 ], [ "max_bounces", "int", 6 ], [ "transparent_background", "int", 1 if transparent_background else 0 ],
		[ "camera_position", "vec3", camera.global_position ], [ "camera_forward", "vec3", -basis.z ],
		[ "camera_right", "vec3", basis.x ], [ "camera_up", "vec3", basis.y ], [ "camera_fov", "float", deg_to_rad(camera.fov) ],
		[ "env_rotation", "float", environment.sky_rotation.y if environment != null else 0.0 ], [ "env_energy", "float", env_energy ],
		[ "background_color", "vec4", background_color ],
		[ "albedo_color", "vec4", albedo_color if albedo_color is Color else Color(1, 1, 1) ],
		[ "metallic_value", "float", get_float_parameter(material, "metallic", 1.0) ], [ "roughness_value", "float", get_float_parameter(material, "roughness", 1.0) ],
		[ "emission_energy", "float", get_float_parameter(material, "emission_energy", 1.0) ], [ "normal_strength", "float", get_float_parameter(material, "normal", 1.0) ],
		[ "coat_value", "float", get_float_parameter(material, "coat", 0.0) ], [ "coat_roughness_value", "float", get_float_parameter(material, "coat_roughness", 0.1) ],
		[ "sheen_value", "float", get_float_parameter(material, "sheen", 0.0) ], [ "transmission_value", "float", get_float_parameter(material, "transmission", 0.0) ],
		[ "sss_value", "float", get_float_parameter(material, "sss", 0.0) ], [ "sss_radius", "vec3", sss_radii ],
		[ "thin_walled", "int", 1 if thin_walled else 0 ],
		[ "sun_direction", "vec3", sun.direction ], [ "sun_color", "vec3", sun.color ], [ "sun_energy", "float", sun.energy ], [ "sun_angle", "float", sun.angle ],
		[ "uv_scale", "vec2", uv_scale ], [ "scene_scale", "float", max(prepared.aabb.size.length(), 0.001) ], [ "firefly_clamp", "float", 20.0 ] ]
	for v in values:
		compute.add_parameter_or_texture(v[0], v[1], v[2])
	var template : String = load("res://addons/material_maker/engine/path_tracer_compute.tres").text
	return await compute.set_shader_ext(template, [ { name="OUTPUT_TEXTURE", type=3 } ])

## The brightest visible directional light of the object's scene (direction
## towards the light, linear color, energy and angular radius), or no light
static func find_sun(object : Node3D) -> Dictionary:
	var sun : Dictionary = { direction=Vector3(0, 1, 0), color=Vector3(1, 1, 1), energy=0.0, angle=0.001 }
	for l : DirectionalLight3D in object.get_viewport().find_children("*", "DirectionalLight3D", true, false):
		if not l.is_visible_in_tree() or l.light_energy <= sun.energy:
			continue
		var c : Color = l.light_color.srgb_to_linear()
		sun = { direction=l.global_transform.basis.z.normalized(), color=Vector3(c.r, c.g, c.b), energy=l.light_energy, angle=max(deg_to_rad(l.light_angular_distance)*0.5, 0.001) }
	return sun

## Adds samples to the render
func render_samples(count : int) -> bool:
	for i in count:
		var target : MMTexture = accumulation[sample_count%2]
		compute.set_parameter("sample_index", sample_count)
		compute.set_parameter("accumulation", accumulation[(sample_count+1)%2] if sample_count > 0 else dummy)
		if not await compute.render_ext([ target ], image_size):
			return false
		sample_count += 1
	return true

## The average of the samples, in linear values (with premultiplied alpha)
func get_hdr_image() -> Image:
	var image : Image = (await accumulation[(sample_count+1)%2].get_texture()).get_image()
	if image.get_format() != Image.FORMAT_RGBAF:
		image.convert(Image.FORMAT_RGBAF)
	return image

## The render, tone mapped (clamped if linear, else with an approximation of
## ACES) and sRGB encoded, with straight alpha (colors of partly transparent
## pixels are divided by their coverage)
func get_image(exposure : float = 1.0, linear : bool = false) -> Image:
	var hdr : Image = await get_hdr_image()
	var data : PackedFloat32Array = hdr.get_data().to_float32_array()
	var out : PackedByteArray = PackedByteArray()
	out.resize(data.size())
	for i in range(0, data.size(), 4):
		var alpha : float = clampf(data[i+3], 0.0, 1.0)
		var scale : float = exposure/alpha if alpha > 0.0 else 0.0
		for c in 3:
			var x : float = data[i+c]*scale
			if linear:
				x = clampf(x, 0.0, 1.0)
			else:
				x = clampf((x*(2.51*x+0.03))/(x*(2.43*x+0.59)+0.14), 0.0, 1.0)
			x = 1.055*pow(x, 1.0/2.4)-0.055 if x > 0.0031308 else 12.92*x
			out[i+c] = int(clampf(x, 0.0, 1.0)*255.0+0.5)
		out[i+3] = int(alpha*255.0+0.5)
	return Image.create_from_data(hdr.get_width(), hdr.get_height(), false, Image.FORMAT_RGBA8, out)
