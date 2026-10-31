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