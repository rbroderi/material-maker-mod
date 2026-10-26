Dirt node
~~~~~~~~~

The **Dirt** node: generates a mask of dirt accumulated in cavities and concave areas, from ambient occlusion and curvature maps, broken up by noise.

Inputs
++++++

* **Ambient occlusion**: An ambient occlusion map (dark in cavities)
* **Curvature**: A curvature map (0.5 is flat, brighter is convex), e.g. from the Curvature or Mesh Map nodes

Outputs
+++++++

* **Mask**: The weathering mask (1 where the effect is present)

Parameters
++++++++++

* **Amount**: The amount of the effect
* **Softness**: The softness of the mask's edges
* **Curvature weight**: How much concave areas (from the curvature map) get dirt
* **Noise scale**: The scale of the noise that breaks up the mask
* **Noise amount**: How much the noise breaks up the mask
