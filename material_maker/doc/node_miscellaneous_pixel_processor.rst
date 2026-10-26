Pixel Processor node
~~~~~~~~~~~~~~~~~~~~

The **Pixel Processor** node computes each pixel of its output with a *function graph*:
a small typed graph of operations (arithmetic, vector operations, comparisons, selection,
sampling of its inputs at any position, random values...) that is compiled to GLSL.

The function graph format and the list of operations are described in
``design/function_graphs.md`` in the source repository.

Inputs
++++++

The **Pixel Processor** node has the image inputs declared in its function graph
(one RGBA input named *Input* by default). Inputs can be sampled several times at
arbitrary positions.

Outputs
+++++++

The **Pixel Processor** node has a single RGBA output. A grayscale result is output
as gray with an opaque alpha.

Parameters
++++++++++

The **Pixel Processor** node has the float parameters declared in its function graph
(an *Amount* parameter by default, that blends the input with its inverse).
If the function graph uses the *size* variable, a *Size* parameter is added.

Editing
+++++++

Until a visual editor is available, the function graph is edited as JSON text: click the
node's edit button to open it. Invalid graphs are rejected with an explanation of each
error (unknown operation, type mismatch, cycle...).

Notes
+++++

When *Automatic Buffers* are enabled in the preferences, inputs that depend on many nodes
are sampled through an automatic buffer, which is much faster when the function graph
samples them several times.
