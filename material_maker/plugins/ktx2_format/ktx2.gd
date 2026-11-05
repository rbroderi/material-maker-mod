extends RefCounted


# KTX2 files (Khronos Texture 2.0): 2D textures with mipmaps, and 3D textures
# (the volume_export plugin), uncompressed or with Zstandard supercompression. The data
# format descriptor is a basic block with one sample per channel.


## Texel formats: Godot image format, Vulkan formats (linear and sRGB),
## component size (bytes) and channels
const FORMATS : Dictionary = {
	r8={ image=Image.FORMAT_R8, vulkan=9, vulkan_srgb=15, type_size=1, channels=1 },
	rgb8={ image=Image.FORMAT_RGB8, vulkan=23, vulkan_srgb=29, type_size=1, channels=3 },
	rgba8={ image=Image.FORMAT_RGBA8, vulkan=37, vulkan_srgb=43, type_size=1, channels=4 },
	r16f={ image=Image.FORMAT_RH, vulkan=76, type_size=2, channels=1 },
	rgb16f={ image=Image.FORMAT_RGBH, vulkan=90, type_size=2, channels=3 },
	rgba16f={ image=Image.FORMAT_RGBAH, vulkan=97, type_size=2, channels=4 },
	r32f={ image=Image.FORMAT_RF, vulkan=100, type_size=4, channels=1 },
	rgb32f={ image=Image.FORMAT_RGBF, vulkan=106, type_size=4, channels=3 },
	rgba32f={ image=Image.FORMAT_RGBAF, vulkan=109, type_size=4, channels=4 },
}
const CHANNEL_PREFIXES : Dictionary = { 1: "r", 3: "rgb", 4: "rgba" }

const IDENTIFIER : PackedByteArray = [ 0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A ]
const SUPERCOMPRESSION_ZSTD : int = 2

## Conversions of components (see convert_components): 8 bits unsigned
## normalized input or output instead of 32 bits floats, 16 bits floats
## output, and sRGB to linear or linear to sRGB (colors, not alpha)
const FROM_UNORM8 : int = 1
const TO_UNORM8 : int = 2
const TO_HALF : int = 4
const DECODE_SRGB : int = 8
const ENCODE_SRGB : int = 16

## Components converted per dispatch (keeps buffers small and the workgroup
## count below the 65535 limit)
const BATCH_COMPONENTS : int = 1 << 23
const WORKGROUP_SIZE : int = 256

## Converts components (packed in 32 bits words). 8 bits values are decoded
## with tables, and encoded (rounded to nearest) by counting the thresholds
## (the values of k-0.5, k = 1..255) they reach, so that results are the same
## as on the CPU. Floats are rounded to the nearest 16 bits float, with
## denormals (Image.convert rounds down and flushes them).
const CONVERT_SHADER : String = """
#version 450
layout(local_size_x = 256) in;
layout(set = 0, binding = 0, std430) readonly buffer Source { uint source[]; };
layout(set = 0, binding = 1, std430) writeonly buffer Result { uint result[]; };
layout(set = 0, binding = 2, std430) readonly buffer Tables { float tables[1024]; };
layout(push_constant, std430) uniform Parameters {
	uint count;
	uint mode;
	uint channels;
	uint padding;
} parameters;

const uint FROM_UNORM8 = 1u;
const uint TO_UNORM8 = 2u;
const uint TO_HALF = 4u;
const uint DECODE_SRGB = 8u;
const uint ENCODE_SRGB = 16u;

bool is_color(uint i) {
	return parameters.channels != 4u || (i & 3u) != 3u;
}

float component(uint i) {
	if ((parameters.mode & FROM_UNORM8) != 0u) {
		uint v = (source[i >> 2] >> ((i & 3u)*8u)) & 255u;
		return tables[((parameters.mode & DECODE_SRGB) != 0u && is_color(i)) ? v : 512u+v];
	}
	float c = uintBitsToFloat(source[i]);
	if ((parameters.mode & DECODE_SRGB) != 0u && is_color(i)) {
		c = c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055, 2.4);
	}
	return c;
}

uint to_unorm8(uint i, float c) {
	uint thresholds = ((parameters.mode & ENCODE_SRGB) != 0u && is_color(i)) ? 256u : 768u;
	uint k = 0u;
	for (uint step = 128u; step > 0u; step >>= 1) {
		if (k+step <= 255u && c >= tables[thresholds+k+step]) {
			k += step;
		}
	}
	return k;
}

uint to_half(uint f) {
	uint sign = (f >> 16) & 0x8000u;
	uint a = f & 0x7fffffffu;
	if (a > 0x7f800000u) {
		return sign | 0x7e00u | ((a >> 13) & 0x3ffu);
	} else if (a >= 0x477ff000u) {
		return sign | 0x7c00u;
	} else if (a >= 0x38800000u) {
		uint r = a-0x38000000u;
		r += 0xfffu+((r >> 13) & 1u);
		return sign | (r >> 13);
	} else if (a <= 0x33000000u) {
		return sign;
	}
	uint shift = 126u-(a >> 23);
	uint m = (a & 0x7fffffu) | 0x800000u;
	uint r = m >> shift;
	uint remainder = m & ((1u << shift)-1u);
	uint halfway = 1u << (shift-1u);
	if (remainder > halfway || (remainder == halfway && (r & 1u) != 0u)) {
		r += 1u;
	}
	return sign | r;
}

void main() {
	uint word = gl_GlobalInvocationID.x;
	uint i = word;
	if ((parameters.mode & TO_UNORM8) != 0u) {
		i = 4u*word;
		if (i < parameters.count) {
			uint value = 0u;
			for (uint k = 0u; k < 4u && i+k < parameters.count; ++k) {
				value |= to_unorm8(i+k, component(i+k)) << (8u*k);
			}
			result[word] = value;
		}
	} else if ((parameters.mode & TO_HALF) != 0u) {
		i = 2u*word;
		if (i < parameters.count) {
			uint high = i+1u < parameters.count ? to_half(floatBitsToUint(component(i+1u))) : 0u;
			result[word] = to_half(floatBitsToUint(component(i))) | (high << 16);
		}
	} else if (i < parameters.count) {
		result[word] = floatBitsToUint(component(i));
	}
}
"""


