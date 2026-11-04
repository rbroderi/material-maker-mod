# OpenColorIO support (GDExtension)

An optional GDExtension that gives Material Maker OpenColorIO 2.6 color
management. Material Maker works without it: when the extension is not built,
`MMColorManagement.is_available()` is false and nothing changes.

The config is OCIO's built-in ACES studio config by default
(`ocio://studio-config-latest`). The `ocio_config` setting (Material Maker's
configuration file) can point to another config file, and `ocio_working_space`
is the color space of Material Maker's values (`sRGB Encoded Rec.709 (sRGB)`
by default, since Material Maker works with sRGB encoded colors; `sRGB - Texture`
is its alias in the ACES configs).

## Building

Needs git, CMake 3.24+, Python 3 and a C++17 compiler (on Windows, Visual Studio
Build Tools with the C++ workload; on Linux, GCC or Clang; on macOS, Xcode's
command line tools):

```
python native/ocio/build.py --generator "Visual Studio 18 2026"
python3 native/ocio/build.py            # Linux and macOS
```

It downloads OpenColorIO (v2.6.0) and godot-cpp (godot-4.5-stable) to
`native/ocio/build`, builds them, and copies the extension, OpenColorIO's
library and `mm_ocio.gdextension` to `addons/material_maker/ocio` (not
versioned). The extension is named after the platform and architecture
(`mm_ocio.windows.x86_64.dll`, `mm_ocio.linux.x86_64.so`,
`mm_ocio.macos.arm64.dylib`...). On Linux and macOS, OpenColorIO's library
(`libOpenColorIO.so.2.6`, `libOpenColorIO.2.6.dylib`) is copied next to it and
found through an `$ORIGIN`/`@loader_path` rpath. Building for macOS needs a
Mac (Apple's SDK). An OpenColorIO already
installed in `native/ocio/build/ocio-install` is reused. Then run Material
Maker's import once (`godot --headless --path . --import`, or open the project
in the editor) so Godot registers the extension.

To remove the extension, delete `addons/material_maker/ocio/bin` and
`addons/material_maker/ocio/mm_ocio.gdextension`, then delete
`.godot/extension_list.cfg` and run the import again (Godot keeps listing a
deleted extension there, and reports an error at every start).

## API

`MMOCIO` (a `RefCounted` class, used through `MMColorManagement` in
`addons/material_maker/engine/color_management.gd`):

- `load_config(path)`: a config file or a built-in config URI (`""` is the
  studio config)
- `get_color_spaces()`, `get_displays()`, `get_views(display)`,
  `get_default_display()`, `get_default_view(display)`, `get_role(role)`
- `convert(rgba, source, destination)` and `display_view(rgba, source, display, view)`
  on RGBA float arrays, `convert_image(image, source, destination)`
- `bake_display_view_lut(source, display, view, size)`: a 3D LUT for previews
- `get_error()`, `get_version()`, `get_config_name()`

`MMColorManagement` loads the configured config, converts images between color
spaces (`convert_image`, `convert_between`), lists display/view transforms
(`get_views`, `create_view_picker`) and bakes them into 3D textures with the
matching shader code (`get_view_lut`, `get_view_shader_code`).
