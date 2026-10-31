.. _scripting-section:

Scripting
=========

Material Maker can be controlled from scripts through a JSON-RPC 2.0 server, either with its
user interface or without:

 material_maker --rpc-port 7680 [<input_file>]
 material_maker --rpc [--rpc-port <port>] [<input_file>]

The server is only started with one of these options (the default port is 7680), and only
accepts connections from the local computer (127.0.0.1). With **--rpc**, the input file is
loaded before clients can connect. Each request is a JSON object on a single line, and each
response is sent on a single line:

 {"jsonrpc": "2.0", "id": 1, "method": "set_parameters", "params": {"values": {"Hue": 0.5}}}
 {"jsonrpc": "2.0", "id": 1, "result": true}

With the user interface, methods act on the current graph of the current project, and changes
can be undone (with the user interface, connections are accepted once the main window is
ready). Without user interface (**--rpc**), the server owns a single material graph, and the
window is minimized (rendering needs a GPU) unless **--show-window** is used.

Python client
-------------

The **python** directory of the source repository contains a Python client without dependencies
(*pip install ./python*):

.. code-block:: python

    from material_maker_client import launch, color

    process, mm = launch(["material_maker"], graph="bricks.ptex")
    print(mm.list_parameters())
    for i in range(4):
        mm.reseed()
        mm.render("Material", "bricks_%d.png" % i, output=0, size=1024)
    mm.set_parameter("Material", "albedo_color", color(1.0, 0.8, 0.6))
    mm.export("MaterialX/Standard Surface", "out/bricks")
    mm.quit()

**launch** starts Material Maker in **--rpc** mode and connects to it. To connect to a running
server, use **MaterialMaker(port=7680)**. Any method of the server can also be called with
**mm.call("method", **params)**. See **python/examples/variations.py** for a complete script.

Methods
-------

Paths must be absolute (the Python client converts them). Node names are those shown in the
graph (and in **list_nodes**).

* **ping()** returns the version and whether the user interface is running
* **new_graph(template)**, **load(path)**, **save(path)** create, load and save .ptex files
  (**load** also imports MaterialX materials, .mtlx files).
  The optional template is an output template (a name returned by **list_templates()**, or
  an export target) that sets the export target of the new material
* **list_nodes()** returns the nodes with their type, inputs, outputs and parameters
* **get_node(node)**, **list_connections()**, **list_parameters()**
* **set_parameter(node, parameter, value)** and **set_parameters(values)**, where values is a
  dictionary whose keys are remote parameter names or labels, or "node:parameter".
  Colors are written {"type": "Color", "r": 1, "g": 0, "b": 0, "a": 1}
* **create_node(type, name, position, parameters)** creates a node from its type (such as
  "perlin"), from a library item (**item**, a dictionary as stored in library files) or, with
  the user interface, from a library item path (such as "Noise/Voronoi"), and returns its name
* **delete_node(node)**, **connect(from, to, from_port, to_port)**, **disconnect(from, to, from_port, to_port)**
  (ports are numbered from 0, and connect fails if a node does not have the given port)
* **list_presets()** returns the names of the presets of the graph's remote nodes, and
  **apply_preset(name)** applies one to the remote nodes that have it
* **save_preset(name, node)** saves the current values of a remote node as a preset (an existing
  preset with this name is replaced), and **delete_preset(name, node)** deletes one. **node** is
  only needed for **save_preset** when the graph has several remote nodes; **delete_preset**
  deletes the preset from all the remote nodes that have it by default. With the user interface,
  these methods can be undone (one step for all the remote nodes they change)
* **randomize_parameters(seed, node)** sets random values to the parameters of the remote nodes
  (or of one of them), within their ranges, and returns the seed (random by default), so the
  same values can be generated again
* **reseed(offset)** changes the seeds of all nodes that are not locked (cannot be undone)
* **render(node, output, size, path, height)** renders a node output to a PNG, EXR, JPEG or WebP
  file (outputs are numbered from 0, as with **--render** on the command line, with an optional
  height for non-square images). Its directory is created if needed
