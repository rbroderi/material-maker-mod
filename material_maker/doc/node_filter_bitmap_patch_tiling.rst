Patch Tiling node
~~~~~~~~~~~~~~~~~

The **Patch Tiling** node: makes an image tileable by recombining random patches of it, blended with soft edges while keeping its contrast (works best on stochastic textures such as gravel, grass or noise).

Inputs
++++++

* **Input**: The image

Outputs
+++++++

* **Output**: The tileable image

Parameters
++++++++++

* **Patches**: The number of patches in each direction
* **Softness**: The softness of the transitions between patches
* **Keep contrast**: Keeps the contrast of the image where patches are blended (histogram preserving blending), instead of averaging them
