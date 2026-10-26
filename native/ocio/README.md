# OpenColorIO support (GDExtension)

An optional GDExtension that gives Material Maker OpenColorIO 2.6 color
management. Material Maker works without it; when it is built:

- the **Image** node has an **OCIO** color space mode, that converts images
  from any color space of the config to Material Maker's working space;
- the 2D preview's **View** menu has OCIO **display/view transforms** (for
  example *sRGB - Display / ACES 2.0 - SDR 100 nits (Rec.709)*), applied with
  a 33³ 3D LUT baked by OpenColorIO.

The config is OCIO's built-in ACES studio config by default
(`ocio://studio-config-latest`). The `ocio_config` setting (Material Maker's
configuration file) can point to another config file, and `ocio_working_space`
is the color space of Material Maker's values (`sRGB - Texture` by default,
since Material Maker works with sRGB encoded colors).

## Building

Needs git, CMake 3.24+, Python 3 and a C++17 compiler (on Windows, Visual Studio
Build Tools with the C++ workload):

```
python native/ocio/build.py --generator "Visual Studio 18 2026"
```

It downloads OpenColorIO and godot-cpp to `native/ocio/build`, builds them,
and copies the extension, OpenColorIO's library and `mm_ocio.gdextension` to
`addons/material_maker/ocio` (not versioned). Then run Material Maker's
import once (`godot --headless --path . --import`, or open the project in the
editor) so Godot registers the extension.

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
