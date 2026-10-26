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

The **Advanced Buffer** node has 3 parameters:

* the *texture resolution*

* the *filter* property; if set, the buffer output will be filtered

* the *mipmap* property; if set, mipmaps will be generated for this buffer

* the *32 bits* property; if set, the buffer is stored as 32 bits floats

* the *8 bits* property; if set (and *32 bits* is not), the buffer is stored as 8 bits values,
  which uses half the memory of the default 16 bits floats, but values are clamped between 0 and 1

* the *size mode*: *Absolute* uses the *texture resolution*, and *Relative to output* uses the
  size of the graph's material multiplied by 2 to the power of *size offset*, so the buffer
  follows the output resolution when it is changed

Advanced Buffer nodes show their resolution and format (16F, 32F or 8 bits, grayscale or RGBA)
under the node. An orange warning is shown when an 8 bits buffer stores grayscale data (such as
heights) or feeds a node that computes normals or uses heights, because 256 levels are usually
not enough for them (steps become visible in normal maps).

Automatic buffers
+++++++++++++++++

When *Automatic Buffers* are enabled in the preferences (Graph tab), Material Maker inserts
buffers by itself where they make rendering cheaper:

* in front of inputs that are sampled many times (blur, warp, normal map, pixel processor...)
  when their source is expensive to evaluate,

* in front of any input whose source would make the generated shader too large (the
  *shader budget*). This splits very large materials into several smaller shaders, and
  editing a node only recompiles the part of the graph after it up to the next buffer.

Automatic buffers use the resolution of the node they feed when it has a size parameter.
They are not saved with the graph, and are listed in *Tools > Show buffer render times*.

Connection buffers
++++++++++++++++++

*Alt + right click* on a connection shows a menu to choose whether it is buffered
*automatically*, *always* or *never*. This setting is saved with the graph, and *always*
works even when automatic buffers are disabled. Buffered connections are marked with a
blue (automatic) or orange (always) *B*, and connections that are never buffered with a
grey *-*.

GPU memory budget
+++++++++++++++++

When a GPU memory budget is set in the preferences, the least recently used buffers are
copied back to the main memory when the budget is exceeded, and uploaded again when they
are needed. Their content is kept, so nothing has to be rendered again.
