Atlas Island Scatter node
~~~~~~~~~~~~~~~~~~~~~~~~~

The **Atlas Island Scatter** node: scatters random items of an atlas whose items are not on a grid (found by a Fill node) on a grid of cells, with random scale and rotation.

Inputs
++++++

* **Atlas**: The atlas: separate items on a background
* **Fill**: The output of a Fill node that finds the atlas items: its input must be white between the items (for example the inverted alpha of the atlas)

Outputs
+++++++

* **Output**: The scattered items
* **Instance**: A random value for each instance

Parameters
++++++++++

* **Count**: The number of cells in each direction
* **Scale**: The size of items, relative to a cell
* **Scale random**: The random reduction of the scale
* **Rotation random**: The random rotation (1 is up to half a turn either way)
* **Position random**: The random offset of items in their cell
* **Drop**: The proportion of cells left empty
* **Rotate to fit**: Rotates items by a quarter turn so they fit the output better

Usage
+++++

As for the Atlas Islands node, the **Fill** input is the output of a Fill node whose input is
white between the atlas items.
