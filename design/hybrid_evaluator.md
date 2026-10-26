# Hybrid evaluator (SD_PARITY_PLAN §2.1)

Status: design + first slice (automatic buffers), 2026-10-25.

## Problem

Material Maker turns a graph into GLSL by inlining every node into its consumer. Two
consequences:

1. **Multiplicative cost.** A node that samples an input N times (blur, warp, emboss,
   anything with a *function* input) calls a GLSL function that re-evaluates the *whole
   upstream subgraph* N times per pixel. Chains of such nodes multiply: a 9-tap filter
   after a 50-tap blur re-evaluates the source 450 times.
2. **Monolithic shaders.** Large graphs produce huge shaders: slow to compile, slow to
   recompile on every structural edit, and sometimes beyond driver limits.

Today the only remedy is the manual **Buffer** node. Library nodes that sample their
input many times already embed one, but user-built chains (and custom shader nodes)
don't, and users must know where to put buffers.

Substance Designer avoids both problems by cooking every node into its own cached
texture. That costs memory and bandwidth for cheap point-wise nodes, which MM's
inlining handles better. The goal is a **hybrid**: keep inlining point-wise chains,
and cut the graph into cached passes where it pays off.

## What already exists

- Buffers render through compute shaders (`engine/pipeline/compute_shader.gd`) into
  `MMTexture`s, which are referenced by downstream shaders as `sampler2D` uniforms.
- `engine/dependencies.gd` (`mm_deps`) tracks buffers by name, their parameter
  dependencies, and invalidation. A uniform change re-renders only the buffers that
  read it, then their dependents. **This is already a per-pass cache with dirty
  propagation**; the evaluator work is about *where passes are cut*, not about
  building a cache from scratch.
- `MMGenShader.generate_input_function()` is the single place where a function input
  inlines its source.

## Design

### Cut points

A *cut point* is a connection whose source is rendered into a cached texture instead of
being inlined. Cut points come from three places, in priority order:

1. **Manual** — Buffer / Iterate Buffer nodes (unchanged).
2. **Automatic** — chosen by a cost heuristic at code generation time (this slice).
3. **Pinned** — a per-connection user override ("always buffer" / "never buffer"),
   stored in the graph file (milestone 3).

### Cost model

Milestone 1 (this slice) uses the simplest model that captures the multiplicative
problem:

- Only **function inputs** are candidates (inputs declared `"function": true` in a
  shader model). Those are the inputs a node samples at arbitrary UVs, usually many
  times.
- The **upstream node count** is the number of generators reachable from the input
  without crossing a texture (buffer, image, …). Subgraphs count their inner nodes.
- An automatic buffer is inserted when the count reaches the threshold
  (`auto_buffer_threshold`, default 4).

Milestone 2 replaces the count with an estimated per-pixel cost: instruction count of
the generated code × number of samples per call site (loop bounds where they are
constant), and compares the inlined cost against the buffer cost
(resolution² × memory traffic). Node timings from the profiler (`rendering_time`) can
calibrate the weights.

### Automatic buffer generator

`MMGenAutoBuffer` (extends `MMGenBuffer`):

- Created by the consumer `MMGenShader`, one per function input, as a **child node of
  the consumer**. It is never serialized (graphs don't change on disk), and it is
  discarded when it's no longer needed.
- Its source is set explicitly (`get_source()` is overridden) instead of coming from
  graph connections.
- Rendering, caching and invalidation go through `mm_deps`, exactly like a manual
  buffer. Parameter changes upstream re-render it; structural changes upstream reach
  the consumer through `source_changed()`, which regenerates the auto buffer's shader.
- It appears in `get_buffers()` of its consumer, so it shows the buffer icon, can be
  paused, and is listed by *Tools → Show buffer render times*.

Resolution: `auto_buffer_size` preference (default 2^10). Milestone 2 derives it from
the consumer's own output resolution once per-node resolution (§2.2) exists.

### Preferences

| Key | Default | Meaning |
|---|---|---|
| `auto_buffer` | `false` | Enables automatic buffers (opt-in while experimental) |
| `auto_buffer_threshold` | `4` | Upstream node count that triggers a buffer |
| `auto_buffer_size` | `10` | Resolution of automatic buffers, as log2 |

Changing a preference affects shaders generated afterwards; reload the graph to apply
it everywhere.

## Milestones

| # | Content | Size |
|---|---|---|
| 1 | Automatic buffers on function inputs, node-count heuristic, preferences (**this slice**) | M |
| 2 | Cost model (instruction count × sample count), resolution derived from consumer, auto buffers on high fan-out outputs | L |
| 3 | Per-connection pin (always/never buffer), visual marker on buffered connections | M |
| 4 | Shader splitting for monolithic graphs: cut at the deepest high-cost points until each shader is under a size budget; incremental recompilation per pass | L |
| 5 | GPU memory budget with LRU eviction of cached passes | M |

## Risks

- **Visual differences.** A buffer samples at a fixed resolution with bilinear
  filtering, so fine detail above that resolution is lost. That's why the feature is
  opt-in and the resolution is a preference.
- **Memory.** Each automatic buffer is an RGBA16F texture (8 MB at 1024²). The
  threshold keeps the count low; milestone 5 adds a budget.
- **Non-image inputs.** Only `f`, `rgb` and `rgba` inputs are buffered; SDF, 3D texture
  and other types stay inlined.