* **render_queue()** lists the buffers that are not rendered yet, to diagnose renders that never
  finish
* **list_export_targets()** and **export(target, prefix, size, height, udim)** export the material
  (prefix is the path of the exported files without extension, and size 0 uses the Material
  node's size; **udim** exports UDIM tiles: true for the graph's tiles, or a list such as "1001-1004,1011"
  or [1001, 1002])
* **export_mmr(path, size, height)** exports a runtime package (.mmr) of the material
* **export_volume(node, path, output, resolution, extent, texel_format)** exports a 3D texture or
  SDF output as a volume (.vdb, .dds or .ktx2)
* **render_path_traced(path, size, samples, transparent, thin_walled)** and **render_turntable(path, frames, size)**
  render the 3D preview (with the user interface only, see the 3D preview panel)
* **undo()** and **redo()** (with the user interface only)
* **quit()** (without user interface only)

Errors are returned as JSON-RPC errors (the Python client raises **MaterialMakerError**):
parse errors, invalid requests, unknown methods, invalid params (params that are not an object),
and server errors with a message for missing parameters or parameters of the wrong type, unknown
nodes, and methods that fail.

Plugins
-------

Plugins are folders that contain a **plugin.cfg** file, in the **plugins** folder of Material
Maker's user data folder (the *Tools > Plugins...* window has a button that opens it) or in the **plugins** folder next to
Material Maker. *Tools > Plugins...* lists them and enables or disables them (changes are
applied when Material Maker starts again).

.. code-block:: ini

    [plugin]
    name="My plugin"
    description="What it does"
    version="1.0"
    script="plugin.gd"          ; optional, extends MMPlugin
    nodes="nodes"               ; optional, a folder of nodes (.mmg files)
    library="library.json"      ; optional, a node library
    export_targets="exports"    ; optional, a folder of export targets (.mme files)
    enabled_by_default=true
    depends=["car_paint", "other_plugin>=1.2"] ; optional, plugins it needs
    cli_modes=["--my-export"]   ; optional, command line modes added by the script

**depends** lists the plugins (by folder name, optionally with a minimum version) that must be
loaded first. Dependencies that are only disabled by default are enabled when needed. A plugin
whose dependencies are missing, too old, disabled by the user, cannot be loaded or depend on it
again (a cycle) is not loaded, and *Tools > Plugins...* shows why. Enabling a plugin in that
window also enables its dependencies, and disabling one also disables the plugins that need it.

A plugin's script extends **MMPlugin**. Its **_enable(api)** function is called when Material
Maker starts, and **_disable()** when it quits. The API object adds:

* menu items: **api.add_menu_item(label, callable, menu="Plugins", after="")**, in the
  **Plugins** menu, or in another menu (e.g. *File*) after one of its items (e.g. *Export
  material*)
* import formats: **api.add_import_format(extension, description, callable)**, whose files are
  imported as new material graphs by *File > Load*, drag and drop, the **load** JSON-RPC method and
  the command line. The callable receives the file's path and returns the graph (a dictionary, as
  in .ptex files, with optional **warnings**), or an empty dictionary on errors
* JSON-RPC methods: **api.add_rpc_method(name, callable)**, called with the request's parameters
  (and, when the callable has 2 arguments, the RPC server, whose **fail(message)**,
  **require(params, names)**, **get_graph()** and **get_generator(graph, name)** report errors
  and give access to the current graph)
* command line commands, run with **--plugin <command> [arguments]**:
  **api.add_command(name, callable)**, called with the arguments and returning the exit code
* command line modes (such as **--export-volume**, also listed in **cli_modes**):
  **api.add_cli_mode(mode, callable, usage, options)**. The callable receives the command line
  tool (whose **process_graph_files(files, options, variation, mode)** loads each graph, applies
  **--set**, **--preset**, **--seed** and **--variations**, and calls **variation(suffix, graph,
  file, options)**, and **expand_files(files)** expands wildcards), the files and the options.
  **options** maps the mode's own options to **{ key, type, help }** (type is TYPE_INT,
  TYPE_FLOAT, TYPE_STRING, or TYPE_BOOL for flags, and an optional **minimum**), that are checked
  like the built-in options, and **usage** and the options' help are shown by **--help**
