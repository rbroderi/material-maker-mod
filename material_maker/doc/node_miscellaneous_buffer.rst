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

* the *size mode*: *Absolute* uses the *texture resolution*, *Relative to output* uses the
  size of the graph's material multiplied by 2 to the power of *size offset*, so the buffer
  follows the output resolution when it is changed (including the size of command line exports),
  and *Relative to input* uses the size of the texture its input reads multiplied by 2 to the
  power of *size offset* (0 for the same size as the input, -1 for half, 1 for double)

* the *size offset* used by the relative modes can also be an expression of the graph's named
  parameters (for example *$detail-2*, rounded to the nearest integer), so a parameter of a
  Remote node or of a graph's parameters controls the resolution

* the *aspect ratio* (1:1, 2:1, 1:2, 4:1, 1:4, 8:1 or 1:8): the buffer's height is its
  resolution divided by the ratio, for example 1024x512 for a 1024 buffer with a 2:1 ratio.
  The buffer still covers the whole UV square, so its pixels are not square.
  In *Relative to input* mode, the ratio is applied to the input's, so 1:1 keeps the input's
  width and height (a 1024x512 input gives a 512x256 buffer with a size offset of -1)

In *Relative to input* mode, the input's size is that of the nearest buffer, iterate buffer or
image upstream: through nodes that have inputs, the first input is followed (also into and out of
groups). If the input reads no texture (for example a noise), the material's size is used.
The buffer is resized and rendered again when the size of its input changes, and buffers
that are relative to other relative buffers follow in turn.

When the *size offset* is an expression, changing one of the named parameters it uses resizes
the buffer and renders it again, with the nodes that read it. If the expression is invalid (a
syntax error, an unknown named parameter or a result that is not a number), a size offset of 0
is used, a warning is printed and *Invalid size offset* is shown under the node. In *Absolute*
mode, the *texture resolution* can be controlled by a Remote node's linked control instead.

Buffer nodes show their resolution (for example 512x256 px for non-square buffers) and format (16F, 32F or 8 bits, grayscale or RGBA) under
the node. The *texture resolution* is greyed out in the relative modes, and the
*size offset* in *Absolute* mode. An orange warning is shown when an 8 bits Advanced Buffer
feeds a node that computes normals or uses heights (directly, through reroutes or through
groups), because 256 levels are usually not enough for them and steps become visible.
If the GPU does not support 8 bits storage, 16 bits floats are used instead, and the badge
shows *16F (8 bits unsupported)*.
