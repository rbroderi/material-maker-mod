3D Buffer node
~~~~~~~~~~~~~~

The **3D Buffer** node replaces a heavy 3D texture graph by a baked lookup. It stores the input volume as slices in an atlas image (inside a regular Buffer) and reads it back with trilinear filtering. It needs no change in the engine and works wherever buffers do.

Inputs
......

The **3D Buffer** node accepts a 3D texture. It should be periodic with a period equal to the *extent* parameter, otherwise a seam shows at the border of the volume. The noise nodes have a *period* parameter for this: set it to the noise scale multiplied by the extent.

Outputs
.......

The **3D Buffer** node provides a 3D texture.

Parameters
..........

The 3D Buffer node accepts the following parameters:

* the layout of the atlas: *64^3* (512x512 image), *128x128x64* (1024x1024), *128x128x256* (2048x2048) or *256^3* (4096x4096). The image is made of T x T tiles, each one a z slice, so the volume has T x T slices
* the extent, i.e. the size in metres covered by the volume. The volume is periodic with this period
* the mode: *Baked* reads the atlas, *Direct* ignores it and evaluates the input directly

Limits
......

* The baked texture loses the normal and the fresh information of the voxel context: the input sees them as zero.
* The lookups are clamped to half a texel inside each tile, so there is no filtering across the x and y borders of the volume. The z axis wraps with filtering.
* The atlas is stored with 16 bits floats, and takes about 2, 8, 32 or 128 MB of video memory for the four layouts.
