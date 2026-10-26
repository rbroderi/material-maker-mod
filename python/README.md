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
