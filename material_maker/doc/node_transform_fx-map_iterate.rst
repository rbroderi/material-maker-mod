FX-Map Iterate node
~~~~~~~~~~~~~~~~~~~

The **FX-Map Iterate** node: splats instances of patterns whose position, size, rotation, value, opacity and pattern are expressions of the instance index and random values, like Substance Designer's FX-Map Iterate and Switch nodes. Parameters can be edited with the expression and function graph editors.

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
* **Instance**: t (i/(n-1)) of the topmost instance

Parameters
++++++++++

* **Count**: The number of instances (up to 256)
* **X**: The x position of each instance. Can be an expression of i (the instance index, from 0), n (the instance count), t (i/(n-1)), r1, r2, r3 and r4 (random values for the instance) and $seed, and use inputs (e.g. $map(vec2(t, 0.5)))
* **Y**: The y position of each instance. Can be an expression of i (the instance index, from 0), n (the instance count), t (i/(n-1)), r1, r2, r3 and r4 (random values for the instance) and $seed, and use inputs (e.g. $map(vec2(t, 0.5)))
* **Scale**: The size of each instance. Can be an expression of i (the instance index, from 0), n (the instance count), t (i/(n-1)), r1, r2, r3 and r4 (random values for the instance) and $seed, and use inputs (e.g. $map(vec2(t, 0.5)))
* **Rotation**: The rotation of each instance, in degrees. Can be an expression of i (the instance index, from 0), n (the instance count), t (i/(n-1)), r1, r2, r3 and r4 (random values for the instance) and $seed, and use inputs (e.g. $map(vec2(t, 0.5)))
* **Value**: Multiplies the color of each instance. Can be an expression of i (the instance index, from 0), n (the instance count), t (i/(n-1)), r1, r2, r3 and r4 (random values for the instance) and $seed, and use inputs (e.g. $map(vec2(t, 0.5)))
* **Opacity**: The opacity of each instance. Can be an expression of i (the instance index, from 0), n (the instance count), t (i/(n-1)), r1, r2, r3 and r4 (random values for the instance) and $seed, and use inputs (e.g. $map(vec2(t, 0.5)))
* **Pattern**: The pattern input (0 to 3) of each instance, as a Switch node. Can be an expression of i (the instance index, from 0), n (the instance count), t (i/(n-1)), r1, r2, r3 and r4 (random values for the instance) and $seed, and use inputs (e.g. $map(vec2(t, 0.5)))
* **Blend**: How instances are combined (later instances are drawn over earlier ones)

Example
+++++++

16 instances on a circle, scaled down along it, with alternating patterns: **X** is
``0.5+0.35*cos(6.2832*t)``, **Y** is ``0.5+0.35*sin(6.2832*t)``, **Scale** is ``0.15-0.1*t``
and **Pattern** is ``mod(i, 2.0)``.

Function graphs
+++++++++++++++

Each property can also be defined with a function graph: open the expression editor of
the parameter and click *Function graph...*. The graph's parameters include **i**, **n**,
**t** and **r1** to **r4**, so the graph is evaluated for each instance.
