FBM noise 3D node
~~~~~~~~~~~~~~~~~

The **FBM noise 3D** node outputs seeded 3D fractional Brownian motion: layers of value or Perlin noise with growing frequency. The noise is computed from an integer hash that gives the same values in GLSL, HLSL and Python, so the exported materials match the preview.

Inputs
......

The node accepts an optional seed as a grayscale 3D texture. The seed is rounded to an integer between 0 and 16777215.
Positions are object space positions in metres, so the size of the features does not depend on the resolution.

Outputs
.......

The node provides a grayscale 3D texture between 0 and 1.

Parameters
..........

* the *X*, *Y* and *Z* scale, in features per metre
* the *X*, *Y* and *Z* offset, in lattice cells
* the seed offset, added to the seed input
* the period, in cells, to get a texture that tiles (0 disables tiling)
* the basis: value or Perlin noise
* the number of octaves
* the gain, i.e. the amplitude factor between two octaves
* the lacunarity, i.e. the frequency factor between two octaves (rounded when the period is not 0)
