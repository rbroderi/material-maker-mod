Unlit Material node
~~~~~~~~~~~~~~~~~~~

The **Unlit Material** node describes a simple unlit material.

.. image:: images/node_material_unlit.png
	:align: center

Inputs
++++++

The **Unlit Material** node has a single RGBA input.

Parameters
++++++++++

The **Unlit Material** has a single partameter that defines the material blending mode.

Exports
+++++++

The **Unlit Material** has exports for the Godot, Unity and Unreal game
engines. For Godot and Unity, ready to use materials are generated. For Unreal,
a shader is generated, to be used in a Custom node.

Buffers used by the shader are exported as EXR textures, with the precision
Material Maker computes them with, and imported as uncompressed, linear textures
without mipmaps (an .import file for Godot, a .meta file for Unity, import
settings in the script for Unreal Engine 5).

Example images
++++++++++++++

.. image:: images/node_material_unlit_samples.gif
	:align: center
