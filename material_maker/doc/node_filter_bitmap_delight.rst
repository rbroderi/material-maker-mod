Delight node
~~~~~~~~~~~~

The **Delight** node: removes large scale lighting variations (shading, vignetting) from a photo, by dividing it by its blurred luminance.

Inputs
++++++

* **Input**: The photo

Outputs
+++++++

* **Output**: The delighted photo
* **Lighting**: The estimated lighting (blurred luminance)

Parameters
++++++++++

* **Radius**: The radius of the blur that estimates the lighting, relative to the image size
* **Target**: The luminance of the delighted image
* **Strength**: The strength of the correction
