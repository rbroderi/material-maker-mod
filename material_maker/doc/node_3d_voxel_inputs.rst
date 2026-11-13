Voxel Inputs node
~~~~~~~~~~~~~~~~~

The **Voxel Inputs** node provides the position and the normal of the shaded point, and the
values that describe the object being shaded, to the 3D texture nodes of a voxel material.

Inputs
......

The **Voxel Inputs** node does not accept any input.

Outputs
.......

The **Voxel Inputs** node has the following outputs:

* **Position**: the object-space position, in metres (a 3D texture)
* **Normal**: the object-space unit normal (a 3D texture); when the normal is not known, it
  is the direction of the position, so that the node shows a sensible result on the sphere
  of the 2D preview
* **Seed**, **Age**, **Upkeep**, **Fresh**, **Char** and **Wet**: grayscale 3D textures whose
  value is the matching parameter (**Fresh** also adds the per point fresh value, 0 for the
  original surface and 1 for a freshly cut one)
* **Axis**: the normalized axis (a 3D texture)
* **Origin**: the origin, in metres (a 3D texture)
* **Footprint**: the size of a pixel in metres, 0 when it is not known (a grayscale 3D texture)

Parameters
..........

The **Voxel Inputs** node accepts the following parameters:

* **Seed** (an integer from 0 to 65535), **Age**, **Upkeep**, **Fresh**, **Char** and **Wet**
  (from 0 to 1)
* the **X**, **Y** and **Z** components of the axis (from -1 to 1) and of the origin (from -10 to 10 metres)
* the **Footprint**, in metres per pixel (from 0 to 0.1)

The parameters are sliders in the 3D preview, are saved in the material and can be set from the
command line and with RPC like any other parameter.

Limitations
...........

Material Maker has no way to carry a normal through the generated functions, so the normal
and the per point fresh value travel in the *controlled variation* of the shader. As a result:

* the **Controlled Variations** node cannot be used in a voxel graph
* anything that is baked into a buffer loses the normal and the fresh value
* when a graph contains several **Voxel Inputs** nodes, their sliders can have different
  values in the preview, but an export uses a single set of values
