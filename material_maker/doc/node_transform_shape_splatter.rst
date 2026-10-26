Shape Splatter node
~~~~~~~~~~~~~~~~~~~

The **Shape Splatter** node splats instances of a pattern, with a choice of distributions,
a density map, random scale, rotation and height, and height-ordered blending. It also
outputs data maps that describe the instances.

Instances are placed in a grid of *count* x *count* cells (one instance per cell), and the
result tiles.

Inputs
++++++

* *Pattern* is the height map that is splatted

* *Density map* is the probability that an instance is kept, sampled at its position

* *Scale map* multiplies the scale of each instance, sampled at its position

* *Rotation map* adds a rotation to each instance (1 is a full turn), sampled at its position

Outputs
+++++++

* *Output* is the splatted patterns

* *Instance ID* is a random value for each instance

* *Position* is the position of each instance (red: x, green: y)

* *Mask* is white where an instance is visible

Parameters
++++++++++

* *Count* is the number of cells of the grid on each side

* *Distribution*: *Poisson-like* keeps instances apart, *Uniform* places them anywhere in
  their cell, *Grid* aligns them

* *Scale* is the size of instances relative to the cell size (up to 2)

* *Scale random*, *Rotation*, *Rotation random* and *Height random* add variations to the
  instances

* *Blend*: *Max* keeps the highest instance where instances overlap (height-ordered
  blending), *Add* sums them
