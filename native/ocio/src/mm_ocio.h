// OpenColorIO for Material Maker: configs, color space conversions and
// display/view transforms, on the CPU and as 3D LUTs for previews

#pragma once

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <OpenColorIO/OpenColorIO.h>

#include <map>
#include <string>

namespace OCIO = OCIO_NAMESPACE;

class MMOCIO : public godot::RefCounted {
	GDCLASS(MMOCIO, godot::RefCounted)

public:
	/// Loads a config file, or a built-in config ("ocio://studio-config-latest",
	/// "ocio://cg-config-latest", "ocio://default"). Returns false on error.
	bool load_config(const godot::String &path);
	godot::String get_error() const;
	godot::String get_version() const;
	godot::String get_config_name() const;

	godot::PackedStringArray get_color_spaces() const;
	godot::PackedStringArray get_displays() const;
	godot::PackedStringArray get_views(const godot::String &display) const;
	godot::String get_default_display() const;
	godot::String get_default_view(const godot::String &display) const;
	/// The color space of a role ("scene_linear", "color_picking"...), or ""
	godot::String get_role(const godot::String &role) const;

	/// Converts RGBA float pixels from a color space to another
	godot::PackedFloat32Array convert(const godot::PackedFloat32Array &rgba, const godot::String &source, const godot::String &destination);
	/// Applies a display/view transform to RGBA float pixels
	godot::PackedFloat32Array display_view(const godot::PackedFloat32Array &rgba, const godot::String &source, const godot::String &display, const godot::String &view);
	/// Converts an image (returned as RGBAF) from a color space to another
	godot::Ref<godot::Image> convert_image(const godot::Ref<godot::Image> &image, const godot::String &source, const godot::String &destination);
	/// A size^3 LUT of a display/view transform for inputs in [0, 1] in the
	/// source color space, as RGBA floats (red varies fastest, then green, then blue)
	godot::PackedFloat32Array bake_display_view_lut(const godot::String &source, const godot::String &display, const godot::String &view, int size);

protected:
	static void _bind_methods();

private:
	OCIO::ConstCPUProcessorRcPtr get_processor(const std::string &key, const OCIO::ConstTransformRcPtr &transform);
	OCIO::ConstCPUProcessorRcPtr conversion_processor(const godot::String &source, const godot::String &destination);
	OCIO::ConstCPUProcessorRcPtr display_view_processor(const godot::String &source, const godot::String &display, const godot::String &view);
	godot::PackedFloat32Array apply(OCIO::ConstCPUProcessorRcPtr processor, const godot::PackedFloat32Array &rgba);

	OCIO::ConstConfigRcPtr config;
	std::map<std::string, OCIO::ConstCPUProcessorRcPtr> processors;
	mutable godot::String error;
};
