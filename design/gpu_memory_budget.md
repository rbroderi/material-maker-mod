# GPU memory budget

Status: **implemented**, 2026-10-25, spilling reworked 2026-10-30. Off by default
(*Preferences > Graph > GPU Memory Budget*, `gpu_memory_budget`, 0 = unlimited;
`--gpu-budget <MB>` on the command line).

This note used to describe the hybrid evaluator (automatic buffers inserted by a cost
model, per-connection buffer pins). Automatic buffers changed rendered images (buffered
inputs are sampled between texels), so they were removed; the memory budget, which was
part of the same work, stays.

## Spilling

`MMTexture` (`engine/pipeline/texture.gd`):

- textures with a copy in the rendering device (`rid`) register themselves in
  `gpu_textures` (weak references) and record when they were last used (rendered into or
  sampled);
- `mm_renderer.check_texture_budget()` runs after renders; when the total exceeds the
  budget, the least recently used **rendered** textures (buffers, material outputs...;
  not textures uploaded from images) that have been idle for at least 200 ms are
  **spilled**: read back into a RAM `Image` (`spilled_image`, never an `ImageTexture`,
  which would stay in video memory) and freed in the rendering device;
- spilling is a single job of the rendering thread (which also runs the renders, so a
  texture is never spilled while a render uses it); the device is then submitted and
  synced so the memory is released at once. Textures that were too recent are checked
  again 200 ms later;
- the next use re-uploads them transparently (`get_texture_rid()`): nothing is rendered
  again. Re-uploaded textures keep the storage bit so iterate buffers can reuse them as
  outputs. 16 bits integer textures come back as 32 bits float textures.

A render still needs all its inputs and outputs at once, so the budget is exceeded while a
render needs more. *Tools > Show buffer render times* shows current usage, the budget and
which buffers are in RAM. Command line exports print the peak texture memory.

Unlike spilling, `MMTexture.release()` (buffer lifetimes, `buffer_lifetimes.md`) drops the
texture, which its buffer renders again when needed.

## Possible follow-ups

- Count the CPU-side `ImageTexture` copies in the memory budget.
