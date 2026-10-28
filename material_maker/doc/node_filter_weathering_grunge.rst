Grunge node
~~~~~~~~~~~

The **Grunge** node generates a procedural grunge mask: large stains broken up by noise, plus small
speckles. It has no input, and can be used to break up the other masks or to add stains to a material.

Inputs
++++++

The **Grunge** node does not accept any input.

Outputs
+++++++

* **Mask**: The weathering mask (1 where the effect is present)

Parameters
++++++++++

* **Amount**: The amount of the effect: 0 gives an empty mask, 1 a full mask
* **Softness**: The softness of the mask's edges
* **Speckles**: The amount of small speckles, added to the mask (even when Amount is 0)
* **Noise scale**: The scale of the noise that breaks up the mask (rounded to a whole number so the mask tiles)
* **Noise amount**: How much the noise breaks up the mask

Notes
+++++

All weathering masks (except **Water Level**) work the same way: the node computes a value
between 0 and 1 from its inputs, adds noise, and keeps the areas above a threshold set by
*Amount*. An *Amount* of 0 always gives an empty mask (apart from the **Grunge** node's
speckles), and 1 a full mask. The noise tiles.
