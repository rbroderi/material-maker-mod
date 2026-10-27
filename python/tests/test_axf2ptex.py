"""Tests of the AxF converter (python/axf2ptex.py) on small synthetic AxF
files. Skipped if numpy or h5py are not installed.

    python python/tests/test_axf2ptex.py"""

import json
import os
import sys
import tempfile
import types
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

try:
    import numpy as np
    import h5py
    import axf2ptex
    import axf_btf
except ImportError:
    np = None

STR = h5py.string_dtype() if np is not None else None


def options(output):
    return types.SimpleNamespace(output=output, fit="crop", max_size=2048, flake_size=16)


def set_type(group, t):
    group.attrs["axf.type"] = np.array([t.encode()], dtype=object)


def lookup(group, name, location):
    g = group.require_group("com.xrite.Resources").create_group(name)
    set_type(g, "com.xrite.ResourceLookupOperator")
    g.create_dataset("ResourceLocations", data=np.array([location.encode()], dtype=object), dtype=STR)


def texture(resources, path, data, origin=b"TOP_LEFT"):
    g = resources.create_group(path)
    g.create_dataset("Data", data=data.astype(np.float32))
    g.create_dataset("TextureOrigin", data=origin)
    g.create_dataset("ColorSpec", data=b"$(COLORSPECS)/sRGB")
    return g


def new_axf(path, name):
    f = h5py.File(path, "w")
    spec = f.create_group("com.xrite.ColorSpecs/sRGB")
    # Linear sRGB (D65) primaries: rows are the primaries' XYZ
    spec.create_dataset("com.xrite.ColorMatrices/XYZ", data=np.array([[0.4124, 0.2126, 0.0193], [0.3576, 0.7152, 0.1192], [0.1805, 0.0722, 0.9505]], dtype=np.float32))
    m = f.create_group("com.xrite.Materials/" + name)
    return f, m


@unittest.skipIf(np is None, "numpy and h5py are needed")
class TestConversions(unittest.TestCase):
    def test_specular_to_metallic(self):
        diffuse = np.array([[0.5, 0.2, 0.1], [0.0, 0.0, 0.0]])
        specular = np.array([[0.04, 0.04, 0.04], [0.9, 0.6, 0.3]])
        base, metallic = axf2ptex.specular_to_metallic(diffuse, specular)
        self.assertAlmostEqual(metallic[0], 0.0, places=3)
        self.assertGreater(metallic[1], 0.95)
        np.testing.assert_allclose(base[1], [0.9, 0.6, 0.3], atol=0.05)

    def test_color_matrix_is_identity_for_srgb(self):
        with tempfile.TemporaryDirectory() as d:
            f, m = new_axf(os.path.join(d, "t.axf"), "t")
            m.create_group("com.xrite.Resources")
            axf = axf2ptex.AxFMaterial(f, "t")
            np.testing.assert_allclose(axf.color_matrix("$(COLORSPECS)/sRGB"), np.eye(3), atol=2e-3)
            f.close()