static func is_float(texel_format : String) -> bool:
	return texel_format.ends_with("f")

static func texel_size(texel_format : String) -> int:
	return FORMATS[texel_format].type_size*FORMATS[texel_format].channels

## Saves an image as a 2D KTX2 texture. Options: grayscale (one channel, by
## default for one channel images), alpha (four channels, or three, by
## default unless the image is RGB), bits (8, 16 or 32, by default those of
## the image), srgb (8 bits: sRGB texel format, by default unless grayscale;
## floats: converted from sRGB to linear when true), mipmaps (default true,
## filtered in linear space for sRGB formats), normal_map (renormalized
## mipmaps) and supercompression (Zstandard, default true).
static func save_image(image : Image, file_name : String, options : Dictionary = {}) -> Error:
	var image_channels : int = MMTexture.image_channels(image.get_format())
	var channels : int = 1
	if not options.get("grayscale", image_channels == 1):
		channels = 4 if options.get("alpha", image_channels != 3) else 3
	var bits : int = int(options.get("bits", MMTexture.image_bits(image.get_format())))
	var texel_format : String = CHANNEL_PREFIXES[channels]+{ 8: "8", 16: "16f", 32: "32f" }.get(bits, "8")
	var srgb : bool = bits == 8 and options.get("srgb", channels != 1)
	var linearize : bool = bits != 8 and options.get("srgb", false)
	var normal_map : bool = options.get("normal_map", false)
	var converted : Image = image.duplicate()
	if converted.has_mipmaps():
		converted.clear_mipmaps()
	var gpu : Dictionary = {}
	# Image.convert rounds down to 16 bits floats
	if linearize or (bits == 16 and MMTexture.image_bits(image.get_format()) != 16):
		converted.convert(FORMATS[CHANNEL_PREFIXES[channels]+"32f"].image)
		var mode : int = (DECODE_SRGB if linearize else 0) | (TO_HALF if bits == 16 else 0)
		var data : PackedByteArray = convert_components(gpu, converted.get_data(), mode, channels)
		if data.is_empty():
			release_gpu(gpu)
			return ERR_CANT_CREATE
		converted = Image.create_from_data(image.get_width(), image.get_height(), false, FORMATS[texel_format].image, data)
	else:
		converted.convert(FORMATS[texel_format].image)
	var levels : Array[PackedByteArray] = []
	if options.get("mipmaps", true) and srgb and not normal_map:
		levels.append(converted.get_data())
		levels.append_array(srgb_mipmaps(gpu, converted, channels))
	else:
		if options.get("mipmaps", true):
			converted.generate_mipmaps(normal_map)
		var data : PackedByteArray = converted.get_data()
		var level_count : int = converted.get_mipmap_count()+1
		for level in level_count:
			var end : int = converted.get_mipmap_offset(level+1) if level+1 < level_count else data.size()
			levels.append(data.slice(converted.get_mipmap_offset(level), end))
	release_gpu(gpu)
	if levels.has(PackedByteArray()):
		return ERR_CANT_CREATE
	return write(file_name, levels, Vector3i(image.get_width(), image.get_height(), 0), texel_format, srgb, options.get("supercompression", true))

