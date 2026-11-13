# ZCity oak: the first acceptance test of the voxel work

voxkit's oak (`ZCity/Tools/voxkit/appearance.py::wood`) rebuilt as a Material Maker graph,
`material_maker/examples/voxel_oak.ptex`: Voxel Inputs -> Voxel Wood -> Voxel Material
(linear albedo, bump 1). The context values are those of the kit test's 162 x 18 x 18 voxel
beam (seed 21, age 0.6, grain along x, pith at (6.48, 11.34) voxels). The remote node `Oak`
controls the four arch parameters of the wood (flow amount, flow scale, pith wander, ripple
amount) and has two presets: `voxkit` (voxkit's own values) and `zcity` (gentler arches).

## Running

Needs Python with numpy, a GPU and a Material Maker started from source or installed. Use
`python -P` (no script directory on the path) when running scripts that import the ZCity
files. Nothing is written to the ZCity repository.

    python -P build_graph.py --mm "<godot> --path <repo> --"
    python -P compare_oak.py --voxkit <ZCity>/Tools/voxkit --reference <ZCity>/Saved/Voxkit/beam_close.png \
        --mm "<godot> --path <repo> --" --out <dir>

`build_graph.py` writes the .ptex through the RPC client (and removes the Static PBR Material
node that every new graph comes with, which the server cannot delete). `compare_oak.py` prints
a table (value, limit, ok / FAIL / advisory) and ends with `OAK ACCEPTANCE: PASS` (exit code 0)
or `FAIL` with the failing metrics. `--reuse` reuses the baseline renders of an earlier run.

## What the numbers mean

**Points** (step 2). The graph's Albedo, bumped normal and Spec are evaluated with
`material_maker_client.voxel.evaluate` on an end face (s = 0, 256 x 256 points over 14 x 14
voxels), a top face (256 x 1024) and 30000 random points with random normals and fresh
weights, and compared with `appearance.wood()` at the same points: mean and 99th percentile
of the per channel difference of the linear albedo, and the angle between the normals.
The check is made in voxkit's own frame: the pith at its place and absolute coordinates, the graph's Origin set to the pith. The comparison with the pith forced to (0, 0) is printed, as advisory output.

`points_end.png` and `points_top.png` show voxkit, the graph and 10 x the difference, one
under the other.

**Pictures** (step 3). voxkit's renderer (run inline, with the process pool replaced) draws the
`beam_close` camera at 700 x 500, `ss=1`: B = voxkit's wood, M1 = the graph with preset
`voxkit`, M2 = preset `zcity`, Bf = voxkit's wood in the frame of the graph (the baseline that
isolates the frame), R = the stored `beam_close.png` box-downscaled. MAD is the mean absolute
difference of the 8 bit sRGB values; SSIM is a global structural similarity (one 8 x 8 window
per block, on luma, averaged). `MAD(B, R)` over 6 would mean the stored picture is stale. For
M2: mean colour over the beam pixels (found with a magenta wood render) within 6/255 of B, the
ring count along a radius of the end face within 10%, and the arches measure.

**Arches**: `mean |d phase / ds|` of the ring phase over the top face, zcity / voxkit, at most
0.6. It is computed exactly (voxkit's phase formula with the preset's parameters) and from
the albedo luminance of the graph (finite differences along the beam, as the plan said; this
proxy also contains the fibre noise, so it falls less than the phase does).

**Export** (step 4). The exported `.shader` is wrapped like an Unreal Custom node and compiled
with `dxc -T ps_6_0`. The numeric parity of the exported HLSL with the GLSL is the job of
`test/test_voxel_hlsl_parity.gd`.

## Result

* Points, in voxkit's own frame (pith at its place, absolute coordinates; Origin = pith): albedo mean 1e-4, 99th percentile under 2e-3, bumped normal under 0.03 degrees. This is a hard check.
* Pictures: MAD(M1, B) 0.02, SSIM(M1, B) 1.0000; MAD(B, R) 1.85.
* The zcity values were retuned from the plan's starting values (3.0, 0.009, 2.0, 0.4) to (4.0, 0.006, 1.0, 0.2): the starting values left the luminance arch measure at 0.64 and the phase ring count at 14 against 12. A person still has to look at oak_compare.png (the side faces).
