FX-Map Iterate node
~~~~~~~~~~~~~~~~~~~

The **FX-Map Iterate** node: splats instances of patterns whose position, size, rotation, value, opacity and pattern are expressions of the instance index and random values, like Substance Designer's FX-Map Iterate and Switch nodes. Instances can be placed in groups (nested iterations), that have their own position, scale and rotation. Parameters can be edited with the expression and function graph editors.

Inputs
++++++

* **Pattern 1**: Pattern 1 (its alpha is the coverage of instances)
* **Pattern 2**: Pattern 2 (its alpha is the coverage of instances)
* **Pattern 3**: Pattern 3 (its alpha is the coverage of instances)
* **Pattern 4**: Pattern 4 (its alpha is the coverage of instances)
* **Map**: A map that expressions can sample with $map(uv)

Outputs
+++++++

* **Output**: The splatted patterns
* **Instance**: The position of the topmost instance in the sequence of all instances (0 to 1)

Parameters
++++++++++

* **Count**: The number of instances (up to 256)
* **Count in group**: The number of instances in each group (nested iteration). With 1, each group is a single instance
* **Group X**: The x position of each group's center. Can be an expression of i, n, t, g1, g2 and $seed
* **Group Y**: The y position of each group's center. Can be an expression of i, n, t, g1, g2 and $seed
* **Group scale**: The size of each group: instances are placed in a square of this size around its center. Can be an expression of i, n, t, g1, g2 and $seed
* **Group rotation**: The rotation of each group, in degrees. Can be an expression of i, n, t, g1, g2 and $seed
* **X**: The x position of each instance. Can be an expression of i (the group index, from 0), n (the group count), t (i/(n-1)), j (the index in the group), m (the count in the group), u (j/(m-1)), r1, r2, r3 and r4 (random values for the instance), g1 and g2 (random values for the group) and $seed, and use inputs
* **Y**: The y position of each instance. Can be an expression of i (the group index, from 0), n (the group count), t (i/(n-1)), j (the index in the group), m (the count in the group), u (j/(m-1)), r1, r2, r3 and r4 (random values for the instance), g1 and g2 (random values for the group) and $seed, and use inputs
* **Scale**: The size of each instance. Can be an expression of i (the group index, from 0), n (the group count), t (i/(n-1)), j (the index in the group), m (the count in the group), u (j/(m-1)), r1, r2, r3 and r4 (random values for the instance), g1 and g2 (random values for the group) and $seed, and use inputs
* **Rotation**: The rotation of each instance, in degrees. Can be an expression of i (the group index, from 0), n (the group count), t (i/(n-1)), j (the index in the group), m (the count in the group), u (j/(m-1)), r1, r2, r3 and r4 (random values for the instance), g1 and g2 (random values for the group) and $seed, and use inputs
* **Value**: Multiplies the color of each instance. Can be an expression of i (the group index, from 0), n (the group count), t (i/(n-1)), j (the index in the group), m (the count in the group), u (j/(m-1)), r1, r2, r3 and r4 (random values for the instance), g1 and g2 (random values for the group) and $seed, and use inputs
* **Opacity**: The opacity of each instance. Can be an expression of i (the group index, from 0), n (the group count), t (i/(n-1)), j (the index in the group), m (the count in the group), u (j/(m-1)), r1, r2, r3 and r4 (random values for the instance), g1 and g2 (random values for the group) and $seed, and use inputs
* **Pattern**: The pattern input (0 to 3) of each instance, as a Switch node. Can be an expression of i (the group index, from 0), n (the group count), t (i/(n-1)), j (the index in the group), m (the count in the group), u (j/(m-1)), r1, r2, r3 and r4 (random values for the instance), g1 and g2 (random values for the group) and $seed, and use inputs
* **Blend**: How instances are combined (later instances are drawn over earlier ones)

Example
+++++++

16 instances on a circle, scaled down along it, with alternating patterns: **X** is
``0.5+0.35*cos(6.2832*t)``, **Y** is ``0.5+0.35*sin(6.2832*t)``, **Scale** is ``0.15-0.1*t``
and **Pattern** is ``mod(i, 2.0)``.

Nested iterations
+++++++++++++++++

With a **Count in group** above 1, each of the **Count** instances becomes a group of instances
(an iteration inside an iteration). **Group X**, **Group Y**, **Group scale** and **Group rotation**
place each group, and are expressions of i, n, t and the group's random values g1 and g2.
**X**, **Y**, **Scale** and **Rotation** then place each instance in its group's space (a square
from 0 to 1, centered on the group and scaled by its scale), and can also use j (the index in the
group), m (the count in the group) and u (j/(m-1)).

For example, 4 groups on a circle, each made of 6 instances on a smaller circle: **Count** is 4,
**Group X** is ``0.5+0.3*cos(6.2832*i/n)``, **Group Y** is ``0.5+0.3*sin(6.2832*i/n)``, **Group scale**
is 0.4, **Count in group** is 6, **X** is ``0.5+0.4*cos(6.2832*j/m)`` and **Y** is
``0.5+0.4*sin(6.2832*j/m)`` (i/n and j/m go around the circle without repeating the first position,
unlike t and u that end at 1).

Function graphs
+++++++++++++++

Each property can also be defined with a function graph: open the expression editor of
the parameter and click *Function graph...*. The graph's parameters include the variables of
the parameter (such as **i**, **t**, **j**, **u** and **r1** to **r4**), so the graph is evaluated for each
instance.
