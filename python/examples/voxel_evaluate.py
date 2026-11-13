"""Evaluates a graph at 10000 random points from Python and checks the result.

    python voxel_evaluate.py <material_maker command> [port]

for example:

    python voxel_evaluate.py "godot --path ../.."

It builds a small voxel graph in a Material Maker started with a server (a
Voxel Inputs node feeding a Voxel Material, and a seeded 3D value noise),
evaluates it with material_maker_client.voxel and compares the results with
numpy: the base colour must equal the normals, the roughness the fresh
values, and the noise the numpy port of its integer hash. Needs a GPU.
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from material_maker_client import DEFAULT_PORT, launch, split_command  # noqa: E402
from material_maker_client.voxel import VoxelGraph  # noqa: E402

M32 = 0xFFFFFFFF


def mix32(x):
    u = np.uint32
    x = np.asarray(x).astype(u)
    with np.errstate(over="ignore"):
        x = x ^ (x >> u(16))
        x = x * u(0x7FEB352D)
        x = x ^ (x >> u(15))
        x = x * u(0x846CA68B)
        x = x ^ (x >> u(16))
    return x


def hash3(x, y, z, s):
    """voxkit's integer hash (ZCity/Tools/voxkit/noise.py), float64 in [0, 1)"""
    u = np.uint32
    with np.errstate(over="ignore"):
        h = (x.astype(np.int64) & M32).astype(u) * u(374761393) + (y.astype(np.int64) & M32).astype(u) * u(668265263) \
            + (z.astype(np.int64) & M32).astype(u) * u(2147483629) + mix32(u(s))
    h = mix32(h)
    return (h >> u(8)).astype(np.float64) * (1.0 / 16777216.0)


def value_noise(p, s):
    c = np.floor(p)
    f = p - c
    f = f * f * (3.0 - 2.0 * f)
    rv = 0.0
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = (f[:, 0] if dx else 1 - f[:, 0]) * (f[:, 1] if dy else 1 - f[:, 1]) * (f[:, 2] if dz else 1 - f[:, 2])
                rv = rv + hash3(c[:, 0] + dx, c[:, 1] + dy, c[:, 2] + dz, s) * w
    return rv


command = split_command(sys.argv[1])
port = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_PORT
process, mm = launch(command, port=port)
try:
    mm.new_graph()
    mm.create_node(type="voxel_inputs", name="In")
    mm.create_node(type="material_voxel", name="Vox")
    mm.create_node(type="tex3d_noise_value", name="Noise")
    mm.connect("In", "Vox", from_port=1, to_port=0)  # Normal -> albedo
    mm.connect("In", "Vox", from_port=5, to_port=2)  # Fresh -> roughness
    mm.set_parameter("Vox", "linear_albedo", True)
    mm.set_parameter("Noise", "scale_x", 4.0)
    mm.set_parameter("Noise", "scale_y", 4.0)
    mm.set_parameter("Noise", "scale_z", 4.0)

    rng = np.random.default_rng(7)
    n = 10000
    points = rng.uniform(-3.0, 3.0, size=(n, 3)).astype(np.float32)
    normals = rng.normal(size=(n, 3)).astype(np.float32)
    normals /= np.linalg.norm(normals, axis=1, keepdims=True)
    fresh = rng.uniform(0.0, 1.0, size=n).astype(np.float32)

    graph = VoxelGraph(mm)
    out = graph.evaluate(points, normals, {"seed": 0, "fresh": 0.0}, fresh=fresh)
    err_color = np.abs(out["base_color"] - normals).max()
    err_fresh = np.abs(out["orm"][:, 1] - fresh).max()
    rgba = graph.evaluate(points, node="Noise:0")
    err_noise = np.abs(rgba[:, 0] - value_noise(points.astype(np.float64) * 4.0, 0)).max()
    for name, err in [("base_color", err_color), ("roughness (fresh)", err_fresh), ("value noise", err_noise)]:
        print("%s: max |err| = %.2e" % (name, err), "< 1e-5" if err < 1e-5 else "FAILED")
    if max(err_color, err_fresh, err_noise) >= 1e-5:
        sys.exit(1)
finally:
    mm.quit()
    process.wait(30)
