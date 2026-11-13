# Material Maker Python client

A dependency-free client for Material Maker's JSON-RPC server.

```
pip install ./python
```

Start Material Maker with `--rpc-port 7680` (with its user interface) or
`--rpc --rpc-port 7680` (without), or let the client start it:

```python
from material_maker_client import launch

process, mm = launch(["godot", "--path", "/path/to/material-maker"], graph="bricks.ptex")
print(mm.list_parameters())
for i, hue in enumerate([0.0, 0.3, 0.6]):
    mm.set_parameters({"Hue": hue})
    mm.render("Material", f"bricks_{i}.png", size=512)
mm.export("USD/UsdPreviewSurface", "out/bricks")
mm.quit()
```

See `examples/variations.py` and `material_maker/doc/scripting.rst`.

## mm-cook

`mm_cook.py` (the `mm-cook` command once installed) exports the runtime
packages (.mmr) of many graphs with Material Maker's `--export-mmr` mode, and
only exports them again when a graph (or a file it uses), the options or
Material Maker changed:

```
mm-cook --mm "godot --path /path/to/material-maker" --jobs 4 -o packages materials/
mm-cook --size 1024x512 -o packages_wide materials/
mm-cook --verify runtime/cpp/build/mmr_render --report report.json -o packages materials/
```

`--verify` renders each package with `mmr_render` (the C++ runtime) and checks
that its outputs are identical to Material Maker's renders. See
`mm-cook --help` and the Runtime packages section of
`material_maker/doc/export.rst`.

Tests (with fake Material Maker and mmr_render commands):

```
python -m pytest python/tests
```

## Voxel materials: evaluation at points

`material_maker_client.voxel` (needs numpy) evaluates the outputs of a graph that ends in a Voxel
Material node at arbitrary points, with numpy arrays in and out. The arrays travel as float32
`.npy` files, so Material Maker must run on the same machine (or share the file system).

```python
from material_maker_client import launch
from material_maker_client.voxel import VoxelGraph, evaluate

process, mm = launch(["godot", "--path", "/path/to/material-maker"])
graph = VoxelGraph(mm, "oak.ptex")                    # loads the graph
out = graph.evaluate(points, normals, {"seed": 12, "age": 0.3})
out["base_color"]   # (N, 3) linear colour (not sRGB)
out["orm"]          # (N, 3) ambient occlusion, roughness, metallic
out["emission"]     # (N, 3)
out["normal"]       # (N, 3) bumped normal, object space
out["opacity"]      # (N,)
rgba = graph.evaluate(points, node="Wood:0")         # one node output, (N, 4)
```

`points` are in metres, object space; `normals` (unit vectors) and `fresh=` are optional per
point arrays. The other voxel inputs (seed, age, upkeep, fresh, char, wet, footprint, axis,
origin) are one value per call, given in `params` (group points that differ and make one call
per group). `evaluate(mm, points, ...)` does the same on the current graph.

Other RPC methods of the voxel plugins, called with `mm.call(...)` or as attributes of the client:
`param_schema()` (the parameters of the graph as a JSON schema), `graph_cost(node=None, output=0)`
(a relative shader cost estimate), `evaluate_points(...)` (the file based method behind
`evaluate`) and `bake_voxel_material(mesh, prefix, size=1024, unit_scale=1.0, format="png")`.

Examples: `examples/voxel_evaluate.py` (evaluation at points) and `examples/zcity_oak/` (the
oak recipe of the ZCity kit rebuilt as a graph and compared with the kit's own code, see its
README). The workflow is described in `material_maker/doc/voxel_workflow.rst`.
