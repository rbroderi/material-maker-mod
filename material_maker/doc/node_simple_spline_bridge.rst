Spline Bridge node
~~~~~~~~~~~~~~~~~~

The **Spline Bridge** node fills the area between two curves, and maps a pattern on it: its x
axis goes along the curves, and its y axis from the first curve to the second.

Inputs
++++++

* **Pattern**: The pattern mapped between the curves

Outputs
+++++++

* **Output**: The pattern mapped between the curves
* **UV**: The coordinates between the curves (red along them, green across) and the mask (blue)
* **Mask**: The area between the curves

Parameters
++++++++++

* **First curve**: The first curve, edited in the 2D preview
* **Second curve**: The second curve, edited in the 2D preview
* **Repeat X**: The number of repetitions of the pattern along the curves
* **Repeat Y**: The number of repetitions of the pattern between the curves
* **Precision**: The number of steps used to find each pixel's position between the curves

Usage
+++++

Both curves are edited in the 2D preview (select them with the drop down button of the
preview). They go smoothly through their points, like the **Poly Curve** node's curve, and
are followed from their first to their last point. The curves can have different numbers of
points: points at the same fraction of the length of each curve (measured on its control
points) are connected.

If the curves cross each other, the area between them folds over itself, and the pattern is
mirrored on the other side of the crossing.
