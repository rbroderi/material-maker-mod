Fill to Index node
~~~~~~~~~~~~~~~~~~

The **Fill to Index** node is a fill companion node that gives each area a consecutive
index. Areas are numbered in the order of their bounding box's top left corner (row by
row), and the output is the index divided by the number of areas minus 1, so the first
area is black and the last one is white. Outlines are black.

Inputs
++++++

The **Fill to Index** node accepts fill data, to be connected to the output of a **Fill**
node (or a compatible output of another node).

Outputs
+++++++

The **Fill to Index** node outputs the normalized index of each area.

Parameters
++++++++++

The *Size* parameter is the resolution at which the fill data is analyzed. It should be at
least the resolution of the **Fill** node, otherwise areas whose bounding boxes start in
the same pixel at this resolution get the same index.

Notes
+++++

The areas are counted on the GPU, then numbered on the CPU, so the index is exact, unlike
the random values of the other fill companion nodes. Like those nodes, the **Fill to
Index** node identifies an area by its bounding box, so two areas whose bounding boxes
start at the same position get the same index.

Combine this node with a **Tones Step** node to select areas by index, or with a
**Colorize** node to map areas to colors.
