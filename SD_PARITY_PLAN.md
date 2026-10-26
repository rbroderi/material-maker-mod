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
| Mesh baking | Same-mesh maps only: position, normal, tangent, AO, bent normals, thickness, curvature, seams, adjacency (BVH-based, `map_generator/`) ✔. No high→low, cages, ID maps, or UDIMs | Full baker suite: high→low, cages, ID, thickness, bent normals, UDIM | **High** |
| SD interop | `.sbsar` → `.ptex` via the separate sbsar2ptex tool (baked maps; node translation in progress) | n/a | MM-side opportunity |
| 3D viewport | Godot renderer | OpenPBR, GPU path tracer, tessellation/displacement popup, OCIO | Medium–High |
| Color management | sRGB/linear only | OCIO/ACES | **High** for studios |
| Runtime format | Export textures / engine shaders | `.sbsar` + engine plugins (Unreal, Unity, Houdini, Maya, Max, Blender) | **Critical** for pipelines |
| Automation | CLI `--export` with `--target`, `--output-dir`, `--output-file`, `--size` (`parse_args.gd`) ✔. No Python | Python API, plugins, Automation Toolkit (cooker/render/baker/mutator) | **High** |
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

Not done: pins are dropped when nodes are grouped into a subgraph, cost weights aren't calibrated against measured timings yet, and per-node *format* control is §2.2.

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
- Non-square sizes: every texture-size uniform and the size widgets assume square textures, so this is a separate refactor.
- Size and format badges on nodes (the render-times dialog shows memory instead).
- Precision-loss warnings.

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

Not done: milestone 5 (sbsar2ptex emitting the IR) is on hold, there's no undo inside the editor itself, and FX-Map random streams wait for §3.2.

### 3.2 FX-Map equivalent — **L**
A recursive quadrant/iterate/switch splatting system with per-instance random seeds, blend modes, and pattern inputs. Implement as a compute-based instancing pass (it pairs with §2.1). MM's tile and splatter nodes cover the common cases. The gap is the general-purpose programmable version.

### 3.3 Node library parity — **L (ongoing)**
Audit against SD's library. Priority gaps to check or build:
- **Shape Splatter v2 parity**. **✔ checked:** MM's Splatter and Circle Splatter take count, scale, rotation, value, variations, and a mask input, and that's all. Missing: Poisson disc and uniform distributions, a density map, per-instance control maps, height-ordered blending, and data outputs (position, rotation, scale, ID maps). ✅ **Done (2026-10-26): Shape Splatter** (`nodes/splatter_v2.mmg`, *Transform/Shape Splatter*):
  - Poisson-like, uniform or grid distribution.
  - Density, scale and rotation maps.
  - Random scale, rotation and height.
  - Max (height-ordered) or Add blending.
  - Output, instance ID, position and mask outputs.
  - Tiles seamlessly.
