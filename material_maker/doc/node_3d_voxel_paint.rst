Voxel Paint node
~~~~~~~~~~~~~~~~

The **Voxel Paint** node paints over a surface where the **Mask** is set, as in the paint
branch of the voxkit wood recipe: the colour varies a little with a noise, the roughness goes
to the **Gloss** value and the bump is reduced to 37.5% under the paint.

Inputs
......

* **Albedo**: the linear albedo (a 3D texture)
* **Roughness**: the roughness (a grayscale 3D texture)
* **Bump**: the bump gradient vector (a 3D texture)
* **Mask**: where the surface is painted, 0 to 1 (a grayscale 3D texture)
* **Seed**: the seed (from :doc:`Voxel Inputs <node_3d_voxel_inputs>`)

Outputs
.......

* **Albedo**, **Roughness** and **Bump**: the painted values

Parameters
..........

* **Paint colour** (sRGB)
* **Gloss**: the roughness of fully painted surfaces (default 0.35)
* **Hides**: how much the paint hides what is below (default 1.0); the mix weight is mask x hides
* **Units per metre** (default 81)
