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

Automatic buffers
+++++++++++++++++

When *Automatic Buffers* are enabled in the preferences (Graph tab), Material Maker inserts
buffers by itself where they make rendering cheaper:

* in front of inputs that are sampled many times (blur, warp, normal map, edge detect...)
  when their source is expensive to evaluate. The source is then rendered once into a
  texture, instead of being evaluated again for each sample. The *minimum gain* sets how
  much cheaper the buffered version must be estimated to be,

* in front of any input whose source would make the generated shader too large (the
  *shader budget*). This splits very large materials into several smaller shaders, and
  editing a node only recompiles the part of the graph up to the next buffer.

Automatic buffers use the node's *size* parameter as resolution if it has one, otherwise
the size of the nodes after it (such as the Material node), or the configured size. Inputs
whose node creates variations of them (such as the Tiler and Splatter nodes) and inputs in
the loop of an Iterate Buffer are never buffered automatically.

Automatic buffers are not saved with the graph. They are shown by the buffer icon of the
node that uses them, and can be paused from its menu. This feature is experimental and
disabled by default.

Connection buffers
++++++++++++++++++

*Alt + right click* on a connection shows a menu to choose whether it is buffered
*automatically*, *always* or *never*. This setting is saved with the graph, and *always*
works even when automatic buffers are disabled. Buffered connections are marked with a
blue (automatic) or orange (always) *B*, and connections that are never buffered with a
grey *-*.
