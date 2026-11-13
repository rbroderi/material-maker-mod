Voxel Wetness node
~~~~~~~~~~~~~~~~~~

The **Voxel Wetness** node darkens the albedo of a wet surface and lowers its roughness, more
on up-facing surfaces where water pools. With **Wet** = 0 the node changes nothing.

Inputs
......

* **Albedo**: the linear albedo (a 3D texture)
* **Roughness**: the roughness (a grayscale 3D texture)
* **Wet**: how wet the surface is, 0 to 1 (a grayscale 3D texture, from :doc:`Voxel Inputs <node_3d_voxel_inputs>`)
* **Normal**: the surface normal (a 3D texture); a zero vector counts as facing up

Outputs
.......

* **Albedo**: the albedo multiplied by a factor going from 1 to **Darkening** with *wet x porosity*
* **Roughness**: the roughness lowered towards **Wet roughness**; it is never raised

Parameters
..........

* **Porosity** (1.0), **Darkening** (0.55)
* **Wet roughness** (0.15)
* **Up bias** (0.5): at 1, the roughness only drops on surfaces facing exactly up
* **Up axis** (0 for X, 1 for Y, 2 for Z, default 2)
