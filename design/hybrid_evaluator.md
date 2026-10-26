# Hybrid evaluator (SD_PARITY_PLAN §2.1)

Status: **implemented** (milestones 1–5), 2026-10-25. Automatic buffers are opt-in
(*Preferences → Graph → Automatic Buffers*); pins and the memory budget work
independently of that switch.

## Problem

Material Maker turns a graph into GLSL by inlining every node into its consumer. Two
consequences:

1. **Multiplicative cost.** A node that samples an input N times (blur, warp, emboss,
   normal map, pixel processor…) calls a GLSL function that re-evaluates the *whole
   upstream subgraph* N times per pixel. Chains of such nodes multiply.
2. **Monolithic shaders.** Large graphs produce huge shaders: slow to compile, slow to
   recompile on every structural edit, and sometimes beyond driver limits.

Substance Designer avoids both by cooking every node into its own cached texture, which
costs memory and bandwidth for cheap point-wise nodes that MM's inlining handles better.
The hybrid evaluator keeps inlining point-wise chains and cuts the graph into cached
passes where it pays off.

## Building blocks that already existed

- Buffers render through compute shaders into `MMTexture`s, sampled downstream as
  `sampler2D` uniforms.
- `mm_deps` (`engine/dependencies.gd`) tracks buffers, their parameter dependencies and
  invalidation, so a uniform change re-renders only the affected buffers.
- A Buffer node stops structural change propagation: its consumers only sample its
  texture, so they don't regenerate when its source changes.
- Within a shader, the same node evaluated at the same UV is generated once
  (`MMGenContext` variants), so fan-out at a single UV is already shared.

## Cut points

A *cut point* is a connection whose source is rendered into a cached texture instead of
being inlined. They come from:

1. **Manual** — Buffer / Iterate Buffer nodes.
2. **Pinned** — a per-connection override, `"buffer": "always"` or `"never"` in the
   graph's connection list (milestone 3).
3. **Automatic** — chosen by the cost model at code generation time (milestones 1, 2, 4).

Pins win over automatic decisions, and "always" works even when automatic buffers are
disabled.

## Cost model (milestone 2)

Costs are rough per-pixel estimates in "function calls" (`MMGenShader`):

- **Node cost** (`get_cost_model()`): `1 + number of "("` in the node's global, instance,
  code and output expressions, multiplied by the estimated loop iteration count
  (constant `for` bounds are parsed; other loops count as 16).
- **Samples per input**: occurrences of `$input` in the node's code; for function inputs,
  multiplied by the loop iteration count.
- **Inlined cost** of a source (`estimate_cost()`): node cost + Σ samples × input cost,
  where an input that would itself be buffered costs one texture fetch. Textures cost one
  fetch. Memoized per decision.
- **Decision** (`should_auto_buffer()`), for `f`/`rgb`/`rgba` inputs:
  - buffer when `samples × cost ≥ min_gain × (samples × fetch + cost + overhead)`
    (sampling repeatedly costs much more than rendering once and sampling the result);
  - otherwise buffer when `cost > shader_budget` (**shader splitting**, milestone 4).

Calibration on the bundled examples: typical material inputs cost 200–4000 units; the
largest (raymarching, pile of bricks, donuts) 10 000–380 000. The Normal Map node samples
its input 8 times; in *stylized_wall* that is 26 000 inlined vs ~3 300 buffered.

**Resolution**: the consumer's own `size` parameter when it has one (e.g. the Material
node's output size, or a library filter's grid size), otherwise `auto_buffer_size`.
Automatic buffers follow later changes of that parameter.

**Fan-out**: outputs consumed several times at the same UV are already shared by context
variants; fan-out across different UVs is not buffered automatically (pin the
connections instead).

## Automatic buffer generator

`MMGenAutoBuffer` (extends `MMGenBuffer`, `engine/nodes/gen_auto_buffer.gd`):

- created by the consumer `MMGenShader` during code generation, one per buffered input,
  as a **child node of the consumer**; never serialized, freed when no longer needed;
- its source is set explicitly (`get_source()` is overridden);
- renders, caches and invalidates through `mm_deps` like a manual buffer;
- appears in its consumer's `get_buffers()`: buffer icon, pause menu, and
  *Tools → Show buffer render times*;
- when its output type changes (grayscale ↔ color), it asks the consumer to regenerate
  (`auto_buffer_output_changed()`), without regenerating itself again.

## Incremental recompilation (milestone 4)

`MMGenShader.source_changed()` re-evaluates the decision for that input. If the input is
still buffered, only the automatic buffer's shader is regenerated and the change is
**not** propagated downstream: the consumer's code only samples the buffer's texture.
Measured: editing a node upstream of a buffered input caused 0 downstream regenerations
(1 without buffers), and the result updated correctly.

## Pins and markers (milestone 3)

- `MMGenGraph.get_connection_buffer()` / `set_connection_buffer()`; pins are saved with
  the connection and restored by `mm_loader.add_to_gen_graph()` (load, paste, undo).
- **UI**: *Alt + right click* on a connection opens *Buffer: Automatic / Always / Never*.
  The change is undoable (`set_connection_buffer` undo action).
- **Markers** are drawn on top of the graph (`graph_edit.gd`, overlay control): blue "B"
  for an automatic buffer, orange "B" for a pinned buffer, grey "–" for "never".
- Limitation: pins are not carried over when nodes are grouped into a subgraph.

## GPU memory budget (milestone 5)

`MMTexture` (`engine/pipeline/texture.gd`) keeps two copies: the compute copy (`rid`) and
a CPU-side `ImageTexture` used by previews. `get_texture_rid()` re-uploads from the latter
when the compute copy is missing. Eviction uses that:

- textures with a compute copy register themselves and record when they were last used
  (rendered into or sampled);
- `mm_renderer.check_texture_budget()` runs after renders; when the total exceeds
  `gpu_memory_budget`, the least recently used textures that have been idle for at least
  1 s are **read back to RAM and freed** on the rendering device;
- the next use re-uploads them transparently — nothing is re-rendered. Re-uploaded
  textures keep the storage bit so iterate buffers can reuse them as outputs.

Measured: 192 MB in 11 textures evicted down to a 4 MB budget; re-rendering afterwards was
pixel-identical. *Tools → Show buffer render times* shows current usage and budget.

## Preferences

| Key | Default | Meaning |
|---|---|---|
| `auto_buffer` | `false` | Enables automatic buffers |
| `auto_buffer_min_gain` | `2.0` | Minimum ratio between inlined and buffered cost |
| `auto_buffer_shader_budget` | `4000` | Inputs costing more are split into a buffer |
| `auto_buffer_size` | `10` | Default resolution of automatic buffers (log2) |
| `gpu_memory_budget` | `0` | Rendering device memory budget in MB (0 = unlimited) |

Preference changes affect shaders generated afterwards; reload the graph to apply them
everywhere.

## Tests

- `test/test_auto_buffer.gd` (GUT): loop estimates, sample counts, decisions, sizes.
- GPU checks (run manually with the scripts described in the commit history): decisions
  on example-like graphs, pins and their serialization, splitting, incremental
  recompilation, eviction and re-upload, marker rendering.

## Possible follow-ups

- Use measured render times (`rendering_time`) to calibrate the cost weights.
- Carry pins over when grouping nodes; show the estimated cost in node tooltips.
- Count the CPU-side `ImageTexture` copies in the memory budget.
