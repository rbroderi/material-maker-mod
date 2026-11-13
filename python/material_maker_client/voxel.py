"""Evaluates the outputs of a Material Maker graph at given points (numpy in, numpy out).

Needs numpy and a running server (see material_maker_client)::

    from material_maker_client import MaterialMaker
    from material_maker_client.voxel import VoxelGraph

    with MaterialMaker() as mm:
        graph = VoxelGraph(mm, "oak.ptex")
        out = graph.evaluate(points, normals, {"seed": 12, "age": 0.3})
        out["base_color"]   # (N, 3) float32, LINEAR colour (not sRGB)
        out["orm"]          # (N, 3) ambient occlusion, roughness, metallic
        out["emission"]     # (N, 3)
        out["normal"]       # (N, 3) bumped normal, object space
        out["opacity"]      # (N,)

Points are in metres (object space). Normals (N, 3) are object space unit
vectors, and fresh (N,) is 0 on the original surface and 1 on a fresh cut;
without normals the graph sees a zero normal and falls back to the direction
of the point. Everything else (seed, age, upkeep, fresh, char, wet, axis,
origin and footprint) is one value per call: the parameters of the Voxel
Inputs nodes, set with ``params`` ("seed", "age", "upkeep", "fresh", "char",
"wet", "footprint", "axis" and "origin" as 3 values, or "node:parameter"
names).  Group the points that differ in these values and make one call per
group.

Data is exchanged as float32 .npy files in a temporary directory, so the
server must run on the same machine (or share the file system).
"""

import json
import os
import tempfile

import numpy as np

__all__ = ["evaluate", "VoxelGraph", "write_npy", "read_npy", "MATERIAL_OUTPUTS"]

# The arrays returned for a Voxel Material: name -> number of channels
MATERIAL_OUTPUTS = {"base_color": 3, "orm": 3, "emission": 3, "normal": 3, "opacity": 1}


def write_npy(path, array):
    """Writes a float32 C order .npy file (version 1.0), the format the server reads"""
    array = np.ascontiguousarray(array, dtype="<f4")
    with open(path, "wb") as f:
        np.lib.format.write_array(f, array, version=(1, 0), allow_pickle=False)


def read_npy(path):
    """Reads a .npy file written by the server (little endian float32, version 1.0)"""
    with open(path, "rb") as f:
        version = np.lib.format.read_magic(f)
        if version != (1, 0):
            raise ValueError("unexpected .npy version %s" % (version,))
        shape, fortran_order, dtype = np.lib.format.read_array_header_1_0(f)
        if dtype != np.dtype("<f4") or fortran_order:
            raise ValueError("unexpected .npy type %s" % dtype)
        return np.fromfile(f, dtype="<f4", count=int(np.prod(shape))).reshape(shape)


def _points(array, name, columns):
    array = np.asarray(array, dtype=np.float32)
    if array.ndim != 2 or array.shape[1] != columns:
        raise ValueError("%s must have shape (N, %d), not %s" % (name, columns, array.shape))
    return array


def evaluate(mm, points, normals=None, fresh=None, params=None, node=None, workdir=None):
    """Evaluates the current graph of a server at N points.

    Without ``node``, evaluates the graph's Voxel Material and returns a dict
    of float32 arrays (see MATERIAL_OUTPUTS). With ``node`` ("name" or
    "name:output"), returns the (N, 4) RGBA float32 array of that output
    (tex3d outputs have alpha 1, tex3d_gs outputs are repeated in r, g, b).
    ``params`` are set before the evaluation (and stay set).  ``workdir`` is a
    directory for the .npy files (default: a temporary directory).
    """
    points = _points(points, "points", 3)
    count = points.shape[0]
    if normals is not None:
        normals = _points(normals, "normals", 3)
        if normals.shape[0] != count:
            raise ValueError("normals must have as many rows as points")
    if fresh is not None:
        fresh = np.asarray(fresh, dtype=np.float32).reshape(-1)
        if fresh.shape[0] != count:
            raise ValueError("fresh must have as many values as points")
    own_dir = None
    if workdir is None:
        own_dir = tempfile.TemporaryDirectory(prefix="mm_eval_")
        workdir = own_dir.name
    try:
        workdir = os.path.abspath(workdir)
        os.makedirs(workdir, exist_ok=True)
        request = {"points": os.path.join(workdir, "points.npy").replace("\\", "/")}
        write_npy(request["points"], points)
        if normals is not None:
            request["normals"] = os.path.join(workdir, "normals.npy").replace("\\", "/")
            write_npy(request["normals"], normals)
        if fresh is not None:
            request["fresh"] = os.path.join(workdir, "fresh.npy").replace("\\", "/")
            write_npy(request["fresh"], fresh)
        if params:
            request["params"] = json.loads(json.dumps(params, default=_json_default))
        if node is not None:
            request["node"] = node
            request["output"] = os.path.join(workdir, "result.npy").replace("\\", "/")
            files = mm.call("evaluate_points", **request)
            return read_npy(files[0]).reshape(count, 4)
        request["output"] = os.path.join(workdir, "result").replace("\\", "/")
        files = mm.call("evaluate_points", **request)
        rv = {}
        for name, channels in MATERIAL_OUTPUTS.items():
            path = next(f for f in files if f.endswith("_%s.npy" % name))
            rv[name] = read_npy(path).reshape((count, channels) if channels > 1 else (count,))
        return rv
    finally:
        if own_dir is not None:
            own_dir.cleanup()


def _json_default(value):
    if isinstance(value, np.generic):
        return value.item()
    if isinstance(value, np.ndarray):
        return value.tolist()
    raise TypeError("cannot send %r" % (value,))


class VoxelGraph:
    """A graph loaded in a server, evaluated at points: ``graph.evaluate(points, normals, params)``"""

    def __init__(self, mm, path=None, node=None):
        """``path`` is a .ptex file to load (default: the server's current graph);
        ``node`` is the output to evaluate instead of the Voxel Material"""
        self.mm = mm
        self.node = node
        if path is not None:
            mm.load(path)

    def evaluate(self, points, normals=None, params=None, fresh=None, node=None, workdir=None):
        """See evaluate(). Returns a dict of arrays for the Voxel Material, or an (N, 4) array with a node"""
        return evaluate(self.mm, points, normals, fresh, params, node or self.node, workdir)
