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

Notes
+++++

Each pixel blends the patches of the 3x3 cells around it. Their weights fade out before a
patch leaves this neighborhood, so there are no seams at any softness, and they are
computed relative to the nearest patch, so there are no black pixels at low softness.
Patches that reach the edges of the image are mirrored.
