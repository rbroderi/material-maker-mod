Car Paint Material node
~~~~~~~~~~~~~~~~~~~~~~~

The **Car Paint Material** node renders measured car paints, as described by X-Rite's AxF
CarPaint2 model. It is created by importing AxF car paints (see :ref:`export-section`, AxF
import).

The model is a clear coat over a Lambert diffuse reflection and 3 Cook-Torrance (Beckmann)
specular lobes, all tinted by a color table indexed by two angles, and flakes:

* the light and view directions are refracted by the clear coat (unless **Refraction** is
  unchecked), and light is attenuated by the coat's Fresnel transmission when it enters and
  when it leaves
* the color table is indexed by theta H (the angle between the normal and the half vector)
  along U and theta D (the angle between the light and the half vector) along V, which
  reproduces color shifts with the viewing angle (flop)
* flakes are a BTF: a texture patch for each pair of theta F (theta H) and theta I (theta D)
  slices, arranged in an atlas (theta F columns, theta I rows), added to the reflection

Inputs
++++++

* **Color table**: the color table (sRGB encoded, divided by the **Color table scale**)
* **Flakes**: the flake atlas (encoded around 0.5, relatively to the **Flake scale**)
* **Ambient**: the reflectance of the paint under uniform lighting, for view angles from 0 to
  90 degrees along U (sRGB encoded, divided by the **Ambient scale**)

Parameters
++++++++++

* **Diffuse** is the Lambert albedo
* **Lobe 1-3 coefficient**, **spread** (Beckmann slope) and **F0** (Fresnel reflectance at
  normal incidence) define the specular lobes
* **Clear coat IOR** and **Refraction** define the clear coat
* **Color table scale**, **Ambient scale** and **Flake scale** decode the textures
* **Flake intensity** multiplies the flakes' sparkle, and **Flake tiling** is the number of
  repetitions of the flake patches across the UV space
* **Theta F slices**, **Theta I slices**, **Theta F columns** and **Theta I rows** describe
  the flake BTF's angular sampling and the atlas

The 3D preview renders direct lights with this model. Environment lighting uses the ambient
reflectance and Godot's clear coat, so flakes only sparkle under direct lights.

Exports
+++++++

The **Car Paint Material** node exports a Godot 4 shader material (the same shader as the
3D preview, with its textures). For other engines, the AxF import also writes a static PBR
approximation of the paint (a *_pbr.ptex* graph).
