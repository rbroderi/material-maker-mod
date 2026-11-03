Image node
~~~~~~~~~~

The image node outputs a single texture based on an image file.

.. image:: images/node_simple_image.png
	:align: center

Inputs
++++++

The image node does not accept any input.

Outputs
+++++++

The image node provides a single color texture.

Parameters
++++++++++

The **Image** node has the following parameters:

* The first parameter defines the image file the node provides.
  It can be modified by clicking the thumbnail and selecting a new image file.

* **Fix Aspect Ratio** will scale the height of non-square images to maintain the correct aspect ratio.

* **Clamp** will disable the default tiling behavior.
  Useful when dealing with non-square images as they cannot easily be clamped further down the graph.

* **Filter** toggles between linear or nearest filtering.

* **Color space** defines how colors are read. Material Maker works with sRGB encoded colors,
  so **As is** (the default) should be used for most images and for data such as normal maps.
  **Linear** converts linear colors (such as most EXR and HDR images) to sRGB, and **Auto**
  converts EXR and HDR images only. Alpha is never converted. When OpenColorIO support is
  built (see the **native/ocio** directory of the source repository), **OCIO** converts the
  image from the **OCIO color space** parameter (a color space of the OpenColorIO config, such
  as *ACEScg* or *Linear Rec.709 (sRGB)*) to Material Maker's working space. Without it,
  **OCIO** uses the image's values as they are.

The supported formats are BMP, EXR, HDR, JPEG, PNG, SVG, TGA, WebP and DDS.
