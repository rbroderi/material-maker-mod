Voxel Weathering node
~~~~~~~~~~~~~~~~~~~~~

The **Voxel Weathering** node adds dirt, a pale bloom and wear to an albedo. It is a port of
the aged branch of the voxkit brick recipe. The effect is weighted by
*age x (1 - upkeep) x (1 - fresh)*, so a freshly cut surface (**Fresh** = 1) keeps its albedo
exactly.

Dirt gathers in hollows (low **Height**) and handling lightens the high spots.

Inputs
......

* **Albedo**: the linear albedo to weather (a 3D texture, default 0.5)
* **Height**: optional height (a grayscale 3D texture, default 0.5, which is neutral)
* **Seed**, **Age**, **Upkeep**, **Fresh**: from :doc:`Voxel Inputs <node_3d_voxel_inputs>`

Outputs
.......

* **Albedo**: the weathered linear albedo (a 3D texture)
* **Roughness delta**: roughness to add to the roughness of the surface (a grayscale 3D texture)
* **Bump scale**: a factor to multiply the bump by (a grayscale 3D texture); weathered surfaces
  are smoother (from 1 down to 0.16/0.34)

Parameters
..........

* **Units per metre** (default 81)
* **Dirt colour** (sRGB, default 96, 86, 78) and **Hides** (0.3)
* **Grime scale** (0.05 per recipe unit), **Bloom** (0.12)
* **Hollows** (0.5): how much more dirt gathers in hollows
* **Wear** (0.16): how much high spots are lightened
* **Roughness gain** (0.2)
