.. _scripting-section:

Scripting
=========

Material Maker can be controlled from scripts through a JSON-RPC 2.0 server, either with its
user interface or without:

 material_maker --rpc-port 7680 [<input_file>]
 material_maker --rpc [--rpc-port <port>] [<input_file>]

The server is only started with one of these options (the default port is 7680), and only
accepts connections from the local computer (127.0.0.1). Each request is a JSON object on a
single line, and each response is sent on a single line:

 {"jsonrpc": "2.0", "id": 1, "method": "set_parameters", "params": {"values": {"Hue": 0.5}}}
 {"jsonrpc": "2.0", "id": 1, "result": true}

With the user interface, methods act on the current graph of the current project, and changes
can be undone. Without user interface (**--rpc**), the server owns a single material graph, and
the window is minimized (rendering needs a GPU) unless **--show-window** is used.

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
    mm.export("Godot/Godot 4 Standard", "out/bricks")
    mm.quit()

**launch** starts Material Maker in **--rpc** mode and connects to it. To connect to a running
server, use **MaterialMaker(port=7680)**. Any method of the server can also be called with
**mm.call("method", **params)**. See **python/examples/variations.py** for a complete script.

Methods
-------

Paths must be absolute (the Python client converts them). Node names are those shown in the
graph (and in **list_nodes**).

* **ping()** returns the version and whether the user interface is running
* **new_graph()**, **load(path)**, **save(path)** create, load and save .ptex files
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
* **reseed(offset)** changes the seeds of all nodes that are not locked (cannot be undone)
* **render(node, output, size, path)** renders a node output to a PNG, EXR, JPEG or WebP file
  (outputs are numbered from 0, as with **--render** on the command line)
* **render_queue()** lists the buffers that are not rendered yet, to diagnose renders that never
  finish
* **list_export_targets()** and **export(target, prefix, size)** export the material (prefix is
  the path of the exported files without extension, and size 0 uses the Material node's size)
* **undo()** and **redo()** (with the user interface only)
* **quit()** (without user interface only)

Errors are returned as JSON-RPC errors (the Python client raises **MaterialMakerError**).
