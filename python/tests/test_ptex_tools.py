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

    def test_validate_example(self):
        self.assertEqual(ptex_tools.validate(self.base), [])

    def test_validate_errors(self):
        cases = {
            "connection to a missing node": lambda g: g["connections"].append({"from": "Perlin", "from_port": 0, "to": "Nowhere", "to_port": 0}),
            "unknown connection key": lambda g: g["connections"][0].update(color="red"),
            "negative port": lambda g: g["connections"][0].update(from_port=-1),
            "bad buffer pin": lambda g: g["connections"][0].update(buffer="sometimes"),
            "color without alpha": lambda g: node(g, "Material")["parameters"].update(albedo_color={"type": "Color", "r": 1, "g": 1, "b": 1}),
            "parameter list": lambda g: node(g, "Perlin")["parameters"].update(scale_x=[1, 2]),
            "graph without connections": lambda g: g.pop("connections"),
            "duplicate node name": lambda g: g["nodes"].append(copy.deepcopy(node(g, "Perlin"))),
            "shader without model": lambda g: g["nodes"].append({"name": "custom", "type": "shader"}),
        }
        for name, change in cases.items():
            graph = copy.deepcopy(self.base)
            change(graph)
            self.assertNotEqual(ptex_tools.validate(graph), [], name)

    def test_schema_matches_jsonschema(self):
        """The built-in validator agrees with the reference implementation (when installed)"""
        try:
            import jsonschema
        except ImportError:
            self.skipTest("jsonschema is not installed")
        schema = ptex_tools.load(ptex_tools.SCHEMA_PATH)
        jsonschema.Draft202012Validator.check_schema(schema)
        validator = jsonschema.Draft202012Validator(schema)
        graph = copy.deepcopy(self.base)
        self.assertEqual(list(validator.iter_errors(graph)), [])
        node(graph, "Material")["parameters"]["albedo_color"] = {"type": "Color", "r": 1}
        self.assertNotEqual(list(validator.iter_errors(graph)), [])


if __name__ == "__main__":
    unittest.main()
