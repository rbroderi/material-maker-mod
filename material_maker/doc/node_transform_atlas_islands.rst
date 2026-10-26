Atlas Islands node
~~~~~~~~~~~~~~~~~~

The **Atlas Islands** node: extracts an item of an atlas whose items are not on a grid (found by a Fill node), scaled to fit the output.

Inputs
++++++

* **Atlas**: The atlas: separate items on a background
* **Fill**: The output of a Fill node that finds the atlas items: its input must be white between the items (for example the inverted alpha of the atlas)

Outputs
+++++++

* **Output**: The extracted item

Parameters
++++++++++

* **Pick X**: A point of the item to extract
* **Pick Y**: A point of the item to extract
* **Margin**: The margin around the item
* **Rotate to fit**: Rotates items by a quarter turn so they fit the output better

Usage
+++++

The Fill node fills the dark areas delimited by white: connect a mask that is white between the
atlas items (for example the atlas's alpha through an Invert node) to a Fill node, and the Fill
node to the **Fill** input. **Pick X** and **Pick Y** select the item to extract. Only the pixels
of the item are kept, so items whose boxes overlap are separated.
