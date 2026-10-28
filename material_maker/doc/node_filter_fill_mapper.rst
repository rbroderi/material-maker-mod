Flood Fill Mapper node
~~~~~~~~~~~~~~~~~~~~~~

The **Flood Fill Mapper** node: places an instance of a pattern in each area of a Flood Fill, with random rotation, size, offset and value per area.

Inputs
++++++

* **Fill**: The output of a Flood Fill node
* **Pattern**: The pattern placed in each area (its alpha is its coverage)

Outputs
+++++++

* **Output**: The patterns placed in the areas
* **Mask**: The coverage of the patterns

Parameters
++++++++++

* **Mode**: Stretch fits patterns to the bounding box of each area, Square keeps them square
* **Scale**: The size of patterns, relative to their area
* **Scale random**: The random reduction of the size of each pattern
* **Rotation random**: The random rotation of each pattern, in degrees
* **Offset random**: The random offset of each pattern, relative to its area
* **Value random**: The random darkening of each pattern
* **Probability**: The probability that an area has a pattern

Notes
+++++

Patterns are rotated in texture space, so patterns stretched to non-square areas are rotated
without shearing. Each pixel only shows its own area's pattern, so patterns larger than their
area are cut at its borders, and outlines and areas of zero width or height are transparent.
The position of an area is wrapped before choosing its random values, so areas get the same
values in every tile, also with fill data that isn't wrapped (such as the **Bricks** node's
*Brick Fill* output).
