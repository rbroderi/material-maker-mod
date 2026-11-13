"""Acceptance test of the voxel work: voxkit's oak rebuilt as a Material Maker graph.

    python -P compare_oak.py --mm "<godot> --path <repo> --" \\
        --voxkit <ZCity>/Tools/voxkit --reference <ZCity>/Saved/Voxkit/beam_close.png [--out dir]

Steps (see README.md for what the numbers mean):

  1. start Material Maker (one instance) and load material_maker/examples/voxel_oak.ptex;
  2. point check against voxkit's appearance.wood(): an end face and a top face of the beam
     and a cloud of random points, compared channel by channel;
  3. image check: voxkit's own renderer draws the beam_close picture three times, with
     voxkit's wood (B), with the graph's "voxkit" preset (M1) and with the "zcity" preset
     (M2); they are compared with each other and with the stored beam_close.png (R);
  4. export check: the graph is exported with the Unreal Engine 5 Voxel target and the
     shader is compiled with dxc;
  5. quit.

Nothing is written to the ZCity repository: the outputs go to --out.  Needs numpy.
"""

import argparse
import glob
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

sys.dont_write_bytecode = True  # (voxkit is imported from the ZCity repository: leave no __pycache__ there)

import numpy as np  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "python"))
sys.path.insert(0, HERE)
from material_maker_client import launch  # noqa: E402
from material_maker_client import voxel  # noqa: E402
from build_graph import PRESETS  # noqa: E402 (the values of the presets)

VPM = 81.0                      # voxels per metre
SIZE = (700, 500)               # of the pictures (beam_close is 1400 x 1000 at ss=2)
TARGET = "Unreal/Unreal Engine 5 Voxel"
RESULTS = []                    # (name, value text, limit text, passed or None for advisory)


def check(name, value, limit, passed):
    RESULTS.append((name, value, limit, passed))
    print("  %-52s %-26s %-18s %s" % (name, value, limit, {True: "ok", False: "FAIL", None: "advisory"}[passed]), flush=True)


# ---- voxkit ---------------------------------------------------------------------------------------------

class Voxkit:
    """The voxkit modules, imported from the given directory"""

    def __init__(self, path):
        path = os.path.abspath(path)
        sys.path.insert(0, path)
        import noise
        import materials
        import appearance
        import kit_test
        import render
        from parts import timber_beam
        self.noise, self.materials, self.appearance, self.kit_test, self.render, self.timber_beam = noise, materials, appearance, kit_test, render, timber_beam
        self.M = materials.Materials()
        self.row = self.M.rows["oak"]
        self.fins = self.M.finishes
        self.aged = self.fins["aged_oak"]["id"]
        self.beam = timber_beam.generate({"length": 162, "width": 18, "height": 18, "species": "oak", "finish": "aged_oak"}, 21)
        self.meta = self.beam.meta
        self.app = dict(self.meta["appearance"])
        self.seed = int(self.meta["seed"])

    def wood(self, pl, n, fw, app, seed, fp=None):
        """appearance.wood() for points on the original aged surface weighted by fw"""
        count = len(pl)
        fin = np.full(count, self.aged, np.int64)
        return self.appearance.wood(pl.astype(np.float32), n.astype(np.float32), fin, np.asarray(fw, np.float32), seed & 0xFFFFFF,
                                    self.row, self.fins, app, np.zeros(count, np.float32) if fp is None else fp)

    def ring_phase(self, s, u0, v0, seed, pith, ring_vox, flow_amount, flow_scale, pith_wander, ripple_amount):
        """The ring phase of appearance.wood() (floor(phase) is the year), with the arch parameters given"""
        noise3, fbm, salt = self.noise.noise3, self.noise.fbm, self.noise.salt
        pu = pith[0] + (noise3(s * 0.011 + 9, 0.3, 0.7, salt(seed, 20)) - 0.5) * pith_wander
        pv = pith[1] + (noise3(s * 0.011 + 19, 0.6, 0.2, salt(seed, 21)) - 0.5) * pith_wander
        u, v = u0 - pu, v0 - pv
        flow = (fbm(s * flow_scale, u * 0.03 + 4, v * 0.03, seed, 2) - 0.5) * flow_amount
        ripple = (noise3(s * 0.05, u * 0.15, v * 0.15, salt(seed, 1)) - 0.5) * ripple_amount
        base = np.abs(np.hypot(u, v) + flow + ripple) / ring_vox
        return base + 1.6 * (noise3(base * 0.17 + 0.5, 0.5, 0.5, salt(seed, 2)) - 0.5) + 0.3 * (noise3(base * 0.9, 0.2, s * 0.02, salt(seed, 22)) - 0.5)


