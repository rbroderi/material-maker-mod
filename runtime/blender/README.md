# Material Maker Runtime for Blender

A Blender add-on (4.2 and later) that imports Material Maker runtime packages
(`.mmr`, exported with *File > Export material > Runtime package* or
`material_maker --export-mmr`) as materials whose parameters can be edited in
Blender.

## Installation

1. Build `mmr_render` (see `runtime/cpp`), or copy `mmr_render.exe` (or
   `mmr_render` on Linux) into the `material_maker_runtime` folder.
2. Zip the `material_maker_runtime` folder, and install it in *Edit >
   Preferences > Add-ons > Install from Disk*.
3. In the add-on's preferences, set the path of `mmr_render` if it is not in
   the add-on's folder, in the `MMR_RENDER` environment variable or in the PATH.

## Use

- *File > Import > Material Maker package (.mmr)* creates a material (assigned
  to the selected objects): a Principled BSDF that uses the package's outputs
  (albedo, occlusion/roughness/metallic, normal, emission and height), with the
  settings of the graph's Material node.
- The *Material Maker* panel of the Material properties shows the package's
  parameters (including the seed of random nodes) and presets, and the size of
  the textures (0 for the size they were exported with). With *Live update*,
  changing them renders the textures again (mmr_render re-renders only what a
  parameter affects).

Textures are rendered in a `material_maker_runtime` folder of the system's
temporary folder. The images are not packed in the .blend file: use *File >
External Data > Pack Resources* to keep them with it.
