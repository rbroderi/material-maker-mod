# Voxel materials for ZCity: design note

Status: implemented on branch `quick-wins-16k-buffer-timing` (working tree, not committed).
The plan it came from is `design/zcity_plan.md`; the user documentation is
`material_maker/doc/voxel_workflow.rst`. This note records the decisions, what was rejected, and
what is still open. Source wishlist: `ZCity/Docs/MATERIALMAKER_WISHLIST.md`.

## What exists

| Area | Where |
|---|---|
| Voxel Material and Voxel Inputs nodes, recipe nodes (Wood, Palette Pick, Weathering, Char, Wetness, Paint, Surface Pattern), UE5 export targets | `material_maker/plugins/voxel/` |
| Seeded 3D noises, domain warp, gradient, 3D Buffer, `mm_noise3d` globals | `addons/material_maker/nodes/`, `material_maker/library/base.json` |
| GLSL to HLSL translation fixes | `addons/material_maker/engine/nodes/gen_material.gd`, `addons/material_maker/nodes/hlsl_defs.tmpl` |
| `--evaluate-points`, RPC `evaluate_points` | `plugins/voxel_eval/` |
| `--bake-voxel-material`, RPC `bake_voxel_material` | `plugins/voxel_mesh_bake/` |
| `--voxel-master` | `plugins/voxel_master/` |
| `--param-schema`, RPC `param_schema` | `plugins/param_schema/` |
| `--graph-cost`, RPC `graph_cost`, menu item | `plugins/graph_cost/` |
| `--export-volume` additions (raw, slices, r8/rg8/r16/rg16, origin, tileable check) | `plugins/volume_export/` |
| Python `material_maker_client.voxel` | `python/material_maker_client/voxel.py` |
| Oak acceptance example | `material_maker/examples/voxel_oak.ptex`, `python/examples/zcity_oak/` |
| Parity test, UE script stub | `test/test_voxel_hlsl_parity.gd`, `test/voxel_unreal_stub.py` |

## Decisions

**D1. Position, normal and per thing values, without an engine change.**
Position is the tex3d coordinate `$uv.xyz` in object space, in metres. The object-space normal
and the per point fresh value ride in `_controlled_variation_` (`.xyz` and `.w`), the only per
pixel channel that already reaches every generated function. Seed, age, upkeep, fresh, char, wet,
axis, origin and footprint are float parameters of one node (`voxel_inputs`), so they are sliders
in the preview, saved in the `.ptex`, settable with `--set` and RPC, and listed by the schema. In
the UE5 export a filter (`voxel_inputs`) rewrites their uniforms (`p_o<id>_vox_*`) into struct
members fed by the Custom node's inputs.
Costs, accepted and documented: the Controlled Variations node is unusable in a voxel graph;
anything baked into a buffer loses the normal and the fresh value; several Voxel Inputs nodes can
show different slider values in the preview but export one set.

