Pixel Processor node
~~~~~~~~~~~~~~~~~~~~

The **Pixel Processor** node computes each pixel of its output with a *function graph*:
a small typed graph of operations (arithmetic, vector operations, comparisons, selection,
sampling of its inputs at any position, random values, sub-functions and loops...) that is
compiled to GLSL.

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

Function graph editor
+++++++++++++++++++++

Click the node's edit button to open the function graph editor:

* *Add node* adds an operation (grouped by category). Connect a node's output to the
  inputs of other nodes, and set constants and settings directly in the nodes.

* *Set output* chooses the node whose value is the result of the graph.

* Each node shows its type (float, vec2, vec3, vec4, int or bool). Nodes with errors are
  shown in red, with the error in their tooltip, and *Apply* and *OK* are disabled until
  the graph is valid.

* The side panel defines the node's inputs and parameters, and an optional fixed seed
  for Substance-compatible random numbers.

* *Add function* creates a sub-function, with typed arguments, that can be used with the
  *call* operation, or repeated with the *loop* operation (a loop function takes an
  accumulator and the iteration index, and returns the new accumulator).

* *Edit JSON* shows the function graph as text.

* *Undo* and *Redo* (or Control+Z and Control+Y / Control+Shift+Z when no text field has
  the focus) undo and redo changes in the editor. Closing the editor with *OK* or *Apply*
  is a single step in the material's undo history.

Random numbers
++++++++++++++

* *rand* returns a random value computed from a 2D seed.

* *sd_rand*, added by the *Substance random numbers* plugin (in the *Other* category),
  reproduces Substance Designer's pixel processor random generator: each call returns the
  next value of a random sequence that depends on the seed and the pixel position. With a
  fixed seed, results match Substance Designer for the same seed.

Plugins can add other operations, that are listed in the *Other* category.

Notes
+++++

When *Automatic Buffers* are enabled in the preferences, inputs that depend on many nodes
are sampled through an automatic buffer, which is much faster when the function graph
samples them several times.

The function graph format is described in ``design/function_graphs.md`` in the source
repository.
