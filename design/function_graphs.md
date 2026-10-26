# Function graphs (SD_PARITY_PLAN §3.1)

Status: **implemented** (milestones 1–4), 2026-10-25. Milestone 5 (sbsar2ptex emitting
this IR) is on hold.

## Goal

Substance Designer's function graphs let artists program per-pixel logic visually
(Pixel Processor), compute values once (Value Processor), and drive parameters from other
parameters. Material Maker had GLSL in custom shader nodes and math expressions in float
parameters, but no structured, typed, visual representation.

Function graphs give MM:

- a **typed intermediate representation (IR)** compiled to GLSL (MM's native target),
- nodes built on it: **Pixel Processor**, **Value Processor**, and **parameter functions**,
- a **visual editor**,
- a target for tools: `sbsar2ptex` can emit this IR for decompiled function graphs, and
  AI-assisted authoring can generate it and have it validated by the compiler.

## IR (version 2)

```json
{
  "version": 2,
  "inputs": [ { "name": "in", "label": "Input" } ],
  "parameters": [ { "name": "contrast", "label": "Contrast", "min": 0.0, "max": 4.0, "default": 1.0 } ],
  "random_seed": 0,
  "functions": {
    "accumulate": {
      "params": [ { "name": "acc", "type": "vec4" }, { "name": "i", "type": "int" } ],
      "nodes": { "...": "..." },
      "output": "..."
    }
  },
  "nodes": {
    "uv":  { "op": "pos", "pos": [ 30, 30 ] },
    "c":   { "op": "sample", "input": 0, "uv": "uv" },
    "k":   { "op": "param", "name": "contrast" },
    "out": { "op": "mul", "a": "c", "b": "k" }
  },
  "output": "out"
}
```

- `nodes` maps ids to operations; operands reference other ids and must form a DAG
  (cycles and dangling references are reported).
- `output` is the result. `float`/`int` results are broadcast to gray RGBA, `vec2` gets
  `b = 0, a = 1`, `vec3` gets `a = 1`.
- `inputs` are image inputs (sampled as RGBA), `parameters` are float parameters.
- `random_seed` (optional) is the integer seed of `sd_rand`; without it, the node's seed
  is used.
- `functions` are sub-functions with typed `params`; their graphs use `arg` to read
  arguments and may use every operation except `sd_rand`. Recursion is rejected.
- `pos` on nodes is editor metadata, ignored by the compiler. Node ids that contain
  `__c` are hidden constants created by the editor for vector constructors.
- Version 1 graphs are valid version 2 graphs.

### Types

`bool`, `int`, `float`, `vec2`, `vec3`, `vec4`. Floats broadcast to vectors; ints never mix
with floats implicitly (`to_float`, `to_int`).

### Operations

| Group | Ops | Typing |
|---|---|---|
| Constants | `float`, `int` (`value`), `vec2`/`vec3`/`vec4` (`value: [..]`), `true`, `false` | as named |
| Variables | `pos` (UV), `size` (vec2), `param` (`name`), `arg` (`name`, in functions) | vec2, vec2, float, arg type |
| Sampling | `sample` (`input`, `uv`) | vec4 |
| Arithmetic | `add`, `sub`, `mul`, `div`, `min`, `max`, `mod` (also on ints), `pow`, `atan2`, `step` | same type, float broadcast |
| Unary | `neg`, `abs`, `sign` (also on ints), `floor`, `ceil`, `fract`, `sqrt`, `sin`, `cos`, `tan`, `exp`, `log`, `normalize` | type of `a` |
| Vector | `dot`, `length`, `distance`, `cross` | as GLSL |
| Construction | `vec2`/`vec3`/`vec4` with `args` | components must add up |
| Swizzle | `swizzle` (`a`, `components`) | float/vecN |
| Interpolation | `mix`, `clamp`, `smoothstep` | type of operands |
| Comparison | `lt`, `le`, `gt`, `ge`, `eq`, `ne` (two floats or two ints) | bool |
| Logic | `and`, `or`, `not`, `select` (`cond`, `a`, `b`) | bool / operand type |
| Conversion | `to_int` (floor), `to_float` | int / float |
| Functions | `call` (`function`, `args`), `loop` (`function`, `count` ≤ 1024, `init`) | return type |
| Random | `rand` (vec2 seed → float), `sd_rand` (`a`: amplitude) | float |

`loop` repeats `acc = function(acc, i)` for `i` in `0..count-1`; the function must take
`(T, int)` and return `T`.

### Substance-compatible random numbers

`sd_rand` follows the behavioral specification in sbsar2ptex's
`docs/random-generator.md` (implemented from the spec):

- **pixel processors**: the state is a Jenkins one-at-a-time hash of the seed and the bit
  patterns of the pixel center, advanced by `state·0x4937573B + 0xC7C1` at each call;
- **value processors**: the state starts from the seed and is advanced by
  `state·0x7FF8A3ED + 0x2AA01D31`;
- each call returns `(bits 1–23 of the state as a mantissa) - 1.0`, times the amplitude.

Calls advance the state in dependency order. Verified on the GPU against the spec's
conformance vectors (pixel `(0,0)`/`(1,0)` at 1×1 and 16×16, seeds 0 and 1; value seeds 0
and 5). FX-Map random streams will come with an FX-Map node.

### Compilation

`MMFunctionGraph.compile(graph, sample_expressions, parameter_expressions, variables)`:

1. validates sub-functions and orders them so callees come first,
2. compiles each sub-function to a GLSL function `prefix+name(vec2 uv, args...)`,
3. compiles the main graph (operands first, one statement per node; loops and `sd_rand`
   add statements),
4. returns `{ ok, code, value, functions, globals, types, node_errors, function_types,
   function_node_errors, errors }`.

The main graph is compiled even when sub-functions fail, and with `compile_all_nodes` every
node is typed (not only those the output depends on), so the editor can show types and
errors everywhere.

`MMFunctionGraph.compile_expression(graph, parameter_expressions)` compiles graphs that
only use parameters and constants into a single GLSL expression (parameter functions).

## Nodes

- **Pixel Processor** (`MMGenPixelProcessor`): compiles its graph into a shader model
  (function inputs, float parameters, sub-functions and the main function as instance
  code, `sd_rand`'s hash as a global). Previews, exports and automatic buffers work
  unchanged. Only `function_graph` is serialized.
- **Value Processor** (`MMGenValueProcessor`): same compilation in *value* mode (no `pos`
  or `size`). Its visible output samples a hidden **1×1 buffer** of the graph's raw
  output, so the graph is evaluated once, not per pixel.
- **Parameter functions**: the expression editor of float parameters has a *Function
  graph…* button. The graph is compiled to an expression that becomes the parameter's
  value, and is stored in the generator's `parameter_functions` (serialized), so it can be
  edited again. If the parameter was changed by other means, editing starts from its
  current value.

## Editor

`MMFunctionGraphEditor` (`material_maker/windows/function_graph_editor/`), a window built
in code:

- the IR is the model; the graph view is rebuilt from it after structural changes;
- one GraphNode per IR node, input slots per operand, inline fields for constants and
  settings (parameter, argument, input, swizzle, function, loop count);
- vector constructors have one slot per component, with constants on unconnected slots;
- the graph is compiled after each change: types in node titles, errors in red with a
  tooltip, *Apply*/*OK* disabled while invalid;
- side panel: inputs, parameters and fixed seed (main graph), name and typed arguments
  (sub-functions), available parameters (expression mode);
- *Add function* / *Remove function* and a scope selector; *Edit JSON* as a fallback;
- layout by dependency depth for nodes without a stored position;
- applying from a processor creates one undo step per apply.

## Tests

- `test/test_function_graph.gd` (GUT, 35 tests): v1 and v2 operations, typing errors,
  functions, recursion, loops, `sd_rand` code generation, parameter functions, value mode.
- GPU checks: `sd_rand` conformance vectors, loops, value processor evaluation and
  updates, editor interactions (open from a node, round trip, connect/disconnect, vector
  constants, type errors, functions, apply with undo, expression mode), parameter
  functions end to end.

## Milestones

| # | Content | Status |
|---|---|---|
| 1 | IR v1, compiler, Pixel Processor | done |
| 2 | Visual editor | done |
| 3 | Value Processor, parameter functions | done |
| 4 | IR v2: integers, loops, sub-functions, Substance-compatible `rand` | done |
| 5 | `sbsar2ptex` emits IR for decompiled function graphs | on hold |

## Possible follow-ups

- Undo/redo inside the editor (today each *Apply* is one undo step of the graph).
- Copy/paste of nodes between function graphs.
- FX-Map node and its random streams.
