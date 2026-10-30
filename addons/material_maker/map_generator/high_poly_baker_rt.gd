extends Object
class_name MMHighPolyBakerRT


# Hardware ray traced high to low poly baking (when the GPU supports ray
# tracing pipelines): the low poly mesh is rasterized in UV space into
# G-buffers that hold the rays of its texels (highpoly_rays_fragment.tres),
# then a ray tracing pipeline traces them against acceleration structures of
# the high poly mesh. Rays and attributes are the same as those of
# MMHighPolyBaker's compute ray caster (highpoly_fragment.tres), so both give
# the same maps (up to floating point rounding).


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

// Before tracing, y is the high poly part the ray can hit (-1 for any). After
// tracing: hit distance (-1 for no hit), face index, barycentric coordinates.
layout(location = 0) rayPayloadEXT vec4 payload;

// Attributes of a face: 3 normals (w of the first one is the surface index,
// and of the second one the part index), 3 colors, then UVs (u0, v0, u1, v1),
// (u2, v2, 0, 0)
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
	// Texels that are not covered by the low poly mesh stay black
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
		// The any hit shader only filters parts when matching them by name
		uint flags = dir.w < 0.0 ? gl_RayFlagsOpaqueEXT : gl_RayFlagsNoneEXT;
		traceRayEXT(tlas, flags, 0xFF, 0, 0, 0, ray_start, 0.0, ray_dir, front + rear_dist, 0);
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
						// OpenGL tangent space, converted to Material Maker's convention
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
					// The high poly texture at the hit point, with the high poly UVs
					vec4 uv01 = attributes[base + 6];
					vec2 high_uv = w.x * uv01.xy + w.y * uv01.zw + w.z * attributes[base + 7].xy;
					value = vec4(textureLod(high_texture, high_uv, 0.0).rgb, 1.0);
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

## When matching parts by name, hits on other parts are ignored (the part
## index is the w component of the second attribute of faces)
const ANY_HIT : String = """#version 460
#extension GL_EXT_ray_tracing : require
layout(set = 0, binding = 6, std430) readonly buffer Attributes { vec4 attributes[]; };
layout(location = 0) rayPayloadInEXT vec4 payload;
void main() {
	int match_part = int(payload.y);
	if (match_part >= 0 && int(attributes[gl_PrimitiveID * 8 + 1].w) != match_part) {
		ignoreIntersectionEXT;
	}
}
"""

## Acceleration structures, attributes and pipeline of a high poly mesh
class HighPolyStructures:
	var rd : RenderingDevice
	var rids : Array[RID] = []
	var tlas : RID
	var hit_sbt : RID
	var pipeline : RID
	var shader : RID
	var attributes : RID

	func free_rids() -> void:
		MMHighPolyBakerRT.free_rids(rd, rids)
		rids.clear()

## Structures of the most recent high poly meshes, by mesh
static var structures : Dictionary = {}
const MAX_STRUCTURES : int = 4

## Whether the GPU (and the rendering driver) supports ray tracing pipelines
static func is_available() -> bool:
	var rd : RenderingDevice = mm_renderer.rendering_device
	return rd != null and rd.has_feature(RenderingDevice.SUPPORTS_RAYTRACING_PIPELINE)

