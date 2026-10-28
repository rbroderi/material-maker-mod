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

The number of iterations can be an expression of the graph's named parameters. Shaders of the
loop can use *$iteration*: 0 for the initialization, then 1 to the number of iterations.

Iterate Buffer with several states
++++++++++++++++++++++++++++++++++

Graphs can also use iterate buffers with several states (type **iterate_buffer_v2**), for
example an image and a running mean. Inputs 1 to n initialize the states, and inputs n+1 to 2n
are the loop inputs. Outputs 1 to n are the final states, and outputs n+1 to 2n the current
states, that are connected to the loop. All states are rendered by a single shader in each
iteration, so the loop always reads the states of the previous iteration. Its parameters are:

* the number of *states* (1 to 4)
* the *size mode*, *size* and *size offset*, as in the Advanced Buffer node
* the number of *iterations*, a number or an expression of named parameters and of *$pass_size*
  (the width of the states in pixels)
* *filter*, and the *rounding* of 8 and 16 bits integer states
* the *format* of each state (16 or 32 bits floats, 8 or 16 bits integers), and whether it only
  stores the *RG* channels

In the loop, *$iteration* is 1 for the first loop pass, and *iterations* loop passes follow the
initialization.