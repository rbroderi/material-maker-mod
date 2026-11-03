# sbs plugin

Nodes that match Substance Designer's atomic nodes, for graphs converted by
[sbsar2ptex](https://github.com/rbroderi/sbsar2ptex). The plugin is not part of
Material Maker: sbsar2ptex generates it from its GLSL, which is checked node by
node against `sbsrender`, and installs it with `sbsar2ptex --install-mm-plugin`
in the user's plugins folder (`user://plugins/sbs`). This folder has no
plugin.cfg, so it is not a plugin: it only documents the conventions.

Conventions:

- The plugin's id is `sbs` (the folder name), and graphs require it with
  `"requires": {"plugins": {"sbs": ">=1.1"}}`.
- Node types are `sbs_<atom>` (e.g. `sbs_levels`) for atomic nodes. Nodes
  specific to a converted material are graph-local definitions, named
  `sbs_<material>_<node>`, in the `<graph>_nodes` folder next to the `.ptex`.
- Parameters keep Substance's names and ranges. Nodes that need several passes
  are graphs (`.mmg` files with `nodes` and `connections`) with their own
  buffers, iterate buffers (`iterate_buffer_v2` for several states) or FX-Maps.
- The plugin's script adds the FX-Map (Substance) node (type `sbs_fxmap`,
  since version 1.1) with `add_node_type`: splats generated on the GPU by code
  the converter writes, binned in order and drawn by a gather shader.
- Shaders use `$pass_size` (the size of the rendered texture in pixels)
  instead of fixed sizes, and buffers use relative sizes (`size_mode` 1 for
  relative to the output, 2 for relative to the input) and Substance's storage
  formats (`f8`, `f16i`, `f32`) with `rounding` 1 (ties rounded down).
