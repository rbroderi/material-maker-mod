.. _export-section:

Exporting Materials
===================

When exporting a material, using either the Export submenu or the command line arguments,
Material Maker generates PNG image files for all elements of the material as well as
specific files for the target game engine.

In all cases, the generated PNG files (and especially the normal map) are generated in the
correct format.

Blender
-----------------

When exporting for Blender, Material Maker will only generate PNG/EXR images, thus the material must be built manually using the shader editor.

The `Add Principled Texture Setup <https://docs.blender.org/manual/en/latest/addons/node/node_wrangler.html#add-principled-texture-setup>`_ feature from the `Node Wrangler <https://docs.blender.org/manual/en/latest/addons/node/node_wrangler.html>`_ add-on can be helpful to automate the material creation process down to several clicks:

.. image:: images/blender_mat_demo.gif
  :align: center

Procedural shaders
------------------

The **Godot/Godot 4 Shader**, **Unity/Built-in Shader** and **Unreal/Unreal Engine 5 Shader**
targets (from the *More export targets* plugin, enabled by default) export the material as a
shader that computes the graph, instead of textures: the material keeps its detail at any
resolution, without a texture budget. Buffers of the graph (for example the ones of normal map,
warp and fill nodes) are exported as EXR textures that the shader samples, with the precision
Material Maker computes them with (16 or 32 bit floats): 8 bit textures would show steps in
heights and normals, and break the data of fill nodes. The engines import them as uncompressed,
linear textures without mipmaps (an .import file for Godot, a .meta file for Unity, import
settings in the script for Unreal), and the shaders read them at full resolution as Material
Maker does (the LOD output of buffers does not blur them).

* **Godot 4**: a .gdshader and a .tres ShaderMaterial. The parameters of the graph are shader
  uniforms (with their current values), so they can be changed in Godot's inspector. Coat,
  anisotropy, sheen and transmission are written when their parameter is above 0.
* **Unity**: a surface shader (built-in render pipeline) and a .mat file, with the buffer
  textures and their .meta files.
* **Unreal Engine 5**: a Python script that creates the material, with a Custom node that
  contains the generated HLSL code (the .shader file).

The Unity and Unreal shaders are HLSL translations of the graph's GLSL code. The random patterns
of noise nodes can differ from Material Maker's: its hash functions are very sensitive to the
precision of the operations, which differs between shading languages.

Godot game engine
-----------------

When exporting for the Godot game engine, Material Maker will generate a .tres file that
describes a fully configured SpatialMaterial.

Unity game engine
-----------------

When exporting for the Unity game engine, Material Maker will generate a .mat file that
describes a fully configured material. It is thus possible to export materials directly
into one of your project assets directory, and Unity will automatically detect the newly
exported materials.

Depending on the Material node type, several Unity targets may be available.

Unreal game engine
------------------

Unreal Engine 4
^^^^^^^^^^^^^^^

When exporting for the Unreal game engine version 4.x, Material Maker will only
generate PNG images and a .mm2ue file. The material must be built manually inside
the Unreal Engine editor by following the instructions in this file.

This will generally consist in:

* Copying a material file from the **export** directory in Material Maker installation

* in the newly created material:

  * assigning generated textures

  * copying the shader generated in the .mm2ue file into a Custom node

  * creating new inputs in the custom node and TextureObject nodes, assigning the textures and connecting them

.. image:: images/unreal_export.png
  :align: center

Unreal Engine 5
^^^^^^^^^^^^^^^

When exporting for the Unreal game engine version 5.x, Material Maker will generate a
Python script that creates the material in Unreal.

Initial setup
~~~~~~~~~~~~~

Before exporting a material, it is necessary to configure a python path in Unreal for
Material Maker:

* in Unreal Engine, open the Project Settings window using the **Edit/Project Settings...** menu

* in this window, type "Python" in the search bar or select the **Plugins/Python** section

* in the **Additional paths** array, add the full path of the **export** directory of your Material Maker installation

* Unreal Engine will prompt to restart. When this is done, the project is ready to import generated materials

.. image:: images/ue5_setup.png
  :align: center

Exporting materials
~~~~~~~~~~~~~~~~~~~

When exporting a material for Unreal Engine 5, Material Maker will generate a python script,
texture files and a shader file, and will store the full path of the script into the clipboard,
so you just have to paste it into Unreal's 5 Python prompt and execute it to create the material.

When exporting, the target path is not that important (all necessary files will be imported into
the Unreal project), but the file name will be used as material name.

MaterialX
---------

The **MaterialX/Standard Surface** and **MaterialX/OpenPBR** targets (from the *More export
targets* plugin, enabled by default) generate a .mtlx file (MaterialX 1.38 and 1.39) with a
standard_surface or open_pbr_surface shader, and the textures it references (albedo, metallic,
roughness, normal, emission and height, when the corresponding inputs of the Material node are
connected). Albedo and emission textures are tagged as srgb_texture, other textures as raw data,
and the normal map uses the OpenGL convention. Parameters of the Material node (albedo color,
metallic, roughness, normal strength, emission energy and depth scale) are applied in the
MaterialX graph. Coat, anisotropy, sheen (OpenPBR's fuzz) and transmission are exported when their
parameter is above 0, with a texture when the corresponding input is also connected. Ambient
occlusion is not exported, since those shaders have no input for it.

The **MaterialX/Procedural** target generates a procedural material: a .mtlx file that defines
a custom node (*mm_procedural*) whose GLSL implementation (the .glsl file next to it) computes
the whole graph, including what buffers compute (they are inlined). The node's outputs feed a
standard_surface shader. The GLSL implementation is used by MaterialX's GLSL shader generator
(genglsl, with the .mtlx file's directory in its search path). Graphs that read textures (Image
nodes, iterate buffers such as the ones of Fill nodes, mesh maps) cannot use this target yet.

USD
---

The **USD/UsdPreviewSurface** target (from the same plugin) generates a .usda file with a
UsdPreviewSurface material named /Material and its textures (including ambient occlusion, and the
coat when it is used). It can be referenced from USD stages, or imported in applications that
support USD materials.
