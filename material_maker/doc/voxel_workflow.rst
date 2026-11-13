.. _voxel-workflow-section:

Voxel material workflow
=======================

This chapter describes how to build materials for voxel objects (and for any other object that is
textured by its position in 3D instead of by UV coordinates), how to check them, and how to
take them to Unreal Engine 5. Everything in it is provided by the *Voxel materials* plugin
(**voxel**) and by small companion plugins (**voxel_eval**, **voxel_mesh_bake**, **voxel_master**,
**param_schema**, **graph_cost**) that are enabled by default.

The chain is:

#. a graph of 3D texture nodes, starting from the :doc:`Voxel Inputs <node_3d_voxel_inputs>` node
   and ending in a :doc:`Voxel Material <node_material_voxel>` node (the *Voxel* section of the
   *3D* library category);
#. the 3D preview, that shows the material on any mesh with the object-space position, normal
   and bump;
#. the checks: the parameter schema, the shader cost estimate, evaluation at given points from
   Python, and the parity test between the GLSL of Material Maker and the exported HLSL;
#. the export to Unreal Engine 5, as a Custom node material, a Material Function, or one master
   material that holds many recipes;
#. optional bakes: a 3D volume, or the 2D textures of a mesh.

A complete example, the oak of the ZCity kit, is in **material_maker/examples/voxel_oak.ptex**
(see :ref:`voxel-oak-example`).

The voxel context
-----------------

Voxel materials read the same values everywhere (preview, evaluation from Python, exports):

* **Position**: the object-space position of the shaded point, **in metres**. The 3D texture
  coordinate is ``$uv.xyz``.
* **Normal**: the object-space unit normal of the surface. A zero vector means that the normal is
  not known (the :doc:`Voxel Inputs <node_3d_voxel_inputs>` node then falls back to the
  direction of the position).
* **Fresh**: a per point value, 0 on the original surface and 1 on a freshly cut one.
* **Per object values**, the parameters of the **Voxel Inputs** node: *Seed*, *Age*, *Upkeep*,
  *Fresh*, *Char*, *Wet*, the *Axis* (a direction), the *Origin* (a position in metres) and
  the *Footprint* (the size of a pixel in metres, 0 when unknown, used to fade details that are
  smaller than a pixel). They are sliders in the 3D preview, they are saved in the .ptex file,
  and they can be set with **--set**, with RPC, and with the evaluation tools below.

The parameters are named ``vox_seed``, ``vox_age``, ``vox_upkeep``, ``vox_fresh``, ``vox_char``,
``vox_wet``, ``vox_axis_x/y/z``, ``vox_origin_x/y/z`` and ``vox_footprint``.

Units
+++++

Everything is in metres. A kit that works in voxels uses a scale factor: the ZCity voxels are
81 per metre, and the :doc:`Voxel Wood <node_3d_voxel_wood>` node has a *Units per metre*
parameter (default 81) for the sizes it expresses in voxels. In Unreal Engine, whose unit is
the centimetre, the exports multiply the position by 0.01 (the *position_scale* of the master
configuration).

Seeds
+++++