**D2. Rejected: threading a new `vec3` normal through every generated function** (about 15 templates
and every user export target change); **mutable globals** (Godot's shading language has none);
**`mm_renderer` global parameters** (application wide, not saved per graph).

**D3. Seeds are integer valued floats and the new noises use voxkit's integer hash bit for bit**
(`noise.py::hash3`). Integer arithmetic is identical in GLSL, HLSL and numpy, so only the float
rounding of the interpolation can differ. `mm_n3_seed(float)` converts exactly (the plan's
`uint(int(floor(s+0.5)))` was replaced by it). The Voxel Inputs seed slider goes to 65535 and the
noise `seed_offset` to 1000, narrower than the 16777215 of the plan; the hash accepts the full range.

**D4. Bump is split in two.** A gradient node outputs the gradient vector of a 3D height; the
Voxel Material combines it with the geometric normal, `nb = normalize(n - k*(g - n*dot(g, n)))`
(voxkit's `_bump`), and the export writes `nb` to the normal output in object space.

**D5. Parity is tested by running the exporter's own HLSL.** DXC compiles the exported `.shader` in
a compute harness, Godot's RenderingDevice runs the SPIR-V (Godot accepts DXC's SPIR-V directly)
and the numbers are compared with the GLSL compute path at the same points. 22 of 22 cases pass;
largest final colour difference 6.1e-4 (wood), noises 3e-6 or less. The test compiles at `-O0`:
optimised SPIR-V of noise loops hangs the driver of an AMD Radeon 780M (device lost).

**D6. Tools are separate small plugins** (`voxel_eval`, `param_schema`, `graph_cost`,
`voxel_master`, `voxel_mesh_bake`) so parallel work never shared a `plugin.gd`. The nodes, the
material type and the export targets are in `voxel`. Generic nodes (seeded noise, gradient, 3D
Buffer) are in the base library so they can be carved into upstream pull requests.
`material_maker/cli/*`, `rpc_server.gd` and the Python client `__init__.py` were not modified:
plugins register CLI modes and RPC methods, and the client forwards unknown methods.

**D7. Extra input beyond the wishlist: `footprint`** (metres per pixel, default 0), for voxkit's
ring fade; Unreal supplies it from the derivatives of the position (`auto` in the master config).

**D8. The Custom node input for burn is `Char`, not `char`** (reserved in HLSL).

**D9 (added during the work). Exact hash option for the legacy 3D noises.** `tex3d_fbm`,
`tex3d_fbm_2`, `tex3d_fbm_3` and `tex3d_voronoi` got an enum `hash`: Legacy (0, default, byte
identical code) or Exact (1, the integer hash of D3; the seed derives from `$seed` as
`mm_n3_seed(mod($seed*16777215, 16777216))`). The library item 3D/Texture/FBM uses Exact. This
reverses the plan's L6 only in part: old graphs are unchanged, new ones can choose parity. Exact
GLSL versus HLSL difference is at most 7.7e-7. The cost lint only reports declarations a graph
uses. Still flagged: the 3D Blend node's Dissolve mode and `sdf3d_fbm`, `sdf3d_fbm2`,
`sdf3d_repeat`, `sdf3d_circle_repeat`.

## Alternatives not taken in the tooling

- Item 12 (reference photo beside the preview): the Reference panel already exists; a split or
  overlay view was judged low value and is not planned (documented in the workflow chapter).
- A single `Texture3D` lookup for the 3D Buffer (L3): the atlas version works with the existing EXR
  buffer export.
- Evaluation with per point age, char and wet (L4): the values are per call; group points.

## Open items (L1 to L9)

- **L1. Verification in Unreal Engine.** Open and important. Material compile, Material Function
  creation (`MaterialFunctionFactoryNew`, `create_material_expression_in_function`,
  `FunctionInputType`), the master material, Custom Primitive Data and vertex colour inputs,
  several structs with `if`/`else` in one Custom node, the `ddx` footprint and the normal transform
  were written from knowledge of the Unreal Python API and checked only with `py_compile`, a
  recording stub of the `unreal` module and DXC. A manual pass in the editor is needed.
- **L2. A dedicated threaded normal variable in the generator.** Rejected (D2).
- **L3. Single lookup Texture3D for the 3D Buffer.** Deferred; `--export-volume` writes a volume to
  wire by hand.
- **L4. Per point arrays for age, char, wet in Python evaluation.** Not done.
- **L5. Reference photo overlay.** Not planned.
- **L6. Bit level parity of legacy sin-hash nodes.** Mitigated by D9 for the four 3D noises; the
  `rand*` nodes and the nodes listed in D9 remain legacy and are flagged by the lint.
- **L7. Brick layout.** Not planned: the bond pattern belongs to the kit's geometry. Palette Pick
  takes an id from any source.
- **L8. voxkit `moulding()`.** Not ported: part specific geometry, not a material recipe.
- **L9. FXC (SM5) compile check.** No `fxc.exe` on the machine; only DXC with `-HV 2018` and
  `-HV 2021` is run.

Further limits found while building it:

- The oak acceptance passes. Voxel Wood takes all non-ring noises from absolute positions (voxkit's
  frame); the Origin input is still the pith, so no separate pith input is needed. Against voxkit:
  albedo mean ~1.2e-4 (p99 < 1.8e-3, max 6.1e-3), normal <= 0.028 deg, spec <= 4.7e-5; picture MAD
  0.023, SSIM 1.0000; `zcity` preset arch measure 0.283 (phase) / 0.574 (luminance), ring count 13
  vs 12. The `zcity` preset values were retuned (4.0, 0.006, 1.0, 0.2) and its side faces still
  need a human look.
- DXC at `-O1` or higher hangs one of the tested GPU drivers on noise loops, so the parity test
  compiles at `-O0`.
- `bake_voxel_material` was only tested from the command line; the RPC method is untested.
- The shader cost is a weighted static estimate, not Unreal's instruction count.
- The 3D Buffer loses the normal and the fresh value of the voxel context.