@unittest.skipIf(np is None, "numpy and h5py are needed")
class TestSvbrdf(unittest.TestCase):
    def make(self, path):
        f, m = new_axf(path, "leather")
        res = m.create_group("com.xrite.Resources")
        size = 8
        diffuse = np.zeros((size, size, 3))
        diffuse[..., 0] = 0.6
        diffuse[..., 1] = 0.3
        diffuse[..., 2] = 0.1
        texture(res, "SVBRDF/Diffuse/Color", diffuse)
        normal = np.zeros((size, size, 3))
        normal[..., 2] = 1.0
        normal[:4, :, 0] = 0.3
        texture(res, "SVBRDF/Normal", normal, origin=b"BOTTOM_LEFT")
        texture(res, "SVBRDF/Specular/Color", np.full((size, size, 3), 0.04))
        lobes = np.full((size, size, 1), 0.25)
        texture(res, "SVBRDF/Specular/Lobes", lobes)
        rep = m.create_group("com.xrite.Representations/0")
        set_type(rep, "com.xrite.Svbrdf")
        rep.create_dataset("RepresentationClass", data=b"SVBRDF")
        lambert = rep.create_group("com.xrite.Operands/0")
        set_type(lambert, "com.xrite.LambertDiffuseModel")
        lookup(lambert, "Color", "SVBRDF/Diffuse/Color")
        lookup(lambert, "Normal", "SVBRDF/Normal")
        ward = rep.create_group("com.xrite.Operands/1")
        set_type(ward, "com.xrite.WardSpecularModel")
        lookup(ward, "Color", "SVBRDF/Specular/Color")
        lookup(ward, "Lobes", "SVBRDF/Specular/Lobes")
        f.close()

    def test_svbrdf(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "leather.axf")
            self.make(path)
            written, warnings = axf2ptex.convert(path, options(d))
            self.assertEqual([os.path.basename(w) for w in written], ["leather.ptex"])
            with open(written[0]) as f:
                graph = json.load(f)
            material = graph["nodes"][0]
            self.assertEqual(material["type"], "material")
            targets = {c["to_port"] for c in graph["connections"] if c["to"] == "Material"}
            for name in ("albedo_tex", "metallic_tex", "roughness_tex", "normal_tex"):
                self.assertIn(axf2ptex.MATERIAL_INPUTS.index(name), targets)
            from_png = lambda name: np.frombuffer(zlib_decode(os.path.join(d, "leather_textures", name + ".png")), dtype=np.uint8)
            # A dielectric (specular 0.04): not metallic, roughness sqrt(0.25)
            self.assertEqual(int(from_png("metallic").max()), 0)
            self.assertEqual(int(np.median(from_png("roughness"))), round(0.5 * 255))
            # BOTTOM_LEFT textures are flipped: the tilted normals are at the bottom
            normal = from_png("normal").reshape(8, 8, 3)
            self.assertGreater(int(normal[7, 0, 0]), 140)
            self.assertLess(abs(int(normal[0, 0, 0]) - 128), 2)