* sections of the 2D preview's export menu: **api.add_export_menu_section(callable)**, that
  receives the export menu (with **get_generator()**, **get_output()** and
  **export_notification(text)**) and returns a Control, whose optional
  **update(generator, output_index)** method is called when the previewed output changes
* export hooks, called after each material export with the material node, the exported file
  prefix and the export target: **api.add_export_hook(callable)**
* image file formats: **api.add_image_format(extension, description, callable)**, used wherever
  images are saved (texture exports, the 2D preview's export menu). The callable receives the
  image, the file name and options (the **options** of the export target's texture file, plus
  **srgb**, **grayscale** and **alpha** from the exported output) and returns an error code
* files that hold several images: **api.add_layered_image_format(extension, description,
  callable)**. Texture files of an export target with a **layer** name and the same file name
  are saved together: the callable receives the file name and the layers (**{ name, image,
  options }**)
* node types implemented by scripts: **api.add_node_type(type, script)**, for nodes that shader
  definitions (.mmg files) cannot describe. **script** extends **MMGenBase** (see the engine's
  generators, such as **MMGenSbsFxMap**), and nodes whose **"type"** is **type** in graph files
  are created from it
* function graph operations (Pixel and Value Processors): **api.add_function_graph_op(name,
  operands, compile_callable, globals)**. **operands** are the keys of the node that reference
  other nodes. **compile_callable** receives the compiler (**MMFunctionGraph.Compiler**), the
  node id, the node, the operation and the operand ids, sets the node's type in
  **compiler.types** and returns its GLSL expression (**compiler.value_of(id)** gives the
  expression of an operand, **compiler.types[id]** its type), or calls
  **compiler.error(node_id, message)** and returns an empty string. It can add statements
  before the node's to **compiler.code**, globals with **compiler.add_global(definition)**,
  and read **compiler.variables** (**mode** is "pixel" or "value") and **compiler.graph**.
  **globals** are GLSL definitions added once per shader when the operation is used. These
  operations are listed in the *Other* category of the function graph editor, and graphs that
  use one that is not available show an "unknown operation" error. The *Substance random
  numbers* plugin (**sd_rand**) is an example
* **MMPlugins.load_plugin_file(plugin_id, file_name)** loads a file of another (loaded) plugin, for
  example a script shared with the plugins that depend on it
* **api.get_main_window()**, the main window (null on the command line), to add panels or dialogs

Export targets of plugins (**export_targets** folder) are listed with the Material node's own
targets. The user's export targets (edited in the material editor) override them, and plugin
targets that are left unchanged are not copied to the user's export targets.

.. code-block:: gdscript

    extends MMPlugin

    func _enable(api) -> void:
        api.add_menu_item("Say hello", func(): print("Hello"))
        api.add_rpc_method("node_count", func(params): return 42)
        api.add_export_hook(func(material, prefix, target): print("exported ", prefix))

Nodes whose type is unknown when a graph is loaded (for example nodes of a plugin that is not
installed) are kept as magenta placeholders, that are saved unchanged with the graph.

Graph requirements
++++++++++++++++++

Graphs can declare what they need, in a top-level **requires** dictionary, or, for files that are
also loaded by versions that do not save it, in a line of the graph's long description
(**<anything>requires:** followed by the JSON on the same line, for example
**sbsar2ptex-requires: {"material_maker_mod": ">=1.17", "plugins": {"sbs": ">=1.0"}}**):

* **material_maker_mod**: the minimum version of this fork's features (1.17)
* **plugins**: plugin ids with an optional minimum version (**">=1.0"**)
* **node_types**: node types that must be available
* **features**: features of this fork: buffer_release, buffer_size_relative_to_input,
  buffer_size_expressions, pass_size, iterate_buffer_v2, iteration_variable, unorm16, rg_formats,
  store_rounding, node_types, missing_node_placeholders, sbs_fxmap

When a graph is loaded, what it needs and is missing (and the types of its placeholders) is shown
in a dialog, returned by the **load** JSON-RPC method (**{ loaded, missing }**), and makes the
command line fail with exit code 2 (placeholders only fail with **--strict**).

Graph-local node definitions
++++++++++++++++++++++++++++

The .mmg files of a folder named **<graph>_nodes** next to a graph file (or of the folder given by
the graph's **nodes_dir**, relative to the graph file) are loaded before the graph, and their names
are node types, that take precedence over the nodes of Material Maker and of plugins. Converters
use them to write each repeated subgraph once (for example sbsar2ptex's
**sbs_<material>_<node>** types).

The **list_plugins** JSON-RPC method lists the plugins, and the RPC methods and commands they add.
The **material_maker/plugins/example** folder contains an example plugin (disabled by default)
that adds a node, a menu item, an import format (.stripes files), an RPC method, a command, a
command line mode (**--example-thumbnails**), a section of the 2D preview's export menu and an
export hook.
Several features of Material Maker are bundled plugins, enabled by default, that can be disabled
in *Tools > Plugins...*: **materialx_import** (MaterialX import), **runtime_export** (runtime
packages, **--export-mmr**), **volume_export** (volumes, **--export-volume**), **export_targets**
(the Godot 4, Unity and Unreal Engine 5 shader exports, MaterialX and USD), **sbs** (a skeleton
of the Substance atomic nodes plugin that sbsar2ptex installs), **ktx2_format**,
**tx_format** and **exr_layers_format** (the KTX2 and TX image formats, multi-layer OpenEXR,
and their export targets), **car_paint** (the
Car Paint Material node) and **axf_import** (AxF import, that depends on **car_paint**).
**volume_export** depends on **ktx2_format**, that writes its KTX2 files.

Cooking runtime packages
------------------------

**python/mm_cook.py** (no dependencies) cooks graphs into runtime packages (.mmr files, see
:ref:`export-section`), like Substance's cooker. Its inputs are .ptex files, folders (searched
recursively, and whose structure is kept in the output folder) or wildcards:

 python mm_cook.py --mm "material_maker" -o cooked --size 1024 --jobs 4 materials/
 python mm_cook.py -o cooked --verify mmr_render --report report.json materials/*.ptex

Cooking is incremental: a package is only cooked again when its graph, the options or Material
Maker's version changed (unless **--force** is used). **--jobs** runs several Material Maker
processes, **--verify** renders each package with the C++ runtime to check it, and **--report**
writes a JSON report. The Material Maker command is **--mm** or the **MATERIAL_MAKER**
environment variable. The exit code is 1 if a package failed.

Version control
---------------

The **python/ptex_tools.py** script helps storing graphs in git:

* **ptex_tools.py diff old.ptex new.ptex** lists the nodes, parameters and connections that changed
* **ptex_tools.py merge base.ptex ours.ptex theirs.ptex -o merged.ptex** merges independent changes
  (nodes are matched by name, connections are merged as sets, and subgraphs and parameters are
  merged recursively), and lists conflicting changes
* **ptex_tools.py normalize file.ptex** prints the graph with nodes and connections in a stable order

It can be used as git's diff and merge driver for .ptex files:

 git config diff.ptex.textconv "python python/ptex_tools.py normalize"
 git config merge.ptex.driver "python python/ptex_tools.py merge %O %A %B -o %A"

with **\*.ptex diff=ptex merge=ptex** in **.gitattributes**.

JSON schema
-----------

**python/ptex.schema.json** is a JSON schema (draft 2020-12) of .ptex files and node
definitions (.mmg): nodes, connections, parameter values (colors, gradients, curves,
polygons...), shader models and remote widgets. It can be used by editors, or to check files
before committing them:

 python python/ptex_tools.py validate material_maker/examples/*.ptex

which also checks that connections refer to existing nodes, and that node names are unique.

Validating libraries
--------------------

**python/validate_library.py** creates every node of a library and renders it, and renders
example materials, so node libraries can be checked in CI:

 python python/validate_library.py --mm "material_maker" --examples material_maker/examples
