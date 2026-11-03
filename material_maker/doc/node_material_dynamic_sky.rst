Dynamic Sky Material node
~~~~~~~~~~~~~~~~~~~~~~~~~

The **Dynamic Sky Material** node describes a sky material.

.. image:: images/node_material_sky.png
	:align: center

Inputs
++++++

The **Dynamic Sky Material** node has a single TEX3D input.

Parameters
++++++++++

The **Dynamic Sky Material** does not have any parameters.

Exports
+++++++

The **Dynamic Sky Material** has exports for the Godot game engine.

Buffers used by the shader are exported as EXR textures, with the precision
Material Maker computes them with, and an .import file that makes Godot import
them as uncompressed textures without mipmaps.

Example images
++++++++++++++

.. image:: images/node_material_sky_samples.png
	:align: center
