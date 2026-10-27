extends Object
class_name MMHighPolyBakerRT


# Hardware ray traced high to low poly baking (when the GPU supports ray
# tracing pipelines): the low poly mesh is rasterized in UV space into
# G-buffers that hold the rays of its texels (highpoly_rays_fragment.tres),
# then a ray tracing pipeline traces them against acceleration structures of
# the high poly mesh. Results are the same as MMHighPolyBaker's software ray
# casting (same rays, same attributes).


const RAYGEN : String = """#version 460
#extension GL_EXT_ray_tracing : require

layout(set = 0, binding = 0) uniform accelerationStructureEXT tlas;
layout(set = 0, binding = 1) uniform sampler2D ray_start_image;
layout(set = 0, binding = 2) uniform sampler2D ray_dir_image;
layout(set = 0, binding = 3) uniform sampler2D normal_image;
layout(set = 0, binding = 4) uniform sampler2D tangent_image;
layout(set = 0, binding = 5, rgba32f) uniform image2D output_image;
layout(set = 0, binding = 6, std430) readonly buffer Attributes { vec4 attributes[]; };
layout(set = 0, binding = 7) uniform sampler2D high_texture;

layout(set = 0, binding = 8, std430) readonly buffer Parameters {
	vec4 aabb_position;		// w: mode
	vec4 aabb_size;			// w: iteration
	vec4 distances;			// front, rear
} parameters;

// t, face, barycentric coordinates (x and y are the matching surface and -1
// before tracing)
layout(location = 0) rayPayloadEXT vec4 payload;

const int ATTRIBUTES_PER_FACE = 8;
const int MODE_NORMAL_TANGENT = 0;
const int MODE_NORMAL_OBJECT = 1;
const int MODE_HEIGHT = 2;
const int MODE_COLOR = 3;
const int MODE_MATERIAL_ID = 4;
const int MODE_POSITION = 5;
const int MODE_TEXTURE = 6;

vec3 id_color(int id) {
	float h = fract(float(id) * 0.618034);
	vec3 c = clamp(abs(fract(h + vec3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
	return c * (1.0 - 0.3 * float((id / 7) % 3));
}

void main() {
	ivec2 pixel = ivec2(gl_LaunchIDEXT.xy);
	int mode = int(parameters.aabb_position.w);
	float iteration = parameters.aabb_size.w;
	vec4 tangent_data = texelFetch(tangent_image, pixel, 0);
	vec4 value = vec4(0.0);
	if (tangent_data.w > 1.5) {
		vec4 start = texelFetch(ray_start_image, pixel, 0);
		vec4 dir = texelFetch(ray_dir_image, pixel, 0);
		vec4 normal_data = texelFetch(normal_image, pixel, 0);
		vec3 ray_start = start.xyz;
		float front = start.w;
		vec3 ray_dir = dir.xyz;
		vec3 n = normal_data.xyz;
		vec3 t = tangent_data.xyz;
		vec3 b = cross(n, t) * normal_data.w;
		float front_dist = parameters.distances.x;
		float rear_dist = parameters.distances.y;
		payload = vec4(-1.0, dir.w, 0.0, 0.0);
		traceRayEXT(tlas, gl_RayFlagsNoneEXT, 0xFF, 0, 0, 0, ray_start, 0.0, ray_dir, front + rear_dist, 0);
		if (payload.x < 0.0) {
			// Values of the low poly surface
			switch (mode) {
				case MODE_NORMAL_TANGENT:
					value = vec4(0.5, 0.5, 0.0, 0.0);
					break;
				case MODE_NORMAL_OBJECT:
					value = vec4(0.5 + 0.5 * n, 0.0);
					break;
				case MODE_HEIGHT:
					value = vec4(vec3(0.5), 0.0);
					break;
				case MODE_POSITION:
					value = vec4((ray_start + ray_dir * front - parameters.aabb_position.xyz) / parameters.aabb_size.xyz, 0.0);
					break;
			}
		} else {
			float hit = payload.x;
			int base = int(payload.y) * ATTRIBUTES_PER_FACE;
			vec3 w = vec3(1.0 - payload.z - payload.w, payload.z, payload.w);
			vec4 n0 = attributes[base];
			switch (mode) {
				case MODE_NORMAL_TANGENT:
				case MODE_NORMAL_OBJECT: {
					vec3 hn = normalize(w.x * n0.xyz + w.y * attributes[base + 1].xyz + w.z * attributes[base + 2].xyz);
					if (mode == MODE_NORMAL_OBJECT) {
						value = vec4(0.5 + 0.5 * hn, 1.0);
					} else {
						vec3 ts = vec3(dot(hn, t), dot(hn, b), dot(hn, n));
						value = vec4(0.5 + 0.5 * vec3(-ts.x, ts.y, -ts.z), 1.0);
					}
					break;
				}
				case MODE_HEIGHT:
					value = vec4(vec3(clamp(0.5 + 0.5 * (front - hit) / max(front_dist, rear_dist), 0.0, 1.0)), 1.0);
					break;
				case MODE_COLOR:
					value = vec4((w.x * attributes[base + 3] + w.y * attributes[base + 4] + w.z * attributes[base + 5]).rgb, 1.0);
					break;
				case MODE_MATERIAL_ID:
					value = vec4(id_color(int(n0.w)), 1.0);
					break;
				case MODE_POSITION:
					value = vec4((ray_start + ray_dir * hit - parameters.aabb_position.xyz) / parameters.aabb_size.xyz, 1.0);
					break;
				case MODE_TEXTURE: {
					vec4 uv01 = attributes[base + 6];
					vec2 uv2 = attributes[base + 7].xy;
					value = vec4(texture(high_texture, w.x * uv01.xy + w.y * uv01.zw + w.z * uv2).rgb, 1.0);
					break;
				}
			}
		}
	}
	// Average of the jittered passes
	vec4 previous = imageLoad(output_image, pixel);
	imageStore(output_image, pixel, mix(previous, value, 1.0 / iteration));
}
"""

