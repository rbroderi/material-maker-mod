# To do

## Top priority

1. **Inverse procedural materials: fit a graph to a photo.** Given a target photo and a graph,
   optimize the graph's parameters so its output matches (style loss on deep features, or
   statistics such as the histogram and spectrum, plus per-pixel loss where aligned). The
   bit-matching GLSL, HLSL and Python outputs help: the Python path can give gradients (finite
   differences, or a JAX version of the generated code) while the GPU checks the result. Start with
   continuous parameters; discrete ones (modes, octaves) by search. References: Shi et al.,
   "MATch: Differentiable Material Graphs for Procedural Material Capture" (2020); Hu et al.,
   "DiffMat" (2022) and "Inverse Procedural Modeling of Materials" (2019). Size: large.

## Material library

- **Real-world material presets.** A library (or installable preset pack) of materials that match
  real ones, each a tidy graph with a few meaningful parameters (age, wetness, wear, colour
  variation, scale in real units) rather than raw noise knobs, all outputs set (albedo, roughness,
  metallic, normal, height, AO), tileable, and checked against measured reference data:
  - Wood: redwood, pine, oak, walnut, maple, birch, cherry, mahogany, ash, teak; end grain, plank
    and plywood variants; raw, oiled, varnished and weathered finishes.
  - Stone: marble (Carrara, Calacatta, Nero Marquina), granite, slate, sandstone, limestone,
    travertine, basalt, concrete, terrazzo.
  - Ground: dirt, mud, sand (dry, wet, rippled), gravel, pebbles, clay, snow, ice.
  - Metal: steel (brushed, galvanized, stainless), iron (cast, rusted), aluminium, copper and
    brass (with patina stages), gold, silver, chrome.
  - Paint and coatings: fresh, chipped and peeling paint over a selectable base; car paint
    (flake, clearcoat); powder coat; enamel.
  - Others: brick, tile, plaster, fabric (cotton, denim, wool, leather), plastic, rubber, paper,
    cardboard, glass, bark, moss, foliage.
  Physically based values from published measurements (albedo and roughness ranges, metal F0 from
  measured IORs; e.g. the Physically Based database, physicallybased.info, CC0). Wood grain from
  growth rings and species ring width, ray flecks (quartersawn oak), knots. The existing examples
  (wood, marble, rock, dry_earth, rusted_metal, wooden_floor, voxel_oak) are a starting point.
  Ship as library entries in base.json or a separate library file, with thumbnails, and per
  material a reference photo comparison (taken or licensed, CC0 only in the repo). Items 1, 6, 7
  and 8 make many of these better. Size: large, can be done a family at a time.

## Nodes

2. **Exact simplex 3D noise.** Add simplex to the seeded integer-hash 3D noises (mm_noise3d,
   tex3d_noise_*), so it gives the same values in the preview, exported HLSL and Python, like the
   value, Perlin, FBM and Voronoi ones. Seed and channel streams with mm_n3_salt; GPU and HLSL parity
   tests as in test/test_noise3d.gd. Algorithm reference: FastNoiseLite's OpenSimplex2
   (https://github.com/Auburn/FastNoiseLite, MIT). The 2D FBM nodes already have a Simplex option
   (fbm2.mmg), with the sin hash. Size: medium.
3. **Flow noise.** Gradient noise whose gradients rotate over time (animated flowing patterns), with
   the integer hash. Idea from akihiko47/Shaders-Gallery (https://github.com/akihiko47/Shaders-Gallery);
   some of its shaders come from Shadertoy, so take the idea only and write it from the published
   algorithm (Perlin and Neyret, "Flow noise", 2001). Size: small.
4. **Reaction-diffusion.** Gray-Scott reaction-diffusion (coral, lichen, labyrinth and spot patterns),
   one diffusion step per iteration of an iterate buffer, wrapping at the tile edges. Feed, kill,
   diffusion rates and seed pattern as parameters, an optional input to vary them over the image.
   Idea from danielsobrado/drusniel-procedural-textures (Apache-2.0); write it from the published
   model, not from that code. Size: small to medium.
5. **Hydraulic erosion.** Grid (pipe model) erosion of a heightmap: rain, water flow between
   neighbours, sediment pickup and deposit, evaporation, run in an iterate buffer with wrapping.
   Outputs: eroded height, and flow and sediment masks for texturing. The morphology node's
   "erosion" is the image-processing operation, not this. Reference: Mei, Decaudin and Hu, "Fast
   Hydraulic Erosion Simulation and Visualization on GPU" (2007). Same idea source and license
   note as item 4. Size: medium.
6. **Histogram-preserving by-example tiling.** Turn any input texture into an endless, repeat-free
   surface: three lookups on a hexagonal grid with random offsets, blended in a Gaussianized
   histogram space so contrast is kept, then mapped back. Per pixel and cheap. Reference: Heitz and
   Neyret, "High-Performance By-Example Noise using a Histogram-Preserving Blending Operator"
   (2018); Deliot and Heitz (2019) for the practical version. Size: medium.
7. **Phasor and Gabor noise.** Noise with controlled orientation and frequency band (brushed metal,
   wood grain, fabric, ripples, fingerprints), from sparse Gabor kernels on a seeded grid; phasor
   noise takes the phase of the sum for clean contrast stripes. Inputs to vary orientation and
   frequency over the image. References: Lagae et al., "Procedural Noise using Sparse Gabor
   Convolution" (2009); Tricard et al., "Procedural Phasor Noise" (2019). Size: medium.
8. **Crack and fracture patterns.** Cracks that grow and stop at earlier cracks (dried mud, paint,
   ceramic glaze, asphalt), with crack width, depth and hierarchy levels; height and mask outputs.
   Beyond what Voronoi edges give. Size: medium.
9. **Curl noise and flowmap generation.** Divergence-free swirl fields (the curl of a noise
   potential) output as flowmaps to drive the warp nodes and animated flow; pairs with item 3.
   Reference: Bridson et al., "Curl-Noise for Procedural Fluid Flow" (2007). Size: small.
10. **Cellular automata.** Rule-based growth (caves, moss spread, corrosion) in an iterate buffer,
    with wrapping and a seeded start state. Size: small.
11. **Wang and corner tile sets.** Export a set of tiles whose edges all match each other, for
    stochastic tiling in game engines; next to the make_tileable nodes. Reference: Cohen et al.,
    "Wang Tiles for Image and Texture Generation" (2003). Size: medium.

## Quality and infrastructure

12. **Filtered (antialiased) noise.** Noise nodes drop or fade octaves finer than the pixel
    footprint, so distant or mipmapped textures don't shimmer; matters for the 3D and voxel
    exports. Size: medium.
13. **Normal map filtering.** Raise roughness where a normal map is averaged down (Toksvig, or
    LEAN mapping), so bumpy surfaces don't turn shiny at a distance; for exported mip chains and
    reduced-size bakes. References: Toksvig (2005); Olano and Baker, "LEAN Mapping" (2010).
    Size: small.
14. **Spectrum (FFT) node and spectral noise.** Show a texture's frequency content, and shape noise
    by drawing its spectrum (inverse FFT of a filtered random spectrum). Size: medium.
