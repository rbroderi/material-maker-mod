Domain warp 3D node
~~~~~~~~~~~~~~~~~~~

The **Domain warp 3D** node displaces the position at which a 3D texture is evaluated, by up to *amount* metres, using seeded 3D noise.

Inputs
......

The node accepts a 3D texture to warp and an optional seed.

Outputs
.......

The node provides the warped 3D texture.

Parameters
..........

* the *X*, *Y* and *Z* scale, in features per metre
* the *X*, *Y* and *Z* offset, in lattice cells
* the seed offset, added to the seed input
* the amount of displacement, in metres
* the number of octaves and the gain of the displacement noise
