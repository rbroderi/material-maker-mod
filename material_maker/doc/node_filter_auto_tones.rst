Auto Tones node
~~~~~~~~~~~~~~~

The **Auto Tones** node finds the minimum and maximum values in the input texture and tone maps it to the full 0.0 - 1.0 range.
The minimum and maximum values are computed exactly (using a **Statistics** node), and input values
outside of the 0.0 - 1.0 range are supported.

.. image:: images/node_filter_tones_auto_tones.png
	:align: center

Inputs
++++++

The **Auto Tones** node requires a grayscale input texture.

Outputs
+++++++

The **Auto Tones** node provides a single grayscale texture.

Parameters
++++++++++

* The *Size* (resolution) at which the input image is sampled to find its minimum and maximum
  values. If the input has small details a higher resolution might be needed to capture precise
  min and max values.

Note: The output itself will not be buffered.
