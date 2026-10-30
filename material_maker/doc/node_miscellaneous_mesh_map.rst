Mesh Map node
~~~~~~~~~~~~~

**Mesh Map** node bakes maps for the current custom mesh and recalculates
automatically when a new mesh is selected in the 3D preview.

.. image:: images/node_miscellaneous_mesh_map.png
	:align: center

Inputs
++++++

The **Mesh Map** node does not accept any input.

Outputs
+++++++

The **Mesh Map** node outputs the selected generated map, which can be the following:

* Position, Normal, Tangent, Minimum/Maximum Curvature, Cavity, Pointiness, Ambient Occulusion, Bent Normals, Thickness, Adjacency

Parameters
++++++++++

The **Mesh Map** node has the following parameters:

* **Map** is the generated map
* **UDIM tile** is the UDIM tile (1001 to 1100) of the current mesh's UV layout that is
  generated, for meshes whose UVs span several tiles: 1001 is the [0, 1] square, 1002 is on its
  right and 1011 above it. Only the faces of this tile are drawn in the map, with UVs relative
  to the tile, but rays still hit the whole mesh (for ambient occlusion, bent normals and
  thickness). UDIM exports generate each tile of the mesh, whatever this parameter is

Example Images
++++++++++++++
.. image:: images/screenshot_mesh_map.jpg
	:align: center
