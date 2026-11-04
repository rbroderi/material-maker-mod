Base material nodes
~~~~~~~~~~~~~~~~~~~

The **Workflow/Materials** section of the library holds example base (flat) materials,
to which maps are applied using the **ApplyMap** node.

.. image:: images/node_workflow_materials_marble.png
	:align: center

.. image:: images/node_workflow_materials_metal.png
	:align: center

.. image:: images/node_workflow_materials_wood.png
	:align: center

.. image:: images/node_workflow_materials_template.png
	:align: center

Inputs
++++++

The base material nodes do not accept any input.

Outputs
+++++++

The base material nodes output the albedo, ORM (ambient occlusion, roughness, metallic),
emission and normal channels of the material.

Parameters
++++++++++

The **Marble** node accepts the following parameters:

* the two colors of the marble

* the amount of scratches

The **Metal** node accepts the following parameters:

* the metal (Aluminum, Chromium, Cobalt, Copper, Gold, Iron, Nickel, Platinum, Silver
  or Titanium)

* the roughness of the metal

The **Wood** node accepts the following parameters:

* the color of the wood

* the waviness of the wood grain

* the amount of scratches

The **Template** node is a uniform material that can be used as a starting point for new
base materials. It accepts the following parameters:

* the albedo color

* the roughness

* the metallic value

* the emission color