- **Tile Sampler parity**. **✔ checked:** Tiler Advanced already has a mask input, per-tile translate/rotate/scale map inputs, two color inputs, multiple input patterns, overlap, and variations. There are also the Height to Angle/Offset and Remap helpers. Missing: vector-map displacement, pattern selection by map, symmetry options, and height-ordered stacking. This is a **smaller gap than first assumed (M, not L)**.
- **Splines and paths**. **✔ checked:** MM has one Splines node (edge, fill, and guide inputs) and Poly Curve (with a width map). Poly Curve already stretches a pattern along a path. ✅ **Done (2026-10-26): Spline Mapper** (`nodes/spline_mapper.mmg`, *Simple/Spline Mapper*) places pattern instances along a curve, oriented to it, with random scale, rotation, offset and height, and height-ordered blending. Still missing: Spline Bridge, spline warp, and Ribbon/Ribbon Path.
- **Flood Fill suite**. **✔ checked:** largely at parity. MM has To Color, To Gradient, To Orientation, To Position, To Random Color/Gray, To Size, To UV, To RGBA, Select, and From Colors. Missing: To Index and a Flood Fill Mapper (pattern per cell).
- **Advanced filters**. **✔ checked, already present:** Slope Blur, Directional Blur, Directional Warp, Multi Warp, Edge Detect (3 variants), Bevel, Normal Map / Normal Blend / Normal Map Convert, Normal to Height, Smooth Curvature, HBAO, Occlusion, Height Blend, Quantize, Tones (levels), and Auto Tones. **Done (2026-10-25): Non-Uniform Blur** (`nodes/non_uniform_blur.mmg`, library *Filter/Blur/Non-Uniform*). It's a golden-angle disc blur whose radius comes from an intensity map, with anisotropy, angle, and sample count. It doesn't yet have SD's "blades" (polygonal bokeh). ✅ **Done (2026-10-26): Distance** (`nodes/distance.mmg`, *Filter/Distance*). It outputs a distance falloff and source colors propagated from the mask's white areas, accurate to 1–2 px.
  - It uses a corrected jump flood: the step halves each pass, and sampling is at pixel centers.
  - Upstream **Mask to SDF** has both bugs. It uses `size/4/k` steps and samples at pixel corners, so with filtering it was off by about 0.04 UV outside the shape and about 0.15 UV inside it. It's left unchanged so existing graphs keep their output.

  Histogram Scan/Shift/Select are done (§2.3). Still missing: Normal Normalize, Whiteout/RNM combine modes *(check Normal Blend's modes)*, and dithered posterize.
- **Atlas tooling**: Atlas Splitter, Atlas Scatter, Atlas Creator, rotate-to-fit, per-atlas-item IDs.
- **✔ checked:** a **Text node** exists (`gen_text.gd`). An **SVG/vector node** with editable paths is still missing.
- **Weathering and material generators**: edge wear, dirt, grunge, water-level, moss and dust (the "Material Filters" family).
- **Bitmap-to-material**: delight, crop/tile-fix, make-it-tile (patch-based), clone patch, and PBR from photo.

### 3.4 Graph UX and organization — **M**
- **Graph instancing with versioning**: a subgraph instance records its source version, with "update outdated instances" and diff-before-update. ✅ **Done (2026-10-26)** (`tools/library_manager/library_instances.gd`, *Tools → Library instances*):
  - Nodes created from library items that embed their definition (graphs, custom shaders) record the item and definition hashes.
  - The window shows instances that are outdated or were modified locally.
  - Updating keeps parameter values, seed and connections, and is undoable.
  - Not done: a visual diff before updating.
- **Dependency manager**: list every external dependency (packages, bitmaps, fonts), relink missing ones, and package graphs with their resources. ✅ **Done (2026-10-26)** (`windows/dependencies/`, *Tools → Dependencies*):
  - Lists every file parameter (images, fonts), including in subgraphs.
  - Relinks one file, finds missing files by name in a folder, or collects all files into a folder.
  - All of it is undoable.
- **Parameter UI**: groups, tooltips, sliders with soft/hard ranges, presets per graph, and color-picker swatches.
- **Presets/variations** UI on top of the 1.6 Controlled Variations system.
- Pinned 2D-view inspection of any output, side-by-side compare, channel isolation, tiling preview, and a pixel value picker that shows float values.
- **Graph templates**: Unreal, Unity HDRP/URP, Godot, glTF, and OpenPBR output sets.
- Faster search with fuzzy matching and the most-recent nodes first; connect-by-drag-to-empty-space search.

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

### 4.2 Viewport and rendering — **L**
- **Displacement/tessellation** preview with height scale and level controls (like SD 16's displacement popup).
- An **OpenPBR** shading model alongside the current one. Map outputs to Godot's StandardMaterial and to OpenPBR.
- **Progressive path tracer** for look-dev (compute-based, accumulating). Optional, but expected for presentation renders.
- HDRI library, rotation and exposure, ground shadow catcher, and turntable/render-to-image.
- Clear-coat, sheen, subsurface, anisotropy, and transmission channels in the material output.

### 4.3 Color management — **L, high for studio adoption**
- **OCIO** integration: working space, per-bitmap input transforms, and display/view transforms in the 2D and 3D views.
- An ACES config by default option, with sRGB as the fallback.
- Correct linear/sRGB tagging on every bitmap input and export.

---

## 5. Phase 3: Pipeline and ecosystem (this is what makes studios adopt it)

### 5.1 Runtime material format and engine plugins — **XL, critical**
SD's moat is `.sbsar`: a parameterized procedural material that engines can re-render at runtime or import time.
- Define an **`.mmr` runtime package**: the compiled shader passes or compute pipeline, the exposed parameter schema, presets, and embedded resources.
- Build a **standalone headless renderer** library (C++/Vulkan, no Godot editor needed), so plugins can embed it.
- Plugins, in priority order: **Godot** (native, easiest), **Blender**, **Unreal**, **Unity**, **Houdini**.
- **Live link** between the MM editor and each engine to push parameter edits in real time.
- Optionally export procedural graphs as **pure engine shaders** (Godot/Unity/Unreal HLSL/GLSL) when they fit in a single pass. SD can't do this, so it's a differentiator.

### 5.2 Scripting and automation — **L, high**
- A documented **Python API** (via a Godot Python binding or a JSON-RPC bridge), plus the existing GDScript. Cover graph creation and edit, cook, export, and baking.
- Plugin system for menu actions, custom panels, and import/export hooks.
- Grow the **CLI** into an SD Automation Toolkit equivalent. **✔ checked:** it currently handles `--export`/`--export-material` with `-t/--target`, `-o/--output-dir`, `--output-file`, and `--size`, but has no parameter overrides or bake mode:
  - `mm-render`: cook a graph or package with parameter overrides and output size.
  - `mm-bake`: mesh bakes.
  - `mm-cook`: build `.mmr` runtime packages.
  - `mm-mutate`: batch-change parameters, generate variations, swap bitmaps.
- Headless operation on CI and render farms (no display server).

### 5.3 Standards interop — **M–L**
- **MaterialX** export: baked texture sets now, and the procedural node subset later. Also MaterialX import of common nodes.
- **USD** (UsdPreviewSurface/OpenPBR) material export.
- **glTF** with KHR material extensions. Then OpenEXR multi-layer, DDS (already in 1.5), KTX2, and TX.
- **✔ checked:** export presets already exist for Godot 3/4 (Standard, ORM, CanvasItem, Dynamic Sky), Unity (3D, URP, HDRP), Unreal 4/5, and Blender. What's left is user-editable naming templates and custom channel-packing presets. There is no MaterialX, USD, or OCIO code anywhere in the tree.

### 5.4 Scan and photo workflows — **L (niche)**
- Multi-angle-to-material and photometric-stereo normal reconstruction.
- AxF import.
- ML-assisted delighting and image-to-PBR (optional ONNX runtime). Ship models with permissive licences only.

### 5.5 Asset ecosystem — **M + community**
- A curated **official library** with a consistent quality bar, tags, and previews. SD's advantage here is the size of the Substance Assets catalogue.
- Package versioning and update notifications on the MM website. Submissions validated in CI by rendering with `mm-render`.
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

1. **Integrated painting plus procedural graph**: SD needs Painter for this. Make painted layers first-class graph inputs, and graph outputs paintable.
2. **Graph → native shader export**: runtime-procedural materials with no plugin at all.
3. **True 3D/volumetric textures and SDF scenes**: MM's SDF and raymarching heritage is ahead of SD 16's new SDF nodes. Add 3D texture export (VDB, 3D DDS/KTX) for volumetrics.
4. **Animated and time-based materials**: `$time`-driven graphs, flipbook and sprite-sheet export, and live animated previews (sky, water, fire).
5. **Open, diff-friendly file format**: `.ptex` is JSON. Add a stable schema, a merge tool, and a git diff/merge driver for graphs.
6. **Free, MIT, native on Linux, macOS, and Windows, and on Steam**: no licence server, so it can be used on farms and in CI at no cost.
7. **AI-assisted authoring**: describe a material in text and get a starting graph built from the node library. Also "explain this graph" and LLM-generated GLSL custom nodes, validated by compiling them.
8. **Web export**: a WebGPU/WebGL runtime for `.mmr` packages, so procedural materials can be previewed and tweaked in a browser.

---

## 7. Suggested sequencing

| Milestone | Contents | Why this order |
|---|---|---|
| **M1: Engine** | 2.1 cooking/cache, 2.2 per-node size/format, 2.3 reductions, 2.4 profiler | Everything else (FX-Map, auto levels, large graphs, runtime packages) depends on it |
| **M2: Authoring + migration** | 3.1 function graphs (shared IR with sbsar2ptex), 3.3 top-priority nodes (Splatter v2, Non-Uniform Blur, Distance, Spline Mapper, Histogram Scan), 3.4 instancing/versioning, 5.6 *Import .sbsar* (baked first) | Removes the main reasons SD artists bounce off MM, and gives them a way to bring their libraries over |
| **M3: Pipeline core** | 5.2 CLI/Python, 5.3 export presets and MaterialX texture export, 4.3 OCIO | Gets MM into studio pipelines even before runtime plugins exist |
| **M4: 3D** | 4.1 baker suite, 4.2 tessellation and OpenPBR | Replaces SD's baker plus Painter-lite in one tool |
| **M5: Runtime** | 5.1 `.mmr` plus headless renderer, then Godot → Blender → Unreal → Unity plugins | Biggest effort, biggest moat-breaker |
| **M6: Exceed** | §6 items, 3.2 FX-Map (unlocks fully procedural `.sbsar` import), 5.4 scans, 5.5 library | Differentiation once parity is credible |

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
