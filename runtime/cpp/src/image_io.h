#pragma once

#include "mmr/mmr.h"

namespace mmr {

/// Decodes an embedded texture (EXR or 8 bits PNG) as RGBA floats, with the
/// same channel expansion as Godot's Image.convert(FORMAT_RGBAF), used by
/// Material Maker: grey is copied to RGB, red-only images get G = B = 0.
bool decode_image(const std::string &file_name, const std::vector<uint8_t> &data, Image &image, std::string &error);

} // namespace mmr
