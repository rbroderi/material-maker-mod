3D Preview panel
^^^^^^^^^^^^^^^^

The 3D preview panel shows a 3D preview of the current material.

.. image:: images/preview_3d.png
  :align: center

The *Model* menu can be used to:

* select a model for the 3D preview

* show a popup to configure its UV scale and specify if it should be tesselated or not

* start and stop the object's rotation animation

* generate the following mesh maps:

  * Mesh Normal Map: Stores object space normals.

  * Inverse UV Map: Stores object space positions.

  * Curvature Map: Stores how curved parts of the object are.

  * Ambient Occlusion Map: Stores how occluded parts of the object are from itself.

  * Thickness Map: Stores how thick parts of the object are.

  These options are only available for custom meshes.

Selecting the *Custom* option in the model list will show a file dialog to select a
3D model (``.glb``, ``.gltf``, ``.fbx`` and Wavefront ``.obj`` are supported). The model should have
UV information to correctly display materials (normals will be generated if they are missing).

When generating a map from a custom mesh, an image node for the generated map will
be stored in the clipboard, and it is possible to directly paste that node into about
a material graph.

The *Environment* menu provides different environments, as well as tonemap options.

In the 3D view, the view can be rotated about the yaw and the pitch axes (from the
camera's point of view) by holding the left mouse button and moving the mouse horizontally
or vertically. The object can also be rotated about the roll axis by holding Shift and
and the right mouse button and moving the mouse horizontally.

Holding the Shift key will rotate the object while the view remains static.

Rotating the object or the camera will automatically disable the object's rotate animation.

The mouse wheel can be used to move the camera along its longitudinal axis (hense zooming
forward or backward).

The *Export* menu's *Render* section makes presentation renders of the previewed object
from the current view:

* **Path traced render...** renders the object with a progressive GPU path tracer and saves
  it as a PNG (tone mapped as the preview) or linear EXR file. The object is lit by the
  environment's panorama and its sun, and its material uses the Material node's albedo,
  metallic, roughness, emission, normal, coat, sheen, transmission and subsurface scattering.
  *Samples* sets the quality and *Transparent background* removes the background. With
  *Displacement*, the object is subdivided and displaced by the material's depth (the
  preview only shows it with parallax). Transmissive objects are rendered as glass-like
  solids that refract light (with an index of refraction of 1.5, tinted by the albedo, and
  the sun shines through them), or with *Thin walled*, as thin sheets that let diffuse light
  through, as leaves, paper or fabric. Subsurface scattering lets light travel inside solid
  objects (a random walk), as in wax, marble or skin: *SSS radius* is how far light travels
  (in percents of the object's size, 3 by default) and *SSS radius color* scales it for red,
  green and blue light (white scatters all colors as far; skin lets red light travel
  farther, for example with a color of (1.0, 0.4, 0.25)).

* **Turntable...** renders a full turn of the object with the 3D preview, as a sprite sheet,
  or as a PNG sequence if the file name contains ``#`` (replaced by the frame number).

*Size* is the size of the rendered images.
