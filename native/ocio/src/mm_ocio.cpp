#include "mm_ocio.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

namespace {

std::string to_std(const String &s) {
	return std::string(s.utf8().get_data());
}

} // namespace

void MMOCIO::_bind_methods() {
	ClassDB::bind_method(D_METHOD("load_config", "path"), &MMOCIO::load_config);
	ClassDB::bind_method(D_METHOD("get_error"), &MMOCIO::get_error);
	ClassDB::bind_method(D_METHOD("get_version"), &MMOCIO::get_version);
	ClassDB::bind_method(D_METHOD("get_config_name"), &MMOCIO::get_config_name);
	ClassDB::bind_method(D_METHOD("get_color_spaces"), &MMOCIO::get_color_spaces);
	ClassDB::bind_method(D_METHOD("get_displays"), &MMOCIO::get_displays);
	ClassDB::bind_method(D_METHOD("get_views", "display"), &MMOCIO::get_views);
	ClassDB::bind_method(D_METHOD("get_default_display"), &MMOCIO::get_default_display);
	ClassDB::bind_method(D_METHOD("get_default_view", "display"), &MMOCIO::get_default_view);
	ClassDB::bind_method(D_METHOD("get_role", "role"), &MMOCIO::get_role);
	ClassDB::bind_method(D_METHOD("convert", "rgba", "source", "destination"), &MMOCIO::convert);
	ClassDB::bind_method(D_METHOD("display_view", "rgba", "source", "display", "view"), &MMOCIO::display_view);
	ClassDB::bind_method(D_METHOD("convert_image", "image", "source", "destination"), &MMOCIO::convert_image);
	ClassDB::bind_method(D_METHOD("bake_display_view_lut", "source", "display", "view", "size"), &MMOCIO::bake_display_view_lut);
}

bool MMOCIO::load_config(const String &path) {
	processors.clear();
	config.reset();
	try {
		std::string p = path.is_empty() ? "ocio://studio-config-latest" : to_std(path);
		config = OCIO::Config::CreateFromFile(p.c_str());
		config->validate();
		error = "";
		return true;
	} catch (const OCIO::Exception &e) {
		config.reset();
		error = String::utf8(e.what());
		return false;
	}
}

String MMOCIO::get_error() const {
	return error;
}

String MMOCIO::get_version() const {
	return String(OCIO::GetVersion());
}

String MMOCIO::get_config_name() const {
	return config ? String::utf8(config->getName()) : String();
}

PackedStringArray MMOCIO::get_color_spaces() const {
	PackedStringArray result;
	if (config) {
		for (int i = 0; i < config->getNumColorSpaces(); i++) {
			result.push_back(String::utf8(config->getColorSpaceNameByIndex(i)));
		}
	}
	return result;
}

PackedStringArray MMOCIO::get_displays() const {
	PackedStringArray result;
	if (config) {
		for (int i = 0; i < config->getNumDisplays(); i++) {
			result.push_back(String::utf8(config->getDisplay(i)));
		}
	}
	return result;
}

PackedStringArray MMOCIO::get_views(const String &display) const {
	PackedStringArray result;
	if (config) {
		std::string d = to_std(display);
		for (int i = 0; i < config->getNumViews(d.c_str()); i++) {
			result.push_back(String::utf8(config->getView(d.c_str(), i)));
		}
	}
	return result;
}

String MMOCIO::get_default_display() const {
	return config ? String::utf8(config->getDefaultDisplay()) : String();
}

String MMOCIO::get_default_view(const String &display) const {
	return config ? String::utf8(config->getDefaultView(to_std(display).c_str())) : String();
}

String MMOCIO::get_role(const String &role) const {
	if (!config) {
		return String();
	}
	OCIO::ConstColorSpaceRcPtr color_space = config->getColorSpace(to_std(role).c_str());
	return color_space ? String::utf8(color_space->getName()) : String();
}

