.. _scripting-section:

Scripting
=========

Material Maker can be controlled from scripts through a JSON-RPC 2.0 server, either with its
user interface or without:

 material_maker --rpc-port 7680
 material_maker --rpc --rpc-port 7680 [<input_file>]

The server only accepts connections from the local computer (127.0.0.1). Each request is a
JSON object on a single line, and each response is sent on a single line:

 {"jsonrpc": "2.0", "id": 1, "method": "set_parameters", "params": {"values": {"Hue": 0.5}}}
 {"jsonrpc": "2.0", "id": 1, "result": true}

With the user interface, methods act on the current graph of the current project, and changes
can be undone. Without user interface, the server owns a single material graph.

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

Methods
-------

Paths must be absolute (the Python client converts them). Node names are those shown in the
graph (and in **list_nodes**).

* **ping()** returns the version and whether the user interface is running
* **new_graph(template)**, **load(path)**, **save(path)** create, load and save .ptex files.
  The optional template is an output template (a name returned by **list_templates()**, or
  an export target) that sets the export target of the new material
* **list_nodes()** returns the nodes with their type, inputs, outputs and parameters
* **get_node(node)**, **list_connections()**, **list_parameters()**
* **set_parameter(node, parameter, value)** and **set_parameters(values)**, where values is a
  dictionary whose keys are remote parameter names or labels, or "node:parameter".
  Colors are written {"type": "Color", "r": 1, "g": 0, "b": 0, "a": 1}
* **create_node(type, name, position, parameters)** creates a node from its type (such as
  "perlin") or, with the user interface, from a library item (such as "Noise/Perlin"), and
  returns its name
* **delete_node(node)**, **connect(from, from_port, to, to_port)**, **disconnect(from, from_port, to, to_port)**
* **list_presets()**, **apply_preset(name)**, **save_preset(name, node)** manage the presets of
  the graph's remote nodes, and **randomize_parameters(seed)** sets random values to their
  parameters
* **reseed(offset)** changes the seeds of all nodes that are not locked (cannot be undone)
* **render(node, output, size, path)** renders a node output to a PNG or EXR file
* **list_export_targets()** and **export(target, prefix, size)** export the material
* **export_mmr(path, size)** exports a runtime package (.mmr) of the material
* **export_volume(node, path, output, resolution, extent, texel_format)** exports a 3D texture or
  SDF output as a volume (.vdb, .dds or .ktx2)
* **undo()** and **redo()** (with the user interface only)
* **quit()** (without user interface only)

Errors are returned as JSON-RPC errors (the Python client raises **MaterialMakerError**).

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

Validating libraries
--------------------

**python/validate_library.py** creates every node of a library and renders it, and renders
example materials, so node libraries can be checked in CI:

 python python/validate_library.py --mm "material_maker" --examples material_maker/examples