## The mip levels of an 8 bits sRGB image: they are box filtered in linear
## space, then encoded to sRGB (rounded to nearest). An empty level on error.
static func srgb_mipmaps(gpu : Dictionary, image : Image, channels : int) -> Array[PackedByteArray]:
	var levels : Array[PackedByteArray] = []
	var linear_data : PackedByteArray = convert_components(gpu, image.get_data(), FROM_UNORM8 | DECODE_SRGB, channels)
	if linear_data.is_empty():
		return [ linear_data ]
	var linear : Image = Image.create_from_data(image.get_width(), image.get_height(), false, FORMATS[CHANNEL_PREFIXES[channels]+"32f"].image, linear_data)
	linear.generate_mipmaps()
	var level_count : int = linear.get_mipmap_count()+1
	if level_count == 1:
		return levels
	var start : int = linear.get_mipmap_offset(1)
	var mipmaps : PackedByteArray = convert_components(gpu, linear.get_data().slice(start), TO_UNORM8 | ENCODE_SRGB, channels)
	if mipmaps.is_empty():
		return [ mipmaps ]
	for level in range(1, level_count):
		var end : int = linear.get_mipmap_offset(level+1) if level+1 < level_count else linear.get_data().size()
		levels.append(mipmaps.slice((linear.get_mipmap_offset(level)-start)/4, (end-start)/4))
	return levels

## Values of 8 bits components (sRGB decoded, then not), each followed by
## the values from which they are encoded to k (k-0.5, k = 1..255; index 0
## unused)
static func unorm8_tables() -> PackedFloat32Array:
	var tables : PackedFloat32Array = PackedFloat32Array()
	tables.resize(1024)
	for k in 256:
		tables[k] = srgb_to_linear(k/255.0)
		tables[256+k] = srgb_to_linear((k-0.5)/255.0) if k > 0 else 0.0
		tables[512+k] = k/255.0
		tables[768+k] = (k-0.5)/255.0 if k > 0 else 0.0
	return tables

static func srgb_to_linear(c : float) -> float:
	return c/12.92 if c <= 0.04045 else pow((c+0.055)/1.055, 2.4)

