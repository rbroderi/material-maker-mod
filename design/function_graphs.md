# Function graphs (SD_PARITY_PLAN §3.1)

Status: design + first slice (IR, compiler, Pixel Processor node), 2026-10-25.

## Goal

Substance Designer's function graphs let artists program per-pixel logic visually
(Pixel Processor), compute values once per graph (Value Processor), and drive any
parameter from other parameters. Material Maker covers part of this with GLSL in
custom shader nodes and math expressions in float parameters, but has no structured,
typed, visual representation.

Function graphs give MM:

- a **typed intermediate representation (IR)** that compiles to GLSL (MM's
  native target, so no interpreter is needed),
- nodes built on that IR: **Pixel Processor** (per pixel), later **Value Processor**
  (once) and **parameter functions**,
- a target for tools: `sbsar2ptex` decompiles Substance function bytecode and could emit
  this IR directly, and AI-assisted authoring can generate it and have it validated by
  the compiler.

## IR (version 1)

A function graph is JSON:

```json
{
  "version": 1,
  "nodes": {
    "uv":  { "op": "pos" },
    "c":   { "op": "sample", "input": 0, "uv": "uv" },
    "k":   { "op": "param", "name": "contrast" },
    "out": { "op": "mul", "a": "c", "b": "k" }
  },
  "output": "out",
  "inputs": [ { "name": "in", "label": "Input" } ],
  "parameters": [ { "name": "contrast", "label": "Contrast", "min": 0.0, "max": 4.0, "default": 1.0 } ]
}
```

- `nodes` maps an id to an operation. Operands reference other node ids, which must
  form a DAG; the compiler reports cycles and dangling references.
- `output` is the node whose value the function returns. A `float` result is broadcast
  to `vec4(v, v, v, 1.0)`; `vec3` gets alpha 1; `vec4` is returned as is.
- `inputs` are image inputs of the Pixel Processor (sampled as RGBA).
- `parameters` are float parameters exposed on the node.

### Types

`bool`, `float`, `vec2`, `vec3`, `vec4`. Every operation has a typing rule; the compiler
infers each node's type and rejects mismatches with an error naming the node.

### Operations

| Group | Ops | Typing |
|---|---|---|
| Constants | `float` (`value`), `vec2`/`vec3`/`vec4` (`value: [..]`), `true`, `false` | as named |
| Variables | `pos` (UV in 0–1), `size` (sampling resolution, `vec2`), `param` (`name`) | `vec2`, `vec2`, `float` |
| Sampling | `sample` (`input`, `uv`) | `vec4` |
| Arithmetic | `add`, `sub`, `mul`, `div`, `min`, `max`, `pow`, `mod`, `atan2`, `step` (`a`, `b`) | same-type operands; a `float` operand broadcasts to the vector size |
| Unary | `neg`, `abs`, `floor`, `ceil`, `fract`, `sqrt`, `sin`, `cos`, `tan`, `exp`, `log`, `sign`, `normalize` (`a`) | type of `a` |
| Vector | `dot` (`a`,`b` → float), `length` (`a` → float), `distance` (`a`,`b` → float), `cross` (vec3) | as GLSL |
| Construction | `vec2`/`vec3`/`vec4` with `args: [..]` (component counts must add up) | as named |
| Swizzle | `swizzle` (`a`, `components` such as `"xy"`, `"bgr"`, `"x"`) | float/vecN by length |
| Interpolation | `mix` (`a`,`b`,`t`), `clamp` (`a`,`min`,`max`), `smoothstep` (`e0`,`e1`,`a`) | type of `a` (or broadcast) |
| Comparison | `lt`, `le`, `gt`, `ge`, `eq`, `ne` (floats) | `bool` |
| Logic | `and`, `or`, `not` | `bool` |
| Selection | `select` (`cond`, `a`, `b`) | type of `a` = type of `b` |
| Random | `rand` (`a`: vec2 seed) — hash in 0–1, seeded with the node seed | `float` |

Missing from v1, planned for v2: integers, loops (`for` over a constant range with an
accumulator), local function calls (sub-functions), and Substance-compatible `rand`.

### Compilation

`MMFunctionGraph.compile(graph, sample_names, param_names)` (`engine/function_graph/`):

1. validates references and detects cycles (DFS from `output`),
2. orders reachable nodes topologically,
3. infers types,
4. emits one GLSL statement per node (`float fg_k = ...;`), inside a function
   `vec4 $(name)_pp(vec2 uv)`.

It returns `{ ok, code, errors }`. Errors carry the node id, so a future editor can
highlight the faulty node.

## Pixel Processor node (this slice)

`MMGenPixelProcessor` extends `MMGenShader`: it compiles its function graph into a
shader model (one function input per image input, one float parameter per graph
parameter, the compiled function as instance code) and hands it to the existing shader
machinery. Previews, parameters, uniforms, exports and automatic buffers (see
`hybrid_evaluator.md`) all work unchanged.

- Serialization stores `function_graph` (not the generated `shader_model`).
- **Editing (temporary):** *Edit* opens the graph JSON in a text dialog; an invalid
  graph is rejected with the compiler's errors. This is a stop-gap until the editor.

## Milestones

| # | Content | Size |
|---|---|---|
| 1 | IR v1, compiler, Pixel Processor, JSON editing, unit tests (**this slice**) | M |
| 2 | Visual editor: a GraphEdit panel reusing MM's node UI, live type display, error highlighting | L |
| 3 | Value Processor (evaluated once into a uniform, like the Statistics node) and parameter functions on any float parameter | M |
| 4 | IR v2: integers, loops, sub-functions, Substance-compatible `rand` | M |
| 5 | `sbsar2ptex` emits IR directly for decompiled function graphs | M |

## Risks

- **Editor effort.** The visual editor is the bulk of the work; the IR is designed so the
  editor only needs to create/link/delete nodes and set constants.
- **Performance.** Every `sample` op of an input calls its function input; with
  automatic buffers enabled, expensive inputs are buffered once.
