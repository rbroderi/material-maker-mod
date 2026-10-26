Dust node
~~~~~~~~~

The **Dust** node: generates a mask of dust settled on flat, upward facing surfaces and in corners, broken up by noise.

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
* **Noise scale**: The scale of the noise that breaks up the mask
* **Noise amount**: How much the noise breaks up the mask