## Converts components (see FROM_UNORM8...: 32 bits floats, or bytes with
## FROM_UNORM8) of an image that has channels channels (alpha is not
## converted from or to sRGB), with a compute shader on a local rendering
## device (created in gpu when first needed, see release_gpu), or on the CPU
## (slower) when there is none. Returns the converted data, empty on error.
static func convert_components(gpu : Dictionary, data : PackedByteArray, mode : int, channels : int) -> PackedByteArray:
	var input_size : int = 1 if mode & FROM_UNORM8 else 4
	var output_size : int = 1 if mode & TO_UNORM8 else (2 if mode & TO_HALF else 4)
	var count : int = data.size()/input_size
	var result : PackedByteArray = PackedByteArray()
	if gpu.is_empty():
		gpu.tables = unorm8_tables()
		gpu.rd = RenderingServer.create_local_rendering_device()
		if gpu.rd != null:
			var source : RDShaderSource = RDShaderSource.new()
			source.source_compute = CONVERT_SHADER
			var spirv : RDShaderSPIRV = gpu.rd.shader_compile_spirv_from_source(source)
			if spirv.compile_error_compute != "":
				push_error(spirv.compile_error_compute)
				return result
			gpu.shader = gpu.rd.shader_create_from_spirv(spirv)
			gpu.pipeline = gpu.rd.compute_pipeline_create(gpu.shader)
			var tables_data : PackedByteArray = gpu.tables.to_byte_array()
			gpu.tables_buffer = gpu.rd.storage_buffer_create(tables_data.size(), tables_data)
	if gpu.rd == null:
		for first in range(0, count, BATCH_COMPONENTS):
			var batch : PackedByteArray = data.slice(first*input_size, mini(first+BATCH_COMPONENTS, count)*input_size)
			result.append_array(convert_components_cpu(batch, mode, channels, gpu.tables))
		return result
	if not gpu.has("pipeline"):
		return result
	var rd : RenderingDevice = gpu.rd
	for first in range(0, count, BATCH_COMPONENTS):
		var batch_count : int = mini(BATCH_COMPONENTS, count-first)
		var batch : PackedByteArray = data.slice(first*input_size, (first+batch_count)*input_size)
		batch.resize((batch.size()+3)/4*4)
		var output_bytes : int = batch_count*output_size
		var words : int = (output_bytes+3)/4
		var input_buffer : RID = rd.storage_buffer_create(batch.size(), batch)
		var output_buffer : RID = rd.storage_buffer_create(words*4)
		var uniforms : Array[RDUniform] = []
		for b in [ input_buffer, output_buffer, gpu.tables_buffer ]:
			var u : RDUniform = RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.binding = uniforms.size()
			u.add_id(b)
			uniforms.append(u)
		var uniform_set : RID = rd.uniform_set_create(uniforms, gpu.shader, 0)
		var parameters : PackedByteArray = PackedInt32Array([ batch_count, mode, channels, 0 ]).to_byte_array()
		var compute_list : int = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, gpu.pipeline)
		rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		rd.compute_list_set_push_constant(compute_list, parameters, parameters.size())
		rd.compute_list_dispatch(compute_list, ceili(float(words)/WORKGROUP_SIZE), 1, 1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		result.append_array(rd.buffer_get_data(output_buffer).slice(0, output_bytes))
		rd.free_rid(uniform_set)
		rd.free_rid(input_buffer)
		rd.free_rid(output_buffer)
	return result

## Frees the rendering device created by convert_components
static func release_gpu(gpu : Dictionary) -> void:
	if gpu.get("rd") != null:
		if gpu.has("tables_buffer"):
			gpu.rd.free_rid(gpu.tables_buffer)
		if gpu.has("shader"):
			# Freeing the shader also frees its pipeline
			gpu.rd.free_rid(gpu.shader)
		gpu.rd.free()
	gpu.clear()

## The same conversions as CONVERT_SHADER, on the CPU
static func convert_components_cpu(data : PackedByteArray, mode : int, channels : int, tables : PackedFloat32Array) -> PackedByteArray:
	var count : int = data.size() if mode & FROM_UNORM8 else data.size()/4
	var values : PackedFloat32Array
	if mode & FROM_UNORM8:
		values.resize(count)
		for i in count:
			var decode : bool = (mode & DECODE_SRGB) != 0 and (channels != 4 or i%4 != 3)
			values[i] = tables[data[i] if decode else 512+data[i]]
	else:
		values = data.to_float32_array()
		if mode & DECODE_SRGB:
			for i in count:
				if channels != 4 or i%4 != 3:
					values[i] = srgb_to_linear(values[i])
	var result : PackedByteArray = PackedByteArray()
	if mode & TO_UNORM8:
		result.resize(count)
		for i in count:
			var c : float = values[i]
			var thresholds : int = 256 if (mode & ENCODE_SRGB) != 0 and (channels != 4 or i%4 != 3) else 768
			var k : int = 0
			var step : int = 128
			while step > 0:
				if k+step <= 255 and c >= tables[thresholds+k+step]:
					k += step
				step >>= 1
			result[i] = k
	elif mode & TO_HALF:
		var bits : PackedInt32Array = values.to_byte_array().to_int32_array()
		result.resize(2*count)
		for i in count:
			result.encode_u16(2*i, float_bits_to_half(bits[i] & 0xffffffff))
	else:
		result = values.to_byte_array()
	return result

## The nearest 16 bits float of a 32 bits float (its bits), with denormals
static func float_bits_to_half(f : int) -> int:
	var sign : int = (f >> 16) & 0x8000
	var a : int = f & 0x7fffffff
	if a > 0x7f800000:
		return sign | 0x7e00 | ((a >> 13) & 0x3ff)
	elif a >= 0x477ff000:
		return sign | 0x7c00
	elif a >= 0x38800000:
		var r : int = a-0x38000000
		r += 0xfff+((r >> 13) & 1)
		return sign | (r >> 13)
	elif a <= 0x33000000:
		return sign
	var shift : int = 126-(a >> 23)
	var m : int = (a & 0x7fffff) | 0x800000
	var r : int = m >> shift
	var remainder : int = m & ((1 << shift)-1)
	var halfway : int = 1 << (shift-1)
	if remainder > halfway or (remainder == halfway and (r & 1) != 0):
		r += 1
	return sign | r

## Writes a KTX2 file: levels are the texel data of each mip level, from the
## largest (rows from the top, then slices for 3D textures whose size.z is
## not 0)
static func write(file_name : String, levels : Array[PackedByteArray], size : Vector3i, texel_format : String, srgb : bool = false, zstd : bool = false) -> Error:
	var format : Dictionary = FORMATS[texel_format]
	var file : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	var dfd : PackedByteArray = data_format_descriptor(texel_format, srgb)
	var kvd : PackedByteArray = key_value_data()
	# Level data is stored from the smallest level, aligned on the texel size
	# and 4 bytes when it is not supercompressed
	var stored : Array[PackedByteArray] = []
	for l in levels:
		stored.append(l.compress(FileAccess.COMPRESSION_ZSTD) if zstd else l)
	var alignment : int = 1 if zstd else lcm(texel_size(texel_format), 4)
	var dfd_offset : int = 80+24*levels.size()
	var offset : int = dfd_offset+dfd.size()+kvd.size()
	var offsets : Array[int] = []
	offsets.resize(levels.size())
	var paddings : Array[int] = []
	paddings.resize(levels.size())
	for level in range(levels.size()-1, -1, -1):
		paddings[level] = (alignment-offset%alignment)%alignment
		offset += paddings[level]
		offsets[level] = offset
		offset += stored[level].size()
	var header : StreamPeerBuffer = StreamPeerBuffer.new()
	header.put_data(IDENTIFIER)
	header.put_u32(format.vulkan_srgb if srgb and format.has("vulkan_srgb") else format.vulkan)
	header.put_u32(format.type_size)
	header.put_u32(size.x)
	header.put_u32(size.y)
	header.put_u32(size.z)
	# Layers, faces, levels, supercompression
	header.put_u32(0)
	header.put_u32(1)
	header.put_u32(levels.size())
	header.put_u32(SUPERCOMPRESSION_ZSTD if zstd else 0)
	header.put_u32(dfd_offset)
	header.put_u32(dfd.size())
	header.put_u32(dfd_offset+dfd.size())
	header.put_u32(kvd.size())
	# No supercompression global data
	header.put_u64(0)
	header.put_u64(0)
	for level in levels.size():
		header.put_u64(offsets[level])
		header.put_u64(stored[level].size())
		header.put_u64(levels[level].size())
	file.store_buffer(header.data_array)
	file.store_buffer(dfd)
	file.store_buffer(kvd)
	for level in range(levels.size()-1, -1, -1):
		var padding : PackedByteArray = PackedByteArray()
		padding.resize(paddings[level])
		file.store_buffer(padding)
		file.store_buffer(stored[level])
	return OK

static func lcm(a : int, b : int) -> int:
	var x : int = a
	var y : int = b
	while y != 0:
		var t : int = y
		y = x%y
		x = t
	return a*b/x

## Data format descriptor: a basic block (RGBSDA color model, BT.709
## primaries, linear or sRGB transfer, straight alpha) with a sample per
## channel
static func data_format_descriptor(texel_format : String, srgb : bool) -> PackedByteArray:
	var format : Dictionary = FORMATS[texel_format]
	var channel_count : int = format.channels
	var bits : int = 8*format.type_size
	var float_format : bool = is_float(texel_format)
	var block_size : int = 24+16*channel_count
	var dfd : StreamPeerBuffer = StreamPeerBuffer.new()
	dfd.put_u32(4+block_size)
	dfd.put_u32(0)
	dfd.put_u32(2 | (block_size << 16))
	dfd.put_u32(1 | (1 << 8) | ((2 if srgb else 1) << 16))
	dfd.put_u32(0)
	dfd.put_u32(texel_size(texel_format))
	dfd.put_u32(0)
	for c in channel_count:
		var channel_id : int = [ 0, 1, 2, 15 ][c]
		var channel_type : int = channel_id | (0xC0 if float_format else 0)
		# Alpha is linear in sRGB formats
		if srgb and channel_id == 15:
			channel_type |= 0x10
		dfd.put_u32((c*bits) | ((bits-1) << 16) | (channel_type << 24))
		dfd.put_u32(0)
		if float_format:
			dfd.put_u32(0xBF800000)
			dfd.put_u32(0x3F800000)
		else:
			dfd.put_u32(0)
			dfd.put_u32((1 << bits)-1)
	return dfd.data_array

static func key_value_data() -> PackedByteArray:
	var kvd : StreamPeerBuffer = StreamPeerBuffer.new()
	var entry : PackedByteArray = "KTXwriter".to_utf8_buffer()
	entry.append(0)
	entry.append_array("Material Maker".to_utf8_buffer())
	entry.append(0)
	kvd.put_u32(entry.size())
	kvd.put_data(entry)
	while kvd.get_size()%4 != 0:
		kvd.put_u8(0)
	return kvd.data_array
