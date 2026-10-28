# Buffer lifetimes

Graphs converted from Substance Designer can have thousands of buffers (a Substance node is
usually one pass). Material Maker kept every buffer's texture, so memory grew with the number of
buffers: a static simulation of a converted graph with about 2,500 buffers needs 24.8 GiB at
2048 px. The GPU memory budget (`hybrid_evaluator.md`) only moves textures to RAM.

## Releasing

`mm_deps` (dependencies.gd) can free a buffer's texture when all the buffers that read it are
rendered (`release_mode`: never, during exports, always; the *Release buffers* preference and
`--low-memory` on the command line).

- A released buffer still counts as updated: its readers have used it, and nothing waits for
  it. `Buffer.released` marks it, and `MMTexture.release()` frees the texture in the rendering
  device and drops its image (`MMTexture.released_buffer` remembers the buffer).
- Buffers are released when one of their readers is rendered (`release_unused_dependencies`),
  if all their readers are updated and are generator buffers (`MMGenBase`, not the Material
  node). Previews, the Material node and widgets read their inputs at any time, and iterate
  buffers read them in each iteration, so their inputs are never released. Only generators with `release_buffer()` (MMGenBuffer) can be released:
  iterate buffers keep their state.
- A released buffer is rendered again on demand (`restore_buffer`), its released inputs first,
  without invalidating its readers (`Buffer.restoring` makes `dependency_update` skip them):
  - before a buffer is rendered (in `do_update`), for its inputs,
  - before any compute shader renders (`MMComputeShader.render_ext`) with a released input
    texture (exports, node previews, the 2D preview's renders),
  - when a released texture is read (`MMTexture.get_texture()`).
- Invalidating a released buffer clears `released`: it is rendered again as usual.

## Order

With releasing, `do_update` renders buffers depth first (`get_render_order`): a post-order
walk from the buffers no buffer reads, visiting the inputs read by more buffers first. Inputs are
then rendered just before their readers and released soon after. The order is recalculated when
dependencies change. The same simulation gives a peak of 1.2 GiB depth first, and 2.3 GiB in the
previous order (the dictionary's order).

## Costs

Releasing trades memory for time: editing a node renders the released buffers it needs again
(and their released inputs). *During exports* only releases while exporting, so editing is not
slower. The command line prints the peak GPU texture memory after exports.
