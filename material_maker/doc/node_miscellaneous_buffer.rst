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

* the *16 bits integer* property; if set (and *32 bits* is not), the buffer is stored as 16 bits
  integers: values are clamped between 0 and 1 and quantized to 65536 evenly spaced levels (16 bits
  floats only have 2048 levels between 0.5 and 1), which suits heights and other data that need
  the same precision everywhere. It takes precedence over *8 bits*. Exporting the buffer from the
  2D preview (or with an Export node connected to it) renders it as 16 bits integers and writes
  16 bits PNG files

* the *RG* property; if set, only the red and green channels of color inputs are stored (blue is
  0 and alpha 1 when the buffer is read), which uses half the memory of RGBA (for example for 2D
  vectors or UV maps). It is ignored for grayscale inputs

* the *rounding* of stored values (8 bits, 16 bits integers and 16 bits floats; 32 bits floats
  are not rounded): *GPU* stores values as the GPU does, which varies between GPUs (values exactly
  halfway between two steps are rounded down by some GPUs and up by others, and some GPUs truncate
  16 bits floats instead of rounding them), *Half down* and *Half up* round values to the nearest
  step themselves (ties down or up, toward or away from 0 for negative 16 bits floats), so buffers
  hold exactly the same values on all GPUs

* the *size mode*: *Absolute* uses the *texture resolution*, and *Relative to output* uses the
  size of the graph's material multiplied by 2 to the power of *size offset*, so the buffer
  follows the output resolution when it is changed (including the size of command line exports)

* the *aspect ratio* (1:1, 2:1, 1:2, 4:1, 1:4, 8:1 or 1:8): the buffer's height is its
  resolution divided by the ratio, for example 1024x512 for a 1024 buffer with a 2:1 ratio.
  The buffer still covers the whole UV square, so its pixels are not square

Buffer nodes show their resolution (for example 512x256 px for non-square buffers) and format (16F, 32F, 8 bits or 16 bits, grayscale, RG or RGBA) under
the node. The *texture resolution* is greyed out in *Relative to output* mode, and the
*size offset* in *Absolute* mode. An orange warning is shown when an 8 bits Advanced Buffer
feeds a node that computes normals or uses heights (directly, through reroutes or through
groups), because 256 levels are usually not enough for them and steps become visible.
If the GPU does not support 8 or 16 bits integer storage, 16 bits floats are used instead, and the
badge shows it (for example *16F gray (16 bits unsupported)*). RG buffers are stored as RGBA if
the GPU does not support them (*RG unsupported*).
