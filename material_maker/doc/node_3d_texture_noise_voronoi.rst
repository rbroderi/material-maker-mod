Voronoi noise 3D node
~~~~~~~~~~~~~~~~~~~~~

The **Voronoi noise 3D** node outputs seeded 3D cellular noise. Each of the 27 neighbour cells holds a feature point. The noise is computed from an integer hash that gives the same values in GLSL, HLSL and Python, so the exported materials match the preview.

Inputs
......

The node accepts an optional seed as a grayscale 3D texture. The seed is rounded to an integer between 0 and 16777215.
Positions are object space positions in metres, so the size of the features does not depend on the resolution.

Outputs
.......

The node provides four outputs: the distance to the nearest feature point, the distance between the two nearest feature points (cell edges), a random value per cell and a random color per cell.

Parameters
..........

* the *X*, *Y* and *Z* scale, in features per metre
* the *X*, *Y* and *Z* offset, in lattice cells
* the seed offset, added to the seed input
* the period, in cells, to get a texture that tiles (0 disables tiling)
* the jitter of the feature points inside their cells
