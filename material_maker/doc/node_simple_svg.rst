SVG node
~~~~~~~~

The **SVG** node renders vector graphics: an SVG file, path data edited in the node, or a
shape edited in the 2D preview.
Vector graphics are rendered at the selected resolution, so they stay sharp.

Inputs
++++++

The **SVG** node does not accept any input.

Outputs
+++++++

* **Output**: the rendered image (RGBA)

Parameters
++++++++++

* **Source**: what is rendered: the path data, the shape, the SVG file, or the curves
* **SVG file**: an SVG file, used with the *File* source, or when the path data is empty
* **Shape**: a polygon, edited in the 2D preview (drag its points, and add or remove points),
  used with the *Shape* source
* **Curves**: cubic Bézier curves, edited in the 2D preview like the curves of the Splines
  node, used with the *Curves* source. Curves whose ends meet are joined into one outline, and
  outlines that end where they start are closed and filled. The default is a circle
* **Path data**: SVG path data (the *d* attribute of an SVG path) on a 100x100 canvas, for
  example *M 10 10 L 90 10 L 50 90 Z*. The path is rendered up to its first invalid
  character, and its coordinates are limited to +/-1000. The default is a star
* **Fill** and **Stroke**: the colors of the path
* **Fill rule**: how overlapping outlines are filled: *Non-zero* fills everything inside the
  outline, *Even-odd* leaves holes where outlines overlap
* **Stroke width**: the width of the path's outline, on the 100x100 canvas
* **Background**: the color the graphics are drawn on. It is opaque black by default, so the
  output can be used as an anti-aliased mask. With a transparent background, the output is
  transparent outside of the shapes, and its alpha channel is the anti-aliased mask
* **Size**: the resolution of the rendered image

Non square SVG files are centered. Documents that are not well formed are not rendered.
