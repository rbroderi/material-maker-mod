Command line arguments
======================

When launched with no command line argument, Material Maker will start with an empty project.

When launched with the path of a .ptex file as command line argument, Material Maker will
start with this project file. Material Maker can thus be associated to files with .ptex
extension so double-clicking on them will directly open them.

Material Maker can also be used to export several .ptex file with the following command line:

 material_maker --export-material --target <engine> -o <output_path> <input_files>

Where:

* **engine** is the target engine/platform (Blender, Godot, Unity or Unreal)
* **output_path** is the path where files will be generated
* **input_files** is the list of input files (wildcards are accepted)

The **--color-space <color_space>** option converts the exported color maps (albedo and
emission) to an OpenColorIO color space (for example *ACEScg*, or an alias such as
*sRGB - Texture*) instead of the one set in the Preferences dialog. It needs OpenColorIO
support, and Material Maker exits with an error, and lists the color spaces of the
OpenColorIO config by family, if the color space is not in the config.

The **--color-map-depth <auto|8|16>** option sets the bit depth of the converted PNG color
maps instead of the **Converted PNG color maps** option of the Preferences dialog: *auto*
writes 16 bit PNG files for linear color spaces (such as ACEScg) and 8 bit PNG files for
the other ones, *8* and *16* always write 8 or 16 bit PNG files. It has no effect on maps
that are not converted (no export color space). Material Maker exits with an error for
other values.
