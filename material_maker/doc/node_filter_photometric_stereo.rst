Photometric Stereo node
~~~~~~~~~~~~~~~~~~~~~~~

The **Photometric Stereo** node reconstructs a normal map and an albedo map from 4 photos
of a surface taken from the same point of view, with a single light at the same
elevation coming from the right, the top, the left and the bottom of the image.

It assumes a diffuse (Lambertian) surface, so shiny surfaces and cast shadows reduce the
quality of the result. Photos should be converted to greyscale and aligned.

Inputs
++++++

The **Photometric Stereo** node has 4 greyscale inputs: the photos lit from the right
(east), the top (north), the left (west) and the bottom (south).

Outputs
+++++++

The **Photometric Stereo** node outputs:

* the normal map, in the same format as the **Normal Map** node's default format
* the albedo (diffuse reflectance)

Parameters
++++++++++

The **Photometric Stereo** node has the following parameters:

* **Elevation** is the elevation of the lights above the surface, in degrees
* **Strength** multiplies the slopes of the normal map
* **sRGB photos** linearizes the photos first (Lambert's law needs linear values) and
  converts the albedo back to sRGB. Set it for most photos and image files, and clear it
  for photos that are already linear

Example images
++++++++++++++

4 synthetic photos of a surface, and the reconstructed normal and albedo maps:

.. image:: images/screenshot_photometric_stereo.png
	:align: center
