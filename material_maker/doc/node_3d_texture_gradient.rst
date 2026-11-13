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

* the epsilon, i.e. the minimum distance used for finite differences, in metres. Far from the origin the distance grows with the largest absolute coordinate (7.4e-6 per metre, i.e. 0.074 m at 10 km) so that it stays above the float32 precision of the positions. It is unchanged within 100 m of the origin with the default epsilon
* the strength, a factor applied to the gradient
* the mode: forward differences or central differences

A reference implementation that samples heights in voxels with a bump strength *k* gives the same result as this node with a strength of *k*/81 with heights sampled in metres.
