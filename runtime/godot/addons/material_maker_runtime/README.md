# Material Maker Runtime for Godot

Loads Material Maker runtime packages (`.mmr`) and renders their materials in
Godot 4.3+, with parameters that can be changed at runtime (in the editor or
in games). It is pure GDScript and runs the material's compute shaders on a
local `RenderingDevice`, so it needs the Forward+ or Mobile renderer.

## Exporting packages

In Material Maker, export a material from the command line:

```
material_maker --export-mmr -o packages bricks.ptex
```

or from Python (`mm.export_mmr("packages/bricks.mmr")`, see the
`python` directory of the Material Maker repository).

The parameters of the graph's remote node become runtime parameters when they
only change shader uniforms (float and color parameters). The manifest lists
the others in `baked_parameters`.

## Using packages

Copy `addons/material_maker_runtime` into your project, then:

```gdscript
var mmr : MMRMaterial = MMRMaterial.load_material("res://materials/bricks.mmr")
$MeshInstance3D.material_override = mmr.material
# Names or labels of the remote parameters
mmr.set_parameter("Hue", 0.3)
mmr.set_parameters({ "Saturation": 0.5, "Value": 0.8 })
```

Only the passes that depend on changed parameters are rendered again.
`MMRPackage` (the package's content) and `MMRRenderer` (renders passes and
returns images with `get_image(output)`) can also be used directly, for
example to bake textures at import time.

Godot does not import `.mmr` files, so add `*.mmr` to the *Filters to export
non-resource files* of your export presets.

## Tests

```
godot --path runtime/godot -s res://tests/runtime_test.gd -- package.mmr out_dir Hue=0.5
```

renders a package's outputs, before and after changing parameters.
