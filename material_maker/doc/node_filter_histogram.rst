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

The **Histogram Range** node scales the input values around mid grey and moves mid grey
to a position, like the output levels of a levels adjustment. The result is clamped
between 0 and 1:

* *Range* is the width of the output range (1 keeps the full range, 0 outputs the
  position everywhere);

* *Position* is the center of the output range, where an input of 0.5 goes. With a range
  of 1, moving it brightens or darkens the input, and values pushed past 0 or 1 are clipped.

At range 1 and position 0.5 the input is unchanged.

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
