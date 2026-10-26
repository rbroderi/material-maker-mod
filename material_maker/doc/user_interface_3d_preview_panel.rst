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

The *Model* menu also has an **OpenPBR shading** option, that replaces Godot's direct lighting
in the preview with an approximation of the OpenPBR surface model: a coat (IOR 1.6) over
fuzz (sheen) over an anisotropic GGX base, with thin walled transmission. Godot does not allow
replacing its whole lighting model, so ambient light and reflections still use Godot's model.

The *Environment* menu provides different environments, as well as tonemap options.

The *Export* menu can also render the preview:

* **Path traced render...** renders the object from the current view with a progressive path
  tracer (in a GPU compute shader) that uses the Material node's maps (albedo, ORM, normal,
  emission, coat, sheen) and the environment's panorama, with the given size and number of
  samples. PNG files are tone mapped, EXR files contain linear values. With **Transparent
  background**, the background is transparent instead of showing the environment.
  Generated preview models are rendered with their untesselated version, and height maps do
  not displace the surface.

* **Turntable...** renders a full turn of the object (the given number of frames) with the
  preview's renderer, as a sprite sheet, or as a PNG sequence if the file name contains #
  characters (replaced by the frame number, for example turntable_###.png).

In the 3D view, the view can be rotated about the yaw and the pitch axes (from the
camera's point of view) by holding the left mouse button and moving the mouse horizontally
or vertically. The object can also be rotated about the roll axis by holding Shift and
and the right mouse button and moving the mouse horizontally.

Holding the Shift key will rotate the object while the view remains static.

Rotating the object or the camera will automatically disable the object's rotate animation.

The mouse wheel can be used to move the camera along its longitudinal axis (hense zooming
forward or backward).
