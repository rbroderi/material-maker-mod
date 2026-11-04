Paint nodes
~~~~~~~~~~~

The **Paint 1** and **Paint 2** nodes paint an applied map (for example the output of an
**ApplyMap** or **Mix** node) where a mask is set.

.. image:: images/node_workflow_effects_paint_1.png
	:align: center

.. image:: images/node_workflow_effects_paint_2.png
	:align: center

Inputs
++++++

The **Paint** nodes accept the height, albedo, ORM, emission and normal channels of
an applied map, and a mask:

* the mask of the **Paint 1** node is a greyscale image, the paint is applied where it is white

* the mask of the **Paint 2** node is a color image: the paint has the color of the mask,
  and is applied where the mask is opaque

Outputs
+++++++

The **Paint** nodes output the height, albedo, ORM, emission and normal channels of the
painted map. The paint changes the albedo, roughness and metallic channels: the height,
ambient occlusion, emission and normal channels are those of the input.

Parameters
++++++++++

The **Paint 1** node accepts the following parameters:

* the color of the paint

* the roughness of the paint

* the metallic value of the paint

The **Paint 2** node accepts the roughness and metallic value of the paint (its color is
that of the mask).
