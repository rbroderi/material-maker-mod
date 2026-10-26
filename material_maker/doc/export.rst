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

Godot game engine
-----------------

When exporting for the Godot game engine, Material Maker will generate a .tres file that
describes a fully configured SpatialMaterial.

The Godot 4 targets also export the Material node's extra channels when they are used: the
coat and coat roughness (Godot's clearcoat), anisotropy (with a flow map pointing along the
tangent), sheen (as Godot's rim lighting) and transmission (as backlight).

Unity game engine
-----------------

When exporting for the Unity game engine, Material Maker will generate a .mat file that
describes a fully configured material. It is thus possible to export materials directly
into one of your project assets directory, and Unity will automatically detect the newly
exported materials.

Depending on the Material node type, several Unity targets may be available.

The HDRP target exports the coat (coat mask map) and anisotropy (anisotropy map, with the
anisotropic material type) of the Material node when they are used.

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

The Material node's extra channels are exported when they are used: coat and coat roughness
(with the Clear Coat shading model), sheen (Cloth shading model, when there is no coat),
transmission (Subsurface shading model, when there is no coat or sheen) and anisotropy.
Unreal materials have a single shading model, so only the first one in this order is used.

MaterialX
---------

The **MaterialX/Standard Surface** and **MaterialX/OpenPBR** targets generate a .mtlx file
(MaterialX 1.38 and 1.39) with a standard_surface or open_pbr_surface shader, and the
textures it references (albedo, metallic, roughness, normal, emission and height, when the
corresponding inputs of the Material node are connected). Albedo and emission textures are
tagged as srgb_texture, other textures as raw data, and the normal map uses the OpenGL convention.
Parameters of the Material node (albedo color, metallic, roughness, normal strength, emission
energy and depth scale) are applied in the MaterialX graph. Ambient occlusion is not exported,
since those shaders have no input for it.

USD
---

The **USD/UsdPreviewSurface** target generates a .usda file with a UsdPreviewSurface material
named /Material and its textures (including ambient occlusion). It can be referenced from USD
stages, or imported in applications that support USD materials.

Volumes
-------

3D textures (TEX3D outputs, for example of the 3D/Texture nodes) and 3D signed distance fields
(SDF3D outputs, for example of the 3D/SDF nodes) can be exported as volumes, from the export menu
of the 2D preview (when it shows such an output), from the command line (**--export-volume**) or
from Python scripts (**export_volume**). The output is sampled at the centers of a grid of voxels
covering a box centered on the origin (from -0.5 to 0.5 by default).

* **OpenVDB** (.vdb) files can be used in Blender, Houdini, Unreal Engine and most renderers.
  SDFs become narrow band level sets (a grid named *surface*), grayscale 3D textures fog volumes
  (*density*), and color 3D textures a *color* grid with a *density* grid (the average of the
  color). Only voxels that matter are stored: non zero densities, and distances within 3 voxels
  of the surface.
* **3D DDS** (.dds) and **KTX2** (.ktx2) files are 3D textures for game engines, in 16 bits float
  (the default), 32 bits float or 8 bits, with 4 channels (colors) or 1 channel (grayscale
  textures and SDFs).

Color spaces
------------

When OpenColorIO support is built (see the **native/ocio** directory of the source
repository), color maps (albedo and emission) can be converted to another color space when
exporting, for example *ACEScg* for an ACES pipeline. The color space is set in the **Color**
tab of the preferences (**Color space of exported color maps**; empty exports sRGB textures
as usual), or with
the **--color-space** command line option. Other maps (normal, roughness, metallic, occlusion,
height...) are data and are never converted.

Runtime packages
----------------

Runtime packages (.mmr files) contain the compute shaders that render a material, so
engines can render it again with different parameter values, at runtime or when importing
it. They are exported with the **--export-mmr** command line option or the **export_mmr**
scripting method.

The parameters of the graph's remote node are runtime parameters when they only change
shader uniforms (float and color parameters). Other parameters, and nodes that cannot be
exported as shaders (such as iterate buffers), are baked into the package.

Packages can be used in Godot 4.3+ with the **Material Maker Runtime** addon, in the
**runtime/godot** directory of the source repository:

.. code-block:: gdscript

    var mmr : MMRMaterial = MMRMaterial.load_material("res://bricks.mmr")
    $MeshInstance3D.material_override = mmr.material
    mmr.set_parameter("Hue", 0.3)
    mmr.apply_preset("Mossy")    # presets saved in the remote node, see get_preset_names()

Animated materials (using $time) have a **time** parameter, in seconds.

A standalone renderer written in C++ with Vulkan (in the **runtime/cpp** directory of the
source repository) renders packages without Godot, and can be embedded in other engines'
plugins:

 mmr_render bricks.mmr -o textures --set Hue=0.3
 mmr_render bricks.mmr -o textures --preset Mossy
 mmr_render bricks.mmr --list   # parameters, outputs and presets

Blender add-on
^^^^^^^^^^^^^^

The **runtime/blender** directory of the source repository contains a Blender (4.2+) add-on
that imports runtime packages as Blender materials, using **mmr_render** to render the
textures. **File > Import > Material Maker package (.mmr)** creates a Principled BSDF
material from the package's outputs and the Material node's settings, and assigns it to the
selected objects. The **Material Maker** panel of the material properties shows the package's
parameters and presets: with **Live update**, changing a parameter renders the textures again.
See **runtime/blender/README.md** for its installation.
