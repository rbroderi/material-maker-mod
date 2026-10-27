# Material Maker runtime (C++)

A standalone renderer for Material Maker runtime packages (`.mmr`), with
Vulkan compute shaders. It needs no Godot and no GLSL compiler (packages
contain SPIR-V), so engine plugins can embed it.

## Building

CMake 3.24+ and a C++17 compiler. Dependencies (Vulkan-Headers, volk, miniz,
nlohmann/json, tinyexr) are fetched at configure time. The Vulkan loader
comes with GPU drivers; the Vulkan SDK is not needed.

```
cmake -S runtime/cpp -B runtime/cpp/build
cmake --build runtime/cpp/build --config Release
```

## mmr_render

```
mmr_render <package.mmr> [-o <dir>] [--preset name] [--set name=value ...] [--size n] [--exr] [--list] [--device n]
```

renders the package's outputs (albedo, orm, emission, normal, height) to
PNG (or EXR) files. `--list` only lists the package's parameters, outputs and
presets. Color values are written `r,g,b,a`. Animated materials
have a `time` parameter, in seconds, and materials with random nodes a `seed`
parameter (`--set seed=3` gives the same result as exporting with
Material Maker's `--seed 3`). `--size` renders the outputs at another size
(all passes are scaled, `Package::set_output_size()` in the library).

## Library

```cpp
#include <mmr/mmr.h>

mmr::Package package;
mmr::Renderer renderer;
std::string error;
if (package.load("bricks.mmr", error) && renderer.init(error) && renderer.load(package, error)) {
	renderer.set_parameter("Hue", { 0.3f }, error);
	renderer.render(error);  // renders only passes that changed
	mmr::Image albedo;
	renderer.read_image("albedo", albedo, error);
}
```

Output images are float pixels (1 or 4 channels). Packages exported by
Material Maker render identically to Material Maker itself (tested on the
bricks, rusted_metal, wood, medieval_wall and lava examples).

## Tests

`python runtime/cpp/tests/check_render.py <mmr_render>` renders
`tests/bricks.mmr` and checks its outputs, seeds and `--size`. The
`native-builds.yml` GitHub workflow builds the runtime for Linux, Windows and
macOS, and runs this test on Linux with Mesa's software Vulkan driver.
