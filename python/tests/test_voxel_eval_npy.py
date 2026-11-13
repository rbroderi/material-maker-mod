"""Tests of the .npy exchange of material_maker_client.voxel (offline, no server)"""
import os
import re
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from material_maker_client import voxel  # noqa: E402


class NpyTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def path(self, name):
        return os.path.join(self.dir.name, name)

    def test_round_trip(self):
        rng = np.random.default_rng(1)
        for shape in [(5000, 3), (7,), (1, 4), (0, 3)]:
            a = rng.uniform(-3, 3, size=shape).astype(np.float32)
            voxel.write_npy(self.path("a.npy"), a)
            b = voxel.read_npy(self.path("a.npy"))
            self.assertEqual(b.dtype, np.dtype("<f4"))
            self.assertEqual(b.shape, shape)
            np.testing.assert_array_equal(a, b)

    def test_converts_to_float32(self):
        voxel.write_npy(self.path("a.npy"), np.arange(6, dtype=np.float64).reshape(2, 3))
        self.assertEqual(voxel.read_npy(self.path("a.npy")).dtype, np.dtype("<f4"))
        # Fortran ordered arrays are written in C order
        f = np.asfortranarray(np.arange(6, dtype=np.float32).reshape(2, 3))
        voxel.write_npy(self.path("f.npy"), f)
        np.testing.assert_array_equal(voxel.read_npy(self.path("f.npy")), f)

    def test_header_is_what_the_server_reads(self):
        """The Material Maker reader (npy.gd) wants version 1.0, '<f4', C order and a header padded to 64 bytes"""
        voxel.write_npy(self.path("a.npy"), np.zeros((12, 3), dtype=np.float32))
        with open(self.path("a.npy"), "rb") as f:
            data = f.read()
        self.assertEqual(data[:8], b"\x93NUMPY\x01\x00")
        header_length = int.from_bytes(data[8:10], "little")
        self.assertEqual((10 + header_length) % 64, 0)
        header = data[10:10 + header_length].decode("ascii")
        self.assertTrue(header.endswith("\n"))
        self.assertIsNotNone(re.search(r"'descr'\s*:\s*'<f4'", header))
        self.assertIsNotNone(re.search(r"'fortran_order'\s*:\s*False", header))
        self.assertIsNotNone(re.search(r"'shape'\s*:\s*\(12, 3\)", header))
        self.assertEqual(len(data), 10 + header_length + 12 * 3 * 4)

    def test_reads_numpy_files(self):
        a = np.linspace(0, 1, 30, dtype=np.float32).reshape(10, 3)
        np.save(self.path("n.npy"), a)
        np.testing.assert_array_equal(voxel.read_npy(self.path("n.npy")), a)

    def test_rejects_other_types(self):
        np.save(self.path("d.npy"), np.zeros(3, dtype=np.float64))
        with self.assertRaises(ValueError):
            voxel.read_npy(self.path("d.npy"))

    def test_point_checks(self):
        with self.assertRaises(ValueError):
            voxel.evaluate(None, np.zeros((4, 2)))
        with self.assertRaises(ValueError):
            voxel.evaluate(None, np.zeros((4, 3)), normals=np.zeros((3, 3)))
        with self.assertRaises(ValueError):
            voxel.evaluate(None, np.zeros((4, 3)), fresh=np.zeros(5))


if __name__ == "__main__":
    unittest.main()
