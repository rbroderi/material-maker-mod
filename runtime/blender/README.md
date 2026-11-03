# Material Maker Runtime for Blender

A Blender add-on (4.2 and later) that imports Material Maker runtime packages
(`.mmr`, exported with *File > Export runtime package (.mmr)...* or
`material_maker --export-mmr`) as materials whose parameters can be edited in
Blender.

## Installation

1. Build `mmr_render` (see `runtime/cpp`), or copy `mmr_render.exe` (or
   `mmr_render` on Linux) into the `material_maker_runtime` folder.
2. Zip the `material_maker_runtime` folder (or run
   `blender --command extension build --source-dir material_maker_runtime`),
   and install it in *Edit > Preferences > Add-ons > Install from Disk*.
3. In the add-on's preferences, set the path of `mmr_render` if it is not in
   the add-on's folder, in the `MMR_RENDER` environment variable or in the PATH.

## Use

- *File > Import > Material Maker package (.mmr)* creates a material (assigned
  to the selected objects): a Principled BSDF that uses the package's outputs
  (albedo, occlusion/roughness/metallic, normal, emission and height), with the
  settings of the graph's Material node. The albedo's alpha is used only if
  the material is transparent and the albedo has transparent pixels, and the
  height only if the material has a depth scale.
- The *Material Maker* panel of the Material properties shows the package's
  parameters (including the seed of random nodes: 0 is the exported seed) and
  presets, and the size of the textures (0 for the size they were exported
  with; as with Material Maker's export size, buffers keep their own size).
  With *Live update*, changing them renders the textures again (mmr_render
  re-renders only what a parameter affects).

Textures are rendered as float EXR files (the values of Material Maker's
renders; albedo and emission are sRGB, the other outputs are data) in a
`material_maker_runtime` folder of the system's temporary folder, and are
rendered again when a .blend file is opened after they were deleted. The
images are not packed in the .blend file: use *File > External Data > Pack
Resources* to keep them with it.
