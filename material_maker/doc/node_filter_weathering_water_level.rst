Water Level node
~~~~~~~~~~~~~~~~

The **Water Level** node: generates masks of water filling the low areas of a height map, of the wet band above it, and of the water's depth, with optional ripples.

Inputs
++++++

* **Height**: The height map

Outputs
+++++++

* **Water**: 1 where the height is below the water level
* **Wetness**: 1 in the water and fading out in a band above it
* **Depth**: The depth of the water, relative to the level

Parameters
++++++++++

* **Level**: The height of the water surface
* **Shore**: The height of the wet band above the water
* **Softness**: The softness of the water's edge
* **Ripples**: How much noise perturbs the water's edge
* **Noise scale**: The scale of the noise
