// Material Maker runtime: loads runtime packages (.mmr) and renders them with
// Vulkan compute shaders. See design/runtime_packages.md.

#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace mmr {

/// Float pixels, rows from top to bottom
struct Image {
	int width = 0;
	int height = 0;
	int channels = 0;
	std::vector<float> pixels;
};

/// A term of a seed uniform: a node's seed, and whether it is locked
struct SeedTerm {
	float value = 0.0f;
	bool locked = false;
};

struct ParameterTarget {
	std::string pass;
	std::string parameter;
	/// For "seed" parameters: the uniform is the sum of these seeds, each
	/// (unless locked) offset by 0.6180339887*seed modulo 1
	std::vector<SeedTerm> seed_terms;
};

/// A parameter that can be changed at runtime ("float", "color", or "seed"
/// for the seed of all random nodes, as Material Maker's --seed)
struct Parameter {
	std::string name;
	std::string label;
	std::string type;
	std::vector<float> default_value;
	float min = 0.0f;
	float max = 1.0f;
	float step = 0.0f;
	std::vector<ParameterTarget> targets;
};

/// Layout of a value in a pass's parameter buffer (std430)
struct ParameterLayout {
	std::string type;
	uint32_t offset = 0;
	uint32_t array_size = 0;
};

/// Input of a pass: the output of another pass, or an embedded texture
struct PassInput {
	std::string name;
	std::string pass;
	std::string texture;
};

struct Pass {
	std::string name;
	std::string format;
	uint32_t width = 0;
	uint32_t height = 0;
	uint32_t local_size = 32;
	std::map<std::string, ParameterLayout> parameters;
	std::vector<uint8_t> parameter_data;
	std::vector<PassInput> inputs;
	std::vector<uint32_t> spirv;
};

class Package {
public:
	bool load(const std::string &path, std::string &error);

	const Pass *find_pass(const std::string &name) const;
	/// Finds a parameter by name or label
	const Parameter *find_parameter(const std::string &name) const;
	/// Scales all passes so the outputs are size x size pixels (call it before
	/// Renderer::load). Outputs and buffers keep their relative sizes.
	bool set_output_size(uint32_t size, std::string &error);
	/// Size of the outputs (the largest output pass)
	uint32_t output_size() const;

	std::string name;
	int version = 0;
	std::vector<Pass> passes;
	/// Pass name of each material output (albedo, orm, emission, normal, height)
	std::map<std::string, std::string> outputs;
	std::vector<Parameter> parameters;
	/// Presets: parameter values by preset name
	std::map<std::string, std::map<std::string, std::vector<float>>> presets;
	std::map<std::string, Image> textures;
	/// The "material" object of the manifest (Material node values), as JSON
	std::string material_json;
};

class Renderer {
public:
	Renderer();
	~Renderer();
	Renderer(const Renderer &) = delete;
	Renderer &operator=(const Renderer &) = delete;

	/// Creates the Vulkan device (device_index -1 picks a discrete GPU first)
	bool init(std::string &error, int device_index = -1);
	/// Uploads a package's textures and creates its pipelines
	bool load(const Package &package, std::string &error);
	/// Sets a parameter (by name or label): 1 value for floats, 4 for colors.
	/// Passes that depend on it are rendered by the next render() call.
	bool set_parameter(const std::string &name, const std::vector<float> &value, std::string &error);
	/// Renders the passes that need it
	bool render(std::string &error);
	/// Reads the content of an output (by channel name) or of a pass
	bool read_image(const std::string &output, Image &image, std::string &error);

	std::string device_name() const;
	/// Number of passes rendered by the last render() call
	size_t rendered_pass_count() const;

private:
	struct Impl;
	std::unique_ptr<Impl> impl;
};

/// Writes an 8 bits PNG (values are clamped to [0, 1])
bool write_png(const std::string &path, const Image &image);
/// Writes a float EXR
bool write_exr(const std::string &path, const Image &image, std::string &error);

} // namespace mmr
