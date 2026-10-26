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
* **new_graph()**, **load(path)**, **save(path)** create, load and save .ptex files
* **list_nodes()** returns the nodes with their type, inputs, outputs and parameters
* **get_node(node)**, **list_connections()**, **list_parameters()**
* **set_parameter(node, parameter, value)** and **set_parameters(values)**, where values is a
  dictionary whose keys are remote parameter names or labels, or "node:parameter".
  Colors are written {"type": "Color", "r": 1, "g": 0, "b": 0, "a": 1}
* **create_node(type, name, position, parameters)** creates a node from its type (such as
  "perlin") or, with the user interface, from a library item (such as "Noise/Perlin"), and
  returns its name
* **delete_node(node)**, **connect(from, from_port, to, to_port)**, **disconnect(from, from_port, to, to_port)**
* **reseed(offset)** changes the seeds of all nodes that are not locked (cannot be undone)
* **render(node, output, size, path)** renders a node output to a PNG or EXR file
* **list_export_targets()** and **export(target, prefix, size)** export the material
* **undo()** and **redo()** (with the user interface only)
* **quit()** (without user interface only)

Errors are returned as JSON-RPC errors (the Python client raises **MaterialMakerError**).