Seeds are integer valued floats. The Voxel Inputs slider goes from 0 to 65535; the noise
nodes add their *seed offset* parameter (0 to 1000) to their seed input and convert the sum
exactly (``mm_n3_seed``, exact up to 16777215). The new noise nodes use an integer hash (the one of the
ZCity kit's ``noise.py``) so that GLSL, HLSL and numpy produce the same values.

Linear versus sRGB
++++++++++++++++++

The *Linear albedo* parameter of the Voxel Material node tells whether its albedo input is
already linear. When it is unchecked (the default), the input is read as sRGB and decoded by the
material, as the other materials do. Recipes that compute linear colours (such as the ZCity
ones, and the :doc:`Voxel Wood <node_3d_voxel_wood>` node) check it. The colours of
parameters (the *aged colour* of the wood, for example) are sRGB, like any colour parameter.
Evaluation from Python always returns the **linear** colour.

Limitations of the context
++++++++++++++++++++++++++

Material Maker does not carry a normal through the generated functions. The normal and the
per point fresh value travel in the *controlled variation* of the shader, and the other values
are node parameters. Consequently:

* the **Controlled Variations** node cannot be used in a voxel graph;
* whatever is baked in a buffer (including a :doc:`3D Buffer <node_3d_texture_buffer>`) loses
  the normal and the per point fresh value: they are seen as zero;
* a graph with several **Voxel Inputs** nodes can show different slider values in the
  preview, but it is exported, evaluated and read by the schema with one set of values;
* in exports, the normal output of the material is in object space.

Nodes
-----

* :doc:`Voxel Inputs <node_3d_voxel_inputs>` and :doc:`Voxel Material <node_material_voxel>`
  (see also the :doc:`voxel nodes <node_3d_voxel>`).
* Seeded 3D noises: :doc:`value <node_3d_texture_noise_value>`,
  :doc:`Perlin <node_3d_texture_noise_perlin>`, :doc:`fBm <node_3d_texture_noise_fbm>`,
  :doc:`Voronoi <node_3d_texture_noise_voronoi>`, the
  :doc:`domain warp <node_3d_texture_domain_warp>` and the
  :doc:`gradient <node_3d_texture_gradient>` node, whose output is the bump input of the
  material. The noises accept a *period* so that a baked volume tiles.
* Recipes: :doc:`Voxel Wood <node_3d_voxel_wood>`, :doc:`Palette Pick <node_3d_voxel_palette_pick>`,
  :doc:`Weathering <node_3d_voxel_weathering>`, :doc:`Char <node_3d_voxel_char>`,
  :doc:`Wetness <node_3d_voxel_wetness>`, :doc:`Paint <node_3d_voxel_paint>`.
* :doc:`Surface Pattern <node_3d_voxel_surface_pattern>`: places a 2D function (wallpaper,
  fabric...) on surfaces, projected along the normal in 3D.
* :doc:`3D Buffer <node_3d_texture_buffer>`: see below.

Legacy noise hash
+++++++++++++++++

The older 3D noises (:doc:`FBM <node_3d_texture_fbm>`, FBM 2, FBM 3 and the 3D Voronoi) hash with
``fract(sin(...))``, which gives different patterns on different GPUs and shader compilers. They
have a *hash* parameter: *Legacy* (the default, so that existing graphs do not change) or *Exact*
(the integer hash of the new noises, with a seed derived from the seed of the node). Choose
*Exact* in graphs that must be the same in Unreal. The *3D/Texture/FBM* library item uses it. The
shader cost tool lists the remaining legacy nodes as parity warnings (the 3D Blend node's
*Dissolve* mode and the SDF 3D fBm, repeat and circle repeat nodes still use the old hash).

Writing nodes for exports
-------------------------

Exports translate GLSL to HLSL by string replacement. Nodes that must export (your own .mmg
files, remote nodes, function graphs) have to follow this subset:

* no ``mat2``, ``mat3``, ``mat4``, no ``uvec*`` or ``bvec*`` types, no ``lessThan``,
  ``greaterThan`` or ``equal``, no ``dFdx`` or ``fwidth``, no ``texelFetch`` or ``textureSize``,
  and no one argument ``atan``. Write rotations component by component (see the *Rotate* node);
* no vector ternaries, and no ``&&`` or ``||`` on vectors;
* integer vectors only as ``ivec3(int, int, int)`` built from scalars, never ``ivec3(vec3)``;
* loops have a constant bound, with ``if (i >= n) break;`` for variable counts;
* new identifiers must not contain ``vec2``, ``vec3``, ``vec4``, ``mat2``, ``mix``, ``fract``,
  ``atan``, ``uniform``, ``sampler2D``, ``elapsed_time`` or ``texture_``, because the translator
  replaces these substrings;
* ``mod(a, b)`` is fine;
* ``Char`` is the name of the Unreal input, as ``char`` is a reserved word in HLSL.

The shader cost estimate (below) reports the constructs it knows to differ between the
languages (*parity_warnings*). The **hlsl_base** step of the translator now matches whole words
and handles ``uvec*``, ``mat3``/``mat4`` and one argument ``atan``, but the subset above is
the safe one.

Parity: what is guaranteed
--------------------------

**test/test_voxel_hlsl_parity.gd** builds voxel graphs (value noise, fBm, Voronoi, domain warp
and gradient bump, every Voxel Inputs output, the existing parity safe 3D nodes, the Voxel
Wood node, and the legacy fBm for information), evaluates them at 4096 points with the generated
GLSL (run as a compute shader), exports them with the real *Unreal Engine 5 Voxel* target,
compiles the exported HLSL with DXC to SPIR-V, runs it on the GPU and compares the colour, the
ORM, the emission and the bumped normal. On the test machine, the 22 cases agree within 1e-4 for
the noises (largest difference of the final colours 6.1e-4, for the wood).

What this proves, and what it does not:

* **Proven**: the HLSL written by the exporter, compiled by DXC (Vulkan SDK version), computes
  the same values as the generated GLSL on the tested GPU.
* **Not proven**: Unreal's own shader pipeline (its DXC version and flags, FXC under SM5, half
  precision on mobile, the wrapper that Unreal puts around Custom nodes); the Godot spatial
  shader of the 3D preview (assumed equal to the compute GLSL, as they come from the same
  generated text); other GPUs; the legacy sin-hash nodes.
