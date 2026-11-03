Iterate Buffer node
~~~~~~~~~~~~~~~~~~~

The **Iterate Buffer** node samples its input into a texture of a given resolution, applies
a "loop subgraph" several times and outputs the result.

Iterate buffers are used to apply a transform or filter several times to an input
image and can thus be used to implement filters that require multiple passes.

.. image:: images/node_miscellaneous_iterate_buffer.png
	:align: center

Inputs
++++++

The **Iterate Buffer** node has an initialization input that provides the base image,
and a loop input that provides the image transformed by a single pass.

Outputs
+++++++

The **Iterate Buffer** node has 2 outputs:

* the first output is the main output that provides the final result

* the second output is the loop output that provides the image for each iteration

Parameters
++++++++++

The **Iterate Buffer** node has two parameters:

* the *texture resolution*

* the *autostop* property; if set, the Iterate buffer will automatically stop if the iteration
  does not change the buffer contents

* the *number of iterations* for the loop

* the *filter* property; if set, the buffer output will be filtered

* the *mipmap* property; if set, mipmaps will be generated for this buffer

The number of iterations can be an expression of the graph's named parameters (for example
*$steps*), that can be larger than the slider's maximum.

Nodes of the loop (between the loop output and the loop input) can use *$iteration* in their
code and parameter expressions: it is 1 for the first loop pass, then 2, up to the number of
iterations. It is 0 for the input that initializes the buffer and in all other shaders, including
nodes that are rendered separately, such as Buffer nodes inside the loop.

Iterate Buffer (States) node
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The **Iterate Buffer (States)** node works like the **Iterate Buffer** node, but iterates up
to 4 textures (*states*) together, for example a position and a color, or an image and a
running sum. All states are rendered by a single shader in each iteration, so the loop always
reads the states of the previous iteration, and each state has its own storage format.

Inputs
++++++

For *n* states, inputs 1 to *n* initialize the states, and inputs *n+1* to *2n* are the loop
inputs that compute the next value of each state.

Outputs
+++++++

Outputs 1 to *n* provide the final states, and outputs *n+1* to *2n* the current states, that
are connected to the loop.

Parameters
++++++++++

* the number of *states* (1 to 4); connections are kept when it changes

* the *size mode*, *size*, *size offset* and *aspect ratio*, as in the **Advanced Buffer** node
  (*Relative to input* uses the texture read by the first input); the size offset can be an
  expression of named parameters

* the number of *iterations*, a number or an expression of the graph's named parameters and of
  *$pass_size* (the width of the states in pixels), for example *log($pass_size)/log(2)*

* the *filter* property; if not set, the outputs are not interpolated

* the *rounding* of stored values, as in the **Advanced Buffer** node

* the *format* of each state (16 or 32 bits floats, 8 or 16 bits integers) and whether it only
  stores the red and green channels (*RG*). A state is grayscale if its initialization input is

Shaders of the loop can use *$iteration* (1 for the first loop pass, up to the number of
iterations, 0 when the states are initialized) and *$pass_size* (the size of the states).
The size and format of each state are shown under the node, and an orange warning when the
number of iterations or the size offset is an invalid expression.