## Builds (once per high poly mesh) the acceleration structures, the ray
## tracing pipeline and the attribute buffer, or returns null
static func get_structures(rd : RenderingDevice, high_mesh : Mesh) -> HighPolyStructures:
	if structures.has(high_mesh):
		return structures[high_mesh]
	while structures.size() >= MAX_STRUCTURES:
		structures[structures.keys()[0]].free_rids()
		structures.erase(structures.keys()[0])
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
	var s : HighPolyStructures = HighPolyStructures.new()
	s.rd = rd
	s.shader = rd.shader_create_from_spirv(spirv)
	if not s.shader.is_valid():
		return null
	s.rids.append(s.shader)
	var stage : RDPipelineShader = RDPipelineShader.new()
	stage.shader = s.shader
	var hit_group : RDHitGroup = RDHitGroup.new()
	hit_group.closest_hit_shader = stage
	hit_group.any_hit_shader = stage
	s.pipeline = rd.raytracing_pipeline_create([ stage ], [ stage ], [ hit_group ], 1)
	if not s.pipeline.is_valid() or not rd.raytracing_pipeline_is_valid(s.pipeline):
		s.free_rids()
		return null
	s.rids.append(s.pipeline)
	s.hit_sbt = rd.hit_sbt_create(s.pipeline, 1)
	s.rids.append(s.hit_sbt)
	var sbt_range : int = rd.hit_sbt_range_alloc(s.hit_sbt, 1)
	rd.hit_sbt_range_update(s.hit_sbt, sbt_range, 0, PackedInt32Array([ 0 ]))
	# The BLAS has the faces of the merged mesh, in the order of the
	# attributes (so the primitive index is the face index)
	var prepared : Dictionary = MMHighPolyBaker.prepare_high_poly(high_mesh)
	var arrays : Array = prepared.mesh.surface_get_arrays(0)
	var vertices : PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices : PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if indices.is_empty():
		s.free_rids()
		return null
	var bits : int = RenderingDevice.BUFFER_CREATION_DEVICE_ADDRESS_BIT | RenderingDevice.BUFFER_CREATION_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT
	var vertex_data : PackedByteArray = vertices.to_byte_array()
	var vertex_buffer : RID = rd.vertex_buffer_create(vertex_data.size(), vertex_data, bits)
	s.rids.append(vertex_buffer)
	var index_buffer : RID = rd.index_buffer_create(indices.size(), RenderingDevice.INDEX_BUFFER_FORMAT_UINT32, indices.to_byte_array(), false, bits)
	s.rids.append(index_buffer)
	var geometry : RDAccelerationStructureGeometry = RDAccelerationStructureGeometry.new()
	# Not opaque, so the any hit shader can ignore other parts (rays that hit
	# all parts are traced as opaque)
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
	if not blas.is_valid():
		s.free_rids()
		return null
	s.rids.append(blas)
	rd.blas_build(blas)
	s.tlas = rd.tlas_create(1, RenderingDevice.ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT)
	if not s.tlas.is_valid():
		s.free_rids()
		return null
	s.rids.append(s.tlas)
	var instance : RDAccelerationStructureInstance = RDAccelerationStructureInstance.new()
	instance.transform = Transform3D.IDENTITY
	instance.mask = 0xFF
	instance.hit_sbt_range = sbt_range
	instance.flags = RenderingDevice.ACCELERATION_STRUCTURE_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT
	instance.blas = blas
	rd.tlas_build(s.tlas, [ instance ])
	var attribute_data : PackedByteArray = prepared.attributes.get_data()
	s.attributes = rd.storage_buffer_create(attribute_data.size(), attribute_data)
	s.rids.append(s.attributes)
	structures[high_mesh] = s
	return s

static func create_storage_texture(rd : RenderingDevice, size : int) -> RID:
	var format : RDTextureFormat = RDTextureFormat.new()
	format.width = size
	format.height = size
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var texture : RID = rd.texture_create(format, RDTextureView.new())
	# Samples are accumulated in it
	rd.texture_clear(texture, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return texture

static func create_uniform(type : RenderingDevice.UniformType, binding : int, ids : Array) -> RDUniform:
	var u : RDUniform = RDUniform.new()
	u.uniform_type = type
	u.binding = binding
	for id in ids:
		u.add_id(id)
	return u

## Frees RIDs in reverse order of creation
static func free_rids(rd : RenderingDevice, rids : Array[RID]) -> void:
	for i in range(rids.size()-1, -1, -1):
		if rids[i].is_valid():
			rd.free_rid(rids[i])

## Renders the rays of the low poly mesh (with the jitter of a sample) in 4
## G-buffers, in a single pass. pipeline has the rays fragment shader.
static func render_gbuffers(rd : RenderingDevice, pipeline : MMMeshRenderingPipeline, framebuffer : RID, render_pipeline : RID) -> void:
	var rids : MMPipeline.RIDs = MMPipeline.RIDs.new()
	var clear_colors : PackedColorArray = PackedColorArray([ Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0, 0, 0, 0), Color(0, 0, 0, 0) ])
	var draw_list : int = rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_CLEAR_COLOR_ALL, clear_colors)
	rd.draw_list_bind_render_pipeline(draw_list, render_pipeline)
	rd.draw_list_bind_uniform_set(draw_list, pipeline.get_parameter_uniforms(rd, pipeline.shader, rids), 1)
	var texture_uniforms : RID = pipeline.get_texture_uniforms(rd, pipeline.shader, rids)
	if texture_uniforms.is_valid():
		rd.draw_list_bind_uniform_set(draw_list, texture_uniforms, 2)
	pipeline.draw_list_extra_setup(rd, draw_list, pipeline.shader, rids)
	rd.draw_list_draw(draw_list, pipeline.index_count == 0, 1, pipeline.index_count)
	rd.draw_list_end()
	rd.submit()
	rd.sync()
	rids.free_rids(rd)

