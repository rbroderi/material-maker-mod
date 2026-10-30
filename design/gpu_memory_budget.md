# GPU memory budget

Status: **implemented**, 2026-10-25. Off by default (*Preferences > Graph > GPU Memory
Budget*, `gpu_memory_budget`, 0 = unlimited; `--gpu-budget <MB>` on the command line).

This note used to describe the hybrid evaluator (automatic buffers inserted by a cost
model, per-connection buffer pins). Automatic buffers changed rendered images (buffered
inputs are sampled between texels), so they were removed; the memory budget, which was
part of the same work, stays.

## Eviction

`MMTexture` (`engine/pipeline/texture.gd`) keeps two copies: the compute copy (`rid`) and
a CPU-side `ImageTexture` used by previews. `get_texture_rid()` re-uploads from the latter
when the compute copy is missing. Eviction uses that:

- textures with a compute copy register themselves and record when they were last used
  (rendered into or sampled);
- `mm_renderer.check_texture_budget()` runs after renders; when the total exceeds
  `gpu_memory_budget`, the least recently used textures that have been idle for at least
  1 s are **read back to RAM and freed** on the rendering device;
- the next use re-uploads them transparently: nothing is rendered again. Re-uploaded
  textures keep the storage bit so iterate buffers can reuse them as outputs.

Measured: 192 MB in 11 textures evicted down to a 4 MB budget; re-rendering afterwards was
pixel-identical. *Tools > Show buffer render times* shows current usage and budget.

## Possible follow-ups

- Count the CPU-side `ImageTexture` copies in the memory budget.
