Gradient 3D node
~~~~~~~~~~~~~~~~

The **Gradient 3D** node outputs the gradient vector of a 3D height, measured with finite differences. The Voxel Material node combines it with the surface normal to bump the surface.

Inputs
......

The node accepts a grayscale 3D texture, the height.

Outputs
.......

The node provides a 3D vector texture: the gradient of the height, in height units per metre.

Parameters
..........

* the epsilon, i.e. the distance used for finite differences, in metres
* the strength, a factor applied to the gradient
* the mode: forward differences or central differences

A reference implementation that samples heights in voxels with a bump strength *k* gives the same result as this node with a strength of *k*/81 with heights sampled in metres.