* The test compiles with ``-O0``. Optimised SPIR-V (``-O1`` or more) of noise loops hangs the
  driver of one of the tested GPUs (an AMD Radeon 780M, device lost). This is a driver problem of
  the tests, not of the exported text.
* There is no ``fxc`` on the development machine: only DXC with ``-HV 2018`` and ``-HV 2021``
  is run.

Exporting to Unreal Engine 5
----------------------------

The plugin adds two export targets (see :ref:`export-section`):

* **Unreal/Unreal Engine 5 Voxel** writes ``<prefix>.py``, ``<prefix>.shader`` (the HLSL for
  a Custom node) and ``<prefix>_texture_<n>.exr`` for buffers. The script creates a material
  whose Custom node computes the recipe.
* **Unreal/Unreal Engine 5 Voxel Function** writes ``<prefix>.voxel.hlsl`` (a struct named
  ``MMVoxRecipe``), the textures and ``<prefix>_function.py``, which creates a Material Function
  named ``MF_<prefix>`` that a master material (below) or your own materials call.

The Custom node has these inputs, in this order: ``Position`` (float3), ``Normal`` (float3),
``Seed``, ``Age``, ``Upkeep``, ``Fresh``, ``Char``, ``Wet`` (floats), ``Axis``, ``Origin``
(float3), ``Footprint``, ``Time`` (floats), then one texture (and its sampler) per buffer. The
outputs are the base colour (the return value) and ``metallic``, ``roughness``, ``normal``
(**object space**, bump included), ``emission``, ``occlusion`` and ``opacity``. In the generated
material the normal output is transformed to world space and the position is the local position
multiplied by 0.01 (Unreal centimetres to metres). The generated code fills the uniforms of the
Voxel Inputs node from these inputs, so the slider values of the graph are not used.

From the command line:

 material_maker --export-material --target "Unreal/Unreal Engine 5 Voxel" -o out oak.ptex

What is unverified
++++++++++++++++++

The generated Python scripts are checked with ``py_compile`` and by running them against a
recording stub of the ``unreal`` module (**test/voxel_unreal_stub.py**), and the HLSL is checked
by DXC. They were **not run in Unreal Engine**. In particular these are unverified: the
material compile in Unreal, ``MaterialFunctionFactoryNew`` and
``create_material_expression_in_function``, the ``FunctionInputType`` values, Custom Primitive
Data and vertex colour inputs, the use of several structs and ``if``/``else`` in one Custom node,
the ``ddx`` based footprint, and the transform of the normal. The scripts say so in their header.
Check them in the editor before relying on them.

The master material
+++++++++++++++++++

**--voxel-master** combines the recipes of several graphs in one material that selects the
recipe of each object with an integer id:

 material_maker --voxel-master --master-config master.json -o out wood.ptex stone.ptex

The graphs are exported with the *Voxel Function* target, the structs are renamed
(``MMVoxRecipe`` becomes one struct per graph) and a dispatcher calls the struct of the object's
id with real branches, so one recipe runs per pixel. It writes ``<name>.shader``,
``<name>.py`` (the Unreal script) and ``<name>.master.json`` (the resolved configuration, the
texture files and the ids). The configuration is a JSON object:

.. code-block:: json

    {
        "name": "M_VoxelMaster",
        "ids": { "wood.ptex": 0, "stone.ptex": 1 },
        "id_source": "custom_primitive_data:0",
        "inputs": {
            "Seed": "custom_primitive_data:1", "Age": "custom_primitive_data:2",
            "Upkeep": "custom_primitive_data:3", "Fresh": "vertex_color:g",
            "Char": "custom_primitive_data:4", "Wet": "custom_primitive_data:5",
            "Axis": "custom_primitive_data:6", "Origin": "custom_primitive_data:9",
            "Footprint": "auto"
        },
        "position_scale": 0.01
    }

