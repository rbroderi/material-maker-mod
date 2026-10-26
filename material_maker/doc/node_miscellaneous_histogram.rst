Histogram node
~~~~~~~~~~~~~~

The **Histogram** node computes the histogram of each channel of its input on the GPU, and
outputs it as a 256x2 texture:

* its bottom half is the cumulative distribution of each channel: sampling it at
  ``((value*255.0)+0.5)/256.0`` gives the rank of the value, between 0 and 1;

* its top half is the histogram, normalized so its highest bin is 1.

It is used by the **Histogram Equalize** node, and can be used to build other
histogram-based filters.

Inputs
++++++

The **Histogram** node has a single RGBA input.

Outputs
+++++++

The **Histogram** node outputs the 256x2 texture described above.

Parameters
++++++++++

The *Size* parameter is the resolution at which the input is analyzed.
