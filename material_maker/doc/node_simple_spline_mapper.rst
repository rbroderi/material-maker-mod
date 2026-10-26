Spline Mapper node
~~~~~~~~~~~~~~~~~~

The **Spline Mapper** node places instances of a pattern along a curve, oriented along the
curve, with random scale, rotation, offset and height. Where instances overlap, the highest
one is visible. Unlike the **Poly Curve** node, it does not stretch the pattern along the
curve.

Inputs
++++++

The **Spline Mapper** node has a single RGBA input, the pattern placed along the curve.

Outputs
+++++++

* *Output* is the pattern instances along the curve

* *Mask* is white where an instance is visible

Parameters
++++++++++

* the *curve*, edited in the 2D preview like the **Poly Curve** node's

* *Count* is the number of instances along the curve

* *Size* is the size of instances

* *Scale random*, *Rotation*, *Rotation random*, *Offset random* and *Height random* add
  variations to the instances

Notes
+++++

Instances are placed at regular intervals of the curve's parameter, so they are closer to
each other where the curve's control points are closer.
