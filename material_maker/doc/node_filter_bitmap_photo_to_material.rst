Photo to Material node
~~~~~~~~~~~~~~~~~~~~~~

The **Photo to Material** node: generates material maps from a single photo: a delit albedo, and height, normal, roughness and ambient occlusion maps estimated from its details.

Inputs
++++++

* **Photo**: The photo of a surface, ideally lit evenly from the front

Outputs
+++++++

* **Albedo**: The photo without large scale lighting variations
* **Height**: The height estimated from the photo's details (bright is high)
* **Normal**: A normal map computed from the height
* **Roughness**: The roughness estimated from the brightness (bright, shiny areas are smoother)
* **Ambient occlusion**: The ambient occlusion estimated from the cavities of the height

Parameters
++++++++++

* **Size**: The resolution used for pixel based effects
* **Detail radius**: The size of the details that make the height; larger variations are considered lighting
* **Delight**: How much large scale lighting is removed from the albedo
* **Height contrast**: The contrast of the height map
* **Invert height**: Makes dark areas high instead of low
* **Normal strength**: The strength of the normal map
* **Roughness min**: The roughness of the brightest areas
* **Roughness max**: The roughness of the darkest areas
* **AO strength**: The strength of the ambient occlusion
