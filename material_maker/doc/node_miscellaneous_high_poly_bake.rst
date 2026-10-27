High Poly Bake node
~~~~~~~~~~~~~~~~~~~

The **High Poly Bake** node bakes maps of a high poly mesh onto the UV layout of the
current custom mesh (the low poly mesh selected in the 3D preview), and recalculates
automatically when either mesh changes.

For each texel of the current mesh, a ray is cast from a cage (the current mesh pushed
along its normals, or a custom cage mesh) towards the current mesh, and the closest
high poly surface it hits provides the baked values.

Inputs
++++++

The **High Poly Bake** node does not accept any input.

Outputs
+++++++

The **High Poly Bake** node outputs the selected map, which can be the following:

* **Normal (tangent space)**: a normal map that can be connected directly to the normal
  input of the Material node. The tangent space is generated with MikkTSpace when the
  mesh has no tangents, as in most engines
* **Normal (object space)**: the normal of the high poly surface
* **Height**: the distance between the high poly surface and the current mesh (0.5 is the
  current mesh, 1.0 and 0.0 are the front and rear distances)
* **Vertex color**: the vertex colors of the high poly mesh (OBJ files with vertex colors,
  as exported by ZBrush, glTF and FBX files)
* **Material ID**: a different color for each material of the high poly mesh
* **Position**: the position of the high poly surface, in the bounding box of the current mesh
* **Coverage**: 1.0 where rays hit the high poly mesh, 0.0 where they missed it
* **Transferred texture**: the high poly mesh's own texture (the **High poly texture**
  parameter), sampled at the hit point with the high poly mesh's UVs, in the UV layout of the
  current mesh

Parameters
++++++++++

The **High Poly Bake** node has the following parameters:

* **High poly** is the high poly mesh file, in the same space as the current mesh
* **Cage** is an optional cage mesh, with the same topology as the current mesh (an
  inflated copy of it). When it is set, rays start from the cage and the front distance
  is not used
* **Map** is the baked map
* **Size** is the size of the baked map
* **Front distance** and **Rear distance** are the maximum distances of the high poly
  surface in front of and behind the current mesh, relative to the diagonal of its
  bounding box
* **Antialiasing** averages 1, 4 or 16 jittered samples for each texel
* **Match by name**: the parts (objects) of the current mesh are matched with the parts of
  the high poly mesh that have the same name, ignoring suffixes such as _low and _high (and
  numbers such as .001): rays from a part only hit the matching high poly part, so parts close
  to each other don't bleed into each other's maps. Parts are OBJ objects and groups, and the
  meshes of glTF and FBX files (all their meshes are loaded)
* **Skew map** is an optional grayscale image in the current mesh's UV space: where it is white,
  rays go along the flat face normal of the current mesh instead of its (smooth) vertex normals,
  which fixes details that are skewed near hard edges
* **High poly texture** is the texture of the high poly mesh, for the **Transferred texture** map

Baking is also available from the command line (see the **--high** option of **--bake**).

Example images
++++++++++++++

Tangent space normal, height, material ID and vertex color maps of a bumpy high poly
sphere with 2 materials, baked on a low poly sphere:

.. image:: images/screenshot_high_poly_bake.png
	:align: center
