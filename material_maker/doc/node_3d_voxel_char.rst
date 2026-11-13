Voxel Char node
~~~~~~~~~~~~~~~

The **Voxel Char** node burns a surface to charcoal. The albedo goes to near black, the roughness
to 0.9, and a pattern of cracks (the distance to the edge of Voronoi cells, like the scales of
burnt wood) is provided as a height for a bump. The cracks can glow.

With **Char** = 0 the node changes nothing.

Inputs
......

* **Albedo**: the linear albedo (a 3D texture)
* **Roughness**: the roughness (a grayscale 3D texture)
* **Char**: how burnt the surface is, 0 to 1 (a grayscale 3D texture, from :doc:`Voxel Inputs <node_3d_voxel_inputs>`)
* **Seed**: the seed

Outputs
.......

* **Albedo**: the charred linear albedo (a 3D texture)
* **Roughness**: the charred roughness (a grayscale 3D texture)
* **Height**: 0.5 when not burnt; when burnt, 0 in the cracks and 1 on the scales (a grayscale 3D texture)
* **Emission**: the glow in the cracks (a 3D texture); zero unless **Ember** is above 0

Parameters
..........

* **Char colour** (linear, default 0.02)
* **Crack scale** (cells per metre, default 40) and **Crack width** (default 0.12)
* **Char roughness** (0.9)
* **Ember** (0) and **Ember colour**