const MISS : String = """#version 460
#extension GL_EXT_ray_tracing : require
layout(location = 0) rayPayloadInEXT vec4 payload;
void main() {
	payload.x = -1.0;
}
"""

const CLOSEST_HIT : String = """#version 460
#extension GL_EXT_ray_tracing : require
layout(location = 0) rayPayloadInEXT vec4 payload;
hitAttributeEXT vec2 bary;
void main() {
	payload = vec4(gl_HitTEXT, float(gl_PrimitiveID), bary);
}
"""

## When matching parts by name, hits on other parts are ignored
const ANY_HIT : String = """#version 460
#extension GL_EXT_ray_tracing : require
layout(set = 0, binding = 6, std430) readonly buffer Attributes { vec4 attributes[]; };
layout(location = 0) rayPayloadInEXT vec4 payload;
void main() {
	int match_surface = int(payload.y);
	if (match_surface >= 0 && int(attributes[gl_PrimitiveID * 8].w) != match_surface) {
		ignoreIntersectionEXT;
	}
}
"""

## Acceleration structures and attributes of high poly meshes, by mesh
class HighPolyStructures:
	var rd : RenderingDevice
	var rids : Array[RID] = []
	var tlas : RID
	var hit_sbt : RID
	var pipeline : RID
	var shader : RID
	var attributes : RID

	func free_rids() -> void:
		for r in rids:
			if r.is_valid():
				rd.free_rid(r)
		rids.clear()

static var structures : Dictionary = {}

static func is_available() -> bool:
	var rd : RenderingDevice = mm_renderer.rendering_device
	return rd != null and rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE)

## Builds (once per high poly mesh) the acceleration structures, the ray
## tracing pipeline and the attribute buffer
static func get_structures(rd : RenderingDevice, high_mesh : Mesh) -> HighPolyStructures:
	if structures.has(high_mesh):
		return structures[high_mesh]
	var prepared : Dictionary = MMHighPolyBaker.prepare_high_poly(high_mesh)
	var s : HighPolyStructures = HighPolyStructures.new()
	s.rd = rd
	var source : RDShaderSource = RDShaderSource.new()
	source.source_raygen = RAYGEN
	source.source_miss = MISS
	source.source_closest_hit = CLOSEST_HIT
	source.source_any_hit = ANY_HIT
	var spirv : RDShaderSPIRV = rd.shader_compile_spirv_from_source(source)
	for e in [ spirv.compile_error_raygen, spirv.compile_error_miss, spirv.compile_error_closest_hit, spirv.compile_error_any_hit ]:
		if e != "":
			push_error("Ray tracing baker shader: "+e)
			return null
	s.shader = rd.shader_create_from_spirv(spirv)
	var stage : RDPipelineShader = RDPipelineShader.new()
	stage.shader = s.shader
	var hit_group : RDHitGroup = RDHitGroup.new()
	hit_group.closest_hit_shader = stage
	hit_group.any_hit_shader = stage
	s.pipeline = rd.raytracing_pipeline_create([ stage ], [ stage ], [ hit_group ], 1)
	s.hit_sbt = rd.hit_sbt_create(s.pipeline, 1)
	var sbt_range : int = rd.hit_sbt_range_alloc(s.hit_sbt, 1)
	rd.hit_sbt_range_update(s.hit_sbt, sbt_range, 0, PackedInt32Array([ 0 ]))
	# The BLAS has the faces of the merged mesh, in the order of the attributes
	var arrays : Array = prepared.mesh.surface_get_arrays(0)
	var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices : PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var bits : int = RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT | RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT
	var vertex_data : PackedByteArray = vertices.to_byte_array()
	var vertex_buffer : RID = rd.vertex_buffer_create(vertex_data.size(), vertex_data, bits)
	var index_buffer : RID = rd.index_buffer_create(indices.size(), RenderingDevice.INDEX_BUFFER_FORMAT_UINT32, indices.to_byte_array(), false, bits)
	var geometry : RDAccelerationStructureGeometry = RDAccelerationStructureGeometry.new()
	# Not opaque, so the any hit shader can ignore other parts
	geometry.flags = RenderingDevice.ACCELERATION_STRUCTURE_GEOMETRY_NO_DUPLICATE_ANY_HIT_INVOCATION_BIT
	geometry.vertex_buffer = vertex_buffer
	geometry.vertex_offset = 0
	geometry.vertex_stride = 12
	geometry.vertex_count = vertices.size()
	geometry.vertex_format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	geometry.index_buffer = index_buffer
	geometry.index_offset = 0
	geometry.index_count = indices.size()
	var blas : RID = rd.blas_create([ geometry ], RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT)
	rd.blas_build(blas)
	s.tlas = rd.tlas_create(1, RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT)
	var instance : RDAccelerationStructureInstance = RDAccelerationStructureInstance.new()
	instance.transform = Transform3D.IDENTITY
	instance.mask = 0xFF
	instance.hit_sbt_range = sbt_range
	instance.flags = RenderingDevice.ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT
	instance.blas = blas
	rd.tlas_build(s.tlas, [ instance ])
	var attribute_data : PackedByteArray = prepared.attributes.get_data()
	s.attributes = rd.storage_buffer_create(attribute_data.size(), attribute_data)
	s.rids = [ s.attributes, s.tlas, blas, index_buffer, vertex_buffer, s.hit_sbt, s.pipeline, s.shader ]
	structures[high_mesh] = s
	return s

