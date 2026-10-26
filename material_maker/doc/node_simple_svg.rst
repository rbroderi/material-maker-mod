SVG node
~~~~~~~~

The **SVG** node renders vector graphics: an SVG file, or path data edited in the node.
Vector graphics are rendered at the selected resolution, so they stay sharp.

Inputs
++++++

The **SVG** node does not accept any input.

Outputs
+++++++

* **Output**: the rendered image (RGBA)

Parameters
++++++++++

* **SVG file**: an SVG file, used when the path data is empty
* **Path data**: SVG path data (the *d* attribute of an SVG path) on a 100x100 canvas, for
  example *M 10 10 L 90 10 L 50 90 Z*. The default is a star
* **Fill** and **Stroke**: the colors of the path
* **Stroke width**: the width of the path's outline, on the 100x100 canvas
* **Size**: the resolution of the rendered image

Non square SVG files are centered.