@unittest.skipIf(np is None, "numpy and h5py are needed")
class TestCarPaint(unittest.TestCase):
    def make(self, path, flakes):
        f, m = new_axf(path, "paint")
        res = m.create_group("com.xrite.Resources")
        cp = res.create_group("CarPaint2")
        g = cp.create_group("DiffuseModel/Color")
        set_type(g, "com.xrite.Uniform")
        g.create_dataset("Data", data=np.array([0.2], dtype=np.float32))
        lobes = [(0.02, 0.1, 0.6), (0.03, 0.25, 0.3), (0.0, 0.5, 1.0)]
        for i, l in enumerate(lobes):
            g = cp.create_group("SpecularModel/Lobes/%d" % i)
            set_type(g, "com.xrite.Uniform")
            g.create_dataset("Data", data=np.array(l, dtype=np.float32))
        table = np.ones((16, 16, 3), dtype=np.float32)
        table[..., 1] = np.linspace(0.5, 1.5, 16)[None, :]
        g = cp.create_group("TabulatedBrdf/Data")
        g.create_dataset("Data", data=table)
        ior = res.create_group("ClearCoat/IOR")
        set_type(ior, "com.xrite.Uniform")
        ior.create_dataset("Data", data=np.float32(1.5))
        rep = m.create_group("com.xrite.Representations/0")
        set_type(rep, "com.xrite.ClearCoatFilter")
        rep.create_dataset("RepresentationClass", data=b"CarPaint2")
        rep.create_dataset("NoRefraction", data=np.uint8(0))
        lookup(rep, "IOR", "ClearCoat/IOR")
        inp = rep.create_group("com.xrite.Input")
        set_type(inp, "com.xrite.SummationOperator")
        index = 0
        if flakes:
            fl = inp.create_group("com.xrite.Operands/0")
            set_type(fl, "com.xrite.FlakesBtf")
            fl.create_dataset("PatchesLookupTable", data=np.array([[0, 1], [2, -1]], dtype=np.int32))
            fl.create_dataset("NumThetaF", data=np.int32(24))
            fl.create_dataset("NumThetaI", data=np.int32(24))
            locations = []
            for p in range(3):
                g = cp.create_group("Flakes/Patch%d" % p)
                data = np.zeros((32, 32, 3), dtype=np.float16)
                data[::8, ::8] = 2.0 / (p + 1)
                d = g.create_dataset("Data", data=data.view(np.uint16))
                d.attrs["axf.datatype"] = np.array([b"half"], dtype=object)
                locations.append(("CarPaint2/Flakes/Patch%d" % p).encode())
            r = fl.create_group("com.xrite.Resources/Data")
            r.create_dataset("ResourceLocations", data=np.array(locations, dtype=object), dtype=STR)
            index = 1
        mult = inp.create_group("com.xrite.Operands/%d" % index)
        set_type(mult, "com.xrite.MultiplicationOperator")
        tab = mult.create_group("com.xrite.Operands/0")
        set_type(tab, "com.xrite.TabulatedBrdf")
        lookup(tab, "Data", "CarPaint2/TabulatedBrdf/Data")
        summ = mult.create_group("com.xrite.Operands/1")
        set_type(summ, "com.xrite.SummationOperator")
        lam = summ.create_group("com.xrite.Operands/0")
        set_type(lam, "com.xrite.LambertDiffuseModel")
        ct = summ.create_group("com.xrite.Operands/1")
        set_type(ct, "com.xrite.CookTorranceSpecularModel")
        r = ct.create_group("com.xrite.Resources/Lobes")
        r.create_dataset("ResourceLocations", data=np.array([("CarPaint2/SpecularModel/Lobes/%d" % i).encode() for i in range(3)], dtype=object), dtype=STR)
        f.close()

    def test_car_paint(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "paint.axf")
            self.make(path, flakes=True)
            written, warnings = axf2ptex.convert(path, options(d))
            self.assertEqual(sorted(os.path.basename(w) for w in written), ["paint.ptex", "paint_pbr.ptex"])
            with open(os.path.join(d, "paint.ptex")) as f:
                graph = json.load(f)
            material = graph["nodes"][0]
            self.assertEqual(material["type"], "material_car_paint")
            p = material["parameters"]
            self.assertAlmostEqual(p["coeff1"], 0.03, places=5)
            self.assertAlmostEqual(p["spread0"], 0.1, places=5)
            self.assertAlmostEqual(p["f0_0"], 0.6, places=5)
            self.assertEqual((p["flake_max_theta_f"], p["flake_max_theta_i"]), (2, 2))
            self.assertAlmostEqual(p["color_table_scale"], 1.5, places=3)
            # The flake atlas has a cell per lookup table entry, empty cells are 0 (0.5)
            atlas = np.frombuffer(zlib_decode(os.path.join(d, "paint_textures", "flakes.png")), dtype=np.uint8).reshape(32, 32, 3)
            self.assertTrue(np.all(np.abs(atlas[16:, 16:].astype(int) - 128) <= 1))
            self.assertGreater(int(atlas[:16, :16].max()), 200)
            self.assertEqual(sorted(c["to_port"] for c in graph["connections"]), [0, 1, 2])

    def test_energy(self):
        """The car paint model reflects less than it receives"""
        table = np.ones((16, 16, 3))
        paint = axf2ptex.CarPaint(0.3, [(0.02, 0.1, 0.6), (0.03, 0.25, 0.3)], table, 1.5, True)
        for theta in (0.0, 0.5, 1.0, 1.4):
            albedo = paint.directional_albedo(theta)
            self.assertTrue(np.all(albedo < 1.0) and np.all(albedo > 0.0), (theta, albedo))
        # Without refraction and with a white table, the diffuse part alone
        # is the Lambert albedo times the clear coat transmission
        lambert = axf2ptex.CarPaint(0.5, [], table, 1.0001, False)
        np.testing.assert_allclose(lambert.directional_albedo(0.3), 0.5, atol=0.02)


