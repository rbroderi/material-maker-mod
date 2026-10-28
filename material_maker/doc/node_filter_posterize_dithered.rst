Dithered Posterize node
~~~~~~~~~~~~~~~~~~~~~~~

The **Dithered Posterize** node: reduces the number of levels of each channel, with ordered (Bayer) dithering between levels.

Inputs
++++++

* **Input**: The input image

Outputs
+++++++

* **Output**: The posterized image

Parameters
++++++++++

* **Levels**: The number of levels of each color channel, including black and white
* **Dither**: The amount of dithering. At 0, each value is rounded to the nearest level. At 1, the average of the output over a tile of the 4x4 Bayer matrix matches the input
* **Size**: The resolution used for pixel based effects
