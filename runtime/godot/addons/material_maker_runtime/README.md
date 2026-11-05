# Material Maker Runtime for Godot

Loads Material Maker runtime packages (`.mmr`) and renders their materials in
Godot 4.3+, with parameters that can be changed at runtime (in the editor or
in games). It is pure GDScript and runs the material's compute shaders on a
local `RenderingDevice`, so it needs the Forward+ or Mobile renderer. The
textures are the same as Material Maker's.

## Exporting packages

In Material Maker (with the Runtime export plugin), use
*File > Export runtime package (.mmr)...*, or the command line:

```
material_maker --export-mmr -o packages bricks.ptex
```

or from Python (`mm.export_mmr("packages/bricks.mmr")`, see the
`python` directory of the Material Maker repository).

The parameters of the graph's remote node become runtime parameters when they
only change shader uniforms (float and color parameters). The manifest lists
the others in `baked_parameters`. Materials with random nodes also have a
`seed` parameter, and animated materials a `time` parameter.

## Using packages

Copy `addons/material_maker_runtime` into your project, then:

```gdscript
var mmr : MMRMaterial = MMRMaterial.load_material("res://materials/bricks.mmr")
# or MMRMaterial.load_material("res://materials/bricks.mmr", 512) for 512x512 textures
$MeshInstance3D.material_override = mmr.material
# Names or labels of the remote parameters
mmr.set_parameter("Hue", 0.3)
mmr.set_parameter("seed", 3)  # as Material Maker's --seed 3 (0: the exported seeds)
mmr.set_parameters({ "Saturation": 0.5, "Value": 0.8 })
mmr.apply_preset("Warm")      # presets of the remote node, if any
mmr.set_output_size(1024)     # renders the textures again at 1024x1024
```

Only the passes that depend on changed parameters are rendered again. The
output size works as Material Maker's export size: buffers keep the size of
their Buffer node.

`MMRPackage` (the package's content) and `MMRRenderer` (renders passes and
returns images with `get_image(output)`, for example to bake textures at
import time) can also be used directly.

Godot does not import `.mmr` files, so add `*.mmr` to the *Filters to export
non-resource files* of your export presets.

## Tests

```
godot --path runtime/godot -s res://tests/runtime_test.gd -- package.mmr out_dir [size=n] [Hue=0.5] [seed=3] [resize=n] [ref=dir]
```

renders a package's outputs, before and after changing parameters and size,
and with `ref=dir` compares them with Material Maker's renders
(`material_maker --render --node Material:<n> --format exr`).