OCIO::ConstCPUProcessorRcPtr MMOCIO::get_processor(const std::string &key, const std::function<OCIO::ConstTransformRcPtr()> &create_transform) {
	if (!config) {
		error = "no config";
		return nullptr;
	}
	// The transform is only built when the processor is not cached
	auto it = processors.find(key);
	if (it != processors.end()) {
		error = "";
		return it->second;
	}
	try {
		OCIO::ConstProcessorRcPtr processor = config->getProcessor(create_transform());
		OCIO::ConstCPUProcessorRcPtr cpu = processor->getDefaultCPUProcessor();
		processors[key] = cpu;
		error = "";
		return cpu;
	} catch (const OCIO::Exception &e) {
		error = String::utf8(e.what());
		return nullptr;
	}
}

OCIO::ConstCPUProcessorRcPtr MMOCIO::conversion_processor(const String &source, const String &destination) {
	std::string src = to_std(source);
	std::string dst = to_std(destination);
	return get_processor("cs:" + src + ">" + dst, [&]() -> OCIO::ConstTransformRcPtr {
		OCIO::ColorSpaceTransformRcPtr transform = OCIO::ColorSpaceTransform::Create();
		transform->setSrc(src.c_str());
		transform->setDst(dst.c_str());
		return transform;
	});
}

OCIO::ConstCPUProcessorRcPtr MMOCIO::display_view_processor(const String &source, const String &display, const String &view) {
	std::string src = to_std(source);
	std::string d = to_std(display);
	std::string v = to_std(view);
	return get_processor("dv:" + src + ">" + d + "/" + v, [&]() -> OCIO::ConstTransformRcPtr {
		OCIO::DisplayViewTransformRcPtr transform = OCIO::DisplayViewTransform::Create();
		transform->setSrc(src.c_str());
		transform->setDisplay(d.c_str());
		transform->setView(v.c_str());
		return transform;
	});
}

PackedFloat32Array MMOCIO::apply(OCIO::ConstCPUProcessorRcPtr processor, const PackedFloat32Array &rgba) {
	PackedFloat32Array result = rgba;
	if (!processor || result.size() < 4) {
		return processor ? result : PackedFloat32Array();
	}
	try {
		OCIO::PackedImageDesc description(result.ptrw(), result.size() / 4, 1, 4);
		processor->apply(description);
	} catch (const OCIO::Exception &e) {
		error = String::utf8(e.what());
		return PackedFloat32Array();
	}
	return result;
}

PackedFloat32Array MMOCIO::convert(const PackedFloat32Array &rgba, const String &source, const String &destination) {
	return apply(conversion_processor(source, destination), rgba);
}

PackedFloat32Array MMOCIO::display_view(const PackedFloat32Array &rgba, const String &source, const String &display, const String &view) {
	return apply(display_view_processor(source, display, view), rgba);
}

Ref<Image> MMOCIO::convert_image(const Ref<Image> &image, const String &source, const String &destination) {
	if (image.is_null()) {
		return Ref<Image>();
	}
	Ref<Image> copy = image->duplicate();
	copy->convert(Image::FORMAT_RGBAF);
	PackedByteArray data = copy->get_data();
	PackedFloat32Array pixels = data.to_float32_array();
	pixels = convert(pixels, source, destination);
	if (pixels.is_empty()) {
		return Ref<Image>();
	}
	return Image::create_from_data(copy->get_width(), copy->get_height(), false, Image::FORMAT_RGBAF, pixels.to_byte_array());
}

PackedFloat32Array MMOCIO::bake_display_view_lut(const String &source, const String &display, const String &view, int size) {
	size = CLAMP(size, 2, 129);
	PackedFloat32Array lattice;
	lattice.resize(size * size * size * 4);
	float *p = lattice.ptrw();
	float scale = 1.0f / float(size - 1);
	for (int b = 0; b < size; b++) {
		for (int g = 0; g < size; g++) {
			for (int r = 0; r < size; r++) {
				*p++ = r * scale;
				*p++ = g * scale;
				*p++ = b * scale;
				*p++ = 1.0f;
			}
		}
	}
	return display_view(lattice, source, display, view);
}
