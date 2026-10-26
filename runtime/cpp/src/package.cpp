// Reading runtime packages: zip container, manifest, SPIR-V and textures

#include "mmr/mmr.h"
#include "image_io.h"

#include <miniz.h>
#include <nlohmann/json.hpp>

#include <cstring>

namespace mmr {

namespace {

std::vector<uint8_t> base64_decode(const std::string &text) {
	static int table[256];
	static bool initialized = false;
	if (!initialized) {
		const char *alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
		for (int &v : table) {
			v = -1;
		}
		for (int i = 0; i < 64; i++) {
			table[(unsigned char)alphabet[i]] = i;
		}
		initialized = true;
	}
	std::vector<uint8_t> result;
	uint32_t bits = 0;
	int bit_count = 0;
	for (unsigned char c : text) {
		if (table[c] < 0) {
			continue;
		}
		bits = (bits << 6) | (uint32_t)table[c];
		bit_count += 6;
		if (bit_count >= 8) {
			bit_count -= 8;
			result.push_back((uint8_t)((bits >> bit_count) & 0xFF));
		}
	}
	return result;
}

class ZipReader {
public:
	explicit ZipReader(const std::string &path) {
		memset(&zip, 0, sizeof(zip));
		opened = mz_zip_reader_init_file(&zip, path.c_str(), 0);
	}
	~ZipReader() {
		if (opened) {
			mz_zip_reader_end(&zip);
		}
	}
	bool is_open() const { return opened; }
	bool read(const std::string &name, std::vector<uint8_t> &data) {
		size_t size = 0;
		void *p = mz_zip_reader_extract_file_to_heap(&zip, name.c_str(), &size, 0);
		if (p == nullptr) {
			return false;
		}
		data.assign((uint8_t *)p, (uint8_t *)p + size);
		mz_free(p);
		return true;
	}

private:
	mz_zip_archive zip;
	bool opened = false;
};

std::vector<float> to_floats(const nlohmann::json &value) {
	std::vector<float> result;
	if (value.is_array()) {
		for (const auto &v : value) {
			result.push_back(v.get<float>());
		}
	} else if (value.is_number()) {
		result.push_back(value.get<float>());
	} else if (value.is_boolean()) {
		result.push_back(value.get<bool>() ? 1.0f : 0.0f);
	}
	return result;
}

} // namespace

const Pass *Package::find_pass(const std::string &pass_name) const {
	for (const Pass &p : passes) {
		if (p.name == pass_name) {
			return &p;
		}
	}
	return nullptr;
}

const Parameter *Package::find_parameter(const std::string &parameter_name) const {
	for (const Parameter &p : parameters) {
		if (p.name == parameter_name || (!p.label.empty() && p.label == parameter_name)) {
			return &p;
		}
	}
	return nullptr;
}

bool Package::load(const std::string &path, std::string &error) {
	ZipReader zip(path);
	if (!zip.is_open()) {
		error = "cannot open " + path;
		return false;
	}
	std::vector<uint8_t> data;
	if (!zip.read("manifest.json", data)) {
		error = "no manifest";
		return false;
	}
	nlohmann::json manifest = nlohmann::json::parse(data.begin(), data.end(), nullptr, false);
	if (manifest.is_discarded() || manifest.value("format", "") != "mmr") {
		error = "not a Material Maker runtime package";
		return false;
	}
	version = manifest.value("version", 0);
	if (version > 1) {
		error = "unsupported package version " + std::to_string(version);
		return false;
	}
	name = manifest.value("name", "");
	for (const auto &p : manifest["passes"]) {
		Pass pass;
		pass.name = p["name"].get<std::string>();
		pass.format = p["format"].get<std::string>();
		pass.width = p["size"][0].get<uint32_t>();
		pass.height = p["size"][1].get<uint32_t>();
		pass.local_size = p.value("local_size", 32u);
		for (const auto &[key, layout] : p["parameters"].items()) {
			pass.parameters[key] = ParameterLayout{ layout["type"].get<std::string>(), layout["offset"].get<uint32_t>(), layout.value("array_size", 0u) };
		}
		pass.parameter_data = base64_decode(p.value("parameter_data", ""));
		for (const auto &i : p["inputs"]) {
			PassInput input;
			input.name = i.value("name", "");
			input.pass = i.value("pass", "");
			input.texture = i.value("texture", "");
			if (!input.texture.empty() && textures.find(input.texture) == textures.end()) {
				std::vector<uint8_t> texture_data;
				Image image;
				if (!zip.read(input.texture, texture_data) || !decode_image(input.texture, texture_data, image, error)) {
					error = input.texture + ": " + (error.empty() ? "cannot read" : error);
					return false;
				}
				textures[input.texture] = std::move(image);
			}
			pass.inputs.push_back(input);
		}
		std::vector<uint8_t> spirv;
		if (!zip.read("shaders/" + pass.name + ".spv", spirv) || spirv.size() % 4 != 0) {
			error = "pass " + pass.name + " has no SPIR-V shader (export the package again with a newer Material Maker)";
			return false;
		}
		pass.spirv.resize(spirv.size() / 4);
		memcpy(pass.spirv.data(), spirv.data(), spirv.size());
		passes.push_back(std::move(pass));
	}
	for (const auto &[channel, pass_name] : manifest["outputs"].items()) {
		outputs[channel] = pass_name.get<std::string>();
	}
	for (const auto &p : manifest["parameters"]) {
		Parameter parameter;
		parameter.name = p["name"].get<std::string>();
		parameter.label = p.value("label", "");
		parameter.type = p.value("type", "float");
		parameter.default_value = to_floats(p["default"]);
		parameter.min = p.value("min", 0.0f);
		parameter.max = p.value("max", 1.0f);
		parameter.step = p.value("step", 0.0f);
		for (const auto &t : p["targets"]) {
			parameter.targets.push_back(ParameterTarget{ t["pass"].get<std::string>(), t["parameter"].get<std::string>() });
		}
		parameters.push_back(std::move(parameter));
	}
	if (manifest.contains("presets")) {
		for (const auto &[preset_name, values] : manifest["presets"].items()) {
			for (const auto &[parameter, value] : values.items()) {
				presets[preset_name][parameter] = to_floats(value);
			}
		}
	}
	material_json = manifest.value("material", nlohmann::json::object()).dump();
	return true;
}

} // namespace mmr
