Distance node
~~~~~~~~~~~~~

The **Distance** node generates a gradient that fades with the distance to the white areas
of a mask, and propagates the colors of a source image from those areas.

Inputs
++++++

The **Distance** node has two inputs:

* the *Mask* whose white areas are the source of the distance field

* an optional *Source* image, whose colors are propagated from the white areas of the mask

Outputs
+++++++

The **Distance** node has two outputs:

* *Distance* is white in the white areas of the mask, and fades to black at the
  *max distance*

* *Color* is the source image in the white areas of the mask, and outside of them the
  color of the closest point of those areas, up to the *max distance* (it is black beyond)

Parameters
++++++++++

* *Size* is the resolution used for the operation

* *Iterations* is the number of jump flooding iterations; it should be at least
  log2(size)+1 (for example 11 for 1024)

* *Tiled* makes the distance field wrap around the image's edges

* *Distance* is the distance function (Euclidean, Manhattan or Chebyshev)

* *Max distance* is the distance at which the gradient reaches 0 and colors stop
  propagating

Notes
+++++

The distance is computed with the jump flooding algorithm. Distances are measured to the
outline of the mask's white areas, so they are accurate to one or two pixels.
