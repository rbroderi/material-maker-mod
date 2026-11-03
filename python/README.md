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
mm.export("Godot/Godot 4 Standard", "out/bricks")
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