static func create_storage_texture(rd : RenderingDevice, size : int) -> RID:
	var format : RDTextureFormat = RDTextureFormat.new()
	format.width = size
	format.height = size
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var data : PackedByteArray = PackedByteArray()
	data.resize(size*size*16)
	return rd.texture_create(format, RDTextureView.new(), [ data ])

static func image_uniform(binding : int, rid : RID) -> RDUniform:
	var u : RDUniform = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(rid)
	return u

## Bakes a map with hardware ray tracing (in the rendering thread). The
## pipeline is set up as for the software baker, with the rays fragment shader.
static func generate(pipeline : MMMeshRenderingPipeline, high_mesh : Mesh, map_mode : int, size : int, front_dist : float, rear_dist : float, aabb : AABB, samples : int, high_texture : MMTexture, texture : MMTexture) -> bool:
	var rd : RenderingDevice = mm_renderer.rendering_device
	var s : HighPolyStructures = get_structures(rd, high_mesh)
	if s == null:
		return false
	var gbuffers : Array[MMTexture] = [ MMTexture.new(), MMTexture.new(), MMTexture.new(), MMTexture.new() ]
	var output : RID = create_storage_texture(rd, size)
	var sampler_state : RDSamplerState = RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	var sampler : RID = rd.sampler_create(sampler_state)
	# The parameters only change by the sample index (updated for each sample)
	var parameters : PackedFloat32Array = PackedFloat32Array([
		aabb.position.x, aabb.position.y, aabb.position.z, float(map_mode),
		aabb.size.x, aabb.size.y, aabb.size.z, 0.0,
		front_dist, rear_dist, 0.0, 0.0 ])
	var parameter_buffer : RID = rd.storage_buffer_create(parameters.size()*4, parameters.to_byte_array())
	# Uniforms that do not change between samples
	var invariant_uniforms : Array[RDUniform] = []
	var u : RDUniform = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE
	u.binding = 0
	u.add_id(s.tlas)
	invariant_uniforms.append(u)
	invariant_uniforms.append(image_uniform(5, output))
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 6
	u.add_id(s.attributes)
	invariant_uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = 7
	u.add_id(sampler)
	u.add_id(high_texture.get_texture_rid(rd))
	invariant_uniforms.append(u)
	u = RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = 8
	u.add_id(parameter_buffer)
	invariant_uniforms.append(u)
	for i in max(1, samples):
		pipeline.set_parameter("jitter", MMHighPolyBaker.get_jitter(i)*2.0/size)
		for g in 4:
			pipeline.set_parameter("gbuffer", g)
			pipeline.in_thread_render(Vector2i(size, size), 3, gbuffers[g])
		parameters[7] = float(i+1)
		rd.buffer_update(parameter_buffer, 0, parameters.size()*4, parameters.to_byte_array())
		# The G-buffers are rendered again for each sample
		var uniforms : Array[RDUniform] = invariant_uniforms.duplicate()
		for g in 4:
			u = RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
			u.binding = g+1
			u.add_id(sampler)
			u.add_id(gbuffers[g].get_texture_rid(rd))
			uniforms.append(u)
		var uniform_set : RID = rd.uniform_set_create(uniforms, s.shader, 0)
		var list : int = rd.raytracing_list_begin()
		rd.raytracing_list_bind_raytracing_pipeline(list, s.pipeline)
		rd.raytracing_list_bind_uniform_set(list, uniform_set, 0)
		rd.raytracing_list_trace_rays(list, 0, s.hit_sbt, size, size, 1)
		rd.raytracing_list_end()
		rd.submit()
		rd.sync()
		rd.free_rid(uniform_set)
	rd.free_rid(parameter_buffer)
	rd.free_rid(sampler)
	texture.set_texture_rid(output, Vector2i(size, size), RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, rd)
	return true
