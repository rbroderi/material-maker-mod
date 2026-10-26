Paint Layer node
~~~~~~~~~~~~~~~~

The **Paint Layer** node reads a channel of a paint project (.mmpp): one of its layers, or all
its visible layers composited as in the painter. Painted details can be used as inputs of a
procedural graph (for example a painted mask that drives weathering, or painted heights that are
combined with generated ones).

The project's files are watched: when the paint project is saved again, the node is updated.

Inputs
++++++

The **Paint Layer** node does not accept any input.

Outputs
+++++++

* **Output**: the channel. Albedo, emission and normal are colors (with the layer's coverage as
  alpha), metallic, roughness, depth and occlusion are grayscale

Parameters
++++++++++

* **Paint project**: a paint project saved by Material Maker's painter
* **Layer**: *All visible layers* composites the project's visible layers with their masks and
  channel opacities, as the painter does (the normal channel starts from a flat normal and the
  occlusion channel from white). Selecting a layer shows only that layer, with its own masks.
  Mask layers show their mask
* **Channel**: albedo, metallic, roughness, emission, normal, depth or occlusion

The layer is selected by its position in the project, so moving layers in the painter changes
which layer the node shows.
