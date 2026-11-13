Repeat node
...........

The **Repeat** node generates a 3D signed distance image of a repetition of its
input on the X and Y axes. It can also apply a random rotation to the repeated
object instances.

.. image:: images/node_3d_sdf_operators_repeat.png
	:align: center

Inputs
::::::

The **Repeat** node accepts an input in 3D signed distance function format.

Outputs
:::::::

The **Repeat** node generates a signed distance function of the
repeated version of the input shape.

Parameters
::::::::::

The **Repeat** node accepts the following parameters:

* *the repetition offset* for both X and Y axes
* *the amount of random rotation* applied to all instances
* *variation* controls whether the input is sampled with variations
* The *Hash* of the random rotations and variations: *Legacy* uses a hash based on sin(), whose results can
  differ between GPUs and compilers (graphs saved before this option keep it), *Exact* uses an
  integer hash that gives the same values in the preview and in exported shaders.

Example images
::::::::::::::

.. image:: images/node_sdf3d_repeat_sample.png
	:align: center
