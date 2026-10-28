Buffer node
~~~~~~~~~~~

The **Buffer** and **Advanced Buffer** nodes sample their input into a texture of a given resolution and
outputs the result.

Buffers can be used either as inputs of complex nodes (to limit the combined
shader's complexity), or to create a cheap blur/pixelization effect (by using the
LOD output).

Note that many complex transforms that are provided in the nodes library
already include buffers where necessary. Buffers and nodes that use buffers
have a small icon in their title bar. Right clicking on that icon will show
a context menu that can be used to pause and resume the corresponding buffer(s).

.. image:: images/node_miscellaneous_buffer.png
	:align: center

Inputs
++++++

The **Buffer** node has an input that will be stored into its buffer image.

Outputs
+++++++

The **Buffer** node has a single output that provides the image

* the second output generates a given mipmap of the image

Parameters
++++++++++

The **Buffer** node has a single parameter, its *texture resolution*.

The **Advanced Buffer** node has the following parameters:

* the *texture resolution*

* the *filter* property; if set, the buffer output will be filtered

* the *mipmap* property; if set, mipmaps will be generated for this buffer

* the *32 bits* property; if set, the buffer is stored as 32 bits floats

* the *8 bits* property; if set (and *32 bits* is not), the buffer is stored as 8 bits values,
  which uses half the memory of the default 16 bits floats, but values are clamped between 0 and 1
  and quantized to 256 levels

* the *size mode*: *Absolute* uses the *texture resolution*, and *Relative to output* uses the
  size of the graph's material multiplied by 2 to the power of *size offset*, so the buffer
  follows the output resolution when it is changed (including the size of command line exports)

Buffer nodes show their resolution and format (16F, 32F or 8 bits, grayscale or RGBA) under
the node. The *texture resolution* is greyed out in *Relative to output* mode, and the
*size offset* in *Absolute* mode. An orange warning is shown when an 8 bits Advanced Buffer
feeds a node that computes normals or uses heights (directly, through reroutes or through
groups), because 256 levels are usually not enough for them and steps become visible.
If the GPU does not support 8 bits storage, 16 bits floats are used instead, and the badge
shows *16F (8 bits unsupported)*.
