Value Processor node
~~~~~~~~~~~~~~~~~~~~

The **Value Processor** node computes a single value with a function graph, once, instead
of computing it for each pixel. Its output is constant over the whole image.

It is edited like the **Pixel Processor** node, but its function graph cannot use the pixel
position (*pos* and *size*). It can sample its inputs at positions computed from its
parameters.

Inputs
++++++

The **Value Processor** node has the image inputs declared in its function graph (one RGBA
input by default).

Outputs
+++++++

The **Value Processor** node has a single RGBA output, that is constant over the image.

Parameters
++++++++++

The **Value Processor** node has the float parameters declared in its function graph. By
default, *X* and *Y* define the position where the input is sampled.

Notes
+++++

*sd_rand* reproduces Substance Designer's random generator for value functions.

Parameter functions
+++++++++++++++++++

Any float parameter that accepts expressions can also be defined with a function graph:
right click the parameter to open the expression editor, and click *Function graph...*.
Those function graphs can use the graph's named parameters (*param*) and constants, and are
compiled to an expression. The function graph is saved with the node, so it can be edited
again later.
