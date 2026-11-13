Voxel Palette Pick node
~~~~~~~~~~~~~~~~~~~~~~~

The **Voxel Palette Pick** node gives every unit (a brick, a tile, a plank) its own colour,
picked from a palette of five, as in the voxkit brick recipe. The unit is identified by the
**Id** input: a Voronoi cell value, a brick id or the per-thing seed. All colours are linear.

Two random values are derived from the id and the seed. The first picks the palette colour with
the cumulative thresholds; the second mixes in a little of the next colour (the palette is
cyclic), so every output colour lies on a segment between two adjacent palette colours.

Inputs
......

* **Id**: the unit id (a grayscale 3D texture); it is rounded to the nearest integer
* **Seed**: the seed (a grayscale 3D texture, from :doc:`Voxel Inputs <node_3d_voxel_inputs>`)

Outputs
.......

* **Colour**: the linear palette colour of the unit (a 3D texture)
* **H1**, **H2**, **H3**: three random values in [0, 1) of the unit (grayscale 3D textures), for
  per-unit variation. H1 picks the colour and H2 the blend

Parameters
..........

* the five palette colours **Colour 0** to **Colour 4** (sRGB; the defaults are the voxkit brick palette)
* the four cumulative thresholds **Threshold 1** to **Threshold 4** (default 0.40, 0.66, 0.86, 0.93)
* **Blend**: the largest amount of the next colour mixed in (default 0.35)
