"""Tests of ptex_tools (python -m unittest discover python/tests)"""
import copy
import json
import os
import subprocess
import sys
import tempfile
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
        theirs["connections"].append({"from": "extra", "from_port": 0, "to": "Material", "to_port": 3})
        removed = ours["connections"].pop(0)
        merger = ptex_tools.Merger()
        merged = merger.merge_value(self.base, ours, theirs, "")
        self.assertEqual(merger.conflicts, [])
        self.assertEqual(node(merged, "Perlin")["parameters"]["scale_x"], 12)
        self.assertEqual(node(merged, "Perlin")["parameters"]["scale_y"], 7)
        self.assertTrue(any(n["name"] == "extra" for n in merged["nodes"]))
        keys = {ptex_tools.connection_key(c) for c in merged["connections"]}
        self.assertIn(("extra", 0, "Material", 3), keys)
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
            "string port": lambda g: g["connections"][0].update(to_port="1"),
            "curve point without slopes": lambda g: node(g, "Perlin")["parameters"].update(curve={"type": "Curve", "points": [{"x": 0, "y": 0}]}),
            "gradient point without position": lambda g: node(g, "Perlin")["parameters"].update(gradient=[{"r": 0, "g": 0, "b": 0}]),
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

    def test_merge_same_input(self):
        """Both sides connect the same input to different outputs: one connection is kept"""
        base = {"type": "graph", "nodes": [{"name": n, "type": "uniform"} for n in "abcx"], "connections": [{"from": "c", "from_port": 0, "to": "x", "to_port": 0}]}
        ours = copy.deepcopy(base)
        theirs = copy.deepcopy(base)
        ours["connections"][0]["from"] = "a"
        theirs["connections"][0]["from"] = "b"
        merger = ptex_tools.Merger()
        merged = merger.merge_value(base, ours, theirs, "")
        self.assertEqual(merged["connections"], ours["connections"])
        self.assertEqual(len(merger.conflicts), 1, merger.conflicts)
        self.assertEqual(ptex_tools.validate(merged), [])
        # Only one side changed it
        merger = ptex_tools.Merger()
        self.assertEqual(merger.merge_value(base, copy.deepcopy(base), theirs, "")["connections"], theirs["connections"])
        self.assertEqual(merger.conflicts, [])

    def test_normalize_keeps_last_connection(self):
        """When loading, the last connection to an input wins: normalizing keeps it last"""
        graph = copy.deepcopy(self.base)
        first = graph["connections"][0]
        graph["connections"].append(dict(first, **{"from": "colorize_0", "from_port": 0}))
        self.assertNotEqual(ptex_tools.validate(graph), [])
        same_input = [c for c in ptex_tools.normalize(graph)["connections"] if (c["to"], c["to_port"]) == (first["to"], first["to_port"])]
        self.assertEqual(same_input, [first, graph["connections"][-1]])

    def test_validate_older_formats(self):
        """Colors without a type and gradients as arrays are still loaded by Material Maker"""
        graph = copy.deepcopy(self.base)
        node(graph, "Material")["parameters"]["albedo_color"] = {"r": 1, "g": 0.5, "b": 0, "a": 1}
        node(graph, "Perlin")["parameters"]["gradient"] = [{"pos": 0, "r": 0, "g": 0, "b": 0}, {"pos": 1, "r": 1, "g": 1, "b": 1, "a": 1}]
        self.assertEqual(ptex_tools.validate(graph), [])

    def test_validate_parameter_defaults(self):
        """Parameter defaults must have the type of the parameter's values"""
        def definition(parameter_type, default):
            return {"name": "n", "type": "shader", "shader_model": {"parameters": [{"name": "p", "type": parameter_type, "default": default}]}}
        valid = [
            ("float", 0.5), ("float", 1), ("float", "0.1+0.1*$seed"), ("size", 9), ("size", 9.0), ("enum", 2),
            ("boolean", False), ("color", {"r": 1, "g": 1, "b": 1, "a": 1}), ("color", {"type": "Color", "r": 1, "g": 1, "b": 1, "a": 1}),
            ("gradient", {"type": "Gradient", "interpolation": 1, "points": [{"pos": 0, "r": 0, "g": 0, "b": 0, "a": 1}]}),
            ("gradient", [{"pos": 0, "r": 0, "g": 0, "b": 0}]),
            ("curve", {"type": "Curve", "points": [{"x": 0, "y": 0, "ls": 0, "rs": 1}]}),
            ("polygon", {"type": "Polygon", "points": [{"x": 0, "y": 0}]}), ("polyline", {"type": "Polygon", "points": []}),
            ("splines", {"type": "Splines", "values": [], "point_groups": []}),
            ("pixels", {"type": "Pixels", "bpp": 1, "w": 1, "h": 1, "pl": [{"r": 0, "g": 0, "b": 0, "a": 1}], "px": [0]}),
            ("lattice", {"type": "Lattice", "size": {"x": 1, "y": 1}, "points": [{"x": 0, "y": 0}]}),
            ("string", 3), ("some_new_type", [1, 2]),
        ]
        invalid = [
            ("float", True), ("float", None), ("float", {"r": 1}), ("size", "big"), ("size", False), ("enum", "a"),
            ("boolean", 3), ("boolean", "true"), ("color", 1), ("color", {"r": 1, "g": 1, "b": 1}),
            ("gradient", {"type": "Curve", "points": []}), ("curve", {"type": "Polygon", "points": []}),
            ("polygon", {"points": []}), ("splines", {"type": "Polygon", "points": []}), ("pixels", 0), ("lattice", "x"),
        ]
        try:
            import jsonschema
            reference = jsonschema.Draft202012Validator(ptex_tools.load(ptex_tools.SCHEMA_PATH))
        except ImportError:
            reference = None
        for parameter_type, default, expected_valid in [c + (True,) for c in valid] + [c + (False,) for c in invalid]:
            errors = ptex_tools.validate(definition(parameter_type, default))
            self.assertEqual(errors == [], expected_valid, "%s default %r: %s" % (parameter_type, default, errors))
            if reference is not None:
                self.assertEqual(reference.is_valid(definition(parameter_type, default)), expected_valid, "jsonschema: %s default %r" % (parameter_type, default))
        # Parameters without a default are still valid
        self.assertEqual(ptex_tools.validate({"name": "n", "type": "shader", "shader_model": {"parameters": [{"name": "p", "type": "float"}]}}), [])

    def test_merge_removed_and_changed_key(self):
        base = {"type": "graph", "nodes": [], "connections": [], "label": "a"}
        ours = {"type": "graph", "nodes": [], "connections": []}
        theirs = {"type": "graph", "nodes": [], "connections": [], "label": "b"}
        merger = ptex_tools.Merger()
        merged = merger.merge_value(base, ours, theirs, "")
        self.assertEqual(len(merger.conflicts), 1)
        self.assertIn("(removed)", merger.conflicts[0])
        self.assertNotIn("label", merged)
        merger = ptex_tools.Merger()
        self.assertNotIn("label", merger.merge_value(base, ours, copy.deepcopy(base), ""))
        self.assertEqual(merger.conflicts, [])

    def test_diff_graph_keys(self):
        new = copy.deepcopy(self.base)
        new["shortdesc"] = "Bricks"
        self.assertIn("~ (graph).shortdesc (removed) -> \"Bricks\"", ptex_tools.diff_graphs(self.base, new))
        new = copy.deepcopy(self.base)
        node(new, "Perlin")["parameters"]["new_parameter"] = None
        self.assertIn("~ Perlin:new_parameter (removed) -> null", ptex_tools.diff_graphs(self.base, new))

    def test_trailing_commas(self):
        text = '{"a": [1, 2,], "code": "f(x, ]", "s": "\\", }",}'
        self.assertEqual(ptex_tools.loads_lenient(text), {"a": [1, 2], "code": "f(x, ]", "s": "\", }"})

    def test_command_line(self):
        """The commands work as git drivers (files, exit codes, UTF-8 through pipes)"""
        script = os.path.join(os.path.dirname(__file__), "..", "ptex_tools.py")
        with tempfile.TemporaryDirectory() as tmp:
            def write(name, graph):
                path = os.path.join(tmp, name)
                with open(path, "w", encoding="utf-8") as f:
                    json.dump(graph, f, indent="\t", sort_keys=True)
                return path

            def run(*args):
                # A pipe whose encoding cannot encode the graph's text, as on Windows
                env = dict(os.environ, PYTHONIOENCODING="ascii")
                return subprocess.run([sys.executable, script] + list(args), capture_output=True, env=env)

            base = copy.deepcopy(self.base)
            node(base, "Perlin")["longdesc"] = "ε > 0"
            ours = copy.deepcopy(base)
            theirs = copy.deepcopy(base)
            node(ours, "Perlin")["parameters"]["scale_x"] = 12
            node(theirs, "Perlin")["parameters"]["scale_y"] = 7
            paths = [write(n, g) for n, g in (("base", base), ("ours", ours), ("theirs", theirs))]
            normalized = run("normalize", paths[0])
            self.assertEqual(normalized.returncode, 0, normalized.stderr)
            self.assertEqual(json.loads(normalized.stdout.decode("utf-8")), ptex_tools.normalize(base))
            self.assertIn(b"~ Perlin:scale_x 4 -> 12", run("diff", paths[0], paths[1]).stdout)
            # Without conflict
            result = run("merge", paths[0], paths[1], paths[2], "-o", paths[1])
            self.assertEqual(result.returncode, 0, result.stderr)
            merged = ptex_tools.load(paths[1])
            self.assertEqual(node(merged, "Perlin")["parameters"]["scale_x"], 12)
            self.assertEqual(node(merged, "Perlin")["parameters"]["scale_y"], 7)
            # With a conflict: ours is kept, and listed
            node(theirs, "Perlin")["parameters"]["scale_x"] = 3
            write("theirs", theirs)
            write("ours", ours)
            result = run("merge", paths[0], paths[1], paths[2], "-o", paths[1])
            self.assertEqual(result.returncode, 1)
            self.assertIn(b"Perlin.parameters.scale_x", result.stderr)
            self.assertEqual(node(ptex_tools.load(paths[1]), "Perlin")["parameters"]["scale_x"], 12)
            # Both sides added the file: git passes an empty base
            open(paths[0], "w").close()
            result = run("merge", paths[0], paths[1], paths[1])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout.decode("utf-8")), ptex_tools.load(paths[1]))

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