@unittest.skipIf(np is None, "numpy and h5py are needed")
class TestBtf(unittest.TestCase):
    def make(self, path, albedo, alpha, f0, normal):
        """A DPVF BTF of a Lambert + GGX material, sampled at 6 rings of
        directions (rank 1 per view and channel)"""
        f, m = new_axf(path, "btf")
        res = m.create_group("com.xrite.Resources")
        thetas = np.radians([0, 15, 30, 45, 60, 75])
        counts = [1, 6, 12, 16, 20, 26]
        table = [(t, p) for t, c in zip(thetas, counts) for p in np.arange(c) * 2 * np.pi / c]
        dirs = np.array(table, dtype=[("Theta", "<f4"), ("Phi", "<f4")])
        rep = m.create_group("com.xrite.Representations/0")
        set_type(rep, "com.xrite.Dpvf")
        lights = np.zeros(len(table), dtype=[("LampID", "<i4"), ("Phi", "<f4"), ("Theta", "<f4")])
        lights["Theta"], lights["Phi"] = dirs["Theta"], dirs["Phi"]
        rep.create_dataset("Lights", data=lights)
        views = np.zeros(len(table), dtype=[("CameraID", "<i4"), ("Phi", "<f4"), ("Theta", "<f4")])
        views["Theta"], views["Phi"] = dirs["Theta"], dirs["Phi"]
        rep.create_dataset("Views", data=views)
        rep.create_dataset("DecorrelatingTransform", data=np.eye(3, dtype=np.float32))
        w, h = 4, 2
        n = np.tile(np.asarray(normal, dtype=np.float64) / np.linalg.norm(normal), (w * h, 1))
        l_dir = axf_btf.directions(lights)
        v_dir = axf_btf.directions(views)
        chunks = res.create_group("DPVF/Chunks")
        chunks.create_dataset("WidthPixel", data=np.int32(w))
        chunks.create_dataset("HeightPixel", data=np.int32(h))
        chunks.create_dataset("ColorSpec", data=b"$(COLORSPECS)/sRGB")
        pairs, locations = [], []
        for vi in range(len(table)):
            v = np.repeat(v_dir[vi][None], len(table), axis=0)
            spec = axf_btf.ggx_specular(n, l_dir, v, alpha).T * f0       # lights x texels
            diffuse = albedo / np.pi * np.clip(l_dir @ n.T, 0, 1)
            for c in range(3):
                data = diffuse + spec
                k = vi * 3 + c
                g = chunks.create_group(str(k))
                # Exact factorization: U = data, SxV = identity on the texels
                g.create_dataset("MatrixU", data=data.astype(np.float32))
                g.create_dataset("MatrixSxV", data=np.eye(w * h, dtype=np.float32))
                g.create_dataset("VectorS", data=np.ones(w * h, dtype=np.float32))
                pairs.append((c, vi))
                locations.append(("DPVF/Chunks/%d" % k).encode())
        r = rep.create_group("com.xrite.Resources/Chunks")
        r.create_dataset("ChannelChunkPairs", data=np.array(pairs, dtype=[("Channel", "<i4"), ("Chunk", "<i4")]))
        r.create_dataset("ResourceLocations", data=np.array(locations, dtype=object), dtype=STR)
        f.close()

    def test_btf_fit(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "btf.axf")
            self.make(path, albedo=0.4, alpha=0.3 ** 2, f0=0.04, normal=[0.2, 0.0, 1.0])
            written, warnings = axf2ptex.convert(path, options(d))
            self.assertTrue(any("explained" in w for w in warnings))
            read = lambda name, c: np.frombuffer(zlib_decode(os.path.join(d, "btf_textures", name + ".png")), dtype=np.uint8).reshape(-1, c).astype(float) / 255
            albedo = read("albedo", 3)
            np.testing.assert_allclose(albedo.mean(axis=0), axf2ptex.to_srgb(np.array([0.4] * 3)), atol=0.03)
            np.testing.assert_allclose(read("roughness", 1).mean(), 0.3, atol=0.06)
            self.assertLess(read("metallic", 1).max(), 0.05)
            normal = read("normal", 3).mean(axis=0) * 2 - 1
            np.testing.assert_allclose(normal / np.linalg.norm(normal), np.array([0.2, 0, 1]) / np.linalg.norm([0.2, 0, 1]), atol=0.03)


def zlib_decode(path):
    """Pixels of an 8-bit PNG written by axf2ptex (filter 0 rows)"""
    import struct
    import zlib
    with open(path, "rb") as f:
        data = f.read()
    pos = 8
    idat = b""
    width = height = channels = 0
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, _, color_type = struct.unpack(">IIBB", payload[:10])
            channels = {0: 1, 2: 3, 6: 4}[color_type]
        elif kind == b"IDAT":
            idat += payload
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = width * channels + 1
    return b"".join(raw[y * stride + 1:(y + 1) * stride] for y in range(height))


if __name__ == "__main__":
    unittest.main()
