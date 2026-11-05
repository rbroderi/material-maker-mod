extends RefCounted


# Multi-layer OpenEXR files: one scanline image whose channels are named
# <layer>.<channel> (albedo.R, normal.X, height.Y...), stored as 16 bits
# floats (or 32 bits floats), ZIP compressed by default.
#
# ZIP compression reorders the bytes of each chunk (even bytes, then odd
# bytes) and replaces them by their differences before compressing them
# with zlib. That step is done by a compute shader, as it is too slow in
# GDScript for large images. Images are written in batches of lines, so
# that large images do not need more memory than a batch.


const PIXEL_TYPE_HALF : int = 1
const PIXEL_TYPE_FLOAT : int = 2
## Compression code and lines per chunk of the compression option's values
const COMPRESSIONS : Dictionary = { "none": [ 0, 1 ], "zips": [ 2, 1 ], "zip": [ 3, 16 ] }
## Bytes of uncompressed chunks and pixels written in a batch (at least a
## chunk)
const BATCH_BYTES : int = 16 << 20
const BATCH_PIXELS : int = 1 << 21
const WORKGROUP_SIZE : int = 256

const PREDICTOR_SHADER : String = """
#version 450
layout(local_size_x = 256) in;
layout(set = 0, binding = 0, std430) readonly buffer Raw { uint raw[]; };
layout(set = 0, binding = 1, std430) writeonly buffer Result { uint result[]; };
layout(push_constant, std430) uniform Parameters {
	uint total_bytes;
	uint chunk_bytes;
	uint padding0;
	uint padding1;
} parameters;

uint raw_byte(uint i) {
	return (raw[i >> 2] >> ((i & 3u)*8u)) & 255u;
}

// Byte j of a chunk (that starts at base, n bytes) after reordering: the
// even bytes, then the odd bytes
uint reordered(uint base, uint n, uint j) {
	uint half_n = (n+1u)/2u;
	return j < half_n ? raw_byte(base+2u*j) : raw_byte(base+2u*(j-half_n)+1u);
}

void main() {
	uint word = gl_GlobalInvocationID.x;
	if (word*4u >= parameters.total_bytes) {
		return;
	}
	uint value = 0u;
	for (uint k = 0u; k < 4u; ++k) {
		uint i = word*4u+k;
		if (i >= parameters.total_bytes) {
			break;
		}
		uint base = (i/parameters.chunk_bytes)*parameters.chunk_bytes;
		uint n = min(parameters.chunk_bytes, parameters.total_bytes-base);
		uint j = i-base;
		uint t = reordered(base, n, j);
		uint d = j == 0u ? t : ((t+384u-reordered(base, n, j-1u)) & 255u);
		value |= d << (k*8u);
	}
	result[word] = value;
}
"""

## Converts RGBA 32 bits floats to 16 bits floats (rounded to nearest even,
## with denormals: Image.convert rounds down and flushes them to zero),
## and/or the components whose bit is set in flags from sRGB to linear
const CONVERT_SHADER : String = """
#version 450
layout(local_size_x = 256) in;
layout(set = 0, binding = 0, std430) readonly buffer Source { uint source[]; };
layout(set = 0, binding = 1, std430) writeonly buffer Result { uint result[]; };
layout(push_constant, std430) uniform Parameters {
	uint count;
	uint flags;
	uint padding0;
	uint padding1;
} parameters;

const uint TO_HALF = 16u;

uint value(uint i) {
	uint v = source[i];
	if ((parameters.flags & (1u << (i & 3u))) != 0u) {
		float c = uintBitsToFloat(v);
		c = c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055, 2.4);
		v = floatBitsToUint(c);
	}
	return v;
}

uint to_half(uint f) {
	uint sign = (f >> 16) & 0x8000u;
	uint a = f & 0x7fffffffu;
	if (a > 0x7f800000u) {
		// NaN
		return sign | 0x7e00u | ((a >> 13) & 0x3ffu);
	} else if (a >= 0x477ff000u) {
		// Infinity, or rounded to infinity
		return sign | 0x7c00u;
	} else if (a >= 0x38800000u) {
		// Normal half float
		uint r = a-0x38000000u;
		r += 0xfffu+((r >> 13) & 1u);
		return sign | (r >> 13);
	} else if (a <= 0x33000000u) {
		// Rounded to zero
		return sign;
	}
	// Denormal half float
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
	uint i = gl_GlobalInvocationID.x;
	if ((parameters.flags & TO_HALF) != 0u) {
		if (2u*i >= parameters.count) {
			return;
		}
		uint high = 2u*i+1u < parameters.count ? to_half(value(2u*i+1u)) : 0u;
		result[i] = to_half(value(2u*i)) | (high << 16);
	} else if (i < parameters.count) {
		result[i] = value(i);
	}
}
"""

