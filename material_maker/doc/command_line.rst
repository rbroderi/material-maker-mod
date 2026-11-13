Command line arguments
======================

When launched with no command line argument, Material Maker will start with an empty project.

When launched with the path of a .ptex file as command line argument, Material Maker will
start with this project file. Material Maker can thus be associated to files with .ptex
extension so double-clicking on them will directly open them.

Material Maker can also process files without user interface, using one of the following
modes. The window is minimized (rendering needs a GPU), unless **--show-window** is used.

Godot's **--headless** option replaces the renderer by a dummy one. Material Maker builds made
with **material_maker/misc/headless.patch** (applied by the *Build Export Templates* GitHub
workflow, whose templates the release builds use) still create GPU devices without a display,
so **--headless** runs work on servers and in containers without a display server (with any
Vulkan driver, including Mesa's software lavapipe). Other builds (and a stock Godot) run again
without **--headless**, with a minimized window: on Linux systems without a display, this
needs **xvfb-run** (from the *xvfb* package), that provides a virtual one.

 material_maker --export-material [options] <input_files>
 material_maker --render --node <node[:output]> [options] <input_files>
 material_maker --export-volume --node <node[:output]> [options] <input_files>
 material_maker --bake [--maps <map,...>] [options] <mesh_files>
 material_maker --list-parameters <input_files>
 material_maker --param-schema [-o <dir>] <input_files>
 material_maker --graph-cost [--node <node[:output]>] <input_files>
 material_maker --evaluate-points --points <points.npy> [options] <input_files>
 material_maker --bake-voxel-material --mesh <mesh> [options] <input_files>
 material_maker --voxel-master --master-config <config.json> -o <dir> <input_files>
 material_maker --export-mmr [options] <input_files>
 material_maker --rpc [--rpc-port <port>] [<input_file>]
 material_maker -- --help

Input files are .ptex files (wildcards are accepted), or MaterialX files (.mtlx) that are
imported (see :ref:`export-section`). The mode and options can be given before or after **--**
(for example material_maker -- --render --node Material:0 bricks.ptex). Godot handles some short
options itself (such as **-t** and **--help**), so they only reach Material Maker after **--**.
Unknown options and incorrect values are errors (Material Maker exits with code 1).

Modes
-----

* **--export-material** exports materials for a target engine (see :ref:`export-section`)
* **--render** renders an output of a node (outputs are numbered from 0, the Material
  node's outputs are the exported maps: 0 is albedo, 2 emission, 3 normal, 12 metallic,
  13 roughness...)
* **--export-volume** exports a 3D texture or SDF output as a volume (see :ref:`export-section`),
  named <input>_<node>.<format>, with **--format** vdb (the default), dds or ktx2, **--voxels**
  (the resolution, from 8 to 256, 128 by default), **--extent** (the size of the sampled box, 1 by default) and,
  for dds and ktx2, **--texel-format** (rgba16f, rgba32f, rgba8, r16f or r32f; also r8, rg8, r16
  and rg16 for dds, ktx2 and the formats below). **--format** raw writes <input>_<node>.raw and a
  <input>_<node>.raw.json file that describes it, and **--format** slices one image per z slice.
  **--volume-origin** corner samples the box [0, extent]^3 instead of the centered one
  (the default is center), and **--check-tileable** fails if the volume is not periodic with the
  period given by **--extent**
* **--bake** bakes mesh maps (position, normal, tangent, ambient_occlusion, bent_normals,
  thickness, curvature, seams, adjacency) to files named <mesh>_<map>.png
* **--list-parameters** lists the parameters that can be set with **--set**
* **--export-mmr** exports runtime packages (see :ref:`export-section`), named <input>.mmr
  (the material's size is used unless **--size** is given)
* **--param-schema** writes the parameters of each graph (the Voxel Inputs sliders, the Voxel
  Material inputs, the remote parameters and the parameters of the top level nodes) as a JSON
  file named <input>.schema.json, without rendering (see :ref:`voxel-workflow-section`)
* **--graph-cost** prints, as one line of JSON per graph, a relative estimate of the shader cost
  (instructions, texture samples, parity warnings) of the material, or of a node output with
  **--node**
* **--evaluate-points** evaluates the Voxel Material of a graph (or a node output, with **--node**)
  at the points of a NumPy .npy file, and writes the results as .npy files (<input>_base_color,
  _orm, _emission, _normal and _opacity, or <input>_<node> with **--node**). The options are
  **--points** (float32 positions in metres, shape (N, 3), required), **--normals** (unit
  normals, shape (N, 3)), **--fresh** (shape (N)) and **--voxel-params** (a JSON object, or the path
  of a JSON file, with seed, age, upkeep, fresh, char, wet, footprint, axis and origin)
* **--bake-voxel-material** bakes the Voxel Material of a graph to the textures of the mesh given
  with **--mesh** (obj or glb), named <input>_<mesh>_basecolor, _orm, _normal_object, _emission and
  _opacity, with **--size** (1024 by default), **--unit-scale** (metres per mesh unit, 1 by
  default) and **--format** png (the default) or exr
* **--voxel-master** combines the voxel recipes of several graphs in one Unreal Engine 5
  master material (<name>.shader, <name>.py and <name>.master.json), configured by the JSON file
  of **--master-config** (see :ref:`voxel-workflow-section`)
* **--rpc** starts a JSON-RPC server to control Material Maker from scripts (see :ref:`scripting-section`)
* **--plugin <command> [arguments]** runs a command added by a plugin (see :ref:`scripting-section`),
  for example **--plugin axf_import material.axf output_dir** to import an AxF material. The
  arguments that follow the command are passed to it (they are not options of Material Maker)

Plugins can also add modes (such as **--export-volume**, or **--example-thumbnails** in the
example plugin) and their options, that are listed by **material_maker -- --help** when the
plugin is enabled. Wildcards also match the files of formats that plugins import.

Options
-------

* **--target <target>** is the export target (for example "Godot/Godot 4 Standard",
  "Unreal/Unreal Engine 5", "MaterialX/Standard Surface" or "USD/UsdPreviewSurface")
* **-o <path>**, **--output-dir <path>** is the directory where files will be generated (created if needed)
* **--output-file <pattern>** is the file name of exported materials (%f is the input file name,
  %n and %N the material name, %a and %A its author)
* **--size <size>** is the size of generated images. For **--render**, **--export-material** and
  **--export-mmr**, **<width>x<height>** (for example 2048x1024) generates non-square outputs:
  the graph is stretched to the image's shape, and buffers keep their sizes. Without a height,
  exports use the Material node's aspect ratio. **--export-material** uses the Material node's size
  when **--size** is not given (2048 before) or is 0, Export nodes their own size, and buffers
  sized relative to the output follow **--size** (rounded to a power of 2). **--render** and
  **--bake** use 2048 by default
* **--gpu-budget <MB>** sets a GPU memory budget: the least recently used textures are moved to the
  main memory above it (see the *GPU memory budget* preference)
* **--low-memory** frees the texture of each buffer when all the buffers that read it are rendered (it is
  rendered again if needed): large graphs need much less memory, for a little more time. The peak GPU
  texture memory is printed after exports.
* **--strict** fails when a graph has nodes of unknown types (by default, they are kept as magenta
  placeholders with a warning). Graphs that declare requirements (plugins, version, features) that are
  not met always fail: they are skipped with an error, the other files are still processed, and
  the exit code is 2.
* **--preset <name>** applies a preset of the graph's remote nodes (before **--set** values). A
  graph that has no such preset is skipped with an error that lists its presets, and Material
  Maker exits with code 1
* **--set <name>=<value>** sets a parameter before rendering, and can be repeated. The name is
  either the name or label of a parameter of the graph's remote node (for example
  --set Hue=0.5), or a node name and a parameter name (for example --set Perlin:scale_x=8).
  Values are numbers, true/false, colors (#rrggbb or #rrggbbaa) or JSON
* **--seed <n>** changes the seeds of all nodes whose seed is not locked
* **--variations <n>** generates n variations with different seeds, whose files are suffixed with _v<i>
* **--format <format>** is the image format of **--render** (png, exr, jpg or webp, png by default,
  or a format added by a plugin)
* **--color-space <space>** converts exported color maps (albedo and emission) to an
  OpenColorIO color space (for example ACEScg, or an alias such as *sRGB - Texture*) instead
  of the one set in the Preferences dialog. It needs OpenColorIO support, and Material Maker
  exits with an error (and lists the color spaces of the config by family) if the color space
  is not in the config
* **--color-map-depth <auto|8|16>** sets the bit depth of the converted PNG color maps instead
  of the **Converted PNG color maps** option of the Preferences dialog: *auto* writes 16 bit PNG
  files for linear color spaces (such as ACEScg) and 8 bit PNG files for the other ones, *8* and
  *16* always write 8 or 16 bit PNG files. It has no effect on maps that are not converted, and
  Material Maker exits with an error for other values
* **--frames <n>** makes **--render** render n frames of an animated material ($time going
  from 0 to the duration, frame i being rendered at duration*i/n so the animation loops) in a
  sprite sheet, rows being filled first, with **--duration <seconds>** (the default is 1) and
  **--columns <n>** (the default is a square sheet). Buffer nodes whose inputs use $time
  are rendered again for each frame (iterations start again).
  **--separate-frames** writes one file per frame instead, suffixed with _<frame> (from 1)
* **--maps <map,...>** is the list of maps generated by **--bake**
* **--high <mesh>** bakes maps of a high poly mesh onto the input mesh with **--bake**, which
  adds the normal_tangent, normal_object, height, color, material_id and position maps
  (the default maps are then normal_tangent and height)
* **--cage <mesh>** is an optional cage mesh for **--high**, with the same topology as the input mesh
* **--front <d>** and **--rear <d>** are the ray distances in front of and behind the input mesh
  for **--high**, relative to the diagonal of its bounding box (the default is 0.01)
* **--samples <n>** is the number of antialiasing samples for **--high** (the default is 4)
* **--match-names** matches the parts of the input mesh and of the **--high** mesh by name (see the
  High Poly Bake node)
* **--skew <image>** is a skew map for **--high**
* **--high-texture <image>** is the texture of the **--high** mesh, for the **texture** map
* **--udim** bakes each UDIM tile used by the input mesh's UVs (with **--high**), to files named
  <mesh>_<map>.<tile>.png (for example model_normal_tangent.1002.png). With **--export-material**,
  it exports each UDIM tile of the graph: those of the mesh of its Mesh Map and High Poly Bake
  nodes, and those of the tile files of its Image nodes (whose path contains **<UDIM>** or a
  tile number, such as albedo.1001.png). Textures are named <name>.<tile>.png (for example
  bricks_albedo.1002.png), and MaterialX and USD files use **<UDIM>** in their file names
* **--udim-tiles <list>** bakes (with **--bake**) or exports (with **--export-material**) these
  UDIM tiles (for example 1001-1004,1011)
* **--mesh <mesh>** is the mesh of the graph's Mesh Map and High Poly Bake nodes with
  **--export-material** and **--render** (as the 3D preview's custom mesh)
* **--software-raytracing** bakes **--high** maps without hardware ray tracing, even when the GPU
  supports it
* **--points <file>**, **--normals <file>**, **--fresh <file>**, **--voxel-params <json>**,
  **--unit-scale <f>**, **--master-config <file>**, **--volume-origin <center|corner>** and
  **--check-tileable** are the options of the voxel modes above (**--node**, **--set**, **--size**,
  **--format**, **--mesh** and **-o** are the options described here)
* **--rpc-port <port>** is the port of the JSON-RPC server (the default is 7680). When used without
  **--rpc**, Material Maker starts with its user interface and a server

**--preset**, **--set**, **--seed** and **--variations** work with **--export-material**, **--render**
and plugin modes. They are applied in this order: the preset first, then the **--set** values (so
they override the preset's values), then the seeds of each variation (presets only hold the values
of remote parameters, not seeds).

Exit code
---------

Material Maker exits with code 0 when all files were processed, and 1 when the options are not
valid. Files that cannot be loaded, downloaded, rendered or baked (and graphs whose **--preset**
or **--set** values cannot be applied) are reported with an error, the other files are still
processed, and the exit code is 1. Graphs whose requirements are not met give exit code 2 (see
**--strict**), even if other files fail too.

Examples
--------

 material_maker --bake --high sculpt.obj --udim --size 2048 -o maps model.obj

 material_maker --export-material --target "Godot/Godot 4 Standard" -o out materials/*.ptex
 material_maker --render --node Material:0 --set Hue=0.3 --variations 4 --size 1024 -o out bricks.ptex
 material_maker --export-material --preset Mossy --set Hue=0.1 -o out bricks.ptex
 material_maker --render --node Material:0 --frames 16 --duration 2 --columns 4 --size 256 -o out fire.ptex
 material_maker --param-schema -o schemas oak.ptex
 material_maker --graph-cost oak.ptex
 material_maker --evaluate-points --points p.npy --normals n.npy --voxel-params '{"seed": 12}' -o out oak.ptex
 material_maker --bake-voxel-material --mesh crate.glb --size 1024 -o out oak.ptex
 material_maker --voxel-master --master-config master.json -o out wood.ptex stone.ptex
 material_maker --export-volume --node Noise:0 --format raw --texel-format r8 --voxels 64 --volume-origin corner -o out noise.ptex
 material_maker --bake --maps ambient_occlusion,curvature --size 2048 -o maps model.obj
 material_maker --bake --high sculpt.obj --maps normal_tangent,height,material_id --front 0.02 -o maps model.obj