## Bakes a map with hardware ray tracing (in the rendering thread) into
## texture, and returns false if it cannot. pipeline is set up as for the
## compute ray caster, with the rays fragment shader.
static func generate(pipeline : MMMeshRenderingPipeline, high_mesh : Mesh, map_mode : int, size : int, front_dist : float, rear_dist : float, aabb : AABB, samples : int, high_texture : MMTexture, texture : MMTexture) -> bool:
	var rd : RenderingDevice = mm_renderer.rendering_device
	var s : HighPolyStructures = get_structures(rd, high_mesh)
	if s == null:
		return false
	# RIDs freed at the end, in reverse order
	var rids : Array[RID] = []
	# The G-buffers, and the pipeline that renders them (created once for all samples)
	var gbuffers : Array[RID] = []
	for g in 4:
		gbuffers.append(pipeline.create_texture(rd, Vector2i(size, size), MMPipeline.TEXTURE_TYPE_RGBA32F, RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT))
		rids.append(gbuffers[g])
	var framebuffer : RID = rd.framebuffer_create(gbuffers)
	rids.append(framebuffer)
	var blend : RDPipelineColorBlendState = RDPipelineColorBlendState.new()
	for g in 4:
		blend.attachments.push_back(RDPipelineColorBlendStateAttachment.new())
	var rasterization_state : RDPipelineRasterizationState = RDPipelineRasterizationState.new()
	rasterization_state.cull_mode = pipeline.cull_mode
	var render_pipeline : RID = rd.render_pipeline_create(pipeline.shader, rd.framebuffer_get_format(framebuffer), -1, RenderingDevice.RENDER_PRIMITIVE_TRIANGLES,
		rasterization_state, RDPipelineMultisampleState.new(), RDPipelineDepthStencilState.new(), blend)
	if not render_pipeline.is_valid():
		free_rids(rd, rids)
		return false
	rids.append(render_pipeline)
	var output : RID = create_storage_texture(rd, size)
	var sampler_state : RDSamplerState = RDSamplerState.new()
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	var sampler : RID = rd.sampler_create(sampler_state)
	rids.append(sampler)
	# Only the sample index changes between samples
	var parameters : PackedFloat32Array = PackedFloat32Array([
		aabb.position.x, aabb.position.y, aabb.position.z, float(map_mode),
		aabb.size.x, aabb.size.y, aabb.size.z, 0.0,
		front_dist, rear_dist, 0.0, 0.0 ])
	var parameter_buffer : RID = rd.storage_buffer_create(parameters.size()*4, parameters.to_byte_array())
	rids.append(parameter_buffer)
	var uniforms : Array[RDUniform] = [
		create_uniform(RenderingDevice.UNIFORM_TYPE_ACCELERATION_STRUCTURE, 0, [ s.tlas ]),
		create_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 5, [ output ]),
		create_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 6, [ s.attributes ]),
		create_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 7, [ sampler, high_texture.get_texture_rid(rd) ]),
		create_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 8, [ parameter_buffer ]) ]
	for g in 4:
		uniforms.append(create_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, g+1, [ sampler, gbuffers[g] ]))
	var uniform_set : RID = rd.uniform_set_create(uniforms, s.shader, 0)
	rids.append(uniform_set)
	for i in max(1, samples):
		# The G-buffers are rendered again for each jittered sample
		pipeline.set_parameter("jitter", MMHighPolyBaker.get_jitter(i))
		render_gbuffers(rd, pipeline, framebuffer, render_pipeline)
		parameters[7] = float(i+1)
		rd.buffer_update(parameter_buffer, 0, parameters.size()*4, parameters.to_byte_array())
		var list : int = rd.raytracing_list_begin()
		rd.raytracing_list_bind_raytracing_pipeline(list, s.pipeline)
		rd.raytracing_list_bind_uniform_set(list, uniform_set, 0)
		rd.raytracing_list_trace_rays(list, 0, s.hit_sbt, size, size, 1)
		rd.raytracing_list_end()
		rd.submit()
		rd.sync()
	free_rids(rd, rids)
	texture.set_texture_rid(output, Vector2i(size, size), RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT, rd)
	return true