class InlineExecutor:
    """Stands in for ProcessPoolExecutor: the work runs here, one job after the other, so that the
    replaced wood() can talk to the one Material Maker instance"""

    def __init__(self, workers=None, initializer=None, initargs=()):
        if initializer is not None:
            initializer(*initargs)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def map(self, fn, jobs, chunksize=1):
        return map(fn, jobs)


# ---- images ---------------------------------------------------------------------------------------------

def read_png(path):
    """8 bit RGB or RGBA PNG -> uint8 (h, w, 3)"""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("%s is not a PNG" % path)
    pos, idat, header = 8, b"", None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            header = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    w, h, depth, ctype, _, _, interlace = header
    if depth != 8 or ctype not in (2, 6) or interlace:
        raise ValueError("%s: only 8 bit RGB(A) PNG files that are not interlaced are supported" % path)
    bpp = 3 if ctype == 2 else 4
    stride = w * bpp
    raw = np.frombuffer(zlib.decompress(idat), np.uint8).reshape(h, stride + 1)
    out = np.zeros((h, stride), np.uint8)
    for y in range(h):
        ft, line = raw[y, 0], raw[y, 1:].astype(np.int32)
        prev = out[y - 1].astype(np.int32) if y else np.zeros(stride, np.int32)
        if ft == 0:
            cur = line
        elif ft == 2:
            cur = (line + prev) & 255
        else:  # Sub, Average and Paeth depend on the pixel to the left
            cur = np.zeros(stride, np.int32)
            for i in range(stride):
                a = cur[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                if ft == 1:
                    p = a
                elif ft == 3:
                    p = (a + b) // 2
                else:
                    pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                    p = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                cur[i] = (line[i] + p) & 255
        out[y] = cur
    return out.reshape(h, w, bpp)[:, :, :3]


def box_down(img, factor):
    h, w = img.shape[0] // factor * factor, img.shape[1] // factor * factor
    return (img[:h, :w].astype(np.float64).reshape(h // factor, factor, w // factor, factor, 3).mean(axis=(1, 3)) + 0.5).astype(np.uint8)


def mad(a, b, mask=None):
    d = np.abs(a.astype(np.int16) - b.astype(np.int16))
    return float(d[mask].mean() if mask is not None else d.mean())


def ssim_global(a, b, block=8):
    """Structural similarity of the luma, one window per block x block block, averaged"""
    def luma(x):
        x = x.astype(np.float64)
        return 0.299 * x[..., 0] + 0.587 * x[..., 1] + 0.114 * x[..., 2]
    la, lb = luma(a), luma(b)
    h, w = la.shape[0] // block * block, la.shape[1] // block * block

    def blocks(x):
        return x[:h, :w].reshape(h // block, block, w // block, block).transpose(0, 2, 1, 3).reshape(h // block, w // block, -1)
    ba, bb = blocks(la), blocks(lb)
    ma, mb = ba.mean(-1), bb.mean(-1)
    va, vb = ba.var(-1), bb.var(-1)
    cov = ((ba - ma[..., None]) * (bb - mb[..., None])).mean(-1)
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    return float((((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma ** 2 + mb ** 2 + c1) * (va + vb + c2))).mean())


def to_srgb8(lin):
    lin = np.clip(lin, 0, 1)
    return (np.where(lin <= 0.0031308, lin * 12.92, 1.055 * lin ** (1 / 2.4) - 0.055) * 255 + 0.5).astype(np.uint8)


def face_sheet(vk, path, ref, got, shape):
    """voxkit | Material Maker | 10 x difference, stacked, for a face of (rows, cols) points"""
    r, g = ref.reshape(shape + (3,)), got.reshape(shape + (3,))
    diff = np.clip(np.abs(r - g) * 10.0, 0, 1)
    vk.render.write_png(path, np.ascontiguousarray(np.concatenate([to_srgb8(r), to_srgb8(g), to_srgb8(diff)], axis=0)))


# ---- Material Maker ---------------------------------------------------------------------------------------

def mm_eval(mm, points, normals, fresh, params=None, node=None, chunk=65536):
    """voxel.evaluate in chunks: the material's dict of arrays, or the RGBA array of a node output"""
    parts = []
    for i in range(0, len(points), chunk):
        sl = slice(i, i + chunk)
        parts.append(voxel.evaluate(mm, points[sl], normals[sl], None if fresh is None else fresh[sl], params, node))
        params = None
    if node is not None:
        return np.concatenate(parts)
    return {k: np.concatenate([p[k] for p in parts]) for k in parts[0]}


def angles(a, b):
    d = np.clip(np.sum(a * b, axis=1) / (np.linalg.norm(a, axis=1) * np.linalg.norm(b, axis=1)), -1, 1)
    return np.degrees(np.arccos(d))


def luminance(c):
    return c @ np.array([0.3, 0.59, 0.11], np.float32)


def point_sets(vk):
    """end face (s = 0), top face and random points of the beam: voxel coordinates, normals, fw"""
    pu, pv = vk.app["pith"]
    g = np.linspace(2.0, 16.0, 256, dtype=np.float32)
    yy, zz = np.meshgrid(g, g, indexing="ij")
    end = np.stack([np.zeros_like(yy), yy, zz], axis=-1).reshape(-1, 3)
    n_end = np.tile(np.array([-1.0, 0.0, 0.0], np.float32), (len(end), 1))
    s = np.linspace(0.0, 162.0, 1024, dtype=np.float32)
    # rows = across the beam (y), columns = along it (x)
    top = np.stack([np.tile(s, 256), np.repeat(g, 1024), np.full(256 * 1024, 18.0, np.float32)], axis=-1).astype(np.float32)
    n_top = np.tile(np.array([0.0, 0.0, 1.0], np.float32), (len(top), 1))
    rng = np.random.default_rng(11)
    count = 30000
    rnd = np.stack([rng.uniform(0, 162, count), rng.uniform(0, 18, count), rng.uniform(0, 18, count)], axis=-1).astype(np.float32)
    n_rnd = rng.normal(size=(count, 3)).astype(np.float32)
    n_rnd /= np.linalg.norm(n_rnd, axis=1, keepdims=True)
    fw = rng.uniform(0, 1, count).astype(np.float32)
    fw[:count // 5] = 0.0
    fw[count // 5:2 * count // 5] = 1.0
    return {"end": (end, n_end, np.ones(len(end), np.float32), (256, 256)),
            "top": (top, n_top, np.ones(len(top), np.float32), (256, 1024)),
            "random": (rnd, n_rnd, fw, None)}


def point_check(vk, mm, sets):
    pu, pv = vk.app["pith"]
    org = np.array([0.0, pu, pv], np.float32) / np.float32(VPM)
    ring_node = 5.0 * VPM / 1000.0  # the ring width the node computes
    params = {"seed": vk.seed & 0xFFFFFF, "age": float(vk.app.get("age", 0.6)), "axis": [1.0, 0.0, 0.0],
              "origin": [float(v) for v in org], "footprint": 0.0}
    print("\nStep 2: points against appearance.wood()  (seed %d, age %.2f, pith %.2f, %.2f voxels, %d points on the faces)" %
          (vk.seed, params["age"], pu, pv, len(sets["end"][0]) + len(sets["top"][0]) + len(sets["random"][0])), flush=True)
    cache = {}
    for name, (pl, n, fw, shape) in sets.items():
        P = (pl / np.float32(VPM)).astype(np.float32)
        fresh = (1.0 - fw).astype(np.float32)
        t = time.time()
        out = mm_eval(mm, P, n, fresh, params)
        spec = mm_eval(mm, P, n, fresh, None, "Wood:3")[:, 0]
        cache[name] = (P, out)
        # (a) the frame of the node: the pith is the origin of the coordinates (what the graph implements)
        rel = ((P - org) * np.float32(VPM)).astype(np.float32)
        app_a = {"grain_axis": 0, "pith": [0.0, 0.0], "ring_vox": ring_node, "age": params["age"]}
        col_a, nb_a, spec_a, _ = vk.wood(rel, n, fw, app_a, vk.seed)
        d = np.abs(col_a - out["base_color"])
        ang = angles(nb_a, out["normal"])
        print("      %-8s [advisory: pith forced to 0] per channel albedo mean |diff| R %.2e G %.2e B %.2e, max %.2e; normal 99th pct %.3f deg, max %.3f deg; spec mean %.2e max %.2e; %.1f s" %
              (name, d[:, 0].mean(), d[:, 1].mean(), d[:, 2].mean(), d.max(), np.percentile(ang, 99), ang.max(), np.abs(spec_a - spec).mean(), np.abs(spec_a - spec).max(), time.time() - t), flush=True)
        if shape is not None:
            face_sheet(vk, os.path.join(OUT, "points_%s.png" % name), col_a, out["base_color"], shape)
        # (b) the frame of voxkit: absolute coordinates with the pith at its place (not what the graph implements)
        app_b = dict(vk.app, age=params["age"])
        col_b, nb_b, _, _ = vk.wood(pl, n, fw, app_b, vk.seed)
        db = np.abs(col_b - out["base_color"])
        angb = angles(nb_b, out["normal"])
        check("%s: albedo mean |diff|" % name, "%.2e" % db.mean(), "< 0.01", bool(db.mean() < 0.01))
        check("%s: albedo 99th percentile |diff|" % name, "%.2e" % np.percentile(db, 99), "< 0.05", bool(np.percentile(db, 99) < 0.05))
        check("%s: normal mean angle (deg)" % name, "%.4f" % angb.mean(), "< 2", bool(angb.mean() < 2.0))
        print("      %-8s voxkit's frame: per channel mean |diff| R %.2e G %.2e B %.2e, max %.2e; normal max %.4f deg" %
              (name, db[:, 0].mean(), db[:, 1].mean(), db[:, 2].mean(), db.max(), angb.max()), flush=True)
    return params, org


def ring_count_lum(lum, window=15):
    """Late wood bands of a luminance signal sampled along a radius: hysteresis count of the dips"""
    k = np.ones(window) / window
    sm = np.convolve(lum, k, mode="valid")
    lo, hi = sm.min(), sm.max()
    sm = (sm - lo) / max(hi - lo, 1e-9)
    count, armed = 0, sm[0] > 0.65
    for v in sm:
        if v > 0.65:
            armed = True
        elif v < 0.35 and armed:
            count += 1
            armed = False
    return count


ARCH = {name: tuple(values) for name, values in PRESETS.items()}  # flow amount, flow scale, pith wander, ripple amount


def preset_measures(vk, mm, sets, preset, params, org):
    """Luminance of the top face, ring counts along a radius of the end face, for a preset of the graph"""
    mm.apply_preset(preset)
    pl, n, fw, shape = sets["top"]
    P = (pl / np.float32(VPM)).astype(np.float32)
    out = mm_eval(mm, P, n, (1.0 - fw).astype(np.float32), params)
    lum = luminance(out["base_color"]).reshape(shape)
    pu, pv = vk.app["pith"]
    t = np.arange(0.0, 6.0, 0.005, dtype=np.float32)
    line = np.stack([np.zeros_like(t), pu + t, np.full_like(t, pv)], axis=-1).astype(np.float32)
    nl = np.tile(np.array([-1.0, 0.0, 0.0], np.float32), (len(t), 1))
    rad = mm_eval(mm, line / np.float32(VPM), nl, np.zeros(len(t), np.float32), params)
    return lum, luminance(rad["base_color"]), out["base_color"]


def arch_measure(vk, preset):
    pl = vk.sets["top"][0]
    s = pl[:, 0].reshape(256, 1024)
    u0, v0 = pl[:, 1].reshape(256, 1024), pl[:, 2].reshape(256, 1024)
    ph = vk.ring_phase(s, u0, v0, vk.seed, vk.app["pith"], vk.app["ring_vox"], *ARCH[preset])
    return float(np.abs(np.diff(ph, axis=1) / (162.0 / 1023.0)).mean()), ph


def ring_count_phase(vk, preset):
    pu, pv = vk.app["pith"]
    t = np.arange(0.0, 6.0, 0.005, dtype=np.float32)
    ph = vk.ring_phase(np.zeros_like(t), pu + t, np.full_like(t, pv), vk.seed, vk.app["pith"], vk.app["ring_vox"], *ARCH[preset])
    return int(np.count_nonzero(np.diff(np.floor(ph))))


# ---- the renders ------------------------------------------------------------------------------------------

def render_beam(vk, path, wood_fn, label):
    R = vk.render
    pool, wood = R.ProcessPoolExecutor, vk.appearance.wood
    R.ProcessPoolExecutor = InlineExecutor
    if wood_fn is not None:
        vk.appearance.wood = wood_fn
    t = time.time()
    try:
        build, pos, tgt, fov, _, sun, exposure = vk.kit_test.pictures({"beam": vk.beam})["beam_close"]
        R.render(build(), path, pos, tgt, fov=fov, size=SIZE, ss=1, sun=sun, exposure=exposure)
    finally:
        R.ProcessPoolExecutor, vk.appearance.wood = pool, wood
    print("  %s rendered in %.0f s" % (label, time.time() - t), flush=True)
    return read_png(path)


def make_mm_wood(vk, mm, stats):
    """appearance.wood() answered by the graph: the node outputs Albedo and Spec, the material's bumped normal"""
    def mm_wood(pl, n, fin, fw, seed, row, fins, app, fp):
        if int(app["grain_axis"]) != 0:
            raise ValueError("the example graph is set up for a grain along x")
        ag = ((fin == fins["aged_oak"]["id"]) * fw).astype(np.float32)
        pu, pv = app["pith"]
        params = {"seed": int(seed) & 0xFFFFFF, "age": float(app.get("age", 0.6)), "axis": [1.0, 0.0, 0.0],
                  "origin": [0.0, pu / VPM, pv / VPM], "footprint": 0.0}
        P = (pl / np.float32(VPM)).astype(np.float32)
        n = n.astype(np.float32)
        out = voxel.evaluate(mm, P, n, 1.0 - ag, params)
        spec = voxel.evaluate(mm, P, n, 1.0 - ag, None, "Wood:3")[:, 0]
        stats["calls"] += 1
        stats["points"] += len(pl)
        stats["fp_max"] = max(stats["fp_max"], float(np.max(fp)))
        return out["base_color"].astype(np.float32), out["normal"].astype(np.float32), spec.astype(np.float32), np.full(len(pl), 20.0, np.float32)
    return mm_wood


def make_frame_wood(vk):
    """voxkit's wood() in the frame of the graph: the pith is the origin of the coordinates (the node
    measures every position from its Origin input), where voxkit measures the fibre, pore and check
    noises from the part's own origin and puts the pith at appearance.pith"""
    original = vk.appearance.wood

    def frame_wood(pl, n, fin, fw, seed, row, fins, app, fp):
        pu, pv = app["pith"]
        org = np.array([0.0, pu, pv], np.float32) / np.float32(VPM)
        rel = ((pl / np.float32(VPM) - org) * np.float32(VPM)).astype(np.float32)
        return original(rel, n, fin, fw, seed, row, fins, dict(app, pith=[0.0, 0.0], ring_vox=5.0 * VPM / 1000.0), fp)
    return frame_wood


def stub_wood(pl, n, fin, fw, seed, row, fins, app, fp):
    """Magenta wood, to find the pixels of the beam"""
    c = len(pl)
    return np.tile(np.array([1000.0, 0.0, 1000.0], np.float32), (c, 1)), n.astype(np.float32), np.zeros(c, np.float32), np.full(c, 10.0, np.float32)


# ---- export ---------------------------------------------------------------------------------------------

INPUTS = [("Position", "float3"), ("Normal", "float3"), ("Seed", "float"), ("Age", "float"), ("Upkeep", "float"), ("Fresh", "float"),
          ("Char", "float"), ("Wet", "float"), ("Axis", "float3"), ("Origin", "float3"), ("Footprint", "float"), ("Time", "float")]
OUTPUTS = [("metallic", "float"), ("roughness", "float"), ("normal", "float3"), ("emission", "float3"), ("occlusion", "float"), ("opacity", "float")]


def wrap_custom_node(shader_text, textures):
    """The body of an Unreal Custom node as a pixel shader (as MMTestHlsl.wrap_custom_node does in the tests)"""
    params, args, glob_decl, local_decl = [], [], "", ""
    for name, typ in INPUTS:
        params.append("%s %s" % (typ, name))
        args.append("(%s)0.5" % typ)
    for name in textures:
        params += ["Texture2D %s" % name, "SamplerState %sSampler" % name]
        glob_decl += "Texture2D g_%s;\nSamplerState g_%sSampler;\n" % (name, name)
        args += ["g_%s" % name, "g_%sSampler" % name]
    for name, typ in OUTPUTS:
        params.append("out %s %s" % (typ, name))
        local_decl += "\t%s o_%s;\n" % (typ, name)
        args.append("o_%s" % name)
    return (glob_decl + "float4 custom_node_body(%s) {\n%s\n}\n\nfloat4 main(float4 sv_position : SV_Position) : SV_Target {\n%s\treturn custom_node_body(%s);\n}\n"
            % (", ".join(params), shader_text, local_decl, ", ".join(args)))


def export_check(mm, dxc, out_dir):
    print("\nStep 4: export with %s and compile with dxc" % TARGET, flush=True)
    if TARGET not in mm.list_export_targets():
        check("export target registered", "missing", TARGET, False)
        return
    prefix = os.path.join(out_dir, "voxel_oak")
    mm.export(TARGET, prefix)
    shader = prefix + ".shader"
    textures = sorted(os.path.splitext(os.path.basename(f))[0][len("voxel_oak_"):] for f in glob.glob(prefix + "_texture_*.exr"))
    with open(shader, encoding="utf-8") as f:
        text = f.read()
    hlsl = os.path.join(out_dir, "voxel_oak_wrapped.hlsl")
    with open(hlsl, "w", encoding="utf-8", newline="\n") as f:
        f.write(wrap_custom_node(text, textures))
    if dxc is None:
        check("exported shader compiles with dxc", "dxc not found", "ps_6_0", None)
        return
    for hv in ("2021", "2018"):
        r = subprocess.run([dxc, "-T", "ps_6_0", "-E", "main", "-HV", hv, hlsl], capture_output=True, text=True)
        msg = (r.stderr or r.stdout).strip().splitlines()
        check("exported shader compiles with dxc -HV %s" % hv, "ok" if r.returncode == 0 else (msg[0][:24] if msg else "error"), "ps_6_0", r.returncode == 0)
        if r.returncode != 0:
            print("\n".join(msg[:10]))


# ---- main -------------------------------------------------------------------------------------------------

def main():
    global OUT
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--voxkit", required=True, help="ZCity/Tools/voxkit")
    ap.add_argument("--reference", required=True, help="the stored beam_close.png")
    ap.add_argument("--mm", required=True, help='the Material Maker command, e.g. "godot --path <repo> --"')
    ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "oak_compare"), help="directory for the outputs (default: in the temporary directory)")
    ap.add_argument("--graph", default=os.path.join(REPO, "material_maker", "examples", "voxel_oak.ptex"))
    ap.add_argument("--port", type=int, default=7693)
    ap.add_argument("--dxc", default=None, help="path of dxc (default: from the PATH)")
    ap.add_argument("--reuse", action="store_true", help="reuse the baseline renders of a previous run in --out")
    args = ap.parse_args()
    OUT = os.path.abspath(args.out)
    os.makedirs(OUT, exist_ok=True)
    t0 = time.time()

    vk = Voxkit(args.voxkit)
    vk.sets = point_sets(vk)
    ref_full = read_png(args.reference)
    R = box_down(ref_full, ref_full.shape[1] // SIZE[0])
    print("Reference %s %s -> %s; beam %s, seed %d, pith %s, ring_vox %.4f" % (os.path.basename(args.reference), ref_full.shape[:2], R.shape[:2], vk.meta["size"], vk.seed, vk.app["pith"], vk.app["ring_vox"]), flush=True)

    # the baseline renders do not need Material Maker: make them before it is started
    print("\nStep 3a: voxkit's renderer, voxkit's wood (baseline B) and a magenta wood (beam mask)", flush=True)
    b_path, s_path = os.path.join(OUT, "beam_close_B.png"), os.path.join(OUT, "beam_close_mask.png")
    B = read_png(b_path) if args.reuse and os.path.exists(b_path) else render_beam(vk, b_path, None, "B")
    S = read_png(s_path) if args.reuse and os.path.exists(s_path) else render_beam(vk, s_path, stub_wood, "mask")
    beam = (S[..., 0] > 200) & (S[..., 1] < 60) & (S[..., 2] > 200)
    print("  beam covers %d of %d pixels" % (beam.sum(), beam.size), flush=True)

    process, mm = launch(args.mm, port=args.port)
    try:
        mm.load(os.path.abspath(args.graph))
        mm.apply_preset("voxkit")
        params, org = point_check(vk, mm, vk.sets)

        # arch and ring measures, from the top and end faces
        print("\nMeasures on the faces", flush=True)
        lum_k, rad_k, _ = preset_measures(vk, mm, vk.sets, "voxkit", params, org)
        lum_z, rad_z, _ = preset_measures(vk, mm, vk.sets, "zcity", params, org)
        mm.apply_preset("voxkit")
        slope = lambda L: float(np.abs(np.diff(L, axis=1) / (162.0 / 1023.0)).mean())
        arch_k, _ = arch_measure(vk, "voxkit")
        arch_z, _ = arch_measure(vk, "zcity")
        check("arches: mean |d phase/ds|, zcity / voxkit (exact ring phase)", "%.3f (%.4f / %.4f)" % (arch_z / arch_k, arch_z, arch_k), "<= 0.6", bool(arch_z / arch_k <= 0.6))
        lr = slope(lum_z) / slope(lum_k)
        check("arches: mean |d lum/ds|, zcity / voxkit (albedo luminance)", "%.3f" % lr, "<= 0.6", bool(lr <= 0.6))
        rk, rz = ring_count_phase(vk, "voxkit"), ring_count_phase(vk, "zcity")
        check("end grain rings along a radius, zcity vs voxkit (phase)", "%d vs %d" % (rz, rk), "within 10%", bool(abs(rz - rk) <= 0.1 * rk))
        ck, cz = ring_count_lum(rad_k), ring_count_lum(rad_z)
        check("end grain rings along a radius, zcity vs voxkit (albedo)", "%d vs %d" % (cz, ck), "within 10%", bool(abs(cz - ck) <= 0.1 * max(ck, 1)))

        print("\nStep 3b: the same picture with the graph's wood: preset voxkit (M1), preset zcity (M2)", flush=True)
        stats = {"calls": 0, "points": 0, "fp_max": 0.0}
        wood_fn = make_mm_wood(vk, mm, stats)
        mm.apply_preset("voxkit")
        M1 = render_beam(vk, os.path.join(OUT, "beam_close_M1.png"), wood_fn, "M1")
        mm.apply_preset("zcity")
        M2 = render_beam(vk, os.path.join(OUT, "beam_close_M2.png"), wood_fn, "M2")
        mm.apply_preset("voxkit")
        rw = vk.app["ring_vox"]
        print("  %d graph evaluations of %d points; largest footprint %.3f voxels (rings fade from %.3f)" % (stats["calls"], stats["points"], stats["fp_max"], rw / 2.2), flush=True)

        mad_b_r = mad(B, R)
        check("MAD(B, R): voxkit now vs the stored picture", "%.2f" % mad_b_r, "<= 6 else stale", None if mad_b_r > 6 else True)
        check("SSIM(B, R)", "%.4f" % ssim_global(B, R), "", None)
        check("footprint 0 is equivalent (rings do not fade)", "%.3f" % stats["fp_max"], "<= %.3f" % (rw / 2.2), bool(stats["fp_max"] <= rw / 2.2))
        m1, s1 = mad(M1, B), ssim_global(M1, B)
        check("MAD(M1, B)", "%.3f" % m1, "<= 3.0", bool(m1 <= 3.0))
        check("SSIM(M1, B)", "%.4f" % s1, ">= 0.95", bool(s1 >= 0.95))
        check("MAD(M1, B) on the beam only", "%.3f" % mad(M1, B, beam), "", None)
        check("MAD(M1, R)", "%.2f" % mad(M1, R), "", None)
        check("MAD(M2, B)", "%.2f" % mad(M2, B), "", None)
        mean_b, mean_m1, mean_m2 = [x[beam].reshape(-1, 3).mean(axis=0) for x in (B, M1, M2)]
        dm = float(np.abs(mean_m2 - mean_b).max())
        check("beam mean colour, M2 vs B (8 bit, worst channel)", "%.2f (%s vs %s)" % (dm, np.round(mean_m2, 1).tolist(), np.round(mean_b, 1).tolist()), "<= 6", bool(dm <= 6))
        check("beam mean colour, M1 vs B (8 bit, worst channel)", "%.2f" % float(np.abs(mean_m1 - mean_b).max()), "", None)

        # contact sheet R | B / M1 | M2, and the beam enlarged
        sheet = np.concatenate([np.concatenate([R, B], axis=1), np.concatenate([M1, M2], axis=1)], axis=0)
        vk.render.write_png(os.path.join(OUT, "oak_compare.png"), np.ascontiguousarray(sheet))
        ys, xs = np.nonzero(beam)
        y0, y1, x0, x1 = max(ys.min() - 4, 0), min(ys.max() + 5, beam.shape[0]), max(xs.min() - 4, 0), min(xs.max() + 5, beam.shape[1])
        crops = [np.repeat(np.repeat(im[y0:y1, x0:x1], 2, axis=0), 2, axis=1) for im in (R, B, M1, M2)]
        vk.render.write_png(os.path.join(OUT, "oak_compare_crops.png"), np.ascontiguousarray(np.concatenate(crops, axis=0)))

        export_check(mm, args.dxc or shutil.which("dxc"), OUT)
    finally:
        try:
            mm.quit()
        except Exception:
            pass
        try:
            process.wait(60)
        except Exception:
            process.kill()

    failed = [r for r in RESULTS if r[3] is False]
    print("\nOutputs in %s: oak_compare.png (R | B over M1 | M2), oak_compare_crops.png (R, B, M1, M2 enlarged, one under the other), points_*.png (voxkit, graph, 10 x difference), voxel_oak.shader" % OUT)
    print("Took %.0f s" % (time.time() - t0))
    if failed:
        print("\nFAILED: " + "; ".join("%s (%s, limit %s)" % (r[0], r[1], r[2]) for r in failed))
        print("OAK ACCEPTANCE: FAIL")
        return 1
    print("\nOAK ACCEPTANCE: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
