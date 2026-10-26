"""Tests of ptex_tools (python -m unittest discover python/tests)"""
import copy
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import ptex_tools  # noqa: E402

EXAMPLE = os.path.join(os.path.dirname(__file__), "..", "..", "material_maker", "examples", "bricks.ptex")


def node(graph, name):
    return next(n for n in graph["nodes"] if n["name"] == name)


class PtexToolsTest(unittest.TestCase):
    def setUp(self):
        self.base = ptex_tools.load(EXAMPLE)

    def test_normalize_is_stable(self):
        shuffled = copy.deepcopy(self.base)
        shuffled["nodes"].reverse()
        shuffled["connections"].reverse()
        self.assertEqual(ptex_tools.dumps(self.base), ptex_tools.dumps(shuffled))

    def test_diff(self):
        new = copy.deepcopy(self.base)
        node(new, "Perlin")["parameters"]["scale_x"] = 12
        new["connections"] = new["connections"][1:]
        new["nodes"].append({"name": "extra", "type": "uniform", "parameters": {}})
        lines = ptex_tools.diff_graphs(self.base, new)
        self.assertTrue(any(l.startswith("~ Perlin:scale_x") for l in lines), lines)
        self.assertTrue(any(l.startswith("- connection") for l in lines), lines)
        self.assertIn("+ node extra (uniform)", lines)
        self.assertEqual(ptex_tools.diff_graphs(self.base, copy.deepcopy(self.base)), [])

    def test_merge_independent_changes(self):
        ours = copy.deepcopy(self.base)
        theirs = copy.deepcopy(self.base)
        node(ours, "Perlin")["parameters"]["scale_x"] = 12
        node(theirs, "Perlin")["parameters"]["scale_y"] = 7
        theirs["nodes"].append({"name": "extra", "type": "uniform", "parameters": {}})
        theirs["connections"].append({"from": "extra", "from_port": 0, "to": "Material", "to_port": 5})
        removed = ours["connections"].pop(0)
        merger = ptex_tools.Merger()
        merged = merger.merge_value(self.base, ours, theirs, "")
        self.assertEqual(merger.conflicts, [])
        self.assertEqual(node(merged, "Perlin")["parameters"]["scale_x"], 12)
        self.assertEqual(node(merged, "Perlin")["parameters"]["scale_y"], 7)
        self.assertTrue(any(n["name"] == "extra" for n in merged["nodes"]))
        keys = {ptex_tools.connection_key(c) for c in merged["connections"]}
        self.assertIn(("extra", 0, "Material", 5), keys)
        self.assertNotIn(ptex_tools.connection_key(removed), keys)

    def test_merge_conflict(self):
        ours = copy.deepcopy(self.base)
        theirs = copy.deepcopy(self.base)
        node(ours, "Perlin")["parameters"]["scale_x"] = 12
        node(theirs, "Perlin")["parameters"]["scale_x"] = 3
        merger = ptex_tools.Merger()
        merged = merger.merge_value(self.base, ours, theirs, "")
        self.assertEqual(len(merger.conflicts), 1)
        self.assertEqual(node(merged, "Perlin")["parameters"]["scale_x"], 12)

    def test_merge_removed_node(self):
        ours = copy.deepcopy(self.base)
        theirs = copy.deepcopy(self.base)
        theirs["nodes"] = [n for n in theirs["nodes"] if n["name"] != "Perlin"]
        merger = ptex_tools.Merger()
        merged = merger.merge_value(self.base, ours, theirs, "")
        self.assertFalse(any(n["name"] == "Perlin" for n in merged["nodes"]))
        self.assertEqual(merger.conflicts, [])


if __name__ == "__main__":
    unittest.main()
