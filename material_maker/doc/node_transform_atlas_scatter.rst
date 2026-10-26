Atlas Scatter node
~~~~~~~~~~~~~~~~~~

The **Atlas Scatter** node: scatters random images of an atlas on a grid, with random offset, scale, rotation and value, and height-ordered blending.

Inputs
++++++

* **Atlas**: The atlas (a grid of images)

Outputs
+++++++

* **Output**: The scattered images
* **Mask**: The coverage of the images

Parameters
++++++++++

* **Columns**: The number of columns of the atlas
* **Rows**: The number of rows of the atlas
* **Count**: The number of cells of the grid on each side (one image per cell)
* **Scale**: The size of images, relative to their cell
* **Scale random**: The random reduction of the size of each image
* **Rotation random**: The random rotation of each image, in degrees
* **Offset random**: The random offset of each image, relative to its cell
* **Value random**: The random darkening of each image