Every key is optional (the values above are the defaults, ``ids`` is the integer id of each graph
by file name). A source is ``custom_primitive_data:<n>`` (the first of the three for *Axis* and
*Origin*), ``vertex_color:r|g|b|a``, ``uv<n>:x|y``, or ``auto`` (the footprint computed
from the derivatives of the position).

Evaluating from Python
----------------------

Voxel graphs can be evaluated at arbitrary points without rendering an image, with numpy arrays
in and out. This is what a kit needs to compare its own renderer with the graph, or to bake
per-voxel colours.

.. code-block:: python

    from material_maker_client import launch
    from material_maker_client.voxel import VoxelGraph

    process, mm = launch(["material_maker"], graph="oak.ptex")
    graph = VoxelGraph(mm, "oak.ptex")
    out = graph.evaluate(points, normals, {"seed": 12, "age": 0.3})
    out["base_color"]   # (N, 3) float32, linear colour
    out["orm"]          # (N, 3) ambient occlusion, roughness, metallic
    out["emission"]     # (N, 3)
    out["normal"]       # (N, 3) bumped normal, object space
    out["opacity"]      # (N,)

``points`` is an (N, 3) array in metres, ``normals`` (optional) an (N, 3) array of unit vectors,
and ``fresh=`` (optional) an array of N per point values. With ``node="Name"`` or
``node="Name:output"``, ``evaluate`` returns the (N, 4) RGBA values of that node output instead
(3D textures have an alpha of 1, grayscale ones are repeated in r, g and b).

The other voxel inputs (seed, age, upkeep, fresh, char, wet, footprint, axis, origin) are
**one value per call**: pass them in ``params`` (``"axis"`` and ``"origin"`` as lists of three
numbers, or ``"node:parameter"`` names). To evaluate points that differ in these values, group
them and make one call per group. The server and the client must share a file system, as the
arrays are exchanged as float32 .npy files.

The same can be done without Python, from the command line:

 material_maker --evaluate-points --points p.npy --normals n.npy --fresh f.npy --voxel-params '{"seed": 12, "axis": [1, 0, 0]}' -o out oak.ptex

which writes ``out/oak_base_color.npy``, ``_orm``, ``_emission``, ``_normal`` and ``_opacity``
(or ``oak_<node>.npy`` with **--node**). See **python/examples/voxel_evaluate.py** and
:ref:`scripting-section`.

Volumes and mesh bakes
----------------------

**3D volume.** *--export-volume* samples a 3D output on a grid (see :ref:`export-section`). For
voxel work the useful options are the **raw** format (``<name>.raw`` and a ``<name>.raw.json``
that gives the resolution, the texel format, the channels, the extent and the origin, with the
x axis varying fastest), the single and two channel 8 and 16 bit texel formats (r8, rg8, r16, rg16),
**--volume-origin corner** (samples the box [0, extent]^3, for noises whose *period* is
the extent) and **--check-tileable** (fails when the volume is not periodic with the period
*extent*; use it on a tileable noise, not on the wood):

 material_maker --export-volume --node Wood:0 --format raw --texel-format rgba8 --voxels 64 --extent 1 --volume-origin corner -o out oak.ptex

**Mesh bake.** *--bake-voxel-material* bakes the Voxel Material of a graph to the textures of
a mesh, using the mesh's UVs (the 3D position of each texel is evaluated, with the mesh normal):

 material_maker --bake-voxel-material --mesh crate.glb --size 1024 --unit-scale 1.0 --set Inputs:vox_seed=12 -o out oak.ptex

It writes ``<graph>_<mesh>_basecolor``, ``_orm``, ``_normal_object``, ``_emission`` and ``_opacity``
as **png** (the default) or **exr** (**--format**). The base colour and the emission of the PNG
files are sRGB; the others are linear. The normal map is the object-space normal as
``0.5 + 0.5 n``. **--unit-scale** is the number of metres per mesh unit. UV islands are
dilated by 4 pixels. The default size is 1024. The same function is available from RPC as
**bake_voxel_material**.

Parameter schema
----------------

