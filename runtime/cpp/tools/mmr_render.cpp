// Renders the outputs of a Material Maker runtime package
//
//   mmr_render <package.mmr> [-o <dir>] [--preset name] [--set name=value ...] [--exr] [--list] [--device n]
//
// Values are numbers, or comma separated lists for colors (r,g,b,a).

#include "mmr/mmr.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <sstream>

namespace {

double elapsed_ms(std::chrono::steady_clock::time_point start) {
	return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}

int fail(const std::string &message) {
	fprintf(stderr, "error: %s\n", message.c_str());
	return 1;
}

} // namespace

int main(int argc, char **argv) {
	std::string package_path;
	std::string output_dir = ".";
	std::vector<std::pair<std::string, std::vector<float>>> values;
	std::string preset;
	bool exr = false;
	bool list = false;
	int device = -1;
	for (int i = 1; i < argc; i++) {
		std::string arg = argv[i];
		if ((arg == "-o" || arg == "--output-dir") && i + 1 < argc) {
			output_dir = argv[++i];
		} else if (arg == "--set" && i + 1 < argc) {
			std::string assignment = argv[++i];
			size_t equal = assignment.find('=');
			if (equal == std::string::npos) {
				return fail("invalid --set " + assignment + " (expected name=value)");
			}
			std::vector<float> value;
			std::stringstream stream(assignment.substr(equal + 1));
			std::string item;
			while (std::getline(stream, item, ',')) {
				value.push_back(std::strtof(item.c_str(), nullptr));
			}
			values.push_back({ assignment.substr(0, equal), value });
		} else if (arg == "--preset" && i + 1 < argc) {
			preset = argv[++i];
		} else if (arg == "--exr") {
			exr = true;
		} else if (arg == "--list") {
			list = true;
		} else if (arg == "--device" && i + 1 < argc) {
			device = std::atoi(argv[++i]);
		} else if (arg == "-h" || arg == "--help") {
			printf("usage: mmr_render <package.mmr> [-o <dir>] [--preset name] [--set name=value ...] [--exr] [--list] [--device n]\n");
			return 0;
		} else {
			package_path = arg;
		}
	}
	if (package_path.empty()) {
		return fail("no package (see --help)");
	}
	std::string error;
	auto start = std::chrono::steady_clock::now();
	mmr::Package package;
	if (!package.load(package_path, error)) {
		return fail(package_path + ": " + error);
	}
	printf("Loaded %s: %zu passes, %zu textures (%.1f ms)\n", package_path.c_str(), package.passes.size(), package.textures.size(), elapsed_ms(start));
	if (list) {
		for (const mmr::Parameter &p : package.parameters) {
			printf("  %s (%s): %s, %zu targets\n", p.name.c_str(), p.label.c_str(), p.type.c_str(), p.targets.size());
		}
		for (const auto &[channel, pass] : package.outputs) {
			printf("  output %s: pass %s\n", channel.c_str(), pass.c_str());
		}
		for (const auto &[preset_name, preset_values] : package.presets) {
			printf("  preset %s (%zu values)\n", preset_name.c_str(), preset_values.size());
		}
	}
	// Presets are applied before --set values
	if (!preset.empty()) {
		auto it = package.presets.find(preset);
		if (it == package.presets.end()) {
			return fail("no preset " + preset);
		}
		std::vector<std::pair<std::string, std::vector<float>>> preset_values(it->second.begin(), it->second.end());
		values.insert(values.begin(), preset_values.begin(), preset_values.end());
	}
	mmr::Renderer renderer;
	start = std::chrono::steady_clock::now();
	if (!renderer.init(error, device) || !renderer.load(package, error)) {
		return fail(error);
	}
	printf("Device: %s (setup %.1f ms)\n", renderer.device_name().c_str(), elapsed_ms(start));
	start = std::chrono::steady_clock::now();
	if (!renderer.render(error)) {
		return fail(error);
	}
	printf("Rendered %zu passes (%.1f ms)\n", renderer.rendered_pass_count(), elapsed_ms(start));
	if (!values.empty()) {
		for (const auto &[name, value] : values) {
			if (!renderer.set_parameter(name, value, error)) {
				return fail(error);
			}
		}
		start = std::chrono::steady_clock::now();
		if (!renderer.render(error)) {
			return fail(error);
		}
		printf("Parameters changed: rendered %zu passes (%.1f ms)\n", renderer.rendered_pass_count(), elapsed_ms(start));
	}
	std::filesystem::create_directories(output_dir);
	for (const auto &[channel, pass] : package.outputs) {
		mmr::Image image;
		if (!renderer.read_image(channel, image, error)) {
			return fail(error);
		}
		std::string path = (std::filesystem::path(output_dir) / (channel + (exr ? ".exr" : ".png"))).string();
		bool ok = exr ? mmr::write_exr(path, image, error) : mmr::write_png(path, image);
		if (!ok) {
			return fail("cannot write " + path + (error.empty() ? "" : ": " + error));
		}
		printf("Wrote %s\n", path.c_str());
	}
	return 0;
}
