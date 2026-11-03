Nodes overview
==============

Material Maker provides different node types to describe materials. Nodes may
have parameters, inputs and outputs.

.. toctree::
   :maxdepth: 2

   nodes_common
   shader_nodes
   material_nodes
   texture_nodes
   remote_nodes
   subgraph_nodes
   reroute_nodes
   aperture_nodes

Graph-local node definitions
----------------------------

A graph can carry its own node definitions, so it can be shared with nodes that are
not in Material Maker's or the user's library. The .mmg node files of a folder named
**<graph>_nodes** next to the graph file (for example **brick_wall_nodes** for
**brick_wall.ptex**) are loaded with the graph, and their file names are node types
of that graph. Graphs can name another folder in a top-level **nodes_dir** string
(relative to the graph file, for example **"nodes_dir": "../shared_nodes"**).

Graph-local node types take precedence over the library's node types of the same
name (also for nodes added from the library), in that graph only: other graphs that
are open at the same time, and the library, are not affected, and the definitions
are freed when the graph is closed.
To update a graph-local node, edit its .mmg file and reload the graph.

Graphs are saved with references to their graph-local nodes (as for library nodes).
When a graph is saved in another folder or under another name, its **nodes_dir** is
updated to point to the folder it was loaded from. Nodes copied into another graph,
or added to a library, are copied with their definitions if the other graph does not
define the same node type in the same way.
