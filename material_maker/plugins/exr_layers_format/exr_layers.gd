extends RefCounted


# Multi-layer OpenEXR files: one scanline image whose channels are named
# <layer>.<channel> (albedo.R, normal.X, height.Y...), half floats, with ZIP
# compression (16 scanlines per chunk).
#
# ZIP compression reorders the bytes of each chunk (even bytes, then odd
# bytes) and replaces them by their differences before compressing them
# with zlib. That step is done by a compute shader, as it is too slow in
# GDScript for large images.


const LINES_PER_CHUNK : int = 16
const COMPRESSION_ZIP : int = 3
const PIXEL_TYPE_HALF : int = 1
# Bytes of chunks processed by a dispatch of the compute shader
const BATCH_SIZE : int = 16 << 20
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

## The values of a channel of an image, as half floats
static func channel_plane(image : Image, channel : int) -> PackedByteArray:
	var rgba : Image = image.duplicate()
	if rgba.has_mipmaps():
		rgba.clear_mipmaps()
	rgba.convert(Image.FORMAT_RGBAH)
	var data : PackedByteArray = rgba.get_data()
	if channel > 0:
		# Shift the channel's values to the red channel
		var shifted : PackedByteArray = data.slice(2*channel)
		shifted.resize(data.size())
		data = shifted
	var plane : Image = Image.create_from_data(rgba.get_width(), rgba.get_height(), false, Image.FORMAT_RGBAH, data)
	plane.convert(Image.FORMAT_RH)
	return plane.get_data()

## Saves layers ({ name, image, options }, options.channels naming the
## channels of the image, e.g. "XYZ") in a multi-layer EXR file
static func save_layers(file_name : String, layers : Array) -> Error:
	if layers.is_empty():
		return ERR_INVALID_PARAMETER
	var size : Vector2i = layers[0].image.get_size()
	var channels : Array = []
	for layer in layers:
		if layer.image.get_size() != size:
			push_error("Layers of %s have different sizes" % file_name)
			return ERR_INVALID_PARAMETER
		var names : String = layer.options.get("channels", default_channels(layer.image, layer.options))
		for c in names.length():
			channels.append({ name="%s.%s" % [ layer.name, names[c] ], plane=channel_plane(layer.image, c) })
	# Channels are sorted by name
	channels.sort_custom(func(a, b): return a.name < b.name)
	var line_bytes : int = 2*size.x
	var chunk_count : int = ceili(float(size.y)/LINES_PER_CHUNK)
	# Uncompressed chunks: each line has the values of each channel
	var raw : PackedByteArray = PackedByteArray()
	for y in size.y:
		for c in channels:
			raw.append_array(c.plane.slice(y*line_bytes, (y+1)*line_bytes))
	var chunk_bytes : int = LINES_PER_CHUNK*line_bytes*channels.size()
	var predicted : PackedByteArray = predict(raw, chunk_bytes)
	if predicted.is_empty():
		return ERR_CANT_CREATE
	var chunks : Array[PackedByteArray] = []
	for chunk in chunk_count:
		var begin : int = chunk*chunk_bytes
		var end : int = mini(begin+chunk_bytes, raw.size())
		var compressed : PackedByteArray = predicted.slice(begin, end).compress(FileAccess.COMPRESSION_DEFLATE)
		# Chunks that do not get smaller are stored uncompressed
		chunks.append(compressed if compressed.size() < end-begin else raw.slice(begin, end))
	var file : FileAccess = FileAccess.open(file_name, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	var header : PackedByteArray = make_header(size, channels.map(func(c): return c.name))
	file.store_buffer(header)
	# Offset table, then chunks (first line, size, data)
	var offset : int = header.size()+8*chunk_count
	for chunk in chunks:
		file.store_64(offset)
		offset += 8+chunk.size()
	for chunk in chunk_count:
		file.store_32(chunk*LINES_PER_CHUNK)
		file.store_32(chunks[chunk].size())
		file.store_buffer(chunks[chunk])
	return OK

static func make_header(size : Vector2i, channel_names : Array) -> PackedByteArray:
	var header : StreamPeerBuffer = StreamPeerBuffer.new()
	# Magic number, version 2 (single part scanline, long names if needed)
	header.put_u32(20000630)
	var long_names : bool = channel_names.any(func(n): return n.length() > 31)
	header.put_u32(2 | (0x400 if long_names else 0))
	var channel_list : StreamPeerBuffer = StreamPeerBuffer.new()
	for n in channel_names:
		channel_list.put_data(n.to_utf8_buffer())
		channel_list.put_u8(0)
		channel_list.put_32(PIXEL_TYPE_HALF)
		# pLinear and reserved bytes, x and y sampling
		channel_list.put_u32(0)
		channel_list.put_32(1)
		channel_list.put_32(1)
	channel_list.put_u8(0)
	add_attribute(header, "channels", "chlist", channel_list.data_array)
	add_attribute(header, "compression", "compression", PackedByteArray([ COMPRESSION_ZIP ]))
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

## Reorders and replaces the bytes of each chunk by their differences, on
## the GPU (empty if no rendering device can be created)
static func predict(raw : PackedByteArray, chunk_bytes : int) -> PackedByteArray:
	var rd : RenderingDevice = RenderingServer.create_local_rendering_device()
	if rd == null:
		return PackedByteArray()
	var source : RDShaderSource = RDShaderSource.new()
	source.source_compute = PREDICTOR_SHADER
	var spirv : RDShaderSPIRV = rd.shader_compile_spirv_from_source(source)
	if spirv.compile_error_compute != "":
		push_error(spirv.compile_error_compute)
		rd.free()
		return PackedByteArray()
	var shader : RID = rd.shader_create_from_spirv(spirv)
	var pipeline : RID = rd.compute_pipeline_create(shader)
	var result : PackedByteArray = PackedByteArray()
	# Batches of whole chunks
	var batch_chunks : int = maxi(1, BATCH_SIZE/chunk_bytes)
	var begin : int = 0
	while begin < raw.size():
		var end : int = mini(begin+batch_chunks*chunk_bytes, raw.size())
		var batch : PackedByteArray = raw.slice(begin, end)
		var total : int = batch.size()
		batch.resize((total+3)/4*4)
		var input_buffer : RID = rd.storage_buffer_create(batch.size(), batch)
		var output_buffer : RID = rd.storage_buffer_create(batch.size())
		var uniforms : Array[RDUniform] = []
		for b in [ input_buffer, output_buffer ]:
			var u : RDUniform = RDUniform.new()
			u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
			u.binding = uniforms.size()
			u.add_id(b)
			uniforms.append(u)
		var uniform_set : RID = rd.uniform_set_create(uniforms, shader, 0)
		var parameters : PackedByteArray = PackedInt32Array([ total, chunk_bytes, 0, 0 ]).to_byte_array()
		var compute_list : int = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
		rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		rd.compute_list_set_push_constant(compute_list, parameters, parameters.size())
		rd.compute_list_dispatch(compute_list, ceili(float(batch.size()/4)/WORKGROUP_SIZE), 1, 1)
		rd.compute_list_end()
		rd.submit()
		rd.sync()
		result.append_array(rd.buffer_get_data(output_buffer).slice(0, total))
		rd.free_rid(uniform_set)
		rd.free_rid(input_buffer)
		rd.free_rid(output_buffer)
		begin = end
	rd.free_rid(pipeline)
	rd.free_rid(shader)
	rd.free()
	return result
