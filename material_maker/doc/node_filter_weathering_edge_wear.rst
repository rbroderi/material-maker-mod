Edge Wear node
~~~~~~~~~~~~~~

The **Edge Wear** node: generates a mask of worn edges, from a curvature map, broken up by noise.

Inputs
++++++

* **Curvature**: A curvature map (0.5 is flat, brighter is convex), e.g. from the Curvature or Mesh Map nodes

Outputs
+++++++

* **Mask**: The weathering mask (1 where the effect is present)

Parameters
++++++++++

* **Amount**: The amount of the effect
* **Softness**: The softness of the mask's edges
* **Noise scale**: The scale of the noise that breaks up the mask
* **Noise amount**: How much the noise breaks up the mask
