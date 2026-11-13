Voxel Wood node
~~~~~~~~~~~~~~~

The **Voxel Wood** node generates oak, as a port of the voxkit wood recipe: growth rings that
wander and flow, fibre, pores, pale medullary rays, ageing and dark drying checks. It is
meant to be connected to the outputs of a :doc:`Voxel Inputs <node_3d_voxel_inputs>` node and
to a :doc:`Voxel Material <node_material_voxel>` node.

The grain runs along the axis given by the **Axis** input. The pith (the centre of the rings)
is at the position given by the **Origin** input and the recipe works in units of
1/**Units per metre** metres.

Inputs
......

The **Voxel Wood** node accepts the following inputs. They are normally connected to the
outputs of the same name of the **Voxel Inputs** node:

* **Seed**: the seed of the piece (a grayscale 3D texture, default 0)
* **Normal**: the surface normal (a 3D texture); a zero vector, the default, counts as a face
  along the grain
* **Axis**: the grain axis (a 3D texture, default X)
* **Origin**: the position of the pith, in metres (a 3D texture)
* **Age**: how old and handled the surface is, from 0 to 1 (a grayscale 3D texture, default 0.1)
* **Fresh**: 0 for the aged surface, 1 for a freshly cut surface (a grayscale 3D texture)
* **Footprint**: the size of a pixel in metres; rings finer than a pixel fade to their mean
  colour (a grayscale 3D texture)

Outputs
.......

The **Voxel Wood** node has the following outputs:

* **Albedo**: the linear base colour (a 3D texture); connect it to a **Voxel Material** whose
  *Linear albedo* parameter is enabled
* **Bump**: the gradient vector of the grain relief, already multiplied by the bump strength
  (a 3D texture). It is expressed in recipe units, so connect it to the *Bump* input of a
  **Voxel Material** and set the bump parameter of the material to 1: the material then computes
  the same bumped normal as voxkit
* **Roughness**: 0.75 minus 0.25 times the medullary ray amount (a grayscale 3D texture)
* **Spec**: 0.05 plus 0.10 times the medullary ray amount (a grayscale 3D texture)
* **Power**: the specular power, always 20 (a grayscale 3D texture)

Parameters
..........

The **Voxel Wood** node accepts the following parameters:

* **Units per metre** (default 81) and **Ring width (mm)** (default 5)
* the colours (sRGB) of the **Early wood** (146, 110, 76), of the **Late wood** (84, 58, 40)
  and of the **Aged colour** (106, 84, 62), and how much the aged finish hides the wood
  (**Aged hides**, 0.55)
* **Ring porous**: oak has a line of open pores in the early wood and strong medullary rays
* **Flow amount** (7.0), **Flow scale** (0.014), **Pith wander** (4.0) and **Ripple amount**
  (0.7), which shape the rings
* **Ray strength** (0.40), **Pore strength** (0.55) and **Check strength** (0.7)
* **Bump strength** (0.08)

All other constants of the recipe are fixed.
