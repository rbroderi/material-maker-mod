Histogram nodes
~~~~~~~~~~~~~~~

The histogram nodes remap the values of a grayscale input. All of them take a grayscale
input and produce a grayscale output.

Histogram Scan
++++++++++++++

The **Histogram Scan** node scans the input values with a position and increases the
contrast of the result:

* *Position* shifts the transition, like a brightness control: 0 gives a black output,
  1 a white output, and 0.5 leaves the input unchanged when contrast is 0;

* *Contrast* increases the contrast of the result (1 is a threshold).

Histogram Range
+++++++++++++++

The **Histogram Range** node compresses the input values towards a position, like moving
both output levels inwards:

* *Range* is how much the range is reduced (0 leaves the input unchanged, 1 outputs the
  position everywhere);

* *Position* is the value the range is reduced towards.

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
