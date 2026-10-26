Moss node
~~~~~~~~~

The **Moss** node: generates a mask of moss growing on surfaces that face a direction (up by default), in cavities, broken up by noise.

Inputs
++++++

* **Normal**: A normal map
* **Ambient occlusion**: An ambient occlusion map (dark in cavities)

Outputs
+++++++

* **Mask**: The weathering mask (1 where the effect is present)

Parameters
++++++++++

* **Amount**: The amount of the effect
* **Softness**: The softness of the mask's edges
* **Direction**: The direction moss grows towards, in degrees (90 is up in the image)
* **Cavity weight**: How much cavities (from the ambient occlusion map) get moss
* **Noise scale**: The scale of the noise that breaks up the mask
* **Noise amount**: How much the noise breaks up the mask