**--param-schema** writes ``<graph>.schema.json``, a description of everything an external tool
can set, without rendering:

 material_maker --param-schema -o schemas oak.ptex

The file is a JSON object with ``format`` (``"mm-param-schema"``), ``version`` (1),
``graph``, ``material`` (type and inputs, with whether each is connected), ``voxel_inputs`` (one
entry per Voxel Inputs slider, with its ``name``, its ``parameter`` ("Node:vox_name"), type,
minimum, maximum, step and default), ``remotes`` (the remote parameters) and ``parameters``
(the parameters of the top level nodes). The ``param_schema`` RPC method returns the same object.

Cost readout
------------

**--graph-cost** prints one JSON line per graph with a *relative* estimate of the shader cost
of the material (or of a node output, with **--node**):

 material_maker --graph-cost oak.ptex
 material_maker --graph-cost --node Wood:0 oak.ptex

The line has ``instructions`` (a weighted count, not Unreal's instruction count),
``texture_samples``, ``functions``, ``loops_unbounded``, ``by_function`` and ``parity_warnings``
(the legacy sin-hash functions and other constructs that differ between GLSL and HLSL); with
**--node** on a node with inputs it also has ``by_input``. The *Plugins > Show shader cost*
menu item shows the numbers of the current graph. Use it to compare variants of a recipe, not
to predict the Unreal cost.

3D Buffer trade-off
-------------------

The :doc:`3D Buffer <node_3d_texture_buffer>` node replaces an expensive 3D subgraph by a lookup.
It stores the volume in a 16 bit float 2D atlas of slices (a regular buffer) and reads it back with
two lookups and trilinear filtering, so it needs no engine change and exports with the
other buffers. In exchange: the input must be periodic with the node's *extent* or a seam shows,
the atlas takes 2 to 128 MB of video memory depending on its layout, filtering is clamped at the
x and y borders of the volume, and the baked branch loses the normal and the fresh value (they
are zero below the buffer). The *Direct* mode skips the bake for comparison (the mean absolute
difference between the modes is about 0.0002). A real 3D texture lookup in the Unreal Custom
node is not generated; ``--export-volume`` can write a volume for wiring by hand.

Matching a recipe against a photo
---------------------------------

Material Maker has no split view or overlay of the 3D preview and a photo, and none is planned.
The :doc:`Reference panel <user_interface_reference_panel>` already shows a photo beside the
preview, and picks colors and gradients from it: store the main colors of the photo in its color
boxes and drop them into the color parameters of the recipe (for example the early, late and aged
colors of the wood), then tune the other sliders by eye.

.. _voxel-oak-example:

Example: the ZCity oak
----------------------

**material_maker/examples/voxel_oak.ptex** rebuilds the oak of the ZCity kit's voxkit:
*Voxel Inputs*, then *Voxel Wood*, then *Voxel Material* (linear albedo, bump 1). Its remote node
**Oak** controls the four arch parameters of the wood and has two presets, *voxkit* (the kit's
values) and *zcity* (gentler arches).

The scripts in **python/examples/zcity_oak/** (see its README.md) rebuild the graph with the
Python client (**build_graph.py**) and compare it with voxkit's own code and with the stored
render **beam_close.png** (**compare_oak.py**): the points are evaluated with the method above,
the exported HLSL is compiled, and the pictures are drawn with voxkit's renderer. At the points,
the graph agrees with voxkit's wood in its own frame (the Origin is the pith, the other noises
use absolute positions): albedo mean about 1.2e-4 (99th percentile under 1.8e-3, maximum 6.1e-3),
normal within 0.028 degrees, spec within 4.7e-5. The comparison picture meets the thresholds:
MAD 0.023 and SSIM 1.0000 against the voxkit render, and the ``zcity`` preset has an arch measure
of 0.283 (phase) and 0.574 (luminance) and 13 rings against 12. The side faces of the ``zcity``
preset still need a look by a person.

Known limits
------------

* Nothing here was run in Unreal Engine (see above).
* Only the position, the normal and the fresh value are per point; the other voxel inputs are
  one value per call or per object.
* Legacy sin-hash nodes do not give the same pattern in HLSL; use their *Exact* hash.
* The cost is an estimate, and the 3D Buffer loses the normal and the fresh value.
* The brick bond layout and the window moulding profile of the ZCity kit are part of its geometry
  and are not nodes; the *Palette Pick* node takes an id from any source.
