Raymarching Material node
~~~~~~~~~~~~~~~~~~~~~~~~~

The **Raymarching Material** node describes a material that raymarches
a surface defined using a Signed Distance Function, and applies albedo,
metallic, and roughness.

.. image:: images/node_material_raymarching.png
	:align: center

Inputs
++++++

The **Raymarching Material** node has inputs for the distance function and all PBR channels.

Parameters
++++++++++

The **Raymarching Material** has no parameter.

Exports
+++++++

The **Raymarching Material** has exports for the Godot, Unity and Unreal game
engines. For Godot and Unity, ready to use materials are generated. For Unreal,
a shader is generated, to be used in a Custom node.

Buffers used by the shader are exported as EXR textures, with the precision
Material Maker computes them with, and imported as uncompressed, linear textures
without mipmaps (an .import file for Godot, a .meta file for Unity, import
settings in the script for Unreal Engine 5).

Example images
++++++++++++++

.. image:: images/node_material_raymarching_samples.gif
	:align: center
