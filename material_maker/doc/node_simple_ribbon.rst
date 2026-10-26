Ribbon node
~~~~~~~~~~~

The **Ribbon** node: draws a ribbon along a smooth curve, with tapering and twisting, and maps a pattern along it (which also warps an image along the curve).

Inputs
++++++

* **Pattern**: The pattern mapped along the ribbon (x along it, y across it)
* **Width map**: Multiplies the width along the ribbon (its x coordinate goes from 0 at the start to 1 at the end)

Outputs
+++++++

* **Output**: The ribbon
* **UV**: The ribbon's coordinates (red along it, green across) and its mask (blue)
* **Mask**: The ribbon's mask

Parameters
++++++++++

* **Curve**: The curve, edited in the 2D preview. It goes smoothly through its points
* **Width**: The half width of the ribbon
* **Taper start**: How much the ribbon narrows at its start
* **Taper end**: How much the ribbon narrows at its end
* **Twist**: The number of half turns of the ribbon along the curve
* **Repeat**: The number of repetitions of the pattern along the ribbon

Usage
+++++

The curve is edited in the 2D preview. Connect an image to the **Pattern** input to warp
it along the curve, and use the **UV** output with a Custom UV node for other effects.
