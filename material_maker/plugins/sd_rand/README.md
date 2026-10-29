# Substance random numbers (sd_rand)

This plugin adds the `sd_rand` operation to function graphs (Pixel Processor and
Value Processor nodes). It reproduces Substance Designer's random generators, so graphs
translated from Substance (for example by sbsar2ptex) give the same random values.

It is a clean-room implementation of the behavioral specification in sbsar2ptex's
`docs/random-generator.md`: no code was copied.

## Using it

`sd_rand` takes one float operand, `a` (the amplitude), and returns a float in `[0, a)`:

```json
{ "op": "sd_rand", "a": "amplitude" }
```

In the function graph editor, it is in the *Other* category of the *Add node* menu.

- In a **Pixel Processor**, each call returns the next value of a random sequence that
  depends on the seed and on the pixel position.
- When the graph is compiled in value mode (the compiler's `mode` variable is `"value"`, for
  Value Processors), each call returns the next value of Substance's value function random
  sequence, that only depends on the seed.

Calls advance the sequence in dependency order (operands first), as in Substance.

The seed is the graph's `random_seed` (an integer, set for example by graphs translated
from Substance), or the node's seed when the graph has none. With the same seed, results
match Substance Designer. `random_seed` can be set with *Edit JSON* in the function graph
editor:

```json
{ "version": 2, "random_seed": 1234, "nodes": { "...": "..." }, "output": "..." }
```

`sd_rand` can only be used in the main graph, not in sub-functions.

When the plugin is disabled (Tools > Plugins), graphs that use `sd_rand` show the error
"unknown operation sd_rand".

## How it works

- **Pixel processors**: the state is a Jenkins one-at-a-time hash of the seed and of the
  bit patterns of the pixel center, advanced by `state * 0x4937573B + 0xC7C1` at each call.
- **Value processors**: the state starts from the seed and is advanced by
  `state * 0x7FF8A3ED + 0x2AA01D31` at each call.
- Each call returns `(bits 1-23 of the state as the mantissa of a float in [1, 2)) - 1.0`,
  multiplied by the amplitude.

GPU renders were checked against a CPU implementation of the specification, for both
sequences.

## Tests

`tests/test_sd_rand.gd` (GUT):

```
godot --headless -s addons/gut/gut_cmdln.gd -gdir=res://material_maker/plugins/sd_rand/tests -gexit
```
