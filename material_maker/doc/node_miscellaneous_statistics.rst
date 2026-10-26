Statistics node
~~~~~~~~~~~~~~~

The **Statistics** node computes the minimum, maximum and mean value of each channel of
its input on the GPU, in a single pass. Its outputs are constant over the whole image, so they
can be connected to any input that should depend on the overall content of an image (for
example to normalize it, as the **Auto Tones** node does).

Inputs
++++++

The **Statistics** node has a single RGBA input. Grayscale images are converted to RGBA,
so all color channels provide the same values.

Outputs
+++++++

The **Statistics** node has three RGBA outputs:

* *Min* provides the minimum value of each channel

* *Max* provides the maximum value of each channel

* *Mean* provides the mean value of each channel

Parameters
++++++++++

The **Statistics** node has a single parameter, the *size* (resolution) at which the input is
sampled. If the input has small details, a higher resolution might be needed to capture precise
minimum and maximum values.

Notes
+++++

The mean is computed with a precision of 1/65536, and pixel values beyond +/-1024 are clamped
when computing it. Minimum and maximum values are exact.

Like buffers, the **Statistics** node shows its rendering time below the node, can be paused,
and is listed in *Tools > Show buffer render times*.
