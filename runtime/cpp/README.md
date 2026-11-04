# Material Maker runtime (C++)

A standalone renderer for Material Maker runtime packages (`.mmr`, written by
the runtime export plugin: File > Export runtime package, or `--export-mmr`),
with Vulkan compute shaders. It needs no Godot and no GLSL compiler (packages
contain SPIR-V), so engine plugins and tools can embed it.

## Building

CMake 3.24+ and a C++17 compiler. Dependencies (Vulkan-Headers, volk, miniz,
nlohmann/json, tinyexr) are fetched at configure time. The Vulkan loader
comes with GPU drivers; the Vulkan SDK is not needed.

```
cmake -S runtime/cpp -B runtime/cpp/build
cmake --build runtime/cpp/build --config Release
```

Other CMake projects can `add_subdirectory(runtime/cpp)` and link
`mmr_runtime`.

## mmr_render

```
mmr_render <package.mmr> [-o <dir>] [--preset name] [--set name=value ...] [--size n] [--exr] [--list] [--device n]
```

renders the package's outputs (albedo, orm, emission, normal, height) to
PNG (or EXR) files. `--list` only lists the package's parameters, outputs and
presets. Color values are written `r,g,b,a`. Animated materials
have a `time` parameter, in seconds, and materials with random nodes a `seed`
parameter (`--set seed=3` gives the same result as exporting with
Material Maker's `--seed 3`, and 0 is the exported seed). `--size` renders
the outputs at another size; as with Material Maker's export size, buffers
keep their own size (`Package::set_output_size()` in the library, or
`Renderer::set_output_size()` for a loaded package).

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
Material Maker render identically to Material Maker itself: the float values
of every output are the same as Material Maker's EXR renders (tested on the
beehive, bricks, marble, medieval_wall, rock, skulls, stylized_wall and wood
examples, at their own size and resized, with seeds, parameters and presets).

## Tests

`python runtime/cpp/tests/check_render.py <mmr_render>` renders
`tests/bricks.mmr` (a 256 x 256 package of the bricks example) and checks its
outputs, seeds and `--size`. It runs on any Vulkan driver, including Mesa's
software driver (lavapipe) for CI.
