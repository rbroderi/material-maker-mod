# Runtime packages (`.mmr`) and engine runtimes

Status (2026-10-26): exporter, format v1, Godot runtime, C++/Vulkan runtime, Blender add-on,
seed parameter and output resizing done. Deferred: Unreal/Unity plugins, live link, CI builds of
the C++ runtime.

## Goal

Ship a procedural material as a package that an engine can re-render at
runtime or import time with different parameter values, like Substance's
`.sbsar`, without Material Maker.

## Key idea

Material Maker already renders every texture as a GLSL 450 compute shader
(`MMComputeShader`): a fully preprocessed source, a std430 parameter buffer,
sampled input textures and one output image. Buffers are separate passes
whose outputs are inputs of other passes. A package is therefore a list of
compute passes, and a runtime is a small, generic pass runner: no node
library, no shader generation, no GDScript graph code.

Parameters that only change uniform values (float and color parameters,
which is most of them) can be changed at runtime by patching the parameter
buffers and re-running the dependent passes. Parameters that change the
shader structure (enums, booleans, gradients point count, sizes) are baked
at their exported value.

## Format v1

A zip file:

```
manifest.json
shaders/<pass>.glsl        compute shader source, ready to compile
shaders/<pass>.spv         the same shader compiled to SPIR-V (Vulkan 1.0+)
textures/<name>.exr|.png   embedded textures (images, mesh maps, results
                           of nodes that are not exported as passes)
```

`manifest.json`:

```jsonc
{
  "format": "mmr", "version": 1,
  "generator": "Material Maker 1.x",
  "name": "bricks", "author": "...",
  "passes": [
    {
      "name": "p0",                       // also the shader file name
      "size": [1024, 1024],
      "format": "rgba16f",                // r16f, rgba16f, r32f, rgba32f, r8, rgba8
      "local_size": 32,                   // work group size along x
      "parameters": {                     // std430 layout of set 1, binding 0
        "p_o123_amount": { "type": "float", "offset": 0, "array_size": 0 }
      },
      "parameter_data": "<base64>",       // initial content of the buffer
      "inputs": [                         // set 2, binding = index
        { "name": "o456_tex", "pass": "p1" },
        { "name": "o789_tex", "texture": "textures/t0.exr" }
      ]
    }
  ],
  "outputs": {                            // pass names, by material channel
    "albedo": "p0", "orm": "p2", "normal": "p3", "emission": "p4", "height": "p5"
  },
  "material": {                           // Material node values for engines
    "albedo_color": [1, 1, 1, 1], "metallic": 1.0, "roughness": 1.0,
    "emission_energy": 1.0, "normal": 1.0, "depth_scale": 0.5
  },
  "parameters": [                         // runtime parameters
    {
      "name": "param1", "label": "Hue", "type": "float",
      "default": 0.0, "min": 0.0, "max": 1.0, "step": 0.01,
      "targets": [ { "pass": "p0", "parameter": "p_o123_hue" } ]
    }
  ],
  "baked_parameters": [ "param3 (Shape): not a shader uniform" ]
}
```

Passes are listed in dependency order (inputs before the passes that use
them).

Parameters of type `seed` (named `seed`, for materials with random nodes)
change the seeds of all random nodes, as Material Maker's `--seed` option.
Each target has `terms`, the `[ value, locked ]` seeds whose sum is the
uniform (a node's own seed, then those of the parents it inherits seeds
from). For a seed `s`, the uniform is the sum of `value` for locked terms and
of `fmod(value+0.6180339887*s, 1.0)` for the others.

Runtimes can render packages at another size: all passes are scaled by the
same factor, so that the largest output pass has the requested size.

### Binding layout (same as Material Maker's)

| Set | Binding | Content |
|---|---|---|
| 0 | 0 | output image (`OUTPUT_TEXTURE`), `format` of the pass |
| 1 | 0 | parameter storage buffer (if `parameters` is not empty) |
| 2 | i | input `i`: sampler2D, linear filtering, repeat wrapping |
| 3 | 0 | storage buffer with one int: the first row of the chunk |

The shader is dispatched with `ceil(width/local_size) x rows x 1` work
groups, where rows can be split in chunks (the int in set 3 is the first
row of each chunk).

### Parameter values

Values are encoded as in `MMPipeline.set_parameter_value_to_buffer`:
`float` and `int` are 4 bytes, `vec2` 8, `vec3`/`vec4` 16 (colors are
`vec4`), arrays use the std430 stride of their element.

## Exporter

`MMRuntimeExporter` (`addons/material_maker/engine/runtime/runtime_exporter.gd`):

1. For each material output, build the output shader code as
   `render_output_to_texture` does, compile it with `MMComputeShader`, and
   capture the preprocessed source (`MMPipeline.compiled_sources`).
2. For each input texture of a pass: if it is the texture of a Buffer node
   (including auto buffers), export that buffer's compute shader as a pass
   (recursively); otherwise, save the texture's current content as an
   embedded EXR (float formats) or PNG.
3. Map the graph's remote parameters to the uniforms they drive
   (`p_o<id>_<parameter>`). A remote parameter is exposed only if every
   linked control is a uniform of an exported pass.

CLI: `material_maker --export-mmr [--size n] -o <dir> <files>`.

## Runtimes

### Godot (done)

`runtime/godot/addons/material_maker_runtime`, pure GDScript, Godot 4.3+:

- `MMRPackage`: loads and validates the zip.
- `MMRRenderer`: compiles the passes on a local `RenderingDevice`, renders
  them in order, keeps their textures, and re-renders only passes that depend
  on changed parameters.
- `MMRMaterial`: a `StandardMaterial3D` built from the outputs, with
  `set_parameter(name, value)`.

### Standalone renderer (done)

`runtime/cpp`: a C++17 library and the `mmr_render` tool, with the same pass
runner on Vulkan (loaded with volk, so only the driver's loader is needed),
using the SPIR-V stored in packages. Its output is byte-identical to Material
Maker's on the tested examples, including after parameter and time changes.
CI builds per platform are still to do.

### Blender, Unreal, Unity (deferred)

- Blender: the `gpu` module can run compute shaders since 4.x; a Python
  add-on could run the GLSL passes directly (after translating the binding
  layout to Blender's shader info), or use the standalone renderer.
- Unreal and Unity: use the standalone renderer, or translate passes to
  HLSL compute shaders with SPIRV-Cross at export time.

### Live link (deferred)

The JSON-RPC server (§5.2) can stream parameter changes; a runtime only
needs `set_parameter`, so a live link is a small bridge between the two.

## Limits of v1

- Iterate buffers, statistics/histogram nodes and other CPU or multi-pass
  nodes are embedded as textures, so they don't react to parameters.
- Pass sizes are fixed at export time.
- Random seeds are baked (seed uniforms could be exposed later).
- Animated materials (`$time`) get a `time` runtime parameter, in seconds.