const CONVERT_TO_HALF : int = 16


## Compute shaders on a local rendering device, created when first needed
class Gpu:
	var rd : RenderingDevice = null
	var shaders : Dictionary = {}
	var pipelines : Dictionary = {}

	func get_pipeline(source_code : String) -> RID:
		if pipelines.has(source_code):
			return pipelines[source_code]
		if rd == null:
			rd = RenderingServer.create_local_rendering_device()
			if rd == null:
				push_error("Multi-layer OpenEXR files need a rendering device")
				return RID()
		var source : RDShaderSource = RDShaderSource.new()
		source.source_compute = source_code
		var spirv : RDShaderSPIRV = rd.shader_compile_spirv_from_source(source)
		if spirv.compile_error_compute != "":
			push_error(spirv.compile_error_compute)
			return RID()
		shaders[source_code] = rd.shader_create_from_spirv(spirv)
		pipelines[source_code] = rd.compute_pipeline_create(shaders[source_code])
		return pipelines[source_code]

	## Runs a shader on data (words_per_invocation words per invocation) with
	## 2 parameters, and returns the first result_size bytes of its result
	## (empty on error)
	func run(source_code : String, data : PackedByteArray, parameter0 : int, parameter1 : int, result_size : int, words_per_invocation : int = 1) -> PackedByteArray:
		var pipeline : RID = get_pipeline(source_code)
		if not pipeline.is_valid():
			return PackedByteArray()
		var input : PackedByteArray = data
		if input.size() % 4 != 0:
			input = data.duplicate()
			input.resize((data.size()+3)/4*4)
		var input_buffer : RID = rd.storage_buffer_create(input.size(), input)
		var output_buffer : RID = rd.storage_buffer_create((result_size+3)/4*4)
		var uniforms : Array[RDUniform] = []
		for b in [ input_buffer, output_buffer ]:
			var u : RDUniform = RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.binding = uniforms.size()
			u.add_id(b)
			uniforms.append(u)
		var uniform_set : RID = rd.uniform_set_create(uniforms, shaders[source_code], 0)
		var parameters : PackedByteArray = PackedInt32Array([ parameter0, parameter1, 0, 0 ]).to_byte_array()
		var compute_list : int = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		rd.compute_list_set_push_constant(compute_list, parameters, parameters.size())
		var invocations : int = ceili(float(input.size()/4)/words_per_invocation)
		rd.compute_list_dispatch(compute_list, ceili(float(invocations)/WORKGROUP_SIZE), 1, 1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		var result : PackedByteArray = rd.buffer_get_data(output_buffer).slice(0, result_size)
		rd.free_rid(uniform_set)
		rd.free_rid(input_buffer)
		rd.free_rid(output_buffer)
		return result

	func release() -> void:
		if rd != null:
			# Freeing a shader also frees its pipeline
			for s in shaders.values():
				rd.free_rid(s)
			rd.free()
			rd = null


## Default channel names of a layer (see the grayscale and alpha options of
## exports), by channel count
static func default_channels(image : Image, options : Dictionary) -> String:
	if options.get("grayscale", false):
		return "Y"
	elif options.has("alpha"):
		return "RGBA" if options.alpha else "RGB"
	match MMTexture.image_channels(image.get_format()):
		1:
			return "Y"
		3:
			return "RGB"
	return "RGBA"

## Lines of a layer's image, as a RGBAH or RGBAF image (the layer's pixel
## type), null on error
static func layer_lines(gpu : Gpu, layer : Dictionary, first_line : int, line_count : int) -> Image:
	var image : Image = layer.image
	var lines : Image = image.get_region(Rect2i(0, first_line, image.get_width(), line_count))
	if lines.has_mipmaps():
		lines.clear_mipmaps()
	var half : bool = layer.pixel_type == PIXEL_TYPE_HALF
	if half and layer.linearize == 0 and lines.get_format() in [ Image.FORMAT_RH, Image.FORMAT_RGH, Image.FORMAT_RGBH, Image.FORMAT_RGBAH ]:
		lines.convert(Image.FORMAT_RGBAH)
		return lines
	# Image.convert to 32 bits floats is exact, to 16 bits floats it is not
	lines.convert(Image.FORMAT_RGBAF)
	if not half and layer.linearize == 0:
		return lines
	var count : int = lines.get_width()*lines.get_height()*4
	var flags : int = layer.linearize | (CONVERT_TO_HALF if half else 0)
	var converted : PackedByteArray = gpu.run(CONVERT_SHADER, lines.get_data(), count, flags, count*(2 if half else 4), 2 if half else 1)
	if converted.is_empty():
		return null
	return Image.create_from_data(lines.get_width(), lines.get_height(), false, Image.FORMAT_RGBAH if half else Image.FORMAT_RGBAF, converted)

## A channel of a RGBAH or RGBAF image
static func channel_plane(rgba : Image, channel : int) -> PackedByteArray:
	var half : bool = rgba.get_format() == Image.FORMAT_RGBAH
	var data : PackedByteArray = rgba.get_data()
	if channel > 0:
		# Shift the channel's values to the red channel
		var shifted : PackedByteArray = data.slice((2 if half else 4)*channel)
		shifted.resize(data.size())
		data = shifted
	var plane : Image = Image.create_from_data(rgba.get_width(), rgba.get_height(), false, rgba.get_format(), data)
	plane.convert(Image.FORMAT_RH if half else Image.FORMAT_RF)
	return plane.get_data()

## Saves layers ({ name, image, options }) in a multi-layer EXR file.
## Options of layers: channels (names of the image's channels, e.g. "XYZ"),
## bits (32 for 32 bits floats, 16 bits floats otherwise), srgb (RGB
## converted to linear), grayscale and alpha (default channel names), and
## compression (zip, zips or none; the first layer that has it sets it for
## the file). A layer whose name is empty has channels without prefix.
static func save_layers(file_name : String, layers : Array) -> Error:
	if layers.is_empty():
		return ERR_INVALID_PARAMETER
	var size : Vector2i = layers[0].image.get_size() if layers[0].image != null else Vector2i.ZERO
	if size.x <= 0 or size.y <= 0:
		push_error("Cannot save an empty image in %s" % file_name)
		return ERR_INVALID_PARAMETER
	var compression : String = ""
	var file_layers : Array[Dictionary] = []
	var channels : Array[Dictionary] = []
	for layer in layers:
		var image : Image = layer.image
		var options : Dictionary = layer.get("options", {})
		if image == null or image.get_size() != size:
			push_error("Layers of %s have different sizes" % file_name)
			return ERR_INVALID_PARAMETER
		if image.is_compressed():
			push_error("Cannot save compressed images in %s" % file_name)
			return ERR_INVALID_PARAMETER
		if compression == "" and options.has("compression"):
			compression = str(options.compression).to_lower()
		var names : String = options.get("channels", default_channels(image, options))
		if names.length() < 1 or names.length() > 4:
			push_error("Layer %s of %s must have 1 to 4 channels" % [ layer.name, file_name ])
			return ERR_INVALID_PARAMETER
		var file_layer : Dictionary = {
			image=image,
			pixel_type=PIXEL_TYPE_FLOAT if int(options.get("bits", 16)) == 32 else PIXEL_TYPE_HALF,
			linearize=0b0111 if options.get("srgb", false) else 0
		}
		for c in names.length():
			var channel_name : String = names[c] if layer.name == "" else "%s.%s" % [ layer.name, names[c] ]
			if channels.any(func(other): return other.name == channel_name):
				push_error("Channel %s of %s is defined twice" % [ channel_name, file_name ])
				return ERR_INVALID_PARAMETER
			channels.append({ name=channel_name, layer=file_layers.size(), channel=c, pixel_type=file_layer.pixel_type })
		file_layers.append(file_layer)
	if compression == "":
		compression = "zip"
	if not COMPRESSIONS.has(compression):
		push_error("Unknown compression %s for %s" % [ compression, file_name ])
		return ERR_INVALID_PARAMETER
	# Channels are sorted by name
	channels.sort_custom(func(a, b): return a.name < b.name)
	var line_bytes : int = 0
	for c in channels:
		line_bytes += (2 if c.pixel_type == PIXEL_TYPE_HALF else 4)*size.x
	var lines_per_chunk : int = COMPRESSIONS[compression][1]
	var compressed : bool = COMPRESSIONS[compression][0] != 0
	var chunk_bytes : int = lines_per_chunk*line_bytes
	var chunk_count : int = ceili(float(size.y)/lines_per_chunk)
	var batch_lines : int = mini(BATCH_BYTES/line_bytes, BATCH_PIXELS/size.x)
	batch_lines = maxi(lines_per_chunk, batch_lines/lines_per_chunk*lines_per_chunk)
	var file : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	var header : PackedByteArray = make_header(size, channels, COMPRESSIONS[compression][0])
	file.store_buffer(header)
	# Offset table (written once the chunks are), then chunks (first line,
	# size, data)
	var offsets : PackedInt64Array = PackedInt64Array()
	offsets.resize(chunk_count)
	file.store_buffer(offsets.to_byte_array())
	var gpu : Gpu = Gpu.new()
	var error : Error = OK
	for first_line in range(0, size.y, batch_lines):
		var line_count : int = mini(batch_lines, size.y-first_line)
		var lines : Array[Image] = []
		for l in file_layers:
			var layer_image : Image = layer_lines(gpu, l, first_line, line_count)
			if layer_image == null:
				error = ERR_CANT_CREATE
				break
			lines.append(layer_image)
		if error != OK:
			break
		var planes : Array[PackedByteArray] = []
		for c in channels:
			planes.append(channel_plane(lines[c.layer], c.channel))
		lines.clear()
		# Uncompressed chunks: each line has the values of each channel
		var raw : PackedByteArray = PackedByteArray()
		for y in line_count:
			for plane in planes:
				var plane_line_bytes : int = plane.size()/line_count
				raw.append_array(plane.slice(y*plane_line_bytes, (y+1)*plane_line_bytes))
		planes.clear()
		var predicted : PackedByteArray = PackedByteArray()
		if compressed:
			predicted = gpu.run(PREDICTOR_SHADER, raw, raw.size(), chunk_bytes, raw.size())
			if predicted.is_empty():
				error = ERR_CANT_CREATE
				break
		var batch_chunks : int = ceili(float(raw.size())/chunk_bytes)
		var compressed_chunks : Array[PackedByteArray] = []
		if compressed:
			# Chunks are compressed in parallel
			compressed_chunks.resize(batch_chunks)
			var compress_chunk : Callable = func(i : int) -> void:
				compressed_chunks[i] = predicted.slice(i*chunk_bytes, mini((i+1)*chunk_bytes, predicted.size())).compress(FileAccess.COMPRESSION_DEFLATE)
			WorkerThreadPool.wait_for_group_task_completion(WorkerThreadPool.add_group_task(compress_chunk, batch_chunks))
		for i in batch_chunks:
			var begin : int = i*chunk_bytes
			var data : PackedByteArray = raw.slice(begin, mini(begin+chunk_bytes, raw.size()))
			# Chunks that do not get smaller are stored uncompressed
			if compressed and compressed_chunks[i].size() < data.size():
				data = compressed_chunks[i]
			var chunk : int = (first_line+begin/line_bytes)/lines_per_chunk
			offsets[chunk] = file.get_position()
			file.store_32(chunk*lines_per_chunk)
			file.store_32(data.size())
			file.store_buffer(data)
	gpu.release()
	if error == OK:
		file.seek(header.size())
		file.store_buffer(offsets.to_byte_array())
		error = file.get_error()
	file.close()
	if error != OK:
		DirAccess.remove_absolute(file_name)
	return error

static func make_header(size : Vector2i, channels : Array[Dictionary], compression : int) -> PackedByteArray:
	var header : StreamPeerBuffer = StreamPeerBuffer.new()
	# Magic number, version 2 (single part scanline, long names if needed)
	header.put_u32(20000630)
	var long_names : bool = channels.any(func(c): return c.name.to_utf8_buffer().size() > 31)
	header.put_u32(2 | (0x400 if long_names else 0))
	var channel_list : StreamPeerBuffer = StreamPeerBuffer.new()
	for c in channels:
		channel_list.put_data(c.name.to_utf8_buffer())
		channel_list.put_u8(0)
		channel_list.put_32(c.pixel_type)
		# pLinear and reserved bytes, x and y sampling
		channel_list.put_u32(0)
		channel_list.put_32(1)
		channel_list.put_32(1)
	channel_list.put_u8(0)
	add_attribute(header, "channels", "chlist", channel_list.data_array)
	add_attribute(header, "compression", "compression", PackedByteArray([ compression ]))
	var window : StreamPeerBuffer = StreamPeerBuffer.new()
	for v in [ 0, 0, size.x-1, size.y-1 ]:
		window.put_32(v)
	add_attribute(header, "dataWindow", "box2i", window.data_array)
	add_attribute(header, "displayWindow", "box2i", window.data_array)
	add_attribute(header, "lineOrder", "lineOrder", PackedByteArray([ 0 ]))
	var value : StreamPeerBuffer = StreamPeerBuffer.new()
	value.put_float(1.0)
	add_attribute(header, "pixelAspectRatio", "float", value.data_array)
	add_attribute(header, "screenWindowCenter", "v2f", PackedByteArray([ 0, 0, 0, 0, 0, 0, 0, 0 ]))
	add_attribute(header, "screenWindowWidth", "float", value.data_array)
	header.put_u8(0)
	return header.data_array

static func add_attribute(header : StreamPeerBuffer, attribute_name : String, type : String, value : PackedByteArray) -> void:
	header.put_data(attribute_name.to_utf8_buffer())
	header.put_u8(0)
	header.put_data(type.to_utf8_buffer())
	header.put_u8(0)
	header.put_32(value.size())
	header.put_data(value)
