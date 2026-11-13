Voxel Surface Pattern node
~~~~~~~~~~~~~~~~~~~~~~~~~~

The **Voxel Surface Pattern** node places a 2D pattern, such as a wallpaper motif or a
fabric weave, on the surfaces of a voxel object. The projection follows the surface normal,
so the pattern stays upright on walls and is not mirrored on opposite faces.

Inputs
......

* **Pattern**: the 2D pattern to project (an ordinary Material Maker image)
* **Normal**: the object-space surface normal (a 3D texture, from :doc:`Voxel Inputs <node_3d_voxel_inputs>`); without a normal (a zero vector, for instance inside a 3D Buffer bake) the node uses the Z projection
* **Mask**: a grayscale 3D texture that multiplies the colour and the height (default 1)

Outputs
.......

* **Colour**: the projected pattern (a 3D texture)
* **Height**: the luminance of the projected pattern (a grayscale 3D texture), to be fed to a Gradient node for bump

Parameters
..........

* **Scale U**, **Scale V** (2.0): repeats of the pattern per metre
* **Up** (Z or Y): the object axis that is up on walls
* **Mode**:

  * *Dominant axis*: one projection along the largest component of the normal
  * *Triplanar blend*: the three projections are blended with weights *abs(n)^sharpness*

* **Blend sharpness** (4.0): the exponent of the blend weights in Triplanar blend mode
* **Offset U**, **Offset V** (0.0): shifts the pattern, in pattern repeats

Projection
..........

On a wall, **U** is the horizontal axis in the plane of the wall and **V** is the up axis. On a floor or a ceiling, **U**
is the X axis and **V** is the other horizontal axis. **U** changes sign with the sign of the normal component, so the pattern reads
the same way from both sides of a wall. The pattern coordinates are *fract(vec2(u*scale_u+offset_u, v*scale_v+offset_v))*.

Notes
.....

* 2D inputs made with buffers are exported as textures (EXR) by the Unreal voxel export target, and work there.
* A pattern that is not tileable shows seams at the edges of its repeats.
