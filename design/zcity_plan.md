# ZCity voxel material plan for the Material Maker fork

Repo: `C:\Users\richa\workspace_local\materialmakermod` (branch `quick-wins-16k-buffer-timing`). Target file: `design/zcity_plan.md`.
Source wishlist: `C:\Users\richa\workspace_local\zcity\ZCity\Docs\MATERIALMAKER_WISHLIST.md`. Reference recipes: `ZCity\Tools\voxkit\appearance.py`, `noise.py`. Reference render: `ZCity\Saved\Voxkit\beam_close.png`.

Each subagent brief = **Standing constraints** + **Shared contract** + **HLSL-safe subset** + the WP section. Those three blocks are written once below and are part of every WP.

---

## 0. What exploration found (facts the plan rests on)

- **The UE5 export target** is `material_maker/plugins/export_targets/export_targets/material_export_Unreal_Unreal Engine 5 Shader.mme` (JSON, `"material": "material"`). It writes `<prefix>.shader` (HLSL body for a Custom node: `struct Functions { ... generated_shader(...) }`) and `<prefix>.py` (Unreal Python using `material_maker/misc/export/mm.py`).
- **GLSL to HLSL is plain string replacement** in `addons/material_maker/engine/nodes/gen_material.gd`: `process_option_hlsl_base` (line 429), `process_option_unreal5` (534), `process_option_rename_buffers`, `process_option_sample_level_0`, plus `addons/material_maker/nodes/hlsl_defs.tmpl`. Gaps: `mat3`/`mat4` and `uvec*` are not handled, and `uvec3(` is mangled to `utofloat3(`. One-argument `atan(x)` breaks, because `hlsl_atan` is a two-argument macro (`tex3d_math.mmg` uses `atan(A)`). The replacements are not word-bounded (`mix`, `fract`, `atan`, `vec3` inside identifiers are rewritten).
- **An export target can carry its own filter**: the `.mme` `custom` field is GDScript whose `process_option_<name>(s, is_declaration)` functions are found by `apply_gen_options` (gen_material.gd:308). `check_custom_script` rejects any script containing the substrings `OS`, `DirAccess`, `FileAccess`.
- **3D types**: `tex3d` (vec3) and `tex3d_gs` (float) are functions of `vec4 p` (`addons/material_maker/nodes/io_types.mmt`). A 3D material node already exists (`addons/material_maker/nodes/material_3d.mmg`, tex3d inputs, spatial preview shader using `VERTEX`).
- **Existing 3D noise** (`tex3d_fbm*.mmg`, `tex3d_voronoi.mmg`) hashes with `fract(sin(dot()))*43758`, with integer scales 1..32. That is not parity-safe across compilers or drivers and has no seed input. `tex3d_warp.mmg` shows function inputs (`"function": true`) and instance functions (finite differences already). `"includes": ["other_node"]` in a shader model pulls another node's `global` (see `tex3d_fbm_3.mmg`).
- **Two per-pixel values are threaded through every generated function**: `float _seed_variation_` and `vec4 _controlled_variation_` (gen_shader.gd:112, 513, 641). They are readable in any node as `$?1..$?4`. Every preview and compute template declares them before the node code (`buffer_compute.tres` line 29-30). This is the only per-pixel channel that exists without an engine change.
- **Float parameters become uniforms named `p_o<instance id>_<param name>`** (gen_shader.gd:529). The `unreal5` filter turns uniforms into struct members initialised at the top of each `$begin_generate` block.
- **Plugins** (`material_maker/plugins/<id>/plugin.cfg` + `plugin.gd extends MMPlugin`) can add node directories (`nodes=`), a library file (`library=`), export targets (`export_targets=`), CLI modes (`api.add_cli_mode`, also listed in `cli_modes=`), RPC methods (`api.add_rpc_method`), menu items and dependencies (`depends=`). Prior art: `plugins/volume_export`, `plugins/example`, `plugins/car_paint` (a material type in a plugin).
- **Already present, so only extended**:
  - `--export-volume` (`plugins/volume_export`: vdb/dds/ktx2, `--voxels`, `--extent`, texel formats rgba16f/rgba32f/rgba8/r16f/r32f, centred box). `VolumeExport.render_volume` is the pattern for evaluating a 3D output at arbitrary points in a compute shader.
  - `--bake` (mesh maps including position and normal), `--mesh`, `--list-parameters` (text only), `--rpc` JSON-RPC (`material_maker/tools/rpc/rpc_server.gd`).
  - The Python client `python/material_maker_client/__init__.py` (unknown methods forward to RPC through `__getattr__`).
  - A Reference panel (`material_maker/doc/user_interface_reference_panel.rst`).
