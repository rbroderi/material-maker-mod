Non-Uniform Blur node
~~~~~~~~~~~~~~~~~~~~~

The **Non-Uniform Blur** node applies a disc blur to its input whose radius is driven,
for each pixel, by a grayscale intensity map. The disc can be squashed into an ellipse
to create anisotropic blurs.

.. image:: images/node_filter_blur_non-uniform.png
	:align: center

Inputs
++++++

The **Non-Uniform Blur** node accepts an RGBA input to be blurred and an optional
grayscale intensity map. Where the map is white, the blur radius is the *intensity*
parameter; where it is black, the input is not blurred. When the map is not connected,
the whole image is blurred with the maximum radius.

Outputs
+++++++

The **Non-Uniform Blur** node outputs the result of the blur operation.

Parameters
++++++++++

The **Non-Uniform Blur** node has the following parameters:

* The *grid size* defines the resolution at which the input is sampled.

* The *intensity* is the maximum blur radius, in pixels of the grid size.

* The *anisotropy* squashes the blur disc into an ellipse: 0 is a circle and 1 a line.

* The *angle* specifies the orientation of the ellipse when anisotropy is used.

* The number of *samples* taken for each pixel. More samples give a smoother result,
  but are slower.

* The number of *blades* of the aperture: 0 gives a round blur, and 3 or more a polygonal
  (bokeh) shape, whose orientation is the *blade rotation*.

* Whether a *32 Bit* buffer is used to sample the input.
  Reduces banding artifacts but could result in higher video memory usage.

Example images
++++++++++++++

From left to right: the input image, the input blurred with a horizontal gradient as
intensity map, and an anisotropic blur (anisotropy 0.85, angle 30).
