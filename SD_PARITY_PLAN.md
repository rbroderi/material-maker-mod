# Material Maker → Substance Designer Parity (and Beyond) Plan

Baseline compared: **Material Maker 1.7** (July 2026, Godot 4) vs **Substance 3D Designer 16.0** (April 2026).
Sizes: **S** ≈ days, **M** ≈ 1–3 weeks, **L** ≈ 1–3 months, **XL** ≈ 3+ months (one experienced dev).

> Checked against the source of the fork [rbroderi/material-maker-mod](https://github.com/rbroderi/material-maker-mod)
> at commit `7d6daae` (merged from RodZill4/material-maker master): 426 node definitions in
> `addons/material_maker/nodes/`, 328 library entries in `material_maker/library/base.json`, and the engine in
> `addons/material_maker/engine/`. Lines marked **✔ checked** were confirmed in the code.
>
> Related tool: [rbroderi/sbsar2ptex](https://github.com/rbroderi/sbsar2ptex). It converts and decompiles `.sbsar`
> files and translates Substance atomic filters into Material Maker GLSL. See §5.6.

---

## 1. Where things stand

| Area | Material Maker 1.7 | Substance Designer 16 | Gap |
|---|---|---|---|
| Evaluation model | Graph compiled to GLSL; manual **Buffer** nodes split it into compute passes that are cached and invalidated individually (`engine/dependencies.gd`) ✔ | Every node cooked and cached on its own; resolution/bit depth per node | **Critical** |
| Per-node resolution / bit depth | Only on Buffer nodes: square, 2^4–2^14 (16–16384 px, raised from 8192 in this fork), 16-bit float by default with optional 32-bit float (`gen_buffer.gd`) ✔ | Relative/absolute per node, 8/16/16F/32F, non-square | **Critical** |
| Visual per-pixel programming | GLSL custom nodes, expression params | Pixel Processor, Value Processor, FX-Map, function graphs on any param | **High** |
| Node library | ~300+ nodes, strong SDF/3D | Atomic nodes plus a very large library; Shape Splatter v2, splines/paths, Ribbon | Medium |
| Mesh baking | Same-mesh maps (position, normal, tangent, AO, bent normals, thickness, curvature, seams, adjacency), plus high→low with cages, AA, tangent/object normals, height, vertex color, material ID and position ✅ (§4.1). No UDIMs | Full baker suite: high→low, cages, ID, thickness, bent normals, UDIM | **High** |
| SD interop | `.sbsar` → `.ptex` via the separate sbsar2ptex tool (baked maps; node translation in progress) | n/a | MM-side opportunity |
| 3D viewport | Godot renderer, with an OpenPBR approximation for direct light, OCIO view transforms, a progressive GPU path tracer (sun, displacement, transmission) and turntables ✅ (§4.2) | OpenPBR, GPU path tracer, tessellation/displacement popup, OCIO | Medium |
| Color management | Image color spaces, plus OpenColorIO 2.6 through an optional GDExtension (input transforms, display/view transforms in the 2D and 3D previews, HDR LUTs, export transforms) ✅ (§4.3) | OCIO/ACES | **High** for studios |
| Runtime format | `.mmr` runtime packages (with seeds and resizable outputs), a Godot runtime addon, a C++/Vulkan renderer and a Blender add-on ✅ (§5.1), plus procedural shader exports for Godot, Unity and Unreal (§6); no Unreal, Unity or Houdini plugins yet | `.sbsar` + engine plugins (Unreal, Unity, Houdini, Maya, Max, Blender) | **Critical** for pipelines |
| Automation | CLI export, render, bake, `--set` overrides and variations, plus a JSON-RPC server and Python client ✅ (§5.2) | Python API, plugins, Automation Toolkit (cooker/render/baker/mutator) | **High** |
| Packages / dependencies | Library panel, user nodes | Packages, dependency manager, instance versioning, update outdated | Medium |
| Scan processing | — | Multi-angle-to-material, AxF, scan workflows | Medium (niche) |
| Painting | **Built in** | None (needs Painter) | MM ahead |
| Cost / licence / platform | **Free, MIT, native Linux** | $200 perpetual or subscription | MM ahead |

---

## 2. Phase 0: Engine foundations (do these first; almost everything else depends on them)

### 2.1 Node-level cooking with a cache — **XL, critical**
Today the graph compiles into large monolithic shaders. That causes slow recompiles, driver limits on big graphs, and no way to inspect intermediate results cheaply.

**✔ checked, already in place:** a compute pipeline on Godot's RenderingDevice (`engine/shader_compute.gd`, `engine/pipeline/`). Buffer-level dependency tracking with Invalidated/Updating/Updated states (`engine/dependencies.gd`). Iterate Buffer for feedback loops. So this item is *extending* that system to finer granularity, not building it from scratch.
- Add a **hybrid evaluator**: keep fusing cheap pointwise chains into one shader, but break the graph into cached passes at sensible points (expensive nodes, high fan-out, resolution changes, user-pinned).
- **Insert buffers automatically** using a cost heuristic (instruction count × fan-out × sample count). Manual Buffer nodes stay as an override.
- **Dirty propagation**: a parameter change re-cooks only the downstream passes. Cache per (node, parameter hash, resolution, format).
- A **GPU memory budget** with LRU eviction and spill-to-RAM.
- Reuse the existing compute path for passes that need reductions or scatter.

✅ **Done (2026-10-25), milestones 1–5.** See [design/hybrid_evaluator.md](design/hybrid_evaluator.md).
- **Automatic buffers** (`gen_auto_buffer.gd`) are chosen by a **cost model** (`MMGenShader.get_cost_model()`, `estimate_cost()`, `should_auto_buffer()`). It counts calls × parsed loop bounds × samples per input. Inputs that will themselves be buffered count as one fetch.
- An input is buffered when inlining it costs at least *min gain* × the buffered cost. The buffer uses the consumer's own Size parameter as its resolution.
- **Shader splitting:** any input costing more than the shader budget is buffered, which cuts monolithic shaders.
- **Incremental recompilation:** an upstream edit behind a buffer regenerates only that buffer.
- **Per-connection pins** (Always/Never) are set with Alt+right-click on a connection. They're saved with the graph, undoable, and drawn as markers.
- **GPU memory budget:** the least recently used compute textures are spilled to RAM and re-uploaded on demand, with no re-render.
- Preferences are under *Graph*. Automatic buffers are still opt-in.

Measured:
- A 16-sample blur of a 6-node chain went from about 360 ms to about 90–180 ms.
- 0 downstream recompiles after an upstream edit behind a buffer.
- 192 MB was evicted down to a 4 MB budget with pixel-identical results.

Tests: `test/test_auto_buffer.gd` (5 GUT tests), plus GPU harness runs.

✅ **Done (2026-10-26):**
- **Pins and grouping:** grouping nodes into a subgraph keeps pins. A pin on a connection that crosses the boundary moves to the connection that feeds the reading node.
- **Calibrated weights:** 130 library nodes were timed at 1024² and 4096² on a Radeon 780M, plus a buffer sampled K times (`test/calibration/`). One estimated cost unit is about 0.0005 ns per pixel, a nearby texture fetch about 0.024 ns (48 units, was 1), and writing a pixel of a pass about 2.5 ns (about 5 000 units, was 16).
  - Memory traffic dominates on this GPU, so automatic buffers are now only inserted when the inlined work is large.
  - The estimated node cost only roughly predicts arithmetic time (rank correlation 0.27): loops driven by parameters (splatters, FX-Maps) are underestimated, and scattered fetches cost more than nearby ones.
  - Fixed along the way: automatic buffers no longer wrap sources that are already textures, or inputs read through `$in.texture`/`$in.size`. These break, because the attribute names the original texture, and a low shader budget triggered them.

Per-node *format* control is §2.2.

### 2.2 Per-node output size and format — **L**
- Output size modes: *relative to parent*, *relative to input*, *absolute*. Support **non-square** sizes up to 16k (and 32k via tiling).
- Formats: 8-bit, 16-bit, 16F, 32F, mono vs RGBA, with inheritance rules like SD's.
- Show the size and format on node badges, and warn on precision loss (for example height data in 8-bit).

✅ **Done (2026-10-25), adapted to MM.** In MM only buffers are separate passes, so per-node size and format apply to buffers:
- **Formats:** the Advanced Buffer has *8 bits* (R8/RGBA8, half the memory of 16F) next to *32 bits*. 16F stays the default, and mono vs RGBA is still detected automatically. The new `TEXTURE_TYPE_R8/RGBA8` pipeline types and the readback support make this possible. Grayscale detection now uses the type's channel count instead of a bitmask.
- **Size modes:** *Absolute*, or *Relative to output*: the material's size × 2^offset. Buffers follow the material when its size changes.
- Automatic buffers (§2.1) already take their size from the node they feed.
- Measured: an 8-bit buffer uses half the memory and stays within 1/255 of the 16F result. A relative buffer followed the material from 2048 to 1024.

Not done:
- Non-square sizes: every texture-size uniform and the size widgets assume square textures, so this is a separate refactor. ✅ **Outputs done (M12):** `--render`, `--export-material` and `--export-mmr` accept `--size <width>x<height>` (and the RPC `render`, `export` and `export_mmr` a `height`). The graph is stretched to the image's shape, and buffers stay square. Verified: a 512×256 runtime package renders pixel-identical to MM's 512×256 render. Still missing: non-square buffers and per-node sizes, and non-square sizes in the user interface.
- ✅ **Done (2026-10-26): badges and warnings.** Advanced Buffers show their resolution and format under the node, for example *512 px 8 bits gray*. An orange warning appears when an 8-bit buffer stores grayscale data (heights) or feeds a node that computes normals or reads heights.

### 2.3 GPU reductions and analysis — **M**
SD-style Auto Levels, Histogram Scan/Range, and "normalize" all need min, max, mean, or histogram over the whole image.

**✔ checked:** MM's **Auto Tones** already finds min/max, but it does so with an Iterate Buffer subgraph (`nodes/auto_tones.mmg`). There's also a **Histogram panel** (`material_maker/widgets/histogram`). Replace the iterate-buffer approach with a real compute parallel-reduce primitive whose results nodes can read as uniforms. That makes Auto Tones faster, and adds Histogram Scan/Select, Equalize, and an auto-range Highpass.

**Done (2026-10-25), first part:** a new **Statistics** node (`engine/nodes/gen_statistics.gd`, `statistics_compute.tres`, library *Miscellaneous/Statistics*). It works like this:
- One compute pass evaluates the input and reduces each workgroup in shared memory.
- Results merge into an SSBO with atomics: order-preserving ints for min/max, and a 64-bit fixed-point sum (two 32-bit words with carry) for the mean.
- It outputs per-channel **Min / Max / Mean** as a `vec4[3]` uniform named after the node's buffer, so downstream shaders wait for it.
- Results match a CPU reference. Negative values work.

**Auto Tones** now uses it instead of the Iterate Buffer subgraph. It's exact: within 0.001 of the CPU result, where the old version was off by up to 0.05. Existing graphs that use Auto Tones may change slightly.

✅ **Done (2026-10-25), second part:** a shared base class `MMGenAnalysis` (`gen_analysis.gd`, `analysis_compute.tres`) runs a GPU pass that accumulates into an int array with atomics, processes the result on the CPU, and publishes a small texture. Two nodes use it:
- **Histogram** (*Miscellaneous/Histogram*): 256 bins per channel. Its output is a 256×2 texture holding the cumulative distribution and the normalized histogram.
- **Fill to Index** (*Filter/Fill/To Index*): one bit per area origin. The CPU numbers the set bits in raster order, and the output looks up each area's index. Tested on a 4×4 grid: 16 areas, numbered 0–15 in order.

The new library nodes **Histogram Equalize**, **Scan**, **Range**, **Shift** and **Select** are under *Filter/Histogram*. Equalize is within about 1.6 bins of the exact result.

### 2.4 Performance profiler — **S–M**
Per-node GPU time and memory overlay, plus a "slowest nodes" list. SD has this, and it matters for large graphs. **✔ checked:** Buffer nodes already draw their last render time in ms under the node (`material_maker/nodes/base.gd`). **Done (quick win):** Iterate Buffers now report their total time across iterations too. *Tools → Show buffer render times* lists the 20 slowest buffers in the graph, with group paths and a total. ✅ **Done (2026-10-25):** the dialog also shows each buffer's GPU memory and the total, plus the memory budget (§2.1). Mesh Map nodes now report their generation time, so they appear in the list and under the node. Still missing: preview rendering times, which aren't graph nodes.

---

## 3. Phase 1: Authoring parity

### 3.1 Visual function graphs — **XL, high**
Equivalent to SD's function graphs, Pixel Processor, and Value Processor:
- A **function graph editor** (scalar/vector/int/bool/float2-4 types, sampling nodes, `$pos`, `$size`, `$time` variables, loops via sequence/for nodes) that **compiles to GLSL**. This fits MM's architecture naturally.
- **Pixel Processor** node: a per-pixel function graph with N image inputs.
- **Value Processor**: evaluated once, outputs a uniform.
- **Parameter functions**: any exposed parameter can be driven by a function of other parameters (for example `tile_count = density * 4`). Also a visibility/enable condition per parameter.
- Keep GLSL custom nodes as the power-user path. Consider a "view as GLSL" toggle on any function graph. SD can't do that.

✅ **Done (2026-10-25), milestones 1–4.** See [design/function_graphs.md](design/function_graphs.md).
- **Compiler** (`engine/function_graph/function_graph.gd`): typed IR v2 → GLSL.
  - About 60 ops, including integers with explicit conversions, typed **sub-functions**, and **loops**.
  - Errors and types are reported per node.
  - **`sd_rand`** is Substance-compatible: implemented from sbsar2ptex's random-generator spec, and matches its conformance vectors on the GPU for both pixel-processor and value-function streams.
- **Pixel Processor** and **Value Processor** nodes. The Value Processor renders its graph once into a 1×1 buffer.
- **Parameter functions:** *Function graph…* in the float expression editor compiles a graph to the parameter's expression, and the graph is saved with the node.
- **Visual editor** (`material_maker/windows/function_graph_editor/`):
  - typed nodes, inline constants, errors highlighted on nodes;
  - an inputs and parameters panel, and sub-function editing;
  - a JSON fallback, and an undo step per apply.
- 35 GUT tests, plus GPU and editor interaction runs.

✅ **Done (2026-10-26): undo inside the editor.** Undo/Redo buttons and Ctrl+Z, Ctrl+Y and Ctrl+Shift+Z (unless a text field has the focus), with up to 100 steps. Applying is still a single undo step in the material.

Not done: milestone 5 (sbsar2ptex emitting the IR) is on hold.

### 3.2 FX-Map equivalent — **L**
A recursive quadrant/iterate/switch splatting system with per-instance random seeds, blend modes, and pattern inputs. Implement as a compute-based instancing pass (it pairs with §2.1). MM's tile and splatter nodes cover the common cases. The gap is the general-purpose programmable version.

✅ **Done (2026-10-26), quadrant FX-Map:** an **FX-Map** node (`nodes/fx_map.mmg`, *Transform/FX-Map*).
- Up to 10 quadrant levels, with one optional instance per cell. Instances get a random offset, scale, rotation and value, and a per-level opacity falloff.
- 4 pattern inputs, chosen at random or by level.
- Alpha-over, add and max blending, an instance ID output, and seamless tiling.
- ✅ **Done (2026-10-26): programmable FX-Map.** The **FX-Map Iterate** node (`nodes/fx_map_iterate.mmg`, *Transform/FX-Map/Iterate*) splats up to 256 instances.
  - Position, scale, rotation, value, opacity and pattern are expressions of the instance index `i`, the count `n`, `t = i/(n-1)`, random values `r1` to `r4` and `$seed`. They can sample inputs, such as a map.
  - Each property can be a function graph (§3.1). The parameter function editor exposes `i`, `n`, `t` and `r1` to `r4` to the graph through a new `expression_variables` field on shader parameters.
  - The pattern expression acts as SD's Switch node, picking one of 4 inputs per instance. Alpha-over, add and max blending, and an instance output.
  - ✅ **Done (2026-10-26): nested iterations.** With *Count in group* above 1, each instance becomes a group of instances (an Iterate inside an Iterate).
    - Groups have their own position, scale and rotation expressions (of i, n, t and the group random values g1, g2).
    - Instances are placed in their group's space, with j, m and u = j/(m-1).
    - Graphs without groups render as before.

### 3.3 Node library parity — **L (ongoing)**
Audit against SD's library. Priority gaps to check or build:
- **Shape Splatter v2 parity**. **✔ checked:** MM's Splatter and Circle Splatter take count, scale, rotation, value, variations, and a mask input, and that's all. Missing: Poisson disc and uniform distributions, a density map, per-instance control maps, height-ordered blending, and data outputs (position, rotation, scale, ID maps). ✅ **Done (2026-10-26): Shape Splatter** (`nodes/splatter_v2.mmg`, *Transform/Shape Splatter*):
  - Poisson-like, uniform or grid distribution.
  - Density, scale and rotation maps.
  - Random scale, rotation and height.
  - Max (height-ordered) or Add blending.
  - Output, instance ID, position and mask outputs.
  - Tiles seamlessly.
- **Tile Sampler parity**. **✔ checked:** Tiler Advanced already has a mask input, per-tile translate/rotate/scale map inputs, two color inputs, multiple input patterns, overlap, and variations. There are also the Height to Angle/Offset and Remap helpers. Missing: vector-map displacement, pattern selection by map, symmetry options, and height-ordered stacking. This is a **smaller gap than first assumed (M, not L)**. ✅ **Done (2026-10-26): Tile Sampler** (`nodes/tile_sampler.mmg`, *Transform/Tile Sampler*). It has 4 pattern inputs chosen at random, by a map or in sequence, a vector-map displacement input, mask, scale and rotation maps, random position, scale, rotation, value and drop, row offsets, and random mirror or quarter-turn symmetry. Overlapping instances are combined by max, height order (the instance with the highest random height on top), alpha over or add. It tiles, and has an instance output.
- **Splines and paths**. **✔ checked:** MM has one Splines node (edge, fill, and guide inputs) and Poly Curve (with a width map). Poly Curve already stretches a pattern along a path. ✅ **Done (2026-10-26): Spline Mapper** (`nodes/spline_mapper.mmg`, *Simple/Spline Mapper*) places pattern instances along a curve, oriented to it, with random scale, rotation, offset and height, and height-ordered blending. ✅ **Done (2026-10-26):** **Spline Bridge** (`nodes/spline_bridge.mmg`) fills the area between two curves edited in the 2D preview and maps a pattern on it, with UV and mask outputs. **Ribbon** (`nodes/spline_ribbon.mmg`) draws a ribbon along a smooth (Catmull-Rom) curve, with arc-length mapping, width map, tapering and twist, and UV and mask outputs. Mapping an image on the ribbon is the spline warp.
- **Flood Fill suite**. **✔ checked:** largely at parity. MM has To Color, To Gradient, To Orientation, To Position, To Random Color/Gray, To Size, To UV, To RGBA, Select, and From Colors. To Index was added in §2.3. ✅ **Done (2026-10-26): Flood Fill Mapper** (`nodes/fill_mapper.mmg`, *Filter/Fill/Mapper*) places a pattern in each cell, fitted to its bounding box, with random rotation, scale and value.
- **Advanced filters**. **✔ checked, already present:** Slope Blur, Directional Blur, Directional Warp, Multi Warp, Edge Detect (3 variants), Bevel, Normal Map / Normal Blend / Normal Map Convert, Normal to Height, Smooth Curvature, HBAO, Occlusion, Height Blend, Quantize, Tones (levels), and Auto Tones. **Done (2026-10-25): Non-Uniform Blur** (`nodes/non_uniform_blur.mmg`, library *Filter/Blur/Non-Uniform*). It's a golden-angle disc blur whose radius comes from an intensity map, with anisotropy, angle, and sample count. ✅ **Done (2026-10-26):** SD's "blades" (polygonal bokeh), with a blade count and rotation. ✅ **Done (2026-10-26): Distance** (`nodes/distance.mmg`, *Filter/Distance*). It outputs a distance falloff and source colors propagated from the mask's white areas, accurate to 1–2 px.
  - It uses a corrected jump flood: the step halves each pass, and sampling is at pixel centers.
  - ✅ **Fixed (2026-10-26): Mask to SDF** had both bugs. It used `size/4/k` steps and sampled at pixel corners, so with filtering it was off by about 0.04 UV outside the shape and about 0.15 UV inside it. It now uses the same corrected jump flood and is accurate to 1–2 px (for example −0.145 at the center of a radius-0.15 circle, where it used to give −0.005). New instances default to 12 iterations. Saved graphs keep their own count, which is still correct. Graphs that use Mask to SDF will render differently, now with correct distances.

  Histogram Scan/Shift/Select are done (§2.3). ✅ **Done (2026-10-26):** **Normal Normalize** (`nodes/normal_normalize.mmg`), **Normal Combine** with RNM, Whiteout and UDN modes (`nodes/normal_combine.mmg`; Normal Blend only mixes linearly), and **Posterize (Dithered)** with a 4×4 Bayer matrix (`nodes/posterize_dither.mmg`).
- **Atlas tooling**: Atlas Splitter, Atlas Scatter, Atlas Creator, rotate-to-fit, per-atlas-item IDs. ✅ **Done (2026-10-26):** *Transform/Atlas/Splitter* extracts one item of a grid atlas, *Creator* packs 4 inputs into a 2×2 atlas, and *Scatter* splats random items of an atlas, with an item ID output. ✅ **Done (2026-10-26):** non-grid atlases, with items found by a Fill node: *Atlas Islands* extracts an item (picked by a point), fitted with its aspect ratio, and *Atlas Island Scatter* scatters random items. Both can rotate items by a quarter turn to fit (rotate-to-fit).
- **✔ checked:** a **Text node** exists (`gen_text.gd`). ✅ **Done (2026-10-26): SVG node** (`engine/nodes/gen_svg.gd`, *Simple/SVG*). It renders an SVG file, or a path (SVG `d` syntax on a 100×100 canvas) with fill and stroke colors and stroke width. ✅ **Done (2026-10-26):** a *Shape* source, a polygon edited in the 2D preview. ✅ **Done (2026-10-26):** a *Curves* source, Bézier curves edited in the 2D preview with the Splines editor. Curves whose ends meet are joined, and closed outlines are filled.
- **Weathering and material generators**: edge wear, dirt, grunge, water-level, moss and dust (the "Material Filters" family). ✅ **Done (2026-10-26):** *Filter/Weathering* has Edge Wear (from curvature), Dirt (ambient occlusion and curvature), Grunge, Moss (normal direction and cavities) and Dust (upward-facing areas). They're masks broken up by shared noise (`nodes/weathering_*.mmg`). ✅ **Done (2026-10-26): Water Level** (`nodes/weathering_water_level.mmg`): water, wetness and depth masks from a height map, with ripples.
- **Bitmap-to-material**: delight, crop/tile-fix, make-it-tile (patch-based), clone patch, and PBR from photo. ✅ **Done (2026-10-26):** **Delight** (`nodes/delight.mmg`, *Filter/Bitmap/Delight*) divides by a large blur to remove baked lighting, and **Clone Patch** (`nodes/clone_patch.mmg`) copies a soft-edged patch over a defect. Make Tileable already existed. ✅ **Done (2026-10-26):** **Patch Tiling** (`nodes/make_tileable_patches.mmg`) makes an image tileable from random patches blended with histogram-preserving (variance-preserving) blending, and **Photo to Material** (`nodes/photo_to_material.mmg`) estimates a delit albedo and height, normal, roughness and AO maps from one photo. Photometric stereo (§5.4) gives better normals from 4 photos.

### 3.4 Graph UX and organization — **M**
- **Graph instancing with versioning**: a subgraph instance records its source version, with "update outdated instances" and diff-before-update. ✅ **Done (2026-10-26)** (`tools/library_manager/library_instances.gd`, *Tools → Library instances*):
  - Nodes created from library items that embed their definition (graphs, custom shaders) record the item and definition hashes.
  - The window shows instances that are outdated or were modified locally.
  - Updating keeps parameter values, seed and connections, and is undoable.
  - ✅ **Done (2026-10-26): diff before updating.** *Show changes* renders the instance before and after the update, and lists the changes of its definition: nodes, connections, parameters, inputs and outputs, and shader code as a line diff.
- **Dependency manager**: list every external dependency (packages, bitmaps, fonts), relink missing ones, and package graphs with their resources. ✅ **Done (2026-10-26)** (`windows/dependencies/`, *Tools → Dependencies*):
  - Lists every file parameter (images, fonts), including in subgraphs.
  - Relinks one file, finds missing files by name in a folder, or collects all files into a folder.
  - All of it is undoable.
- **Parameter UI**: groups, tooltips, sliders with soft/hard ranges, presets per graph, and color-picker swatches. ✅ **Done (2026-10-26)**, including persistent color swatches shared by all color pickers:
  - **Groups:** labels written `Group::Label` are shown under collapsible headers in the parameters panel.
  - **Hard ranges:** min/max stay the slider's soft range, and `hard_min`/`hard_max` clamp values. The node editor keeps them.
  - **Presets per graph:** remote nodes save, apply and delete named presets, saved in the `.ptex`. They're used by the CLI (`--preset`), RPC (`list_presets`, `apply_preset`, `save_preset`) and `.mmr` packages (`presets` in the manifest, `apply_preset` in the Godot runtime, `--preset` in `mmr_render`).
- **Presets/variations** UI on top of the 1.6 Controlled Variations system. ✅ **Done (2026-10-26):** a preset bar on remote nodes (apply, save, delete, *Randomize* within each parameter's range), all undoable, plus `randomize_parameters(seed)` in RPC.
- Pinned 2D-view inspection of any output, side-by-side compare, channel isolation, tiling preview, and a pixel value picker that shows float values. ✅ **Done (2026-10-26).** Pinning (preview lock) and the tiling preview (*Repeat* view mode) already existed. The 2D preview's *View* menu now has channel isolation (R, G, B, A, luminance), a pixel value readout from a float render, and a snapshot compared with the current output on either side of a draggable split.
- **Graph templates**: Unreal, Unity HDRP/URP, Godot, glTF, and OpenPBR output sets. ✅ **Done (2026-10-26):** *File → New material from template* creates a material whose export target and Material node are set for Godot 4 (Standard or ORM), Unity HDRP/URP, Unreal Engine 5, glTF, MaterialX (OpenPBR), USD or Blender (`MMCliTools.ENGINE_TEMPLATES`, and `new_graph(template)` in RPC).
- Faster search with fuzzy matching and the most-recent nodes first; connect-by-drag-to-empty-space search. ✅ **Done (2026-10-26):** the search falls back to typo-tolerant (one edit per word) and subsequence matches, recently created nodes come first (and lead an empty search), and dropping a connection on empty space already opened the search.

---

## 4. Phase 2: 3D, baking, color

### 4.1 Mesh baker suite — **L–XL, high**
**✔ checked, already in place:** a BVH ray-traced map generator (`map_generator/`). It bakes position, normal, tangent, AO, bent normals, thickness, curvature, seams, and adjacency from the *same* mesh, and exposes them through the **Mesh Map** node (`gen_meshmap.gd`). It also does dilation and denoising in compute. So baking-as-nodes already exists. What's missing:
- High-to-low baking with **cage support** (auto-cage and custom mesh), front/rear ray distances, match-by-name, and anti-aliasing.
- New maps: ID (from vertex color, material, or mesh ID), height (high→low), world-space direction, opacity, and color-from-mesh.
- **MikkTSpace** tangent basis, configurable to match the target engine.
- **UDIM** support for both bakes and texture sets. **✔ checked:** there's no UDIM handling anywhere in the code.
- Hardware ray tracing where available, keeping the existing BVH compute path as the fallback.
- Keep baking available as nodes (it already is). SD keeps baking separate, so this goes beyond it.

✅ **Done (2026-10-26): high-to-low baking**
- **What's new:** a **High Poly Bake** node (`engine/nodes/gen_highpoly_bake.gd`, *Miscellaneous/High Poly Bake*), built on `map_generator/high_poly_baker.gd`, `highpoly_vertex.tres` and `highpoly_fragment.tres`.
- **How it works:**
  - The high-poly surfaces are merged into one BVH. Its spare fourth channel now stores the face index.
  - Per-face normals, vertex colors and surface IDs go into a data texture.
  - The low-poly mesh is rasterized in UV space. Each texel casts a ray from the cage towards the low-poly surface and takes the closest hit.
- **Maps:** tangent-space normal (in MM's convention, so it connects straight to the Material node), object-space normal, height, vertex color, material ID, position and coverage.
- **Options:**
  - Front and rear ray distances, relative to the bounding box diagonal (the auto-cage).
  - An optional custom cage mesh, which must have the same topology as the low-poly mesh.
  - 1, 4 or 16 jittered anti-aliasing samples.
  - MikkTSpace tangents, via Godot's `SurfaceTool.generate_tangents`, when the low-poly mesh has none.
  - Dilation past UV seams.
- **Loaders:** the OBJ loader can now split materials (`usemtl`) into surfaces for ID maps, and it reads `v x y z r g b` vertex colors (the ZBrush polypaint export). glTF and FBX already have one surface per material.
- **CLI:** `--bake --high <mesh> [--cage <mesh>] [--front d] [--rear d] [--samples n]`.
- **Checks:**
  - A mesh baked onto itself gives a perfectly flat normal map.
  - Baked tangent normals correlate positively with the gradients of the baked height map, following MM's Normal Map convention (0.93 for u, 0.88 for v).
  - A bumpy, two-material, vertex-colored sphere bakes without misses in both a SceneTree harness and the CLI.
  - A 1.1× cage gives the same normals except at the poles, and a cage with mismatched topology is rejected with an error.
- **Fixed along the way:**
  - The ray-traced bakes (AO, thickness, bent normals) segfaulted on Vulkan, upstream too. The denoise compute shader used `texture(tex, uv, 0)`, and a LOD bias isn't allowed outside fragment shaders (D3D12 rejected the shader outright). It now uses `textureLod` at pixel centers.
  - UV-space rasterization culled back faces, so mirrored UV islands were never baked, for any mesh map. Culling is now disabled for bakes and stays on for the painter.
  - The ray/box test produced NaN (0/0) for rays with an exactly null direction component starting on a box face, so whole low-poly triangles missed at sphere poles. Fixed in both ray-traced shaders.
- ✅ **Done (2026-10-26, M12): match by name, skew maps and texture transfer** (High Poly Bake node parameters, and `--match-names`, `--skew`, `--high-texture` and the `texture` map in the CLI):
  - **Match by name:** parts (OBJ objects and groups, glTF/FBX mesh nodes, now loaded with their names and transforms) of the low poly mesh only hit the high poly part with the same name, ignoring `_low`/`_high` suffixes and Blender's `.001` numbers. Low poly meshes with several parts are merged before baking (only the first surface was baked before).
  - **Skew maps:** a grayscale image bends rays from the vertex normals (or cage) direction to the flat face normal.
  - **Transferred texture:** the high poly mesh's own texture, sampled with its UVs at the hit point (per-face UVs were added to the baker's attributes).
  - **Verified** with synthetic meshes: a high poly part overlapping a neighbor bleeds into its height map without matching and not with it; a texture on a high poly plane with mirrored UVs is transferred mirrored (max error 0.004); with a white skew map, rays from tilted vertex normals hit right below each texel (max position error 0.003).
- **Still missing:**
  - UDIMs.
  - Hardware ray tracing.

### 4.2 Viewport and rendering — **L**
- **Displacement/tessellation** preview with height scale and level controls (like SD 16's displacement popup).
- An **OpenPBR** shading model alongside the current one. Map outputs to Godot's StandardMaterial and to OpenPBR.
- **Progressive path tracer** for look-dev (compute-based, accumulating). Optional, but expected for presentation renders.
- HDRI library, rotation and exposure, ground shadow catcher, and turntable/render-to-image.
- Clear-coat, sheen, subsurface, anisotropy, and transmission channels in the material output.

✅ **Done (2026-10-26):**
- **Displacement:** **✔ checked, already present.** The *Tesselated Material* node displaces geometry in the 3D preview, and the standard Material's preview does parallax occlusion with a *Depth* control.
- **New Material inputs:** coat, coat roughness, anisotropy, sheen and transmission.
  - They're appended after the existing ones, so saved graphs keep their port indices.
  - Each input has a multiplier parameter, used alone when the input isn't connected (coat, anisotropy, sheen and transmission default to 0).
- **Preview:** the inputs map to Godot's CLEARCOAT, ANISOTROPY, RIM and BACKLIGHT. Their textures are only rendered when the inputs are connected.
- **Exports:** they go to MaterialX standard_surface and OpenPBR (coat_weight, specular_roughness_anisotropy, fuzz_weight, transmission_weight), and coat/coat roughness to USD (clearcoat). The files pass MaterialX validation and GLSL generation, and USD resolves them.
- ~~**Still missing:** an OpenPBR shading model, the path tracer, turntable rendering, and Godot/Unity/Unreal export of the new channels.~~ ✅ **Done (2026-10-26, M11):**
  - **OpenPBR shading** (*Model → OpenPBR shading*, `engine/openpbr_preview.gd`): Godot can't replace its whole lighting model, but a `light()` function replaces direct lighting. The Material node's preview shader gets one that layers a coat (IOR 1.6, isotropic GGX) over fuzz (Charlie sheen) over an anisotropic GGX base with thin-walled transmission. The coat, anisotropy, sheen and transmission values reach `light()` through varyings. Ambient light and reflections still use Godot's model.
  - **Path tracer** (`engine/path_tracer.gd`, `path_tracer_compute.tres`): a progressive compute path tracer that uses the high-poly baker's BVH traversal. It renders the preview object (generated preview models use their untessellated fallback mesh) with the Material node's maps (albedo, ORM, normal, emission, coat/sheen) and the preview's camera and panorama. Lobes are coat, fuzz, GGX specular and diffuse, with Russian roulette and a firefly clamp. The *Export* menu writes tone-mapped PNGs or linear EXRs, optionally with a transparent background. It also works over RPC (`render_path_traced`).
  - **Turntable:** a full turn of the preview object, rendered by the preview at a fixed size, saved as a sprite sheet or a PNG sequence (from the *Export* menu, or `render_turntable` over RPC).
  - **Exports of the new channels:** Godot 4 (clearcoat, anisotropy with a flow map, sheen as rim, transmission as backlight), Unity HDRP (coat mask and anisotropy maps, anisotropic material type), and Unreal 5 (clear coat, cloth or subsurface shading model, anisotropy).
  - **Fixed along the way (upstream bug):** nested `$if` blocks in export templates ran inside skipped outer blocks, and `$else` toggled the wrong level (`gen_material.gd`, `process_conditionals`).
  - **Verified:** Godot loads the exported .tres with all features. The HDRP .mat YAML and its .meta GUIDs are consistent, and the Unreal script compiles as Python. The OpenPBR preview shader compiles and renders without NaN. Path traced renders (bricks, 32 to 128 samples at 256² and 512²) have no NaN or infinite values; a 256² render with 32 samples takes about 3 s. Transparent backgrounds have alpha 0, and turntable frames differ and restore the object's rotation.
  - **Not verified:** the Unity and Unreal exports were not imported into Unity or Unreal (neither is installed here).
  - ~~**Still missing:** the path tracer has no direct light sampling (environment only, so it's noisy with small bright sources), no displacement, and no subsurface or refraction. OCIO in the 3D preview.~~ ✅ **Done (M12):**
    - **Sun light:** the brightest visible directional light is sampled directly (shadow rays in the cone of its angular size, with the full coat/fuzz/GGX/diffuse BSDF). It isn't part of the environment, so there's no double counting. Verified: the render gets brighter with the sun (mean 0.024 → 0.060) and keeps the same coverage.
    - **Displacement:** when the Material node has a depth scale, the mesh is subdivided (up to about 60k triangles, for the GDScript BVH) and moved inside by the depth map, as the Tesselated Material does. Corners shared by several faces (box edges, UV seams) move together, so the surface doesn't crack.
    - **Transmission:** thin walled transmission (light passes through surfaces), sampled and lit by the sun from behind.
    - Subsurface scattering and refraction are still missing.
    - OCIO in the 3D preview: see §4.3.

### 4.3 Color management — **L, high for studio adoption**
- **OCIO** integration: working space, per-bitmap input transforms, and display/view transforms in the 2D and 3D views.
- An ACES config by default option, with sRGB as the fallback.
- Correct linear/sRGB tagging on every bitmap input and export.

✅ **Done (2026-10-26), lite version without OCIO:**
- The **Image** node has a *Color space* parameter: *As is* (the default, so saved graphs don't change), *Linear* (converts linear colors to sRGB, MM's working encoding), and *Auto* (linear for EXR and HDR files). The conversion runs in the shader, so it also works on float images.
- **✔ checked:** the 3D preview already has view transforms (Linear, Reinhard, Filmic, ACES, AgX, with exposure and white point) in its post-process menu, so nothing was added there.
- The MaterialX and USD exports (§5.3) tag albedo and emission as sRGB and every other map as raw.
- ~~Still missing: real OCIO.~~ ✅ **Done (2026-10-26): OpenColorIO GDExtension** (`native/ocio`, built with `python native/ocio/build.py`):
  - **The extension:** `MMOCIO` is a godot-cpp (godot-4.5-stable) wrapper around OpenColorIO 2.6.0. OCIO is built as one DLL with its dependencies (expat, yaml-cpp, Imath, pystring, minizip-ng, zlib) linked in.
    - Configs are loaded from files or as OCIO's built-in configs. The default is the ACES studio config.
    - It lists color spaces, displays, views and roles.
    - It runs CPU conversions on float arrays and Images, and bakes display/view 3D LUTs.
  - **Optional:** the binaries go to `addons/material_maker/ocio` (not versioned). `MMColorManagement` checks `ClassDB.class_exists("MMOCIO")`, so Material Maker works unchanged without them.
  - **Image node:** a new *OCIO* color space converts an image from any config color space (the *OCIO color space* parameter) to the working space (`ocio_working_space`, default *sRGB - Texture*) when it loads.
  - **2D preview:** *View → View transform (OCIO)* lists every display/view (51 in the studio config). It's applied with a 33³ `sampler3D` LUT wrapped around the preview's post-processing, so OCIO's GLSL doesn't need translating to Godot's shader language.
  - **Verified:**
    - sRGB red converts to ACEScg as (0.6131, 0.0702, 0.0206) and round-trips back to (1.00002, 0, 0).
    - The *OCIO / Linear Rec.709 (sRGB)* Image mode matches MM's built-in *Linear* mode to within 1/255.
    - The *Un-tone-mapped* view LUT is exactly identity, and the ACES 2.0 SDR view maps white to 0.707.
    - The preview shader compiles in the full app, with the transform and after removing it.
  - **Still missing:**
    - ~~OCIO in the 3D preview, which uses Godot's tonemappers.~~ ✅ **Done (M12):** the post-processing menu has a *View transform (OCIO)* list. A transform replaces Godot's tonemapper: the preview viewport renders in HDR (linear and unclamped), and the transform's LUT (from the config's linear Rec.709 space) is applied when the viewport is drawn. Verified: *sRGB - Display / Un-tone-mapped* matches Godot's own linear output to 1/255 (mean 0.008/255), and removing the transform restores the preview exactly.
    - ~~Output transforms on export (e.g. writing ACEScg EXRs).~~ ✅ **Done (M11):** color maps (albedo and emission) are converted to the color space set in *Preferences → Color* or with `--color-space` (for example ACEScg). Data maps are never converted. Verified: an sRGB albedo exported with `--color-space ACEScg` gives the expected ACEScg values, and ORM is unchanged.
    - Linux and macOS builds of the extension, and CI.
    - ~~Values above 1 are clamped before the preview LUT (a shaper would fix that for HDR values).~~ ✅ **Done (M12):** LUTs (now 49³) have a shaped input: [0, 1] uses three quarters of the LUT (linearly for the working space, so LDR values are as precise as before, and as a square root for scene linear values), and values up to 16 the rest, logarithmically. Verified against OCIO's CPU transform from 0 to 10: max error 0.07/255.

**Full OCIO plan (assessed 2026-10-26, medium effort):**
- **GDExtension (moderate, mostly build work).** A small godot-cpp wrapper around OpenColorIO 2.x that exposes:
  - loading a config, or OCIO's built-in ACES configs, which need no file;
  - listing color spaces, displays and views;
  - building a processor (source→destination, or display/view);
  - returning the generated GLSL plus its LUT data, and converting images on the CPU.

  It's a few hundred lines, and OCIO generates the shader code itself. Most of the work is the build: static linking of yaml-cpp, expat, Imath, pystring, minizip and zlib, plus Windows/Linux/macOS binaries from a GitHub Actions matrix. `addons/godotsteam` shows how the repo already ships a GDExtension.
- **MM integration (moderate, GDScript):**
  - Image node input transforms, applied on the CPU at load or injected into the shader like the current sRGB conversion.
  - `sampler3D` support in the compute pipeline and uniform handling. Display/view transforms usually need 3D LUTs, and MM only handles `sampler2D` today.
  - A 2D preview view transform, and OCIO as an alternative to the 3D preview tonemapper.
  - Project working-space and config settings, and color-space tags in exports.
- **Toolchain:** MSVC (VS 2026 Build Tools) and CMake are now installed and used by the C++ runtime (§5.1). Still needed: vcpkg (or CMake FetchContent) for OCIO and its dependencies, and `pip install scons` for godot-cpp. Alternatively, build only in CI.
- **Estimate:** with a working toolchain, about one session for an extension that builds on Windows, one for the MM integration and tests, and one for cross-platform CI and packaging.
- **Risks:**
  - OCIO's generated GLSL may need small adaptations for MM's shader assembly and Godot's GLSL dialect.
  - It adds about 5–10 MB of binaries per platform.
  - Licensing is fine: OCIO is BSD-3, compatible with MIT.
- **Cheaper alternative (about 80% of the value, no native code):** a script that bakes OCIO transforms (such as ACES display views) into LUT files, plus a 3D LUT apply node and a LUT-based preview view transform in GDScript. It covers fixed views but not arbitrary user configs.

---

## 5. Phase 3: Pipeline and ecosystem (this is what makes studios adopt it)

### 5.1 Runtime material format and engine plugins — **XL, critical**
SD's moat is `.sbsar`: a parameterized procedural material that engines can re-render at runtime or import time.
- Define an **`.mmr` runtime package**: the compiled shader passes or compute pipeline, the exposed parameter schema, presets, and embedded resources.
- Build a **standalone headless renderer** library (C++/Vulkan, no Godot editor needed), so plugins can embed it.
- Plugins, in priority order: **Godot** (native, easiest), **Blender**, **Unreal**, **Unity**, **Houdini**.
- **Live link** between the MM editor and each engine to push parameter edits in real time.
- Optionally export procedural graphs as **pure engine shaders** (Godot/Unity/Unreal HLSL/GLSL) when they fit in a single pass. SD can't do this, so it's a differentiator.

✅ **Done (2026-10-26), first slice: the `.mmr` format, the exporter and the Godot runtime.** See [design/runtime_packages.md](design/runtime_packages.md).
- **Format v1:** a zip with a manifest and one GLSL 450 compute shader per pass.
  - Each pass records its size, format, std430 parameter layout and initial bytes, and its inputs (other passes or embedded textures).
  - The manifest also lists the material outputs (albedo, ORM, emission, normal, height), the Material node values, and the runtime parameters, each with the uniforms it drives.
  - Packages are small: bricks is 19 passes in 29 KB, medieval_wall 74 passes in 109 KB.
- **Exporter** (`engine/runtime/runtime_exporter.gd`):
  - It reuses MM's own compiled shaders. `MMPipeline.compiled_sources` keeps the preprocessed GLSL.
  - Buffers, including auto buffers and buffers inside subgraphs, become passes. Other textures (images, mesh maps, iterate buffers) are embedded at their current value.
  - Remote parameters are exposed when every control they drive, followed through subgraph parameters, is a shader uniform. The others are listed as baked, with the reason.
  - Available as `--export-mmr` in the CLI and `export_mmr` over RPC and Python.
- **Godot runtime** (`runtime/godot/addons/material_maker_runtime`, pure GDScript, Godot 4.3+):
  - `MMRPackage` reads packages, `MMRRenderer` runs the passes on a local RenderingDevice, and `MMRMaterial` builds a StandardMaterial3D with the same channel mapping as the Godot 4 export.
  - A parameter change re-renders only the dependent passes (3 of 19 for bricks' Hue, in 9 ms).
- **Verified:** the runtime output is pixel-identical (max difference 0/255) to MM's renders of the same Material outputs for bricks, rusted_metal, wood, medieval_wall and lava. For bricks this also holds after changing Hue at runtime, compared with `--set Hue=0.5`.
- ✅ **Standalone C++ renderer** (`runtime/cpp`, 2026-10-26): a C++17 library and the `mmr_render` tool.
  - It runs passes with Vulkan compute. volk loads the driver's Vulkan loader, so no SDK is needed.
  - It uses SPIR-V that the exporter now stores next to the GLSL, so no GLSL compiler is needed either.
  - Dependencies (Vulkan-Headers, volk, miniz, nlohmann/json, tinyexr) are fetched by CMake.
  - **Verified:** its PNGs are byte-identical to MM's for all 23 outputs of 5 examples, including after a runtime Hue change. Animated materials match MM's flipbook frames exactly at 4 times.
  - **Speed:** bricks renders in 18 ms on a Radeon 780M, and a Hue change re-renders 3 of 19 passes in 3.7 ms.
- **Still missing:**
  - CI builds of the C++ runtime for each platform.
  - ~~Blender plugin.~~ ✅ **Done (M11): Blender add-on** (`runtime/blender/material_maker_runtime`, Blender 4.2+ extension). It imports `.mmr` packages as Principled BSDF materials, rendering textures with `mmr_render`, and its *Material Maker* panel edits the package's parameters and presets, with optional live updates. Verified in Blender 5.2: the extension builds, installs and enables; importing a package creates a material with the right maps and color spaces, which Cycles renders without missing textures; and parameter changes (live update) and presets render new textures.
  - Unreal, Unity and Houdini plugins.
  - Live link. (Presets were done in M7: the `presets` in the manifest, `apply_preset` in the Godot runtime, and `--preset` in `mmr_render`.)
  - ~~Exposed seeds and runtime-resizable outputs.~~ ✅ **Done (M12):** packages with random nodes have a `seed` parameter. Its targets list the seeds each seed uniform sums (a node's seed and the ones it inherits), so runtimes compute exactly what `--seed` does. Runtimes can also scale all passes to another output size (`MMRMaterial.load_material(path, size)`, `mmr_render --size`, the Blender add-on's *Texture size*). Verified: `--set seed=3` renders byte-identical to a package exported with `--seed 3` (bricks and medieval_wall, C++ and Godot runtimes identical); half size renders are within 0.33 and 1.19/255 (mean) of downsampled full size renders; in Blender, the seed and texture size update the textures.

### 5.2 Scripting and automation — **L, high**
- A documented **Python API** (via a Godot Python binding or a JSON-RPC bridge), plus the existing GDScript. Cover graph creation and edit, cook, export, and baking.
- Plugin system for menu actions, custom panels, and import/export hooks.
- Grow the **CLI** into an SD Automation Toolkit equivalent. **✔ checked:** it currently handles `--export`/`--export-material` with `-t/--target`, `-o/--output-dir`, `--output-file`, and `--size`, but has no parameter overrides or bake mode:
  - `mm-render`: cook a graph or package with parameter overrides and output size.
  - `mm-bake`: mesh bakes.
  - `mm-cook`: build `.mmr` runtime packages.
  - `mm-mutate`: batch-change parameters, generate variations, swap bitmaps.
- Headless operation on CI and render farms (no display server).

✅ **Done (2026-10-26):**
- **CLI** (`parse_args.gd`, `cli/cli_tools.gd`). See [command_line.rst](material_maker/doc/command_line.rst).
  - New modes: `--render --node <node[:output]>` writes PNG or EXR, `--bake --maps <...>` bakes mesh maps, and `--list-parameters` lists what can be set.
  - Every mode accepts `--set name=value` (repeatable). The name is a remote parameter's name or label, or `node:parameter`.
  - `--seed n` and `--variations n` cover the mutator use case. Variation files get a `_v<i>` suffix, and `--seed 3` reproduces variation 0 of `--variations` with the same seed.
  - Options after `--` also work. Godot itself takes `-t` (always on top) and `--help`, so the docs use `--target`.
  - The existing exports are byte-identical to before.
- **JSON-RPC server** (`tools/rpc/rpc_server.gd`). Start it with `--rpc-port <port>` alongside the user interface, or `--rpc` without it. It listens on 127.0.0.1 only and takes one JSON-RPC 2.0 request per line.
  - Methods: load, save, new graph, list nodes, connections and parameters, set parameters, create, delete, connect and disconnect nodes, reseed, render, list export targets, export, undo/redo, and quit.
  - In the user interface, edits act on the current graph and go through undo. Parameter changes use the same `setparams` actions as the node UI.
- **Python client** (`python/material_maker_client`, no dependencies), with `launch()` to start MM, and an example (`python/examples/variations.py`). See [scripting.rst](material_maker/doc/scripting.rst).
- Tested end to end: 20 checks without the user interface and 10 with it, including undo/redo.
- Still missing:
  - A plugin system.
  - Truly headless runs. Godot's `--headless` has no RenderingDevice, so a minimized window is still needed. **Investigated (M12):** `--headless` (with any rendering driver, Vulkan or D3D12) replaces the renderer by a dummy one, and neither the global nor a local RenderingDevice can be created. With a normal display driver, a local RenderingDevice works while the root window is hidden, but Godot refuses to hide its main window (*Can't change visibility of main window*), so command line modes keep the 1×1, transparent, minimized window. `--headless` now stops with an explanation (it used to wait forever for a device), and the documentation suggests a virtual display (xvfb-run) for Linux servers. A truly headless mode would need an engine change (a RenderingDevice without a display server).
  - `mm-cook`, which depends on §5.1.
- **Upstream bug found and fixed in M4 (§4.1):** baking ambient occlusion, thickness and bent normals segfaulted on Vulkan, in the CLI, with the full user interface, and on the upstream base commit. The cause was an invalid `texture()` call with a LOD bias in the denoise compute shader.

### 5.3 Standards interop — **M–L**
- **MaterialX** export: baked texture sets now, and the procedural node subset later. Also MaterialX import of common nodes.
- **USD** (UsdPreviewSurface/OpenPBR) material export.
- **glTF** with KHR material extensions. Then OpenEXR multi-layer, DDS (already in 1.5), KTX2, and TX.
- **✔ checked:** export presets already exist for Godot 3/4 (Standard, ORM, CanvasItem, Dynamic Sky), Unity (3D, URP, HDRP), Unreal 4/5, and Blender. What's left is user-editable naming templates and custom channel-packing presets. There is no MaterialX, USD, or OCIO code anywhere in the tree.

✅ **Done (2026-10-26): MaterialX and USD texture-set export.** There are three new targets on the Material node (`nodes/material.mmg`): *MaterialX/Standard Surface* (1.38), *MaterialX/OpenPBR* (1.39) and *USD/UsdPreviewSurface*.
- **What's exported:** maps are written only for connected inputs (albedo + opacity, metallic, roughness, normal, emission, height, and AO for USD). The Material node's color and multipliers are applied in the graph, and the normal map uses the OpenGL convention.
- **Validation:** the files pass MaterialX 1.39.5 `validate()` and MaterialX GLSL generation. They also open in USD (`usd-core`) with every connection and texture resolved, tested on three graphs including one with every input connected.
- ~~Still missing: procedural MaterialX export, MaterialX import, and glTF KHR extensions.~~ ✅ **Done (2026-10-26, M12):**
  - **Procedural MaterialX** (*MaterialX/Procedural*): a custom node with a genglsl implementation (the graph's generated GLSL, with buffers inlined: `MMGenBuffer.inline_buffers`) feeds a standard_surface. Verified with MaterialX 1.39.5: the documents validate, and MaterialX's own GLSL texture baker renders the four examples (1941 lines of GLSL for medieval_wall). Base color and roughness have the same structure as MM's maps but differ per texel by 10 to 39/255 (mean), because MM's hash noises are sensitive to the precision of each compiler (here OpenGL's). GLSL targets only (not OSL or MDL), and iterate buffers are not supported.
  - **MaterialX import** (`engine/materialx_import.gd`, no MaterialX dependency): .mtlx files can be loaded in the user interface, from the command line and over RPC. The material's standard_surface, open_pbr_surface, UsdPreviewSurface or gltf_pbr inputs become Material inputs and parameters, through image, tiledimage, UsdUVTexture, constant, multiply, convert, extract, swizzle, separate and normalmap nodes (with file prefixes and color spaces). Unsupported nodes are reported. Verified: MM's Standard Surface and OpenPBR exports of bricks and medieval_wall round trip to the same maps (max 1/255), and a hand written UsdPreviewSurface material with an ORM texture, a linear EXR and a scaled emission imports as expected.
  - **glTF:** the *GLTF/Plane* export has KHR_materials_clearcoat, sheen, anisotropy and transmission, with textures for connected inputs. Verified: Blender 5.2's glTF importer links coat, coat roughness, anisotropy and transmission to the textures and reads the sheen.

### 5.4 Scan and photo workflows — **L (niche)**
- Multi-angle-to-material and photometric-stereo normal reconstruction. ✅ **Photometric stereo done (2026-10-26):** a **Photometric Stereo** node (*Filter/Photometric Stereo*) reconstructs a normal map, in MM's convention, and an albedo map from 4 photos lit from the right, top, left and bottom at a known elevation. On synthetic Lambertian renders it recovers albedo 0.698 (true value 0.7), and normals are within 0.006 of the true ones.
- AxF import.
- ML-assisted delighting and image-to-PBR (optional ONNX runtime). Ship models with permissive licences only.

### 5.5 Asset ecosystem — **M + community**
- A curated **official library** with a consistent quality bar, tags, and previews. SD's advantage here is the size of the Substance Assets catalogue.
- Package versioning and update notifications on the MM website. Submissions validated in CI by rendering with `mm-render`. ✅ **Validation done (2026-10-26):** `python/validate_library.py` creates every library node and renders it, and renders the example materials, through the RPC server. RPC `create_node` now accepts library item dictionaries.
  - **Upstream bugs found and fixed by the validation run:**
    - Deleting a node while one of its buffers was rendering (closing a project, replacing a graph) dropped the coroutine the dependency update loop was awaiting. The loop stayed "updating" forever: no buffer was rendered again, and every render or export waited until its timeout. A new loop now takes over, and a generation counter stops the old one if it ever resumes (`dependencies.gd`).
    - Buffers that failed to render counted as pending forever. They're no longer counted, and RPC renders report them.
    - `render_node` (CLI and RPC) could render before the automatic buffers that its own shader generation had just created. It now waits for them.
    - An Iterate Buffer without inputs never compiled its shaders (only source changes did), and with an unconnected loop input it never finished iterating. It now compiles on ready, and stops after one loop pass when the loop input doesn't use the loop output.
    - Unconnected inputs read with `$in.variation(uv, v)` replaced `$uv` with the whole argument list, so Kaleidoscope (and other nodes using variations) didn't compile until connected (`gen_shader.gd`).
    - Tiler Color and Layer Color had float defaults on RGBA inputs, which didn't compile when unconnected.
    - With these fixes, all 345 library items and 43 examples render.
- Packages for weathering filters, smart masks, and engine output templates.

### 5.6 Substance migration path with sbsar2ptex — **M–L, high leverage**
[sbsar2ptex](https://github.com/rbroderi/sbsar2ptex) already does three things:
- Bakes an `.sbsar` (through `sbsrender`) into a `.ptex` graph of Image nodes feeding a Material node.
- Decompiles the compiled `.sbsasm` graph into atomic nodes (`sbsasm-dump`).
- Translates many atomic filters into MM shader nodes, each within 3/255 of `sbsrender`. Covered so far: levels, curve, HSL, gradient map, all 12 blend modes, transform, blur, directional blur/warp, warp, sharpen, emboss, normal, distance (jump flooding), and pixel processors, including a bit-exact clone of Substance's `rand`.

What it means for this plan:
- **It's the shortest path to "SD users can bring their materials."** Wire it into MM as an *Import .sbsar* menu action, by calling the CLI or bundling it. Then let users choose between *baked* and *translated (procedural)* import.
- **Its translator is a test oracle for §3.1 and §3.3.** Every filter it reproduces in GLSL is a candidate for a native MM node. Its `function.py` (function graphs → GLSL) is a working prototype of the function-graph compiler §3.1 needs. Design MM's function-graph intermediate representation (IR) so sbsar2ptex can target it directly.
- **FX-Maps are its biggest untranslated piece**, which makes §3.2 (the FX-Map equivalent) a prerequisite for full procedural import. Raise §3.2's priority if `.sbsar` import matters.
- **Licensing:** sbsar2ptex is GPL-3.0-or-later and Material Maker is MIT. As long as it stays a separate tool that MM calls, nothing changes. Copying its translator code into MM's core needs a relicense of those parts (you're the author) or a clean reimplementation.
- **Regression harness:** `scripts/check_filters.py` (compare against `sbsrender`) already provides a golden-image comparison approach. Reuse it for §8's regression suite.

---

## 6. Where MM can exceed SD (lean into these)

1. **Integrated painting plus procedural graph**: SD needs Painter for this. Make painted layers first-class graph inputs, and graph outputs paintable. ✅ **Painted layers as inputs done (2026-10-26):**
   - The **Paint Layer** node (`engine/nodes/gen_paint_layer.gd`, *Simple/Paint Layer*) reads a channel of a paint project (.mmpp): albedo, metallic, roughness, emission, normal, depth or occlusion.
   - It reads one layer, or all visible layers composited as the painter does (masks, channel opacities, normal and occlusion backgrounds), in the node's generated shader.
   - It follows the project when it is saved again.
   - Painting with graphs already existed as procedural layers. ✅ **Live updates (M11):** when the project is open in the painter, the node reads its layers from memory after each stroke and each layer change, without saving.
   - ✅ **Graph outputs paintable (M12):** *Layer from material...* in the painter's add layer menu renders a material graph's maps (albedo, metallic, roughness, emission, normal, depth, occlusion) into a paint layer at the project's size, which can then be painted over, erased or masked. Verified: the layer gets bricks' maps with the painter's channel packing and normal convention.
2. **Graph → native shader export**: runtime-procedural materials with no plugin at all. ✅ **Done (2026-10-26, M12):** the Static PBR Material has *Godot/Godot 4 Shader*, *Unity/Built-in Shader* and *Unreal/Unreal Engine 5 Shader* targets (upstream's Dynamic PBR Material had similar ones, which this work also fixes). The shader computes the graph; buffers are exported as textures.
   - **Godot:** graph parameters are shader uniforms with their values (editable in the inspector; uniform arrays are constants, as Godot can't initialize them). Verified on bricks, wood, lava and medieval_wall: the shader's albedo, ORM, emission and normal match the texture export texel for texel (albedo mean 0.4 to 0.5/255, 100% within 2/255; normals within 0.7 to 2.6/255 mean), and lit renders match too (lava 1.07/255 mean). Constants instead of uniforms broke the match: compile-time evaluation changes MM's precision-sensitive hash noise.
   - **Unity and Unreal:** HLSL translations, compiled with Slang for all four examples (with stubs for the engines' definitions). Running the Unreal code on the GPU gives the same material structure but a different noise instance (mean 17/255 on bricks), for the same precision reasons, even with uniforms. Neither engine was available to test in.
   - **Upstream bugs fixed along the way:** templates with several `$begin_generate` blocks repeated the code of previous blocks and reused their variables (redefinitions, or code using another block's UVs); exports whose templates generate code didn't export (or bind) the buffers that code samples; the HLSL definitions lacked GLSL constructor forms (`vec2(vec2)`, `vec4(float, vec2, float)`...); Unreal 5's initializations of buffer sizes didn't use the renamed buffers, and its DX9 `textureLod` helper doesn't compile; the parallax used `-VERTEX` as the view direction (wrong for orthographic views); emission was not linearized. The Godot 4 Standard export didn't set `ao_light_affect`, so exported AO didn't darken direct light as MM's preview does.
3. **True 3D/volumetric textures and SDF scenes**: MM's SDF and raymarching heritage is ahead of SD 16's new SDF nodes. Add 3D texture export (VDB, 3D DDS/KTX) for volumetrics. ✅ **Done (2026-10-26):** `engine/volume_export.gd` samples TEX3D and SDF3D outputs (all slices in one compute pass) and writes:
   - **OpenVDB** (format 224, uncompressed, sparse 5-4-3 trees): SDFs as narrow band level sets, grayscale textures as fog volumes, colors as a vec3 grid plus density.
   - **3D DDS** (DX10 header) and **KTX2** (with a data format descriptor), in 16F, 32F or 8 bits.
   - Available from the 2D preview's export menu, the CLI (`--export-volume`) and RPC (`export_volume`).
   - **Verified:** OpenVDB 13 (Blender 5.2's Python module) reads the files with exact level set values, transform and active voxels. Blender imports them as Volume objects. DDS and KTX2 headers and voxels match an independent reader written from the specifications (`pyktx` does not build here, so KTX-Software's validator was not run).
   - **Speed:** 128³ in about 7 s and 256³ in 18 s, including startup.
4. **Animated and time-based materials**: `$time`-driven graphs, flipbook and sprite-sheet export, and live animated previews (sky, water, fire). ✅ **Done (2026-10-26):**
   - `--render --frames n [--duration s] [--columns c]` renders sprite sheets. The time is fixed per frame (`MMComputeShader.fixed_time`), and buffers, including automatic ones, are rendered again for each frame.
   - Runtime packages have a `time` parameter on the passes that use `$time`, so engines can animate them.
5. **Open, diff-friendly file format**: `.ptex` is JSON. Add a stable schema, a merge tool, and a git diff/merge driver for graphs. ✅ **Done (2026-10-26):** `python/ptex_tools.py` has four commands.
   - `validate` checks files against `python/ptex.schema.json` (JSON schema draft 2020-12: nodes, connections, typed parameter values, shader models, remote widgets), with a built-in validator, and checks that connections refer to existing nodes. All 476 .ptex and .mmg files in the repository pass, with the built-in validator and with `jsonschema`.
   - `normalize` gives a canonical order, for use as git's textconv.
   - `diff` is semantic: nodes, parameters and connections, recursively into subgraphs.
   - `merge` is a three-way merge: nodes are matched by name, connections are sets, and parameters and subgraphs merge recursively. Conflicts are reported. It can serve as git's merge driver.
   - It comes with unit tests.
6. **Free, MIT, native on Linux, macOS, and Windows, and on Steam**: no licence server, so it can be used on farms and in CI at no cost.
7. **AI-assisted authoring**: describe a material in text and get a starting graph built from the node library. Also "explain this graph" and LLM-generated GLSL custom nodes, validated by compiling them.
8. **Web export**: a WebGPU/WebGL runtime for `.mmr` packages, so procedural materials can be previewed and tweaked in a browser.

---

## 7. Suggested sequencing

| Milestone | Contents | Why this order |
|---|---|---|
| **M1: Engine** | 2.1 cooking/cache, 2.2 per-node size/format, 2.3 reductions, 2.4 profiler | Everything else (FX-Map, auto levels, large graphs, runtime packages) depends on it |
| **M2: Authoring + migration** | 3.1 function graphs (shared IR with sbsar2ptex), 3.3 top-priority nodes (Splatter v2, Non-Uniform Blur, Distance, Spline Mapper, Histogram Scan), 3.4 instancing/versioning, 5.6 *Import .sbsar* (baked first) | Removes the main reasons SD artists bounce off MM, and gives them a way to bring their libraries over |
| **M3: Pipeline core** ✅ (2026-10-26, OCIO GDExtension added later the same day; plugins deferred) | 5.2 CLI/Python, 5.3 export presets and MaterialX texture export, 4.3 OCIO | Gets MM into studio pipelines even before runtime plugins exist |
| **M4: 3D** ✅ (2026-10-26, UDIM, hardware RT, path tracer and OpenPBR preview deferred) | 4.1 baker suite, 4.2 tessellation and OpenPBR | Replaces SD's baker plus Painter-lite in one tool |
| **M5: Runtime** ✅ (2026-10-26: format, exporter, Godot runtime, C++/Vulkan runtime; Blender/Unreal/Unity plugins pending) | 5.1 `.mmr` plus headless renderer, then Godot → Blender → Unreal → Unity plugins | Biggest effort, biggest moat-breaker |
| **M6: Exceed** ✅ first slice (2026-10-26: FX-Map, photometric stereo, flipbooks and animated packages, ptex diff/merge, library validation) | §6 items, 3.2 FX-Map (unlocks fully procedural `.sbsar` import), 5.4 scans, 5.5 library | Differentiation once parity is credible |
| **M7: Authoring parity** ✅ (2026-10-26: programmable FX-Map, function graph undo, weathering/atlas/normal/bitmap nodes, SVG, parameter groups, hard ranges, presets, engine templates) | 3.1–3.4 remaining items | Closes most of the day-to-day authoring gaps with SD |
| **M8: UX and node gaps** ✅ (2026-10-26: 2D inspection, fuzzy search, swatches, instance diffs, Tile Sampler, Spline Bridge, Ribbon, blur blades, water level, atlas islands, Patch Tiling, Photo to Material, SVG shapes) | 3.3 and 3.4 remaining items | Finishes the authoring phase |
| **M9: Engine follow-ups** ✅ (2026-10-26: nested FX-Map iterations, SVG Bézier curves, pins kept when grouping, calibrated buffer costs, buffer badges and precision warnings) | Leftovers of 2.1, 2.2, 3.2 and 3.3 | Closes the small gaps left in phases 0 and 1 |
| **M10: Painting and volumes** ✅ (2026-10-26: Paint Layer node, VDB/3D DDS/KTX2 export) | §6 items 1 and 3 | Leans into what SD can't do |
| **M11: Viewport and pipeline** ✅ (2026-10-26: OpenPBR preview shading, path tracer, turntables, extra channel exports, OCIO on export, .ptex schema, live paint layers, Blender add-on) | 4.2 and 4.3 leftovers, first DCC plugin of 5.1 | Presentation renders and the first plugin outside Godot |
| **M12: Shaders and interop** ✅ (2026-10-26: procedural shader exports, procedural MaterialX and MaterialX import, glTF KHR extensions, paintable graph outputs, baker match-by-name/skew/texture transfer, path tracer sun/displacement/transmission, OCIO in the 3D preview with HDR LUTs, runtime seeds and sizes, non-square outputs, headless investigation) | §6 item 2, 5.3 leftovers, follow-ups of M4–M11 | Materials that run in engines without textures, and the remaining interop gaps |

**Quick wins** (status as of 2026-10-25):
1. ✅ **Profiler summary**: Iterate Buffer timing, plus *Tools → Show buffer render times* (§2.4).
2. ✅ **16k output**: the size cap went from 2^13 to 2^14 (16384) on Buffer, Iterate Buffer, Export, Auto Export, and the Material/Tesselated Material nodes. Texture creation now checks the GPU's `LIMIT_MAX_TEXTURE_SIZE_2D` and fails cleanly with an error instead of reaching the driver. Bit depth is already 16F by default with an optional 32F toggle, so the only format left to add is 8-bit (memory saving). That's deferred because it changes the texture-type bitmask used across the pipeline.
3. ⏸ *Import .sbsar (baked)* via sbsar2ptex (§5.6): on hold by request.
4. ✅ **Flood Fill To Index**: done with the analysis pass in §2.3.

✅ **Fixed (2026-10-25): startup race.** Buffers could compile shaders before `mm_renderer` had created its rendering device (it's created asynchronously on the rendering thread). Some CLI exports logged `Cannot call method 'shader_compile_spirv_from_source' on a null value` (1 run in 3 on upstream). Shader compilation now waits for the device (`mm_renderer.wait_for_rendering_device()`), and 6 out of 6 test exports were clean.

✅ **Fixed (2026-10-26): Iterate Buffers that never finish** (upstream bug). If an Iterate Buffer's first-iteration input was invalidated while it was being rendered, it was later processed with the loop shader and never marked as updated. The render queue then never drained, which affected Fill, Mask to SDF and anything else built on Iterate Buffer. Now, an invalidated first iteration restarts the iterations, and whichever pass was requested is always marked updated (`gen_iterate_buffer.gd`). The render queue now drains to 0.

**Rough total:** about 2–3 years for a small team (3–5 devs). M1 through M3 alone, about 9–12 months, would make MM a credible SD alternative for most game-texture work.

## 8. Risks

- **Architecture churn**: §2.1 touches the core of MM's shader generation. Prototype it in a branch behind a flag, and keep existing `.ptex` files rendering identically. Use a golden-image regression suite built with `mm-render`.
- **Godot coupling**: the headless runtime (§5.1) argues for extracting the graph compiler into an engine-independent library.
- **Precision and format drift**: per-node formats will change how existing materials look. Version the file format and default old files to legacy behaviour.
- **Scope**: library parity is open-ended. Drive it from user-reported missing nodes and a ranked audit, not a 1:1 clone.
