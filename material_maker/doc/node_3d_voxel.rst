Voxel nodes
~~~~~~~~~~~

The voxel nodes are used to build materials for voxel objects and other objects that are
textured by their position in 3D, in object space and in metres, instead of by UV
coordinates. They are provided by the *Voxel materials* plugin.

A voxel material is a graph whose 3D texture nodes read the object-space position of the
shaded point, and end in a :doc:`Voxel Material <node_material_voxel>` node.
The :doc:`Voxel Inputs <node_3d_voxel_inputs>` node provides the position, the normal and
the values that describe the object being shaded (seed, age, upkeep, fresh, char, wet,
axis, origin and footprint).

.. toctree::
	:maxdepth: 0

	node_3d_voxel_inputs
	node_3d_voxel_wood
	node_3d_voxel_palette_pick
	node_3d_voxel_weathering
	node_3d_voxel_char
	node_3d_voxel_wetness
	node_3d_voxel_paint
	node_3d_voxel_surface_pattern
