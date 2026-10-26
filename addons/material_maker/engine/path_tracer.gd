extends RefCounted
class_name MMPathTracer


# Progressive path tracer for presentation renders of the 3D preview: the
# previewed object (with its current transform) is put in a BVH, the Material
# node's maps are rendered, and the camera and environment panorama are those
# of the preview. Each call of render_samples() adds samples to the average.


const MAP_SIZE : int = 1024
## Material outputs: albedo, ORM, emission, normal (OpenGL), and coat/coat
## roughness/anisotropy/sheen
const MAPS : Dictionary = { albedo_tex=0, orm_tex=1, emission_tex=2, normal_tex=3, extra_tex=14 }

var compute : MMComputeShader
var accumulation : Array[MMTexture] = [ MMTexture.new(), MMTexture.new() ]
var image_size : Vector2i
var sample_count : int = 0
var dummy : MMTexture


## Positions (in world space) of the faces of all surfaces of a mesh, and per
## face attributes: for each vertex, (normal, u), (tangent), (v, 0, 0, 0)
static func prepare_mesh(mesh : Mesh, transform : Transform3D) -> Dictionary:
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
	var merged : ArrayMesh = ArrayMesh.new()
	var merged_arrays : Array = []
	merged_arrays.resize(Mesh.ARRAY_MAX)
	merged_arrays[Mesh.ARRAY_VERTEX] = vertices
	merged_arrays[Mesh.ARRAY_INDEX] = indices
	merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, merged_arrays)
	var texel_count : int = max(1, attributes.size()/4)
	var width : int = min(texel_count, 4096)
	var height : int = (texel_count+width-1)/width
	attributes.resize(width*height*4)
	return { mesh=merged, attributes=Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, attributes.to_byte_array()), aabb=merged.get_aabb() }

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

## Prepares a render of a mesh instance with a Material node's maps, seen from
## a camera, lit by an environment. Generated preview meshes are replaced by
## their (much lighter) fallback meshes, and their UV scale is used.
func setup(object : MeshInstance3D, material : MMGenBase, camera : Camera3D, environment : Environment, size : Vector2i, transparent_background : bool = false) -> bool:
	image_size = size
	sample_count = 0
	var mesh : Mesh = object.mesh
	if object.get("fallback_mesh") != null:
		mesh = object.fallback_mesh
	var uv_scale : Vector2 = object.uv_scale if object.get("uv_scale") is Vector2 else Vector2(1, 1)
	var prepared : Dictionary = prepare_mesh(mesh, object.global_transform)
	if prepared.is_empty():
		return false
	var bvh : MMTexture = MMTexture.new()
	bvh.set_texture(MMBvhGenerator.generate(prepared.mesh))
	await MMCliTools.wait_for_renders(material.get_tree())
	var maps : Dictionary = {}
	for m in MAPS.keys():
		maps[m] = await material.render_output_to_texture(MAPS[m], Vector2i(MAP_SIZE, MAP_SIZE))
	# Environment: the sky's panorama, or the background color
	var env_image : Image = null
	var env_energy : float = 1.0
	if environment != null:
		env_energy = environment.background_energy_multiplier
		if environment.sky != null and environment.sky.sky_material is PanoramaSkyMaterial and environment.sky.sky_material.panorama != null:
			env_image = environment.sky.sky_material.panorama.get_image()
			env_energy *= environment.sky.sky_material.energy_multiplier
		else:
			env_image = Image.create(1, 1, false, Image.FORMAT_RGBAF)
			env_image.fill(environment.background_color)
	if env_image == null:
		env_image = Image.create(1, 1, false, Image.FORMAT_RGBAF)
		env_image.fill(Color(0.5, 0.5, 0.5))
	env_image = env_image.duplicate()
	if env_image.is_compressed():
		env_image.decompress()
	env_image.convert(Image.FORMAT_RGBAH)
	var environment_texture : MMTexture = make_texture(env_image)
	dummy = make_texture(Image.create(1, 1, false, Image.FORMAT_RGBAH))
	var basis : Basis = camera.global_transform.basis.orthonormalized()
	var albedo_color = MMType.deserialize_value(material.get_parameter("albedo_color"))
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
		[ "albedo_color", "vec4", albedo_color if albedo_color is Color else Color(1, 1, 1) ],
		[ "metallic_value", "float", float(material.get_parameter("metallic")) ], [ "roughness_value", "float", float(material.get_parameter("roughness")) ],
		[ "emission_energy", "float", float(material.get_parameter("emission_energy")) ], [ "normal_strength", "float", float(material.get_parameter("normal")) ],
		[ "coat_value", "float", float(material.get_parameter("coat")) ], [ "coat_roughness_value", "float", float(material.get_parameter("coat_roughness")) ],
		[ "sheen_value", "float", float(material.get_parameter("sheen")) ],
		[ "uv_scale", "vec2", uv_scale ], [ "scene_scale", "float", max(prepared.aabb.size.length(), 0.001) ], [ "firefly_clamp", "float", 20.0 ] ]
	for v in values:
		compute.add_parameter_or_texture(v[0], v[1], v[2])
	var template : String = load("res://addons/material_maker/engine/path_tracer_compute.tres").text
	return await compute.set_shader_ext(template, [ { name="OUTPUT_TEXTURE", type=3 } ])

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

## The average of the samples, in linear values
func get_hdr_image() -> Image:
	var image : Image = (await accumulation[(sample_count+1)%2].get_texture()).get_image()
	if image.get_format() != Image.FORMAT_RGBAF:
		image.convert(Image.FORMAT_RGBAF)
	return image

## The render, tone mapped (ACES approximation) and sRGB encoded (with
## straight alpha, as the background is black when transparent)
func get_image(exposure : float = 1.0) -> Image:
	var hdr : Image = await get_hdr_image()
	var data : PackedFloat32Array = hdr.get_data().to_float32_array()
	var out : PackedByteArray = PackedByteArray()
	out.resize(data.size())
	for i in range(0, data.size(), 4):
		for c in 3:
			var x : float = data[i+c]*exposure
			x = clampf((x*(2.51*x+0.03))/(x*(2.43*x+0.59)+0.14), 0.0, 1.0)
			x = 1.055*pow(x, 1.0/2.4)-0.055 if x > 0.0031308 else 12.92*x
			out[i+c] = int(clampf(x, 0.0, 1.0)*255.0+0.5)
		out[i+3] = int(clampf(data[i+3], 0.0, 1.0)*255.0+0.5)
	return Image.create_from_data(hdr.get_width(), hdr.get_height(), false, Image.FORMAT_RGBA8, out)
