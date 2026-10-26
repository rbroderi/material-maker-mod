Tile Sampler node
~~~~~~~~~~~~~~~~~

The **Tile Sampler** node: places pattern instances on a grid, with random or map driven position, scale, rotation, pattern choice, symmetry and value, and several ways to stack overlapping instances.

Inputs
++++++

* **Pattern 1**: Pattern 1 (its alpha is the coverage of instances)
* **Pattern 2**: Pattern 2
* **Pattern 3**: Pattern 3
* **Pattern 4**: Pattern 4
* **Mask**: The probability that an instance is kept, sampled at its position
* **Scale map**: Multiplies the scale of instances, sampled at their position
* **Rotation map**: Adds a rotation (1 is a full turn), sampled at the position of instances
* **Pattern map**: Selects the pattern of instances (with the By map pattern selection)
* **Displacement map**: A vector map (red and green, 0.5 is no displacement) that moves instances

Outputs
+++++++

* **Output**: The sampled patterns
* **Instance**: A random value for each instance (of the instance that is shown)

Parameters
++++++++++

* **X count**: The number of columns
* **Y count**: The number of rows
* **Scale**: The size of instances, relative to a cell
* **Scale random**: The random reduction of the scale
* **Rotation**: The rotation of instances, in degrees
* **Rotation random**: The random rotation (1 is up to half a turn either way)
* **Position random**: The random offset of instances in their cell
* **Row offset**: The offset of odd rows, in cells (0.5 for bricks)
* **Displacement**: The amount of displacement by the displacement map
* **Drop**: The proportion of instances that are removed at random
* **Value random**: The random darkening of instances
* **Patterns**: The number of pattern inputs that are used
* **Pattern selection**: How the pattern of each instance is chosen
* **Symmetry**: Random symmetries applied to instances
* **Blend**: How overlapping instances are combined. Height ordered shows the instance with the highest random height on top
