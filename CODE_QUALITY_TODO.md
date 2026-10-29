# Code quality follow-ups

A review of the fork's own code (everything changed since upstream commit
7d6daae) for duplication, long functions, magic numbers and missing error
handling. The small, behavior-preserving fixes were applied in M13, and the
bigger ones below in M15 (2026-10-27). Nothing is left from this review.

## Plugins: keep fork features out of upstream code (done)

The plugin API gained what the fork's features needed (see
`engine/plugins/plugin_manager.gd` and `material_maker/doc/scripting.rst`):

- dependencies between plugins (`depends=["car_paint>=1.0"]` in plugin.cfg:
  load order, minimum versions, errors for missing, disabled, failed and
  cyclic dependencies; the Plugins window enables dependencies and disables
  dependents),
- menu items in any menu, after a given item,
- import formats (File/Load, drag and drop, the `load` RPC method, the
  command line),
- command line modes with their own options and help (`cli_modes` in
  plugin.cfg, `add_cli_mode()`), so `--export-volume` and `--export-mmr` keep
  working,
- sections of the 2D preview's export menu,
- RPC methods that get the RPC server (`fail()`, `require()`, `get_graph()`),
- export targets of plugins kept apart from the user's (not copied to the
  user's export targets unless edited).

Moved into bundled plugins (`material_maker/plugins`, enabled by default):
`car_paint` (Car Paint Material node), `materialx_import`, `runtime_export`,
`volume_export` and `export_targets` (Godot 4 / Unity / Unreal Engine 5
shader exports, MaterialX, USD). The fork's changes to upstream export
targets (glTF KHR, Godot 4, HDRP, Unreal Engine 5) stay in `material.mmg`.

## Engine (addons/material_maker) (done)

- **Statistics and Analysis nodes** share `MMGenGpuReduction`
  (`gen_gpu_reduction.gd`), with hooks for the template, the results and
  their use. Buffer names are unchanged.
- **Output shader creation**: `MMGenBase.create_output_compute_shader()` is
  used by `render_output_to_texture()` and the runtime exporter.
- **Long dispatch blocks**: `function_graph.gd` (`OP_COMPILERS`, one method
  per operation) and `materialx_import.gd` (`NODE_EVALUATORS`);
  `volume_export.gd` `write_vdb_grid` is split into descriptor, metadata,
  transform, leaves and topology.
- **Material output indices**: `MMGenMaterial.OUTPUT_*` and
  `STANDARD_INPUTS`, used by the path tracer, the runtime exporter, the
  MaterialX import and `COLOR_OUTPUTS`.
- **Texel formats**: one `TEXEL_FORMATS` table in `volume_export.gd`.
- **Baker helpers**: `MMTexture.pack_texels()` and `MMTexture.from_image()`;
  the hardware baker builds its invariant uniforms and parameter buffer once.
- **Paint layer**: `channel_texture()` and `get_layer_masks()`.

## Application (material_maker, parse_args.gd) (done)

- **Argument parsing**: `VALUE_OPTIONS` table, shared with plugin options.
- **Tool windows**: `MMToolWindow` (`windows/tool_window.gd`).
- **Render to image**: `MMCliTools.render_output_texture()` and
  `render_output_image()`.
- **OCIO view picker**: `MMColorManagement.create_view_picker()`.
- **Generator walkers**: `MMCliTools.collect_generators(root, predicate)`.
- **Library instances**: `strip_definition(value, for_diff)` (hashes are
  unchanged) and `by_name()` / `diff_by_name()`.
- **Sprite sheets**: `MMCliTools.make_sprite_sheet()`.

## Runtimes and tools (done)

- **OCIO extension**: transforms are only built when the processor is not
  cached, the error is cleared on success, no `mutable`.
- **Godot runtime** (`mmr_renderer.gd`): pipelines, buffers and uniform sets
  are created once; renders update the parameter buffers.
- **Blender add-on**: manifests are cached by file time and size.
- **C++ runtime** (`renderer.cpp`): `create_pass` is split into resources,
  pipeline and descriptor sets.
- **validate_library.py**: `validate()`, `check_library_item()` and
  `check_example()`. **ptex_tools.py**: a `COMMANDS` table.
