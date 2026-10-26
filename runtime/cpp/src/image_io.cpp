// Image decoding (EXR with tinyexr, PNG with a small decoder using miniz)
// and encoding

#include "image_io.h"

#include <miniz.h>
#include <tinyexr.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>

namespace mmr {

namespace {

uint32_t read_be32(const uint8_t *p) {
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

int paeth(int a, int b, int c) {
	int p = a + b - c;
	int pa = std::abs(p - a);
	int pb = std::abs(p - b);
	int pc = std::abs(p - c);
	if (pa <= pb && pa <= pc) {
		return a;
	}
	return pb <= pc ? b : c;
}

/// Non interlaced 8 bits PNGs (grey, grey + alpha, RGB, RGBA), as written
/// by Godot
bool decode_png(const std::vector<uint8_t> &data, Image &image, std::string &error) {
	static const uint8_t signature[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
	if (data.size() < 8 || memcmp(data.data(), signature, 8) != 0) {
		error = "not a PNG file";
		return false;
	}
	uint32_t width = 0, height = 0;
	int bit_depth = 0, color_type = 0, interlace = 0;
	std::vector<uint8_t> compressed;
	size_t pos = 8;
	while (pos + 12 <= data.size()) {
		uint32_t length = read_be32(&data[pos]);
		const char *type = (const char *)&data[pos + 4];
		const uint8_t *chunk = &data[pos + 8];
		if (pos + 12 + length > data.size()) {
			break;
		}
		if (memcmp(type, "IHDR", 4) == 0) {
			width = read_be32(chunk);
			height = read_be32(chunk + 4);
			bit_depth = chunk[8];
			color_type = chunk[9];
			interlace = chunk[12];
		} else if (memcmp(type, "IDAT", 4) == 0) {
			compressed.insert(compressed.end(), chunk, chunk + length);
		} else if (memcmp(type, "IEND", 4) == 0) {
			break;
		}
		pos += 12 + length;
	}
	int channels = color_type == 0 ? 1 : color_type == 2 ? 3 : color_type == 4 ? 2 : color_type == 6 ? 4 : 0;
	if (bit_depth != 8 || channels == 0 || interlace != 0) {
		error = "unsupported PNG format (only 8 bits, non interlaced grey or RGB(A))";
		return false;
	}
	size_t raw_size = 0;
	void *raw = tinfl_decompress_mem_to_heap(compressed.data(), compressed.size(), &raw_size, TINFL_FLAG_PARSE_ZLIB_HEADER);
	size_t stride = (size_t)width * channels;
	if (raw == nullptr || raw_size < (stride + 1) * height) {
		mz_free(raw);
		error = "corrupted PNG data";
		return false;
	}
	std::vector<uint8_t> pixels(stride * height);
	const uint8_t *src = (const uint8_t *)raw;
	for (uint32_t y = 0; y < height; y++) {
		int filter = src[y * (stride + 1)];
		const uint8_t *line = src + y * (stride + 1) + 1;
		uint8_t *out = &pixels[y * stride];
		const uint8_t *previous = y > 0 ? &pixels[(y - 1) * stride] : nullptr;
		for (size_t x = 0; x < stride; x++) {
			int a = x >= (size_t)channels ? out[x - channels] : 0;
			int b = previous ? previous[x] : 0;
			int c = (previous && x >= (size_t)channels) ? previous[x - channels] : 0;
			int predictor = 0;
			switch (filter) {
				case 1: predictor = a; break;
				case 2: predictor = b; break;
				case 3: predictor = (a + b) / 2; break;
				case 4: predictor = paeth(a, b, c); break;
				default: break;
			}
			out[x] = (uint8_t)(line[x] + predictor);
		}
	}
	mz_free(raw);
	image.width = (int)width;
	image.height = (int)height;
	image.channels = 4;
	image.pixels.resize((size_t)width * height * 4);
	for (size_t i = 0; i < (size_t)width * height; i++) {
		const uint8_t *p = &pixels[i * channels];
		float *o = &image.pixels[i * 4];
		switch (channels) {
			case 1: o[0] = o[1] = o[2] = p[0] / 255.0f; o[3] = 1.0f; break;
			case 2: o[0] = o[1] = o[2] = p[0] / 255.0f; o[3] = p[1] / 255.0f; break;
			case 3: o[0] = p[0] / 255.0f; o[1] = p[1] / 255.0f; o[2] = p[2] / 255.0f; o[3] = 1.0f; break;
			default: for (int c = 0; c < 4; c++) { o[c] = p[c] / 255.0f; } break;
		}
	}
	return true;
}

bool decode_exr(const std::vector<uint8_t> &data, Image &image, std::string &error) {
	EXRVersion version;
	if (ParseEXRVersionFromMemory(&version, data.data(), data.size()) != TINYEXR_SUCCESS) {
		error = "not an EXR file";
		return false;
	}
	EXRHeader header;
	InitEXRHeader(&header);
	const char *message = nullptr;
	if (ParseEXRHeaderFromMemory(&header, &version, data.data(), data.size(), &message) != TINYEXR_SUCCESS) {
		error = message ? message : "invalid EXR header";
		FreeEXRErrorMessage(message);
		return false;
	}
	for (int i = 0; i < header.num_channels; i++) {
		header.requested_pixel_types[i] = TINYEXR_PIXELTYPE_FLOAT;
	}
	EXRImage exr;
	InitEXRImage(&exr);
	if (LoadEXRImageFromMemory(&exr, &header, data.data(), data.size(), &message) != TINYEXR_SUCCESS || exr.images == nullptr) {
		error = message ? message : "cannot decode EXR (tiled images are not supported)";
		FreeEXRErrorMessage(message);
		FreeEXRHeader(&header);
		return false;
	}
	image.width = exr.width;
	image.height = exr.height;
	image.channels = 4;
	image.pixels.assign((size_t)exr.width * exr.height * 4, 0.0f);
	// Channel index of R, G, B, A (-1 if missing); Y is grey
	int index[4] = { -1, -1, -1, -1 };
	bool grey = false;
	for (int i = 0; i < header.num_channels; i++) {
		const char *channel = header.channels[i].name;
		if (strcmp(channel, "R") == 0) index[0] = i;
		else if (strcmp(channel, "G") == 0) index[1] = i;
		else if (strcmp(channel, "B") == 0) index[2] = i;
		else if (strcmp(channel, "A") == 0) index[3] = i;
		else if (strcmp(channel, "Y") == 0) { index[0] = i; grey = true; }
	}
	for (size_t p = 0; p < (size_t)exr.width * exr.height; p++) {
		float *o = &image.pixels[p * 4];
		for (int c = 0; c < 4; c++) {
			if (index[c] >= 0) {
				o[c] = ((const float *)exr.images[index[c]])[p];
			}
		}
		if (grey) {
			o[1] = o[2] = o[0];
		}
		if (index[3] < 0) {
			o[3] = 1.0f;
		}
	}
	FreeEXRImage(&exr);
	FreeEXRHeader(&header);
	return true;
}

} // namespace

bool decode_image(const std::string &file_name, const std::vector<uint8_t> &data, Image &image, std::string &error) {
	std::string extension = file_name.substr(file_name.find_last_of('.') + 1);
	if (extension == "exr") {
		return decode_exr(data, image, error);
	}
	return decode_png(data, image, error);
}

bool write_png(const std::string &path, const Image &image) {
	int channels = image.channels == 1 ? 1 : 4;
	std::vector<uint8_t> bytes((size_t)image.width * image.height * channels);
	for (size_t i = 0; i < (size_t)image.width * image.height; i++) {
		for (int c = 0; c < channels; c++) {
			// Truncated as Godot does, so files match Material Maker's
			float v = std::clamp(image.pixels[i * image.channels + c], 0.0f, 1.0f);
			bytes[i * channels + c] = (uint8_t)(v * 255.0f);
		}
	}
	size_t size = 0;
	void *png = tdefl_write_image_to_png_file_in_memory(bytes.data(), image.width, image.height, channels, &size);
	if (png == nullptr) {
		return false;
	}
	FILE *f = fopen(path.c_str(), "wb");
	bool ok = f != nullptr && fwrite(png, 1, size, f) == size;
	if (f) {
		fclose(f);
	}
	mz_free(png);
	return ok;
}

bool write_exr(const std::string &path, const Image &image, std::string &error) {
	const char *message = nullptr;
	if (SaveEXR(image.pixels.data(), image.width, image.height, image.channels, 0, path.c_str(), &message) != TINYEXR_SUCCESS) {
		error = message ? message : "cannot write EXR";
		FreeEXRErrorMessage(message);
		return false;
	}
	return true;
}

} // namespace mmr