- **Docs test**: `test/test_doc_completion.gd` only checks nodes listed in `material_maker/library/base.json`. Doc name = `node_` + tree_item lowercased with `/` and space replaced by `_`.
- **Toolchain on this machine**: Vulkan SDK 1.4.363 on PATH (`dxc`, `glslangValidator`, `spirv-cross`, `spirv-val`), Python 3.15 with numpy 2.5.4. No `fxc.exe`. No Unreal found at `C:\Program Files\Epic Games`; I did not search other drives, so "no Unreal" is an assumption.
- **voxkit specifics**:
  - `noise.py` uses a uint32 integer hash (lowbias32 finaliser `mix32`, constants 374761393, 668265263, 2147483629), value noise with smoothstep, and fbm with frequency x2.03 and seed `salt(seed, 0x40000000+o)` per octave (the earlier scheme, with a `974711` seed term and `seed+101` octaves, was replaced; the old text of this plan is historical).
  - Coordinates are in voxels (81 per metre). `fw` is 1 on the original surface (the wishlist's `fresh` = 1 - fw). `fp` is the pixel footprint used to fade rings.
  - `render.render` always uses a `ProcessPoolExecutor`.

---

## 1. Design decisions

**D1. Position, normal and per-thing values.**
- Position is the tex3d coordinate `$uv.xyz`, object space, metres.
- Normal and fresh ride in `_controlled_variation_`: `.xyz` = object-space unit normal, `.w` = per-point fresh.
- Seed, age, upkeep, fresh, char, wet, axis, origin, footprint are float parameters of one node (`voxel_inputs`), so they are sliders in the preview, saved in the `.ptex`, settable with `--set` and RPC, and listed in the schema.
- In the UE5 voxel export, a filter rewrites their uniforms (`p_o<id>_vox_*`) to struct members fed by the Custom node's inputs.
- No engine change. Costs, to be documented:
  - the Controlled Variations node cannot be used in a voxel graph;
  - anything baked into a buffer loses normal and fresh;
  - several Voxel Inputs nodes in one graph can show different slider values in the preview, but export as one set.

**D2. Alternatives rejected.**
- Threading a new `vec3` normal through all generated functions: touches about 15 templates and every user export target.
- Mutable globals: Godot's shading language has none.
- `mm_renderer` global parameters: app-wide, not saved per graph.

**D3. Seeds are integer-valued floats** (0..16777215), converted with `uint(int(floor(s+0.5)))`. New noises use voxkit's integer hash bit for bit. Integer arithmetic is identical in GLSL, HLSL and numpy, so the hash values match exactly and only float rounding in the interpolation can differ. This is what makes item 5 achievable.

**D4. Bump is split in two.** A graph node outputs the gradient vector of a 3D height. The material node combines it with the geometric normal: `nb = normalize(n - k*(g - n*dot(g,n)))` (voxkit's `_bump`). The export writes `nb` to the normal output in object space.

**D5. Parity is tested by running the exporter's own HLSL.** `dxc -spirv` compiles the exported `.shader` inside a compute harness, Godot's RenderingDevice runs the SPIR-V, and the numbers are compared with the GLSL compute path at the same points (WP10).

**D6. Tools are separate small plugins** (`voxel_eval`, `param_schema`, `graph_cost`, `voxel_master`, `voxel_mesh_bake`), so parallel WPs never share `plugin.gd` or `plugin.cfg`. Nodes, the material type and export targets live in one plugin, `voxel`. Generic nodes (seeded noise, gradient, 3D buffer) go in the base library so they can be carved into upstream PRs.

**D7. Extra input beyond the wishlist: `footprint`** (metres per pixel, default 0). voxkit's ring fade needs it; UE supplies it from `ddx`/`ddy` of position in the setup script.

**D8. The Custom node input for burn is named `Char`, not `char`.** `char` is a reserved word in HLSL.

---

## 2. Blocks pasted into every subagent brief

### Standing constraints

1. Many `.gd`, `.rst`, `.py`, `.cfg` files are CRLF. Preserve each file's line endings. Check with `file <path>`. Edit through the Edit tool, or through Python that reads and writes with `newline=""`. New files match their neighbours: `.gd`, `.rst`, `.cfg`, `.py` in this repo are CRLF; `.mmg`, `.mme`, `.json`, `.ptex` are LF.
2. Never write files with bash heredocs or shell redirection.
3. No git commits, no branch changes, no stash. Leave changes in the working tree.
4. Only one Material Maker or Godot render/export process at a time. Never start a second while one runs. Do not run GUT and a CLI export in parallel.
5. Godot: `C:/Users/richa/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.7.2-stable_win64_console.exe` (below: `<godot>`).
6. GUT, all tests: `<godot> --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test -gexit`. It currently passes 71/71 and must stay green: no failures; new GPU-only tests may be `pending` when headless. Tests go flat in `res://test/` as `test_*.gd`.
7. GPU tests are run one file at a time without `--headless`: `<godot> --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/<file>.gd -gexit`. In the test, call `pending()` when `RenderingServer.get_rendering_device() == null`.
8. Material Maker CLI from source: `<godot> --path . -- <mode> <options> <files>`.
9. Every new library node needs `material_maker/doc/node_<tree_item lowercased, "/" and " " replaced by "_">.rst` (copy the layout of `material_maker/doc/node_3d_texture_fbm.rst`; images optional) and a toctree entry in the file named in the WP.
10. Only touch the files listed under "Files" in your WP. If you need another file, stop and report.
11. Tests write only under `user://` or the OS temp directory, never into the repo.

### Shared contract (voxel context)

- **Position**: tex3d coordinate `$uv.xyz` = object-space position in metres. `$uv.w` is unused (0).
- **Per-pixel context**: `_controlled_variation_.xyz` = object-space unit normal (zero vector = unknown). `_controlled_variation_.w` = per-point fresh (0 = original surface, 1 = fresh cut).
- **Per-thing values**: float parameters of node type `voxel_inputs`, with these exact names: `vox_seed`, `vox_age`, `vox_upkeep`, `vox_fresh`, `vox_char`, `vox_wet`, `vox_axis_x`, `vox_axis_y`, `vox_axis_z`, `vox_origin_x`, `vox_origin_y`, `vox_origin_z`, `vox_footprint`. Their uniforms are `p_o<digits>_vox_<name>`.
- **Seed**: integer-valued float 0..16777215. Convert with `uint(int(floor(s+0.5)))`.
- **Hash** (must equal `ZCity/Tools/voxkit/noise.py::hash3`):
  ```glsl
  uint mm_n3_lowbias32(uint x) {   // voxkit mix32 (not named mix: the HLSL translation rewrites "mix")
      x ^= x >> 16u; x *= 0x7FEB352Du; x ^= x >> 15u; x *= 0x846CA68Bu; x ^= x >> 16u;
      return x;
  }
  uint mm_n3_salt(uint seed, uint n) { return mm_n3_lowbias32(mm_n3_lowbias32(seed)+n*0x9E3779B9u); }
  uint mm_n3_hash_u(int x, int y, int z, uint s) {
      uint h = uint(x)*374761393u + uint(y)*668265263u + uint(z)*2147483629u + mm_n3_lowbias32(s);
      return mm_n3_lowbias32(h);
  }
  float mm_n3_hash(int x, int y, int z, uint s) { return float(mm_n3_hash_u(x, y, z, s) >> 8u)*(1.0/16777216.0); }
  ```
  A separate stream is `mm_n3_salt(seed, n)`, never `seed+n`.
- **Value noise** `mm_n3_value(vec3 p, uint s)`: lattice `floor(p)`, weights `f*f*(3-2f)`, trilinear mix of `mm_n3_hash` at the 8 corners. Equals voxkit `noise3`.
- **fbm** `mm_n3_fbm(vec3 p, uint s, int octaves, float gain, float lacunarity)`: octave `o` uses seed `mm_n3_salt(s, 0x40000000u+uint(o))` and frequency `lacunarity^o`, normalised by the sum of amplitudes. Equals voxkit `fbm` when lacunarity = 2.03.
- **Bump**: `nb = normalize(n - k*(g - n*dot(g, n)))`, `g` = gradient vector from the graph, `k` = material `bump` parameter.
- **Colour**: the voxel material has boolean `linear_albedo`. False (default) = albedo input is sRGB, decoded in the material as in the existing UE5 template. True = the input is already linear (ZCity recipes use this).
- **Custom node input names (UE)**: `Position`, `Normal`, `Seed`, `Age`, `Upkeep`, `Fresh`, `Char`, `Wet`, `Axis`, `Origin`, `Footprint`, `Time`, then `texture_<n>`.

### HLSL-safe GLSL subset (all new node code)

- No `mat2/3/4`, no `uvec*`/`bvec*`, no `lessThan`/`greaterThan`/`equal`, no `dFdx`/`fwidth`, no `texelFetch`/`textureSize`, no one-argument `atan`.
- No vector ternaries or `&&`/`||` on vectors.
- Integer vectors only as `ivec3(int, int, int)` built from scalars (never `ivec3(vec3)`).
- Loops have a constant bound with `if (i >= n) break;`.
- New identifiers must not contain `vec2`, `vec3`, `vec4`, `mat2`, `mix`, `fract`, `atan`, `uniform`, `sampler2D`, `elapsed_time`, `texture_`. The translator replaces substrings.
- `mod(a, b)` is fine (macro). Rotations are written component-wise (see `tex3d_rotate.mmg`).

---

## 3. Wishlist coverage

| # | Item | WP | Verdict |
|---|------|----|---------|
| 1 | UE5 voxel export target | WP1, WP7 | Feasible. HLSL verified by dxc. The UE Python script is not verifiable here. |
| 2 | Graph input nodes | WP1 (preview), WP7 (Custom inputs) | Feasible. |
| 3 | 3D bump | WP2 (gradient node), WP1 (material normal), WP7 (export) | Feasible. |
| 4 | Seeded 3D noises | WP2 | New integer-hash nodes: value, Perlin, fbm, Voronoi, domain warp. Existing `tex3d_fbm`/`tex3d_voronoi` are left unchanged; see L6. |
| 5 | GLSL/HLSL parity with a test | WP3, WP10 | Feasible for parity-safe nodes on this machine (dxc to SPIR-V, same GPU). Not a test inside Unreal. |
| 6 | Python point evaluation | WP8 | Feasible: numpy in and out through `.npy` files over RPC, plus a file-based CLI mode. |
| 7 | CLI 3D volume and per-mesh 2D bakes | WP6, WP12 | Volume: extend the existing plugin. Per-mesh: new mode on the evaluator. |
| 8 | JSON parameter schema | WP4 | Feasible, small. |
| 9 | Material Function and master material | WP11 | Generators feasible. Correctness inside UE is not verifiable here (dxc compile and stub run only). |
| 10 | Cost readout and 3D buffer node | WP5, WP9 | Cost is a static weighted estimate, not UE's instruction count. The 3D buffer is a 2D slice atlas with 2 lookups. |
| 11 | Recipe nodes | WP13 (wood), WP14 (palette, weathering, char, wetness, paint) | Feasible. |
| 12 | Reference photo beside preview | WP17 (docs only) | Already exists as the Reference panel. A split or overlay view is low value; not planned. |
| 13 | 3D-placed wallpaper/fabric | WP15 | Feasible as a normal-driven projection node. |
| The first test | Oak rebuilt, exported, compared | WP16 | Numeric against `appearance.wood()` plus an image through voxkit's own renderer. |

### Infeasible, deferred or low value

- **L1. Verification in Unreal.** Material compile in UE, Material Function creation, the master material and Custom Primitive Data wiring cannot be run here. Generated `.py` files are checked by `py_compile` and by running them against a recording stub `unreal` module. A manual UE pass is needed before relying on them.
- **L2. A dedicated threaded normal variable in the generator**: rejected (D2).
- **L3. A single-lookup `Texture3D` in the UE Custom node for the 3D buffer**: deferred. The atlas version works with the existing EXR buffer export. A real volume file is available from `--export-volume` for hand wiring.
- **L4. Per-point arrays for age, char, wet in Python evaluation**: only position, normal, fresh are per point; the rest are per call. Workaround: group points by value. voxkit already groups per instance.
- **L5. Reference-photo overlay** (item 12): low value, the panel exists.
- **L6. Bit-level parity for legacy sin-hash nodes** (`tex3d_fbm`, `tex3d_voronoi`, `rand*`): not guaranteed. WP5's lint flags them in voxel graphs. Retrofitting a seed into those nodes would change every existing graph that uses them.
- **L7. Brick layout** (`brick_at(cell)` from `parts/brick_wall.py`): the bond pattern belongs to ZCity's geometry. The palette node takes an `id` input, so any id source works. No brick-bond node is planned.
- **L8. voxkit `moulding()`** (sash-bar profile from pane rectangles): part-specific geometry, not a material recipe; not ported.
- **L9. FXC (SM5) compile check**: no `fxc.exe` here. Only DXC with `-HV 2018` and `-HV 2021` is run.

---

## 4. Work packages

Sizes: S under 200 changed lines, M 200-600, L over 600.

### Wave 1 (parallel: WP1, WP2, WP3, WP4, WP5, WP6)

#### WP1. Voxel plugin core: Voxel Material node and Voxel Inputs node (must-have 1, 2, 3 preview side). Size M.

**Goal**: a material type that takes tex3d inputs, shows them in the 3D preview with object-space position, normal and bump, and a node that exposes the per-thing values as sliders.

**Files (create)**
- `material_maker/plugins/voxel/plugin.cfg`: name "Voxel materials", `nodes="nodes"`, `library="library.json"`, `export_targets="export_targets"` (the directory arrives in WP7; the loader tolerates a missing one), `enabled_by_default=true`.
- `material_maker/plugins/voxel/nodes/material_voxel.mmg`: `"type": "material_export"`. Copy the structure of `addons/material_maker/nodes/material_3d.mmg`; drop its `exports`.
- `material_maker/plugins/voxel/nodes/voxel_inputs.mmg`: `"type": "shader"`.
- `material_maker/plugins/voxel/library.json`: same schema as `material_maker/library/base.json` (`{"lib":[...],"name":"Voxel"}`). One item: tree_item `3D/Voxel/Inputs`, type `voxel_inputs`, no `icon_data`.
- `material_maker/doc/node_3d_voxel.rst` (hub, with a toctree), `material_maker/doc/node_3d_voxel_inputs.rst`, `material_maker/doc/node_material_voxel.rst`.
- `test/test_voxel_nodes.gd`.

**Files (modify)**
- `material_maker/doc/nodes_3d.rst`: add `node_3d_voxel` to the toctree.
- `material_maker/doc/nodes_material.rst`: add `node_material_voxel`.

**Spec, `material_voxel.mmg`**
- Name "Voxel Material".
- Inputs:

  | Name | Type | Default |
  |---|---|---|
  | `albedo_tex` | tex3d | `vec3(0.5)` |
  | `metallic_tex` | tex3d_gs | `0.0` |
  | `roughness_tex` | tex3d_gs | `1.0` |
  | `emission_tex` | tex3d | `vec3(0.0)` |
  | `ao_tex` | tex3d_gs | `1.0` |
  | `opacity_tex` | tex3d_gs | `1.0` |
  | `bump_tex` | tex3d | `vec3(0.0)` |

- Parameters: `albedo_color` (color, white); `metallic` (1); `roughness` (1); `emission_energy` (1); `ao` (1); `bump` (float 0..4, default 1); `linear_albedo` (boolean, false); `preview_scale` (float 0.01..100, default 1; metres per preview unit).
- `preview_shader`: spatial, based on material_3d's.
  - Varyings `vec3 mm_vox_p; vec3 mm_vox_n;`.
  - In `vertex()`: `mm_vox_p = VERTEX*<preview_scale>; mm_vox_n = NORMAL;`. The `$preview_scale` value must be read in a `$begin_generate` block, or passed through a varying computed in `fragment()`. Check how material_3d reads `$(param:world)` and use `$(param:preview_scale)` in the template text if that is simpler.
  - In `fragment()`:
    ```
    float _seed_variation_ = 0.0;
    vec3 mm_n = normalize(mm_vox_n);
    vec4 _controlled_variation_ = vec4(mm_n, 0.0);
    $begin_generate
    vec4 mm_q = vec4(mm_vox_p, 0.0);
    vec3 mm_alb = $albedo_tex(mm_q);
    ```
    then:
    - sRGB decode unless `$if $(param:linear_albedo)`;
    - `ALBEDO = $albedo_color.rgb*mm_alb;`
    - metallic/roughness/emission/AO as material_3d;
    - `vec3 mm_g = $bump_tex(mm_q); vec3 mm_nb = normalize(mm_n - $bump*(mm_g - mm_n*dot(mm_g, mm_n)));`
    - `NORMAL = normalize((VIEW_MATRIX*MODEL_MATRIX*vec4(mm_nb, 0.0)).xyz);`
    - opacity only under `$if $(connected:opacity_tex)`.
- Hidden `outputs` (used by WP8 and WP10; each is a function of `$uv` = vec4 p and reads the normal as `vec3($?1, $?2, $?3)`):

  | Index | Type | Value |
  |---|---|---|
  | 0 | tex3d | base colour, linear (`$albedo_color.rgb *` decoded albedo) |
  | 1 | tex3d | `vec3($ao_tex($uv), $roughness*$roughness_tex($uv), $metallic*$metallic_tex($uv))` |
  | 2 | tex3d | `$emission_energy*$emission_tex($uv)` |
  | 3 | tex3d | the bumped normal, same formula as the preview |
  | 4 | tex3d_gs | `$opacity_tex($uv)` |

  The decode must use the same expression text as the preview. Because `linear_albedo` is a boolean, write output 0 with an enum-like substitution, or as two expressions selected by a boolean-valued expression `($linear_albedo ? a : b)`; verify that it generates.

**Spec, `voxel_inputs.mmg`**
- Name "Voxel Inputs".
- Parameters (all float, `"control": "None"`), with the exact names of the Shared contract:

  | Parameter | Range, step | Default |
  |---|---|---|
  | `vox_seed` | 0..65535, step 1 | 0 |
  | `vox_age`, `vox_upkeep`, `vox_fresh`, `vox_char`, `vox_wet` | 0..1 | 0 |
  | `vox_axis_x/y/z` | -1..1 | 1, 0, 0 |
  | `vox_origin_x/y/z` | -10..10, step 0.001 | 0 |
  | `vox_footprint` | 0..0.1, step 0.0001 | 0 |

- `global`: `vec3 mm_vox_normal(vec3 n, vec3 p) { float l = dot(n, n); return (l > 0.25) ? n/sqrt(l) : normalize(p+vec3(0.0, 0.0, 0.000001)); }` and `vec3 mm_vox_axis(vec3 a) { float l = dot(a, a); return (l > 0.000001) ? a/sqrt(l) : vec3(1.0, 0.0, 0.0); }`.
- Outputs, in this order:

  | Index | Name | Type | Expression |
  |---|---|---|---|
  | 0 | Position | tex3d | `$uv.xyz` |
  | 1 | Normal | tex3d | `mm_vox_normal(vec3($?1, $?2, $?3), $uv.xyz)` |
  | 2 | Seed | tex3d_gs | `$vox_seed` |
  | 3 | Age | tex3d_gs | `$vox_age` |
  | 4 | Upkeep | tex3d_gs | `$vox_upkeep` |
  | 5 | Fresh | tex3d_gs | `clamp($vox_fresh+$?4, 0.0, 1.0)` |
  | 6 | Char | tex3d_gs | `$vox_char` |
  | 7 | Wet | tex3d_gs | `$vox_wet` |
  | 8 | Axis | tex3d | `mm_vox_axis(vec3($vox_axis_x, $vox_axis_y, $vox_axis_z))` |
  | 9 | Origin | tex3d | `vec3($vox_origin_x, $vox_origin_y, $vox_origin_z)` |
  | 10 | Footprint | tex3d_gs | `$vox_footprint` |

  The fallback `normalize(p)` in output 1 makes the 2D sphere preview of any tex3d node show a sensible normal.

**Docs** must state the D1 limitations.

**Dependencies**: none.

**Acceptance** (`test/test_voxel_nodes.gd`, headless)
- Load definitions with `mm_loader.get_predefined_generators_from_dir("res://material_maker/plugins/voxel/nodes")`.
- Build `{nodes:[material_voxel "Material", voxel_inputs "In"], connections:[In:5 -> Material:roughness_tex, In:1 -> Material:albedo_tex]}` with `await mm_loader.create_gen(...)` and add it to the tree.
- Assert:
  1. `In.get_shader_code("uv", 2, MMGenContext.new())` has a uniform named `p_o<id>_vox_seed`;
  2. output 1's value contains `_controlled_variation_.x`;
  3. the material's processed preview shader (`process_shader(shader_model.preview_shader)`) contains `_controlled_variation_ = vec4(` and no unresolved `$`;
  4. `material.get_output_defs(true).size() == 5`.
- Manual check, reported not automated: open MM, set the material type to Voxel Material, connect Voxel Inputs Normal to albedo on the cube mesh; faces show plus/minus axis colours and stay fixed when the object rotates.

#### WP2. Seeded 3D noise nodes and 3D gradient (bump) node (must-have 3, 4). Size L.

**Goal**: integer-hash, seed-driven, metre-scaled 3D noises and a gradient node, in the base library.

**Files (create)** in `addons/material_maker/nodes/`
- `mm_noise3d.mmg`: holder of shared globals only, not in the library. `"type": "shader"`, name "Noise 3D functions", one dummy tex3d_gs output `0.0`. `global` = the Shared contract functions plus `mm_n3_seed(float s)`, `mm_n3_perlin`, `mm_n3_voronoi`, `mm_n3_vnoise` (vec3 of three value noises with seeds s, s+1, s+2) and a periodic wrap helper `int mm_n3_wrap(int i, int period)` (returns `i` when period <= 0, else positive modulo).
- `tex3d_noise_value.mmg`, `tex3d_noise_perlin.mmg`, `tex3d_noise_fbm.mmg`, `tex3d_noise_voronoi.mmg`, `tex3d_domain_warp.mmg`: each has `"includes": ["mm_noise3d"]`.
- `tex3d_gradient.mmg`.
- Docs: `material_maker/doc/node_3d_texture_noise_value.rst`, `..._noise_perlin.rst`, `..._noise_fbm.rst`, `..._noise_voronoi.rst`, `node_3d_texture_domain_warp.rst`, `node_3d_texture_gradient.rst`.
- `test/test_noise3d.gd`.

**Files (modify)**
- `material_maker/library/base.json`: append 6 items with these tree_items: `3D/Texture/Noise/Value`, `3D/Texture/Noise/Perlin`, `3D/Texture/Noise/FBM`, `3D/Texture/Noise/Voronoi`, `3D/Texture/Domain Warp`, `3D/Texture/Gradient`. `icon_data` may be omitted. Keep tab indentation and LF.
- `material_maker/doc/node_3d_texture.rst`: 6 toctree lines.

**Spec common to the noise nodes**
- Input `seed_in` (tex3d_gs, default `0.0`, label "Seed").
- Parameters: `scale_x/y/z` (float 0.001..1000, step 0.001, default 8; features per metre), `offset_x/y/z` (default 0), `seed_offset` (0..1000, step 1), `period` (0..256, step 1, 0 = not periodic; lattice period in cells per axis after scaling, for tileable volumes).
- `code`: `uint $(name_uv)_s = mm_n3_seed($seed_in($uv)+$seed_offset); vec3 $(name_uv)_p = $uv.xyz*vec3($scale_x, $scale_y, $scale_z)+vec3($offset_x, $offset_y, $offset_z);`.

**Per node**
- **Value**: output tex3d_gs in [0,1) = `mm_n3_value`.
- **Perlin**: gradient noise. The gradient per lattice point comes from three `mm_n3_hash` calls with seeds s, salt(s,1), salt(s,2) mapped to [-1,1], not normalised. Quintic fade. Output remapped `0.5+0.5*n`.
- **FBM**: enum `basis` (Value/Perlin), `octaves` (1..8), `gain` (default 0.5), `lacunarity` (default 2.03).
- **Voronoi**: `jitter` 0..1. For each of the 27 neighbour cells, the feature point is `cell + 0.5 + jitter*(hash3-0.5)`. Outputs:
  - F1 distance (tex3d_gs);
  - edge distance F2-F1 (tex3d_gs);
  - cell random (tex3d_gs, hash of the winning cell);
  - cell colour (tex3d, three hashes).

  The winning cell id is hashed from its integer coordinates, so it is exact in every language.
- **Domain Warp**: input `in#` (tex3d, generic like `tex3d_warp.mmg`), plus `seed_in`; parameters `amount` (metres), scale/offset/seed_offset, `octaves`, `gain`. Output `$in#(vec4($uv.xyz+$amount*(2.0*mm_n3_vnoise_fbm(...)-1.0), $uv.w))`.
- **Gradient**: input `in` (tex3d_gs, `"function": true`, default `0.0`); parameters `eps` (0.00001..0.1, default 0.00074), `strength` (default 1), enum `mode` (Forward / Central).
  - Instance function: `vec3 $(name)_grad(vec4 p, float e)` = forward differences `($in(p+dx)-$in(p))/e` (voxkit `_bump`), or central `/(2e)`. Keep `p.w`.
  - Output tex3d `$strength*$(name)_grad($uv, $eps)`.
  - The doc states the unit conversion: a voxkit strength `k` with heights sampled in voxels equals `k/81` here.

Everything follows the HLSL-safe subset.

**Dependencies**: none.

**Acceptance** (`test/test_noise3d.gd`)
- Headless:
  - all 6 nodes instantiate through `mm_loader.create_gen`;
  - `get_shader_code("uv", i, ...)` for each output has no `$` left and its globals contain `mm_n3_hash_u`;
  - none of the generated text matches `\b(mat[234]|uvec[234]|lessThan|dFdx)\b`;
  - `test_doc_completion` still passes.
- GPU (pending when headless): render each noise at 4096 points through `VolumeExport.render_volume`-style compute (copy the pattern from `material_maker/plugins/volume_export/volume_export.gd:60-104` into the test). Compare with a GDScript port of the hash, value noise and fbm (64-bit ints masked with `& 0xFFFFFFFF`). Max abs difference < 1e-5 for value noise at seeds 0, 1, 12345, 16777215, including negative coordinates and points within 1e-4 of lattice planes.
- With `period=4` and scale 4: value at `p` equals value at `p+vec3(1,0,0)` within 1e-6.
- Gradient of `h = fbm` matches finite differences computed in the test within 1e-3.
- Full headless GUT run: no failures.

#### WP3. HLSL translator fixes and HLSL test toolbox (must-have 5, part 1). Size M.

**Goal**: remove known translator breakages for 3D code and provide the dxc tooling later WPs call.

**Files (modify)**
- `addons/material_maker/engine/nodes/gen_material.gd`: only `process_option_hlsl_base`.
- `addons/material_maker/nodes/hlsl_defs.tmpl`.

**Files (create)**
- `test/hlsl_tools.gd`: `class_name MMTestHlsl`, a static helper, not a test.
- `test/test_hlsl_translation.gd`.

**Spec**
- In `process_option_hlsl_base`, add before the existing `vec` replacements:
  - `uvec2/3/4(` to `touint2/3/4(` and `uvec2/3/4` to `uint2/3/4`. This must run before the `vec` rules so `uvec3(` is no longer mangled.
  - `mat3(` to `tofloat3x3(`, `mat3` to `float3x3`, `mat4(` to `tofloat4x4(`, `mat4` to `float4x4`.
  - `inversesqrt(` to `rsqrt(`.

  Do not change the existing replacements or their order otherwise.
- In `hlsl_defs.tmpl`:
  - Replace `#define hlsl_atan(x,y) atan2(x, y)` with overloaded inline functions: `hlsl_atan(float y, float x)` returning `atan2(y, x)`; `hlsl_atan(float x)` returning `atan(x)`; float2/float3/float4 versions of both.

    **Careful**: the text of the template is not itself passed through the `atan` replacement, but verify that. If it is, name the inner calls so they survive.
  - Add `touint2/3/4` constructors mirroring `toint*`.
  - Add `tofloat3x3(float3, float3, float3)` and the 9-scalar form, transposed so that GLSL column-major construction is preserved. Add `tofloat4x4` likewise.
- `MMTestHlsl`:
  - `static func find_tool(name) -> String`: look in `OS.get_environment("VULKAN_SDK")+"/Bin"`, then PATH through `where`.
  - `static func compile_hlsl(source_path, profile := "ps_6_0", entry := "main", hv := "2021", extra := []) -> Dictionary {ok, output}` running `dxc -T <profile> -E <entry> -HV <hv> ...`.
  - `static func compile_to_spirv(source_path, out_path, entry := "main") -> Dictionary` running `dxc -T cs_6_0 -E main -spirv -fspv-target-env=vulkan1.1 -fvk-use-dx-layout`.
  - `static func wrap_custom_node(shader_text : String, inputs : Array, outputs : Array) -> String`: emulates UE's wrapper: a function whose body is the `.shader` text, with typed parameters, plus a trivial pixel-shader `main` that calls it.
  - `static func run_spirv_compute(spv_path, input_floats : PackedFloat32Array, uniform_floats : PackedFloat32Array, output_float_count : int) -> PackedFloat32Array`:
    - uses `RenderingServer.create_local_rendering_device()`, `RDShaderSPIRV.bytecode_compute`, `shader_create_from_spirv`;
    - storage buffers at set 0, binding 0 (in) and 1 (out), uniform buffer at binding 2;
    - dispatches `ceil(n/64)` groups; reads back with `buffer_get_data`;
    - returns an empty array when the device or shader is unavailable.
    - If Godot rejects DXC's SPIR-V, fall back inside this function: `spirv-cross --version 450 --vulkan-semantics <spv>` to GLSL, then `rd.shader_compile_spirv_from_source`.

**Dependencies**: none.

**Acceptance** (`test/test_hlsl_translation.gd`, headless)
- Unit:
  - `process_option_hlsl_base("uvec3 a = uvec3(1u); mat3 m = mat3(a, b, c); float t = atan(x); float u = atan(y, x);")` contains `uint3 a = touint3(`, `float3x3 m = tofloat3x3(`, `hlsl_atan(x)`, `hlsl_atan(y, x)`, and does not contain `utofloat3`.
- Regression:
  - For a fixed list of existing nodes (`perlin`, `bricks`, `tex3d_fbm`, `tex3d_rotate`, `voronoi`), the translated code text before and after this WP is identical. Capture "before" by calling a private copy of the old replacement list kept inside the test.
- dxc (pending if `find_tool("dxc") == ""`):
  - Build a `material` graph with `tex3d_math` (atan op) feeding a `tex3d_apply`-free path, or simply a hand-written GLSL snippet using `atan(x)`, `mat3`, `uvec3`. Translate it, prefix it with `process_option_hlsl_base("", true)` definitions, wrap, and check `compile_hlsl` succeeds with `-HV 2018` and `-HV 2021`.
  - The export of `material_maker/examples/` (any one small `.ptex` using the existing "Unreal/Unreal Engine 5 Shader" target through `MMGenMaterial.process_export_shader`) compiles after `wrap_custom_node`.
- Full headless GUT run: no failures.

#### WP4. JSON parameter schema (should-have 8). Size S.

**Files (create)**
- `material_maker/plugins/param_schema/plugin.cfg` (`cli_modes=["--param-schema"]`, `script="plugin.gd"`), `plugin.gd`, `param_schema.gd`.
- `test/test_param_schema.gd`.

**Spec**
- `MMParamSchema.build(graph : MMGenGraph) -> Dictionary`:
  ```
  { "format": "mm-param-schema", "version": 1, "graph": <name>,
    "material": { "type": <material template name>, "inputs": [{name, type, connected}] },
    "voxel_inputs": [ {name:"seed", parameter:"<node>:vox_seed", type:"float", min, max, step, default}, ... ],
    "remotes": [ {name, label, type, min, max, step, default, values?, linked:["node:param", ...]} ],
    "parameters": [ {node, node_type, name, label, type, min, max, step, default, value, values?} ] }
  ```
  - Types are MM parameter types (`float`, `size`, `enum`, `boolean`, `color`, `gradient`, `curve`, ...).
  - Colours are `[r,g,b,a]`; enums list `values` as `[{name, value}]`.
  - Other objects go through `MMType.serialize_value`.
  - Sort keys and list nodes in tree order so output is deterministic.
  - Remotes come from `MMGenRemote.widgets`; see `MMCliTools.list_parameters` in `material_maker/cli/cli_tools.gd:174`.
- CLI: `--param-schema [-o dir] <files>` writes `<input>.schema.json` per graph through `cli.process_graph_files`, following the `export_mode` pattern in `material_maker/plugins/volume_export/plugin.gd:83`. No rendering.
- RPC method `param_schema` returns the dictionary. The Python client reaches it as `mm.param_schema()` through the existing `__getattr__`; no client edit.

**Dependencies**: none. The `voxel_inputs` section is filled by scanning for nodes of type `voxel_inputs` and is empty if there are none.

**Acceptance**
- GUT headless: build a graph with a `perlin` node, a `remote` linked to its scale, and a `material`; assert schema fields, ranges and determinism (two calls give equal JSON strings).
- CLI: `<godot> --path . -- --param-schema -o <tmp> material_maker/examples/<any>.ptex` prints `Exported ...schema.json`; `python -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['format']=='mm-param-schema'" <file>` exits 0.

#### WP5. Cost readout and parity lint (should-have 10a). Size M.

**Files (create)**
- `material_maker/plugins/graph_cost/plugin.cfg` (`cli_modes=["--graph-cost"]`), `plugin.gd`, `graph_cost.gd`.
- `test/test_graph_cost.gd`.

**Spec**
- `MMGraphCost.estimate_glsl(code : String, entry : String = "") -> Dictionary`. Static text analysis:
  - Strip comments. Split into functions; use `MMGenBase.split_glsl` if suitable.
  - Per function body, count weighted tokens:
    - `+ - * /` and comparisons: 1 each;
    - cheap builtins (`floor fract abs min max clamp mix step dot cross length normalize smoothstep sqrt`): 2 to 6 by a small table;
    - transcendental (`sin cos tan atan pow exp log`): 8;
    - `texture`/`textureLod`: 20, also counted separately as `texture_samples`.
  - A `for` loop with a parsable constant bound multiplies its body by the trip count; unknown bounds multiply by 4 and are flagged.
  - User function calls add the callee's cost (memoised; recursion guarded).
  - Return `{instructions, texture_samples, functions, loops_unbounded, by_function:{...}}`.
- `MMGraphCost.estimate_output(generator, output_index)`: `get_shader_code` for the output's type params, then `estimate_glsl(globals + defs + "float mm_entry() {" + code + "}")`.
- `MMGraphCost.estimate_material(material)`: sum over connected inputs' sources. Works for any material type.
- `MMGraphCost.lint_parity(code) -> PackedStringArray`: warnings when the code contains sin-hash helpers (`rand(`, `rand2(`, `rand3(`, `rand31(`, `rand33(`, `sin(dot(`) or tokens outside the HLSL-safe subset.
- CLI: `--graph-cost [--node <node[:output]>] <files>` prints one JSON object per file to stdout (`{"file":..., "instructions":..., ...,"parity_warnings":[...]}`). No rendering.
- RPC `graph_cost {node?, output?}`.
- Menu item "Plugins > Show shader cost" using `mm_globals.set_tip_text("Material: ~N instructions, T texture samples")`.
- The docs string in `--help` usage says this is a relative estimate, not UE's count.

**Dependencies**: none.

**Acceptance**
- GUT headless:
  - a hand-written GLSL string with a 4-iteration loop calling a function of known weight gives the exact expected number;
  - cost of `perlin` with `iterations` 6 is greater than with 3;
  - the lint flags `tex3d_fbm` and returns empty for a plain `uniform` node.
- CLI command prints parseable JSON with `instructions > 0`.

#### WP6. Volume bake extensions (should-have 7a). Size M.

**Files (modify)**
- `material_maker/plugins/volume_export/volume_export.gd`
- `material_maker/plugins/volume_export/plugin.gd`
- `material_maker/plugins/volume_export/plugin.cfg` (description only)

**Files (create)**
- `test/test_volume_export_formats.gd`.

**Spec**
- New texel formats in `TEXEL_FORMATS`: `r8` (DXGI 61), `rg8` (49), `r16` (56), `rg16` (35), all unorm. Quantise manually from `Volume.get_channel()` (`round(clamp(v,0,1)*255 or 65535)`, little-endian); do not depend on Godot `Image` 16-bit formats. If KTX2 does not support these, return a clear error for ktx2 only.
- New `--format` values:
  - `raw`: `<name>.raw`, texels x fastest, then y, then z, plus `<name>.raw.json` with `{resolution, texel_format, channels, extent, origin, order:"xyz"}`.
  - `slices`: `<name>_z<0000>.png` for 8-bit formats, `.exr` for float.
- New option `--volume-origin center|corner` (default center = current behaviour). Corner samples `[0, extent]^3` so a noise with `period` set tiles exactly. Thread an `origin` argument through `render_volume` and `export_volume` with the default preserving current behaviour; the RPC method gets `origin` too.
- New option `--check-tileable`: renders a second volume offset by `extent` along each axis and fails with an error if max abs difference > 1/255.
- Determinism: no timestamps or random ids in raw/slices/dds output.

**Dependencies**: none (the tileable acceptance graph uses the existing `tex3d_fbm`, which wraps).

**Acceptance**
- GUT headless: `get_texel_data` for a synthetic `Volume` (hand-built 8x8 atlas image) in `r8`/`rg16` yields expected bytes; the DDS header has the right DXGI code and size.
- CLI (GPU), run twice and compare hashes:
  `<godot> --path . -- --export-volume --node <fbm node> --voxels 64 --format raw --texel-format rg16 --volume-origin corner --check-tileable -o <tmp> <test graph .ptex with one tex3d_fbm>`
  Expected: `Exported ...raw`, file size 64*64*64*4 bytes, identical SHA-256 across the two runs.

---

### Wave 2 (parallel: WP7, WP8, WP9, WP13)

#### WP7. UE5 voxel export target (must-have 1, 2, 3 export side). Size L.

**Goal**: "Unreal/Unreal Engine 5 Voxel" export for `material_voxel`: an HLSL Custom node body with voxel inputs, and a setup script.

**Files (create)**
- `material_maker/plugins/voxel/export_targets/material_export_Unreal_Unreal Engine 5 Voxel.mme`. JSON, LF. `"material": "material_voxel"`, `"name": "Unreal/Unreal Engine 5 Voxel"`, `"export_extension": "py"`, `"custom": <GDScript>`. Files: `$(path_prefix).py` (template), `$(path_prefix)_texture_$(buffer_index).exr` (buffers), `$(path_prefix).shader` (template), clipboard. Copy the structure from the existing UE5 `.mme`.
- `test/test_voxel_export.gd`.
- `test/voxel_unreal_stub.py`: a recording fake `unreal` module, used by this WP and WP11.

**Spec, `.shader` template** (tabs; replace the existing template's signature and body):
```
struct Functions {
	float Time;
	float vox_seed; float vox_age; float vox_upkeep; float vox_fresh; float vox_char; float vox_wet; float vox_footprint;
	float3 vox_axis; float3 vox_origin;
$begin_buffers
	Texture2D texture_$(buffer_index);
	SamplerState texture_$(buffer_index)Sampler;
$end_buffers

$definitions hlsl_base,rename_buffers,unreal5,sample_level_0,voxel_inputs
	float4 generated_shader(float3 p, float3 n, float _time,
$begin_buffers
							Texture2D _texture_$(buffer_index), SamplerState _texture_$(buffer_index)Sampler,
$end_buffers
							out float metallic, out float roughness, out float3 normal, out float3 emission, out float occlusion, out float opacity) {
		float _seed_variation_ = 0.0;
		float4 _controlled_variation_ = float4(n, 0.0);
		Time = _time;
$begin_buffers
		texture_$(buffer_index) = _texture_$(buffer_index);
		texture_$(buffer_index)Sampler = _texture_$(buffer_index)Sampler;
$end_buffers
$begin_generate hlsl_base,rename_buffers,unreal5,sample_level_0,voxel_inputs
		float4 mm_q = float4(p, 0.0);
		float3 mm_alb = $albedo_tex(mm_q);
$if not $(param:linear_albedo)
		mm_alb = lerp(pow((mm_alb+float3(0.055, 0.055, 0.055))/1.055, float3(2.4, 2.4, 2.4)), mm_alb/12.92, float3(mm_alb < float3(0.04045, 0.04045, 0.04045)));
$fi
		float4 rv = float4(mm_alb*$albedo_color.rgb, 1.0);
		metallic = $metallic*$metallic_tex(mm_q);
		roughness = $roughness*$roughness_tex(mm_q);
		float3 mm_g = $bump_tex(mm_q);
		normal = normalize(n - $bump*(mm_g - n*dot(mm_g, n)));
		emission = $emission_tex(mm_q)*$emission_energy;
		occlusion = lerp(1.0, $ao_tex(mm_q), $ao);
		opacity = $opacity_tex(mm_q);
		return rv;
$end_generate
	}
};
Functions f;
f.vox_seed = Seed; f.vox_age = Age; f.vox_upkeep = Upkeep; f.vox_fresh = Fresh; f.vox_char = Char; f.vox_wet = Wet; f.vox_footprint = Footprint;
f.vox_axis = Axis; f.vox_origin = Origin;
float4 albedo = f.generated_shader(Position, normalize(Normal), Time,
$begin_buffers
								   texture_$(buffer_index), texture_$(buffer_index)Sampler,
$end_buffers
								   metallic, roughness, normal, emission, occlusion, opacity);
return albedo;
```
- Check how `$if` handles `not` (conditions go through Godot `Expression`; `not true` parses).
- The vector comparison in the sRGB line needs `select()` under HLSL 2021 only if written as a ternary; the `lerp(..., float3(a < b))` form used here is valid in both 2018 and 2021.

**Spec, `custom` script** (must not contain the substrings `OS`, `DirAccess`, `FileAccess`):

`func process_option_voxel_inputs(s : String, is_declaration : bool = false) -> String`
1. If `is_declaration`: delete the lines the `unreal5` filter produced for these uniforms: regex `(?m)^[ \t]*float[ \t]+p_o\d+_vox_\w+;[ \t]*\r?\n`.
2. Else: delete their initialisations: `(?m)^[ \t]*p_o\d+_vox_\w+[ \t]*=[^;]*;[ \t]*\r?\n`.
3. In both cases rewrite references: `\bp_o\d+_vox_axis_([xyz])\b` to `vox_axis.$1`, `\bp_o\d+_vox_origin_([xyz])\b` to `vox_origin.$1`, then `\bp_o\d+_vox_(seed|age|upkeep|fresh|char|wet|footprint)\b` to `vox_$1`.

**Spec, `.py` template** (self-contained helpers allowed; still imports `mm` as the existing template does). Marked **UNVERIFIED in Unreal** in a header comment.
- Creates material `$(file_prefix)`.
- Custom node:
  - `inputs = [mm.custom_input(n) for n in ['Position','Normal','Seed','Age','Upkeep','Fresh','Char','Wet','Axis','Origin','Footprint','Time']]` plus textures;
  - the same additional outputs as the existing template.
- Graph:
  - `WorldPosition` to `TransformPosition` (World to Local) to `Multiply` by 0.01 to `Position`.
  - `VertexNormalWS` to `Transform` (World to Local) to `Normal`.
  - `ScalarParameter` nodes Seed/Age/Upkeep/Fresh/Char/Wet/Footprint with defaults `$(param:...)`. These are parameters of the Voxel Inputs node, not the material, so `$(param:)` does not see them: either hardcode 0 and note that values are set per instance in UE, or extend the custom script with a second option that injects them. Choose hardcoded 0, 0, 0, 0, 0, 0, 0, and Axis (1,0,0), Origin (0,0,0) as `VectorParameter`.
  - Normal output to `Transform` (Local to World) to `MP_NORMAL`, with `mat.set_editor_property('tangent_space_normal', False)`.

**Dependencies**: WP1 (material and inputs nodes), WP2 (noise nodes for the test graph), WP3 (`MMTestHlsl`).

**Acceptance** (`test/test_voxel_export.gd`)
- Headless (text): build graph G = {`voxel_inputs`, `tex3d_noise_fbm` (seed from Inputs:2), `tex3d_gradient`, `material_voxel` with albedo from fbm, bump from gradient, roughness from Inputs:3 (Age)}. Load the target with `MMPlugins.load_export_targets("res://material_maker/plugins/voxel/export_targets")`. Call `material.export_material(<user:// prefix>, "Unreal/Unreal Engine 5 Voxel", 0, true)`. Assert the `.shader` file:
  - contains `float3 p, float3 n`, `f.vox_seed = Seed;`, `vox_age` inside `generated_shader`;
  - matches no `p_o\d+_vox_`;
  - contains none of `\bvec[234]\b`, `\bmix\(`, `\bfract\(`, `uniform `, `$`.
- dxc (pending without dxc; works headless): `MMTestHlsl.wrap_custom_node(shader, inputs, outputs)` compiles as `ps_6_0` under `-HV 2018` and `-HV 2021`.
- The same graph plus a `buffer`-free check that a second Voxel Inputs node exports to the same members.
- Stub: `python test/voxel_unreal_stub.py <exported .py>` (the stub registers a fake `unreal` and `mm`, execs the script, and asserts that a Custom expression received 12 or more inputs named as in the contract and that MP_NORMAL was connected). Expected output `OK`.
- Manual, reported as not done here: run the `.py` in UE5.

#### WP8. Point evaluation: engine, CLI, RPC, Python (should-have 6). Size L.

**Files (create)**
- `material_maker/plugins/voxel_eval/plugin.cfg` (`depends=["voxel"]`, `cli_modes=["--evaluate-points"]`), `plugin.gd`, `voxel_eval.gd` (`MMVoxelEval`), `npy.gd` (`MMNpy`).
- `python/material_maker_client/voxel.py`.
- `python/tests/test_voxel_eval_npy.py` (offline `.npy` round-trip only).
- `python/examples/voxel_evaluate.py`.
- `test/test_voxel_eval.gd`.

**Spec**
- `MMNpy.load(path) -> Dictionary {shape:Array, data:PackedFloat32Array}` and `MMNpy.save(path, shape, data)`. NumPy `.npy` v1.0, `'<f4'`, C order only; error on others.
- `MMVoxelEval.evaluate(generator : MMGenBase, output_index : int, points : PackedFloat32Array (N*3), normals : PackedFloat32Array (N*3 or empty), fresh : PackedFloat32Array (N or empty)) -> PackedFloat32Array` (N*4, RGBA of that output). Follows `VolumeExport.render_volume`:
  - Pack points into an RGBA32F image `W = min(N, 2048)`, `H = ceil(N/W)` as `(x, y, z, fresh)`, and normals into a second image `(nx, ny, nz, 0)`. Wrap them in `MMTexture`s; see how `gen_image.gd` or `MMTexture.set_texture` builds one from an `Image`.
  - `source = generator.get_shader_code("mm_eval_p(uv)", output_index, MMGenContext.new())`.
  - Prepend `source.defs` with `vec4 mm_eval_p(vec2 uv) { return vec4(texture(mm_eval_points, uv).xyz, 0.0); }`.
  - Prepend `source.code` with `_controlled_variation_ = vec4(texture(mm_eval_normals, uv).xyz, texture(mm_eval_points, uv).w);\n`. `buffer_compute.tres` declares `_controlled_variation_` before `@CODE`, so this assignment is legal.
  - Add the two textures through `extra_parameters` (`{name, type="sampler2D", value=<MMTexture>}`) of `set_shader_from_shadercode(source, true, extra)`.
  - `source.output_values = {rgba = ...}` by output type, as `render_volume` does (tex3d to `vec4(v, 1.0)`, tex3d_gs to `vec4(vec3(v), 1.0)`, rgb/rgba/f handled too).
  - `render_ext([texture], Vector2i(W, H))`. Read back, convert to `FORMAT_RGBAF`, return the first N texels.
  - Sampling must be exact: uv at texel centres. Check that the pipeline's sampler does not wrap or filter across texels; if filtering is linear, texel centres still return exact values.
  - Wait for buffers first, as `render_volume` does.
- `MMVoxelEval.evaluate_material(material, points, normals, fresh) -> Dictionary`: evaluates hidden outputs 0..4 of `material_voxel` (`get_output_defs(true)`). Returns `{base_color:N*3, orm:N*3, emission:N*3, normal:N*3, opacity:N}`.
- Parameters (`params`) are applied before evaluation with `MMCliTools.apply_overrides`/`set_parameter_by_name` (names like `In:vox_seed`, or the short forms `seed`, `age`, ... which resolve to every `voxel_inputs` node).
- RPC `evaluate_points {points: <npy path>, normals?: <npy path>, fresh?: <npy path>, node?: "name[:output]", params?: {..}, output: <npy path or prefix>}`. With `node`, writes one `(N,4)` array; without, writes `<prefix>_base_color.npy` and so on. Returns the list of files.
- CLI: `--evaluate-points --points p.npy [--normals n.npy] [--fresh f.npy] [--node N] [--set ...] -o dir <file.ptex>`. Same outputs, named `<input>_<what>.npy`.
- Python `voxel.py`: `evaluate(mm, points, normals=None, fresh=None, params=None, node=None, workdir=None) -> dict[str, np.ndarray] | np.ndarray`. Writes float32 `.npy` into a temp dir, calls `mm.call("evaluate_points", ...)`, loads the results. Also `class VoxelGraph` with `evaluate(points, normals, params)` matching the wishlist signature. Document that base colour is linear.

**Dependencies**: WP1 (hidden outputs), WP2 (test graph).

**Acceptance**
- `python -m pytest python/tests/test_voxel_eval_npy.py`: numpy round-trip of the header writer/reader logic used by `voxel.py`.
- `test/test_voxel_eval.gd`:
  - headless: `MMNpy` save/load round-trip (shape, values); malformed header rejected.
  - GPU: graph with `voxel_inputs` to material (albedo = Inputs Normal, `linear_albedo` true; roughness = Inputs Fresh). Evaluate 5000 points with given normals and fresh. Assert base_color equals normals within 1e-6 and orm.g equals fresh within 1e-6 (proves per-point normal and fresh plumbing, and exact texel fetch for N > 2048). Value noise at points equals the GDScript reference within 1e-5.
- CLI: `<godot> --path . -- --evaluate-points --points <tmp>/p.npy --node In:0 -o <tmp> <graph.ptex>`, then `python -c` loads the result and asserts it equals `p` within 1e-6.
- End to end, manual, one process: `python python/examples/voxel_evaluate.py` launches MM through `material_maker_client.launch`, evaluates 10k points, prints `max |err| < 1e-5`.

#### WP9. 3D Buffer node (should-have 10b). Size M.

**Goal**: trade a heavy tex3d sub-graph for a baked lookup, with no engine change.

**Files (create)** in `addons/material_maker/nodes/`
- `tex3d_to_atlas.mmg` (shader: tex3d in, rgb/rgba out)
- `tex3d_from_atlas.mmg` (shader: rgba in, tex3d out)
- `tex3d_buffer.mmg` (`"type": "graph"`, containing `tex3d_to_atlas`, a `buffer`, `tex3d_from_atlas`, `gen_inputs`, `gen_outputs`, `gen_parameters`; copy the structure of `fast_blur.mmg`)
- `material_maker/doc/node_3d_texture_buffer.rst`
- `test/test_tex3d_buffer.gd`

**Files (modify)**
- `material_maker/library/base.json`: item `3D/Texture/Buffer`, type `tex3d_buffer`.
- `material_maker/doc/node_3d_texture.rst`: toctree.

**Spec**
- Atlas layouts (square, power of two, T x T tiles of R x R, depth D = T*T). Enum `layout`: `64^3` (512, T=8), `128x128x64` (1024, T=8), `128x128x256` (2048, T=16), `256^3` (4096, T=16).
- Parameters (remote): `layout`, `extent` (metres covered, default 1; the volume is periodic with this period), `mode` (Baked / Direct).
- `tex3d_to_atlas`: for atlas uv, tile `(cx, cy) = floor(uv*T)`, slice `z = cy*T+cx`, local `l = fract(uv*T)`. Sample position `p = vec3(l, (z+0.5)/D)*extent`. Output `$in(vec4(p, 0.0))`.
- `tex3d_from_atlas`:
  - `q = fract(p/extent)`; `zf = q.z*D - 0.5`; `z0 = floor(zf)`, `t = zf - z0`.
  - For each of the two slices (wrapped modulo D), tile uv = `(vec2(mod(zi, T), floor(zi/T)) + clamp(q.xy, 0.5/R, 1.0-0.5/R))/T`.
  - Result = mix of two `$in(uv)` lookups. Clamping to half a texel prevents bleeding between tiles; the cost is no wrap filtering in x and y at the border. Document it.
  - Mode Direct replaces the output expression by the direct tex3d input through an enum whose values are the two code strings (pattern: the `mode` enum of `tex3d_warp.mmg`).
- The doc states: bakes lose normal and fresh context (cv = 0); the input should be periodic with period `extent` (use the noise nodes' `period`) or seams show at the volume border.

**Dependencies**: none in code. Base-library ownership passes from WP2 (wave 1) to this WP in wave 2.

**Acceptance** (`test/test_tex3d_buffer.gd`)
- Headless: the node instantiates; generated code for Baked contains a `texture`/sampler uniform; Direct contains none.
- GPU: input = `tex3d_noise_value` with `period` equal to scale x extent. Evaluate the 3D Buffer output and the direct noise at 2000 random points with a compute pass (copy the WP2 test helper). Mean abs difference < 0.01 for `128x128x256` at noise scale 4; exact equality (< 1e-3) at slice-centre, texel-centre points.
- CLI smoke: `--export-material --target "Unreal/Unreal Engine 5 Voxel"` is not required here (WP7 runs in parallel). Instead: `--render --node <a tex3d_apply-free rgb node>` is not applicable. Skip CLI. The full headless GUT run stays green.

#### WP13. Wood recipe node (nice-to-have 11, and the basis of the first test). Size L.

**Files (create)**
- `material_maker/plugins/voxel/nodes/voxel_wood.mmg` (`"includes": ["mm_noise3d"]`)
- `material_maker/doc/node_3d_voxel_wood.rst`
- `test/test_voxel_wood.gd`

**Files (modify)** (this WP owns them in wave 2)
- `material_maker/plugins/voxel/library.json`: item `3D/Voxel/Wood`.
- `material_maker/doc/node_3d_voxel.rst`: toctree.

**Spec**: a line-by-line GLSL port of `wood()` in `C:\Users\richa\workspace_local\zcity\ZCity\Tools\voxkit\appearance.py` (lines 122-205), without the paint loop and `moulding`.
- **Inputs** (all tex3d_gs unless noted, defaults in brackets):
  `seed_in` [0.0]; `normal_in` (tex3d) [`vec3(0.0)`]; `axis_in` (tex3d) [`vec3(1.0, 0.0, 0.0)`]; `origin_in` (tex3d) [`vec3(0.0)`]; `age_in` [0.1]; `fresh_in` [0.0]; `footprint_in` [0.0].
- **Parameters**:

  | Parameter | Default (the voxkit value) |
  |---|---|
  | `units_per_metre` | 81 |
  | `ring_width_mm` | 5 |
  | `early` (color) | sRGB 146, 110, 76 |
  | `late` (color) | sRGB 84, 58, 40 |
  | `aged_colour` (color) | 106, 84, 62 |
  | `aged_hides` | 0.55 |
  | `ring_porous` (boolean) | true |
  | `flow_amount` | 7.0 |
  | `flow_scale` | 0.014 |
  | `pith_wander` | 4.0 |
  | `ripple_amount` | 0.7 |
  | `ray_strength` | 0.40 |
  | `pore_strength` | 0.55 |
  | `check_strength` | 0.7 |
  | `bump_strength` | 0.08 |

  Every other constant stays literal as in the Python.
- **Frame**:
  - `q = ($uv.xyz - origin)*units_per_metre`.
  - Axis frame: pick `(e_u, e_v)` by the dominant axis component: X gives (Y, Z); Y gives (X, Z); Z gives (X, Y).
  - `b1 = normalize(e_u - a*dot(e_u, a))`; `b2 = normalize(e_v - a*dot(e_v, a) - b1*dot(e_v, b1))`.
  - `s = dot(q, a)`, `u0 = dot(q, b1)`, `v0 = dot(q, b2)`.
  - voxkit's absolute `pith` becomes `origin`.
  - `rw = ring_width_mm*units_per_metre/1000` (voxkit: `ring_mm/12.346`).
  - `side = pow(1.0 - abs(dot(n, a)), 2.0)`; when `normal_in` is the zero vector use `side = 1`.
  - `ag = 1 - fresh` (voxkit `fw` with the aged finish everywhere); `age = age_in*ag + 0.10*(1-ag)`.
  - `fp = footprint*units_per_metre`.
- Colours are converted from the pickers (sRGB) to linear with the exact piecewise sRGB function; all maths is in linear.
- Seed offsets (`seed+20`, `+21`, `+1`, `+2`, `+22`, `+3`, `+13`, `+14`, `+4`, `+15`, `+5`, `+16`, `+6`, `+7`, `+30`, `+8`, `+9`, `+10`, `+12`) and all scales are copied verbatim.
- `hash3(yr, 3, 4, seed)` becomes `mm_n3_hash(int(yr), 3, 4, s)`.
- **Outputs**:

  | Index | Name | Type | Value |
  |---|---|---|---|
  | 0 | Albedo | tex3d | linear base colour |
  | 1 | Bump | tex3d | gradient vector already multiplied by `k = bump_strength + 0.05*ag*side`, converted to per-metre: instance function `$(name)_h(vec3 q, ...)` = the Python `hf`, forward differences with eps 0.06 in recipe units, result `k*g_recipe` scaled so the material with `bump = 1` reproduces voxkit's `nb` |
  | 2 | Roughness | tex3d_gs | `0.75 - 0.25*ray` |
  | 3 | Spec | tex3d_gs | voxkit `0.05 + 0.10*ray` |
  | 4 | Power | tex3d_gs | `20.0` |

  Since `nb = normalize(n - k*g)` is evaluated in the material on the gradient vector alone, output 1 = `k*g` with `g` in voxkit's per-voxel units; no further scaling is needed. State this in the doc.
- Follow the HLSL-safe subset (`atan(v, u)` two-argument only).

**Dependencies**: WP1 and WP2 by reference at design time; the node includes `mm_noise3d` and reads Voxel Inputs through its input ports.

**Acceptance** (`test/test_voxel_wood.gd`)
- Headless: the node instantiates; every output generates code without `$`; the forbidden-token regex is clean; cost lint (if WP5 is merged) returns no parity warnings.
- GPU: evaluate output 0 with a compute pass at 2000 points on a 14 x 14 x 80 voxel beam surface (`units_per_metre = 81`, origin = pith `(0, 14*0.36, 14*0.63)/81`). Assert: all finite; in [0,1]; mean colour within 0.05 of `(0.20, 0.12, 0.07)`. This is a loose sanity bound; the strict comparison with Python is WP16.
- Full headless GUT: no failures.

---

### Wave 3 (parallel: WP10, WP11, WP12, WP14)

#### WP10. GLSL versus exported-HLSL parity test (must-have 5). Size M.

**Files (create)**
- `test/test_voxel_hlsl_parity.gd`
- `test/voxel_parity_harness.hlsl.txt` (harness template with `@SHADER@` and `@INPUTS@` markers; `.txt` so Godot does not import it)

**Method**
1. Build each test graph in memory (`mm_loader.create_gen`), with fixed Voxel Inputs values.
2. GLSL side: `MMVoxelEval.evaluate_material(material, points, normals, fresh)` (WP8). This is the same generated GLSL the previews use, run as a compute shader.
3. HLSL side:
   - Export with "Unreal/Unreal Engine 5 Voxel" to `user://`; read `<prefix>.shader`.
   - Fill the harness:
     - `float4 mm_custom(float3 Position, float3 Normal, float Seed, float Age, float Upkeep, float Fresh, float Char, float Wet, float3 Axis, float3 Origin, float Footprint, float Time, out float metallic, out float roughness, out float3 normal, out float3 emission, out float occlusion, out float opacity) { @SHADER@ }`
     - `[[vk::binding(0,0)]] StructuredBuffer<float4> In;` (2 per point: `(p, fresh)`, `(n, 0)`)
     - `[[vk::binding(1,0)]] RWStructuredBuffer<float4> Out;` (4 per point: base colour, ORM, emission, normal + opacity)
     - `[[vk::binding(2,0)]] cbuffer Things { ... }`
     - `[numthreads(64,1,1)] void main(uint3 id : SV_DispatchThreadID)`.

     Per-point fresh is passed as the `Fresh` argument with the node's `vox_fresh` at 0, matching the GLSL side's `.w`.
   - `MMTestHlsl.compile_to_spirv`, then `MMTestHlsl.run_spirv_compute`.
4. Compare per channel.

**Graphs**
- P1: value noise to albedo (linear), seeds 0 / 1 / 12345 / 16777215.
- P2: fbm (Perlin basis) + Voronoi (all 4 outputs mixed) + domain warp + gradient bump.
- P3: every Voxel Inputs output wired into some channel (axis, origin, age, upkeep, char, wet, footprint, normal, fresh).
- P4: existing non-hash tex3d nodes (`tex3d_rotate`, `tex3d_math`, `tex3d_blend`, `tex3d_colorize` with a gradient, `tex3d_tones_step`).
- P5: `voxel_wood` (WP13) with defaults.
- P6, informational: legacy `tex3d_fbm` (sin hash). Assert only that it compiles and report the max difference with `gut.p()`; do not assert equality.

**Points**: 4096 per graph = uniform random in [-2,2]^3 (fixed seed), plus points within 1e-4 of integer lattice planes after scaling, plus negative coordinates, plus random unit normals and fresh in [0,1].

**Tolerances**
- Scalar noise outputs: max abs < 1e-4.
- Final colours and ORM: max abs < 2e-3 (under 1/255) and 99.9th percentile < 5e-4.
- Normal: max angle < 0.1 degree.
- If a tolerance fails only at isolated points next to a `floor()` discontinuity, report the count and fail only when more than 0.1% of points exceed it.

**Tiers and what each proves**
- T0 (always, headless): token blacklist on the exported text (from WP7's test; re-run on P1-P5).
- T1 (needs dxc, headless OK): P1-P6 compile as `ps_6_0` with `-HV 2018` and `-HV 2021`.
- T2 (needs dxc and a GPU, run without `--headless`): the numeric comparison above. `pending()` when `RenderingServer.get_rendering_device() == null` or dxc is missing.

**Honest limits, to be written in the test file header and in the docs**
- Proven: the exporter's HLSL, compiled by DXC 1.8 (Vulkan SDK), computes the same values as the GLSL on this GPU.
- Not proven: Unreal's own shader pipeline (its DXC version and flags, FXC under SM5, half precision on mobile, UE's wrapper around Custom nodes); the Godot spatial-shader preview path (assumed equal to the compute GLSL, which comes from the same generator text); other GPUs; legacy sin-hash nodes.

**Dependencies**: WP3, WP7, WP8, WP2, WP13 (P5 can be `pending` if the node type is missing).

**Acceptance**
- `<godot> --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/test_voxel_hlsl_parity.gd -gexit` (no `--headless`): all P1-P5 asserts pass. Printed summary lines `P<n> max_abs=<x>`.
- Headless full run: T0 and T1 pass, T2 pending, no failures.

#### WP11. Material Function export and master material generator (should-have 9). Size L.

**Files (create)**
- `material_maker/plugins/voxel/export_targets/material_export_Unreal_Unreal Engine 5 Voxel Function.mme`. Same `custom` script as WP7's; copy it, do not share a file.
- `material_maker/plugins/voxel_master/plugin.cfg` (`depends=["voxel"]`, `cli_modes=["--voxel-master"]`), `plugin.gd`, `voxel_master.gd`.
- `test/test_voxel_master.gd`.

**Spec, function target** ("Unreal/Unreal Engine 5 Voxel Function"). Files:
- `$(path_prefix).voxel.hlsl`: `struct MMVoxRecipe { ...same members and generated_shader as WP7... };` only, with no trailing call. The struct name is the fixed placeholder `MMVoxRecipe`.
- `$(path_prefix)_texture_$(buffer_index).exr`.
- `$(path_prefix)_function.py`: creates a `MaterialFunction` asset `MF_$(file_prefix)`:
  - `unreal.MaterialFunctionFactoryNew`;
  - `MaterialEditingLibrary.create_material_expression_in_function` for a Custom node whose code = the struct text + the call;
  - `MaterialExpressionFunctionInput` per contract input (Vector3 for Position/Normal/Axis/Origin, Scalar otherwise);
  - `MaterialExpressionFunctionOutput` for BaseColor, Metallic, Roughness, Normal, Emissive, AmbientOcclusion, Opacity;
  - `update_material_function`.
  - Header comment: UNVERIFIED in Unreal.

**Spec, master generator**
`--voxel-master --master-config <json> -o <dir> <a.ptex> <b.ptex> ...`

Config:
```json
{ "name": "M_VoxelMaster",
  "ids": { "oak.ptex": 5, "brick.ptex": 2 },
  "id_source": "custom_primitive_data:0",
  "inputs": { "Seed": "custom_primitive_data:1", "Age": "custom_primitive_data:2", "Upkeep": "custom_primitive_data:3",
              "Fresh": "vertex_color:g", "Char": "custom_primitive_data:4", "Wet": "custom_primitive_data:5",
              "Axis": "custom_primitive_data:6", "Origin": "custom_primitive_data:9", "Footprint": "auto" },
  "position_scale": 0.01 }
```
`id_source` also accepts `vertex_color:r|g|b|a` (x255, rounded) and `uv<N>:x`.

For each graph (through `cli.process_graph_files`):
- Export with the Function target into a temp prefix.
- Read the `.voxel.hlsl`; rename `MMVoxRecipe` to `MMVox_<sanitised file name>`; rename `texture_<n>` to `tex_<name>_<n>`.

Emit:
- `<name>.shader`: all structs, then a dispatcher:
  ```hlsl
  int mm_id = int(MaterialId + 0.5);
  float4 mm_rv = float4(1.0, 0.0, 1.0, 1.0); /* magenta for unknown ids */
  metallic = 0.0; ...
  if (mm_id == 5) { MMVox_oak f; f.vox_seed = Seed; ...; mm_rv = f.generated_shader(...); }
  else if (mm_id == 2) { ... }
  return mm_rv;
  ```
  Real branches, so only one recipe runs per pixel. Do not use `switch` (FXC flattening issues).
- `<name>.py`: one Material with one Custom node (inputs = contract inputs + `MaterialId` + all textures), wired from the configured sources (`MaterialExpressionCustomPrimitiveData`, `VertexColor`, `TextureCoordinate`). Footprint `auto` = `length(ddx(Position)) + length(ddy(Position))` built with `DDX`/`DDY` expressions, or inside the Custom code. Same position, normal and output-normal wiring as WP7.
- `<name>.master.json`: ids, input mapping, per-recipe texture list.

**Dependencies**: WP7 (template and custom script to copy; `test/voxel_unreal_stub.py`), WP3 (`MMTestHlsl`).

**Acceptance** (`test/test_voxel_master.gd`)
- Headless: `MMVoxelMaster.combine([{name, id, hlsl}, ...], config)` on two synthetic struct texts yields a shader with two distinct struct names, no `MMVoxRecipe`, both ids in the dispatcher, and textures renamed.
- dxc: build two graphs in memory (value-noise albedo; Voronoi albedo); run export + combine; wrap as a Custom node with the extra `MaterialId` input; compiles as `ps_6_0` under `-HV 2018` and `-HV 2021`.
- CLI: `<godot> --path . -- --voxel-master --master-config <cfg> -o <tmp> <g1.ptex> <g2.ptex>` writes the three files; `python -m py_compile <tmp>/M_VoxelMaster.py` exits 0; `python test/voxel_unreal_stub.py <tmp>/M_VoxelMaster.py` prints `OK`.
- Reported as not verified: behaviour in Unreal.

#### WP12. Per-mesh 2D bake of a voxel material (should-have 7b). Size M.

**Files (create)**
- `material_maker/plugins/voxel_mesh_bake/plugin.cfg` (`depends=["voxel", "voxel_eval"]`, `cli_modes=["--bake-voxel-material"]`), `plugin.gd`, `voxel_mesh_bake.gd`.
- `test/test_voxel_mesh_bake.gd`.

**Spec**
- `--bake-voxel-material --mesh <mesh.obj|glb> [--size 1024] [--set ...] [--format png|exr] -o dir <graph.ptex>`
  1. Bake the mesh's `position` and `normal` maps at `--size` with the existing baker (`MMCliTools.bake`, `material_maker/cli/cli_tools.gd:379`, or the map renderer it calls). Keep them in memory, or in a temp dir under `user://`.
  2. **Find out how the position map is normalised** (read the map renderer and `gen_meshmap.gd`; it is expected to be relative to the mesh AABB) and undo it, so that positions are object-space units x `--unit-scale` (default 1.0, metres per mesh unit). Decode the normal map from `0..1` to `-1..1` if encoded.
  3. Run the material's hidden outputs through a variant of `MMVoxelEval` that takes the two maps as textures directly: add `MMVoxelEval.evaluate_textures(generator, output_index, position_tex, normal_tex, size, position_scale, position_offset)` in this plugin's own file by composing the same shader pieces. Do not modify `voxel_eval.gd`; duplicate the 20 lines if needed.
  4. Write `<graph>_<mesh>_basecolor.png` (sRGB-encoded), `_orm.png`, `_normal_object.png` (encoded `0.5+0.5*n`), `_emission.png`, `_opacity.png`. Texels outside UV islands (position-map alpha 0) are transparent; then dilate by 4 px if the baker offers dilation.
- RPC `bake_voxel_material {mesh, size, prefix}`.
- Deterministic: same inputs give identical files.

**Dependencies**: WP8, WP1.

**Acceptance**
- GUT GPU test: a unit-cube mesh built in code with UVs (or Godot's `BoxMesh` if the baker accepts a `Mesh`); graph with albedo = Voxel Inputs Position (linear), so the baked base colour at a texel equals its object-space position. Assert max error < 2/255 on island interiors; normal map equals the face normal.
- CLI: run the command on a small OBJ written by the test into `user://`. Expected `Exported ..._basecolor.png` and 4 more lines. Run twice; identical SHA-256.

#### WP14. Palette, weathering, char, wetness, paint nodes (nice-to-have 11, rest). Size M.

**Files (create)** in `material_maker/plugins/voxel/nodes/`
- `voxel_palette_pick.mmg`, `voxel_weathering.mmg`, `voxel_char.mmg`, `voxel_wetness.mmg`, `voxel_paint.mmg`
- Docs: `node_3d_voxel_palette_pick.rst`, `node_3d_voxel_weathering.rst`, `node_3d_voxel_char.rst`, `node_3d_voxel_wetness.rst`, `node_3d_voxel_paint.rst`
- `test/test_voxel_recipes.gd`

**Files (modify)** (owner in wave 3)
- `material_maker/plugins/voxel/library.json`: tree items `3D/Voxel/Palette Pick`, `3D/Voxel/Weathering`, `3D/Voxel/Char`, `3D/Voxel/Wetness`, `3D/Voxel/Paint`.
- `material_maker/doc/node_3d_voxel.rst`.

**Spec** (all include `mm_noise3d`, HLSL-safe subset, linear colours in and out)
- **Palette Pick**:
  - Inputs `id_in` (tex3d_gs, the unit id: a Voronoi cell value, a brick id or the per-thing seed), `seed_in`.
  - Parameters: 5 colours `c0..c4`, 4 cumulative thresholds (defaults 0.40, 0.66, 0.86, 0.93 from `brick()`), `blend` (0.35).
  - `h1 = hash(id, 3, 1, s)`, `h2 = hash(id, 5, 2, s)`; pick `k` by thresholds; output `mix(c[k], c[(k+1)%5], h2*blend)`. Also outputs `h1`, `h2`, `h3` as tex3d_gs for per-unit variation.
  - Implement the pick with a chain of `step()` mixes, no arrays.
- **Weathering**:
  - Inputs `albedo_in` (tex3d), `height_in` (tex3d_gs, optional, default 0.5), `seed_in`, `age_in`, `upkeep_in`, `fresh_in`.
  - Parameters: `dirt_colour`, `hides` (0.3), grime scale (0.05 x 81 per metre), `bloom` (0.12), `wear` (0.16).
  - Port of the `aged` branch of `brick()` (grime fbm, bloom, darkening) weighted by `age*(1-upkeep)*(1-fresh)`.
  - Dirt gathers in hollows (`1 - smoothstep` on `height_in`); wear lightens high spots (`smoothstep` on `height_in`, as the `hs` term in `wood()`).
  - Outputs: albedo, roughness delta, bump scale factor (`mix(0.34, 0.16, w)/0.34`).
- **Char**:
  - Inputs albedo, roughness, `char_in`, `seed_in`.
  - Blends to near-black charcoal (`vec3(0.02)`), with crack pattern = Voronoi edge distance (alligatoring) feeding a height output for bump; roughness to 0.9; ember emission optional (parameter, default 0).
  - Outputs albedo, roughness, height, emission.
- **Wetness**:
  - Inputs albedo, roughness, `wet_in`, `normal_in`.
  - Darkens albedo (`albedo*mix(1.0, 0.55, wet*porosity)`), lowers roughness towards 0.15, more on up-facing surfaces (`normal.z`, parameter `up_axis`).
  - Outputs albedo, roughness.
- **Paint**:
  - Inputs albedo, roughness, bump (tex3d), `mask_in`, `seed_in`.
  - Parameters `paint_colour`, `gloss` (0.35), `hides` (1.0).
  - Port of the paint branch of `wood()`/`plaster()`: `pc = colour*(0.93 + 0.14*fbm(p*0.15*81, seed+11, 2))`, mix by `mask*hides`, roughness to `mix(r, 0.35, w)`, bump x `mix(1, 0.375, w)`.

**Dependencies**: WP1, WP2.

**Acceptance** (`test/test_voxel_recipes.gd`)
- Headless: all 5 instantiate; outputs generate with no `$`; forbidden-token regex clean.
- GPU:
  - Palette Pick with ids 0..999: every output colour lies on a segment between two adjacent palette colours; the pick frequencies match the thresholds within 5%.
  - Weathering with `fresh=1` returns the input albedo exactly.
  - Wetness with `wet=0` and Char with `char=0` are identities.
- dxc, if available: a graph using all five exports with the voxel target and compiles (reuse `MMTestHlsl`).

---

### Wave 4 (parallel: WP15, WP16, WP17)

#### WP15. Surface patterns placed in 3D: wallpaper and fabric (nice-to-have 13). Size M.

**Files (create)**
- `material_maker/plugins/voxel/nodes/voxel_surface_pattern.mmg`
- `material_maker/doc/node_3d_voxel_surface_pattern.rst`
- `test/test_voxel_surface_pattern.gd`

**Files (modify)** (owner in wave 4)
- `material_maker/plugins/voxel/library.json` (`3D/Voxel/Surface Pattern`)
- `material_maker/doc/node_3d_voxel.rst`

**Spec**
- Inputs: `in` (rgb, `"function": true`, a normal 2D MM pattern such as a wallpaper motif or weave), `normal_in` (tex3d), `mask_in` (tex3d_gs, default 1).
- Parameters: `scale_u`, `scale_v` (repeats per metre), `up` enum (Z / Y: which object axis is "up" on walls), `mode` enum (Dominant axis / Triplanar blend), `blend_sharpness`, `offset_u`, `offset_v`.
- Projection: with `a = abs(n)`, choose the plane perpendicular to the dominant normal component. On walls `u` = the horizontal in-plane axis and `v` = up; on floors and ceilings `u` = x and `v` = the other horizontal axis. Flip `u` by the sign of the normal component so text is not mirrored on opposite faces.
- uv = `fract(vec2(u*scale_u + offset_u, v*scale_v + offset_v))`.
- Dominant mode samples once; Triplanar samples three times and blends with `pow(a, sharpness)` weights.
- Output tex3d (colour) and tex3d_gs (luminance, for bump through Gradient).
- The doc states: 2D inputs made with buffers are exported as textures (EXR) by the voxel target and work there; without a normal (inside a 3D Buffer bake) the node falls back to the Z projection.

**Dependencies**: WP1.

**Acceptance**
- GPU test: input = a `uv`-like pattern (use `uniform`/`gradient` nodes giving `vec3(uv, 0)`). For points on the +X, -X, +Z faces of a cube with known normals, assert the returned uv equals the expected plane coordinates (within 1e-5) and that the `u` direction is mirrored between +X and -X.
- dxc: a graph with this node compiles through the voxel target.

#### WP16. Final acceptance: the oak (the first test). Size M.

**Goal**: rebuild voxkit's oak as a Material Maker graph, export it with the voxel target, and compare with voxkit numerically and with `beam_close.png`.

**Files (create)**
- `material_maker/examples/voxel_oak.ptex`. Built by script, not by hand: `python/examples/zcity_oak/build_graph.py` uses the RPC client (`new_graph`, `create_node`, `connect`, `set_parameter`, `save`). Graph: `voxel_inputs` to `voxel_wood` (all 7 inputs) to `material_voxel` (`linear_albedo` true, albedo, roughness, bump). Two remote presets (use the existing preset API `save_preset`): `voxkit` (all defaults) and `zcity` (gentler arches: `flow_amount` 3.0, `flow_scale` 0.009, `pith_wander` 2.0, `ripple_amount` 0.4; starting values, to be tuned by eye).
- `python/examples/zcity_oak/compare_oak.py`
- `python/examples/zcity_oak/README.md` (how to run, what the numbers mean).
- No changes in the zcity repo. Outputs go to a directory given by `--out` (default the OS temp directory), not into either repo.

**Steps performed by `compare_oak.py`** (arguments: `--voxkit <path to ZCity/Tools/voxkit>`, `--reference <path to beam_close.png>`, `--mm "<godot> --path <repo> --"`):
1. Launch one MM instance with `material_maker_client.launch`, load `voxel_oak.ptex`.
2. **Point check against `appearance.wood()`**:
   - Generate points on the beam: an end face (plane s = 0, 14 x 14 voxels sampled 256 x 256) and a side face (256 x 1024), with face normals, `fw = 1`.
   - Call voxkit's `wood(pl, n, fin=aged_oak id, fw, seed, row=oak row, fins, app={"grain_axis":0,"pith":[w*0.36,h*0.63],"ring_vox":5/12.346,"age":0.6}, fp=0)`.
   - Call `voxel.evaluate` with preset `voxkit`, `seed` equal, `age=0.6`, `fresh=0`, axis (1,0,0), origin = pith/81, points/81.
   - **Pass**: linear albedo mean abs diff < 0.01 and 99th percentile < 0.05; normal mean angle < 2 degrees.
   - Seeds over 16777215 must be masked to 24 bits on both sides; pass `seed & 0xFFFFFF` to voxkit too.
   - Write side-by-side PNGs (voxkit | MM | 10x difference) for both faces.
3. **Image check against `beam_close.png`**: import voxkit's `kit_test` and `render`. In this process only:
   - replace `render.ProcessPoolExecutor` by an inline executor class (constructor calls `initializer(*initargs)`, `map` runs serially, context-manager methods are no-ops);
   - replace `render.appearance.wood` by a function that forwards to `voxel.evaluate` (node outputs Albedo, and the material's normal; `spec`/`power` from wood outputs 3 and 4);
   - render the `beam_close` camera from `kit_test.pictures` at 700x500, `ss=1`: (a) untouched voxkit as baseline B; (b) MM preset `voxkit` as M1; (c) MM preset `zcity` as M2.
   - Load the stored `beam_close.png`, box-downscaled to 700x500, as R.
   - Metrics (numpy only): mean abs difference in 8-bit sRGB and a global SSIM (single window per 8x8 block, averaged).
   - **Pass**: `MAD(M1, B) <= 3.0` and `SSIM(M1, B) >= 0.95`. Report `MAD(B, R)`; if it is over 6, the stored PNG is stale relative to the current `appearance.py`, and the comparison with R is advisory.
   - For M2: mean colour over the beam mask (pixels where B differs from a render with the beam removed, or simply where `|B - ground| > threshold`) within 6/255 of B; end-grain ring count along a radius within 10% of B.
   - Side-face arch measure `mean |d(ring phase)/ds|`, computed from step 2's side-face points by evaluating the ring phase through finite differences of the albedo luminance along s, must be at most 0.6 x the voxkit value ("smaller, gentler arches").
   - Write a contact sheet `oak_compare.png` (R | B | M1 | M2) for human sign-off of the side faces.
4. **Export check**: `export("Unreal/Unreal Engine 5 Voxel", <out>/voxel_oak)`; then run `dxc` on the wrapped shader (same wrapper text as `MMTestHlsl.wrap_custom_node`, reimplemented in Python in this script, 15 lines).
5. Quit MM.

**Dependencies**: WP7, WP8, WP10 (P5 passes), WP13.

**Acceptance**
- `python python/examples/zcity_oak/build_graph.py --mm "..."` writes the `.ptex`.
- `python python/examples/zcity_oak/compare_oak.py --voxkit C:\Users\richa\workspace_local\zcity\ZCity\Tools\voxkit --reference C:\Users\richa\workspace_local\zcity\ZCity\Saved\Voxkit\beam_close.png --mm "..."` prints the metric table and ends with `OAK ACCEPTANCE: PASS` (exit code 0), or lists the failing metric.
- The parity test P5 (WP10) passes with the same graph: this covers "export it with items 1 to 3".
- Human step, cannot be automated: look at `oak_compare.png` and confirm the `zcity` preset's side faces. Tune the preset values and re-run if not.
- Expect to iterate on step 2. Typical causes of mismatch: axis frame sign, `fw` versus `fresh`, sRGB conversion, a seed offset typo.

#### WP17. Documentation and design note (covers item 12). Size M.

**Files (create)**
- `material_maker/doc/voxel_workflow.rst`: the whole workflow: voxel context contract, D1 limitations, HLSL-safe subset for custom nodes, parity guarantees and limits (copy the "honest limits" of WP10), seeds, units (metres; 81 voxels per metre for ZCity), linear versus sRGB, UE setup (input names, `Char`, object-space normal, what is unverified), the master material config, Python evaluation, volume and mesh bakes, schema, cost readout, 3D Buffer trade-off. For item 12: a short section pointing to the existing Reference panel (`user_interface_reference_panel.rst`) as the way to match a recipe against a photo.
- `design/zcity_voxel.md`: decisions D1-D8, what was rejected and why, open items (L1-L9).

**Files (modify)**
- `material_maker/doc/index.rst` (toctree: `voxel_workflow`)
- `material_maker/doc/command_line.rst` (new modes: `--param-schema`, `--graph-cost`, `--evaluate-points`, `--voxel-master`, `--bake-voxel-material`; new `--export-volume` options)
- `material_maker/doc/scripting.rst` (RPC methods `param_schema`, `graph_cost`, `evaluate_points`, `bake_voxel_material`; Python `material_maker_client.voxel`)
- `material_maker/doc/export.rst` (two new Unreal targets)
- `python/README.md`
- `CHANGELOG.md`

**Dependencies**: all others (text only; can start once wave 3 is merged).

**Acceptance**
- Headless GUT run green (doc completion included).
- `python -c` script (given in the WP report) that checks every `node_*.rst` created by WP1, 2, 9, 13, 14, 15 is referenced by exactly one toctree, and that every CLI mode string registered by the new plugins (`grep add_cli_mode material_maker/plugins`) appears in `command_line.rst`.
- If Sphinx is installed: `python -m sphinx -b html material_maker/doc <tmp>` with no new warnings. Otherwise report "not run".

---

## 5. Dependency and file-ownership check

- **`gen_material.gd`**, **`hlsl_defs.tmpl`**: WP3 only.
- **`material_maker/library/base.json`**, **`doc/node_3d_texture.rst`**: WP2 (wave 1), then WP9 (wave 2).
- **`plugins/voxel/library.json`**, **`doc/node_3d_voxel.rst`**: WP1 (wave 1), WP13 (wave 2), WP14 (wave 3), WP15 (wave 4).
- **`plugins/voxel/export_targets/`**: WP7 creates one `.mme` (wave 2); WP11 creates another (wave 3). Different files.
- **`plugins/voxel/nodes/`**: distinct files per WP.
- **`plugins/volume_export/*`**: WP6 only.
- **Shared docs** (`command_line.rst`, `scripting.rst`, `export.rst`, `index.rst`, `CHANGELOG.md`, `python/README.md`): WP17 only. `doc/nodes_3d.rst` and `doc/nodes_material.rst`: WP1 only.
- **`python/material_maker_client/__init__.py`**, **`material_maker/cli/cli_tools.gd`**, **`parse_args.gd`**, **`rpc_server.gd`**: not modified by any WP. Plugins register modes and methods; the client forwards unknown methods.
- **`test/hlsl_tools.gd`**: WP3 creates it; later WPs only call it. **`test/voxel_unreal_stub.py`**: WP7 creates it; WP11 only calls it.
- **Dependencies**:
  - WP7 needs WP1, WP2, WP3.
  - WP8 needs WP1, WP2.
  - WP9 and WP13 need wave 1 only.
  - WP10 needs WP3, WP7, WP8, WP13.
  - WP11 needs WP7.
  - WP12 needs WP8.
  - WP14 needs WP1, WP2.
  - WP15 needs WP1.
  - WP16 needs WP7, WP8, WP10, WP13.
  - WP17 needs everything.
- Between waves the orchestrator merges the worktrees, runs the full headless GUT once, and runs the GPU test files one at a time.

## 6. Risks to watch

1. **Godot may reject DXC's SPIR-V** (reflection of HLSL structured buffers). The fallback through `spirv-cross` is specified in WP3. If both fail, WP10 drops to T0 and T1, and item 5 is only compile-verified. Report that plainly.
2. **Boolean `linear_albedo` in hidden outputs and `$if not`**: template behaviour needs checking in WP1 and WP7. Fallback: an enum parameter with two code strings.
3. **Position map normalisation in the mesh baker** (WP12): unknown until read.
4. **`check_custom_script`** rejects the substring `OS`. Keep that out of the `.mme` custom script, comments included.
5. **Voxkit point parity** (WP16 step 2) depends on a faithful port. Hash values are exact; expect a few threshold outliers at `floor(phase)` boundaries, hence the percentile bound.
6. **The UE Python** in WP7 and WP11 uses API names from memory (`TransformPosition`, `CustomPrimitiveData`, `MaterialFunctionFactoryNew`, `create_material_expression_in_function`). The stub proves only that the script runs and wires what it intends. A UE session is required before use.
7. **Per-thing `ScalarParameter` defaults** in the WP7 script are zeros, not the graph's slider values (the template cannot read another node's parameters). Acceptable, since the engine supplies them per thing.

### Critical Files for Implementation
- `C:\Users\richa\workspace_local\materialmakermod\addons\material_maker\engine\nodes\gen_material.gd` (export pipeline, `process_shader`, HLSL filters, custom option scripts)
- `C:\Users\richa\workspace_local\materialmakermod\material_maker\plugins\export_targets\export_targets\material_export_Unreal_Unreal Engine 5 Shader.mme` (template to derive the voxel targets from)
- `C:\Users\richa\workspace_local\materialmakermod\addons\material_maker\engine\nodes\gen_shader.gd` (uniform naming `p_o<id>_<param>`, `_controlled_variation_` threading, function inputs, `includes`)
- `C:\Users\richa\workspace_local\materialmakermod\material_maker\plugins\volume_export\volume_export.gd` (pattern for evaluating 3D outputs at arbitrary points in compute; extended by WP6)
- `C:\Users\richa\workspace_local\materialmakermod\addons\material_maker\nodes\material_3d.mmg` (base for `material_voxel.mmg`), with `tex3d_warp.mmg` and `tex3d_fbm_3.mmg` as node-definition patterns
- `C:\Users\richa\workspace_local\zcity\ZCity\Tools\voxkit\appearance.py` and `noise.py` (the recipes and the hash to reproduce)

---

## Summary of waves

1. **Wave 1 (6 parallel)**: WP1 voxel plugin core (Voxel Material + Voxel Inputs), WP2 seeded 3D noises + gradient/bump node, WP3 HLSL translator fixes + dxc test toolbox, WP4 JSON parameter schema, WP5 cost readout + parity lint, WP6 volume bake formats (r8/rg16, raw, slices, tileable check).
2. **Wave 2 (4 parallel)**: WP7 "Unreal Engine 5 Voxel" export target, WP8 point evaluation (engine, CLI, RPC, numpy client), WP9 3D Buffer node, WP13 wood recipe node.
3. **Wave 3 (4 parallel)**: WP10 GLSL versus exported-HLSL parity test, WP11 Material Function export + master material generator, WP12 per-mesh 2D bake, WP14 palette/weathering/char/wetness/paint nodes.
4. **Wave 4 (3 parallel)**: WP15 3D-placed surface patterns, WP16 oak acceptance against voxkit and `beam_close.png`, WP17 docs and design note.
5. Must-haves 1-4 land in waves 1-2; must-have 5 (parity) is proven in wave 3 by compiling the exported HLSL with dxc to SPIR-V and running it on the GPU next to the GLSL.
6. Normal and fresh travel in `_controlled_variation_`; seed, age, upkeep, char, wet, axis, origin, footprint are Voxel Inputs sliders rewritten to Custom node inputs at export. No engine change.
7. New noises use voxkit's integer hash, so GLSL, HLSL and numpy agree to float rounding; legacy sin-hash nodes are flagged, not fixed.
8. Not verifiable on this machine: anything inside Unreal (setup scripts, Material Function, master material). They get a dxc compile, `py_compile` and a stub run only.
9. Not planned: reference-photo overlay (the Reference panel exists), single-lookup Texture3D in UE, brick-bond layout, voxkit `moulding()`, FXC checks.
10. Between waves: merge worktrees, run headless GUT once (must stay green), then GPU test files one at a time; shared files have exactly one owner per wave.
