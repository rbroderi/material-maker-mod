Histogram nodes
~~~~~~~~~~~~~~~

The histogram nodes remap the values of a grayscale input. All of them take a grayscale
input and produce a grayscale output.

Histogram Scan
++++++++++++++

The **Histogram Scan** node selects a range of values and increases its contrast:

* *Position* is the input value that is mapped to mid-gray (0.5 leaves the input unchanged
  when contrast is 0; higher values brighten the output);

* *Contrast* increases the contrast around that value (1 is a threshold).

Histogram Range
+++++++++++++++

The **Histogram Range** node compresses the values around a position:

* *Range* is the width of the output range (1 leaves the input unchanged);

* *Position* is the center of the output range.

Histogram Shift
+++++++++++++++

The **Histogram Shift** node adds its *Position* to the input, wrapping values around so
they stay between 0 and 1 (a position of 1 is a full rotation and leaves the input unchanged).

Histogram Select
++++++++++++++++

The **Histogram Select** node outputs white where the input is close to a value:

* *Position* is the center of the selected range;

* *Range* is the width of the selected range;

* *Contrast* is the sharpness of the transition (1 is a hard edge).

Histogram Equalize
++++++++++++++++++

The **Histogram Equalize** node computes the histogram of its input on the GPU (using a
Histogram node) and maps each value to its rank, so the output values are evenly
distributed between 0 and 1. Its *Size* parameter is the resolution at which the input
is analyzed.

Values are counted in 256 bins, so inputs whose values are concentrated in a very small
range (less than 1/256) are not separated.
