"""Tools for Material Maker graphs (.ptex files) in version control.

    python ptex_tools.py normalize <file.ptex>
        prints the graph as canonical JSON (sorted keys, nodes sorted by name,
        connections sorted by input), for line based diffs. Material Maker
        loads the output as the same graph
    python ptex_tools.py diff <old.ptex> <new.ptex> [--positions]
        prints the nodes, parameters and connections that changed
    python ptex_tools.py validate <files...>
        checks graphs (and .mmg node definitions) against ptex.schema.json,
        that node names are unique, that connections refer to existing nodes
        and that no input has two connections; the exit code is 1 if a file
        is invalid
    python ptex_tools.py merge <base.ptex> <ours.ptex> <theirs.ptex> [-o <out.ptex>]
        three-way merge: nodes are matched by name, connections are sets, and
        subgraphs and parameters are merged recursively. Conflicting changes
        (including an input connected to different outputs) keep "ours" and
        are listed; the exit code is 1 if there are conflicts, and the output
        is always a valid graph (there are no conflict markers). An empty base
        (a file added on both sides) is an empty graph.

Git setup (from the repository root):

    git config diff.ptex.textconv "python python/ptex_tools.py normalize"
    git config merge.ptex.name "Material Maker graph merge"
    git config merge.ptex.driver "python python/ptex_tools.py merge %O %A %B -o %A"

and in .gitattributes:

    *.ptex diff=ptex merge=ptex
"""

import json
import os
import re
import sys

# Keys that only affect the layout of the graph editor
LAYOUT_KEYS = {"node_position", "scroll_offset", "zoom"}

# A key that is not in a dictionary (in three-way merges)
MISSING = object()


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def connection_key(c):
    return (c.get("from"), c.get("from_port"), c.get("to"), c.get("to_port"))


def port_order(port):
    return (0, port) if isinstance(port, (int, float)) and not isinstance(port, bool) else (1, str(port))


def input_order(c):
    """Connections are sorted by the input they connect to. An input has one
    connection (when loading, the last connection to an input replaces the
    others), and sorting is stable, so normalizing never changes the graph"""
    return (str(c.get("to")), port_order(c.get("to_port")))


def normalize(graph):
    """Returns a copy of a graph with nodes and connections in a stable order"""
    if isinstance(graph, dict):
        result = {k: normalize(v) for k, v in graph.items()}
        if isinstance(result.get("nodes"), list):
            result["nodes"] = sorted(result["nodes"], key=lambda n: str(n.get("name", "")))
        if isinstance(result.get("connections"), list):
            result["connections"] = sorted(result["connections"], key=input_order)
        return result
    if isinstance(graph, list):
        return [normalize(v) for v in graph]
    return graph


def dumps(graph):
    return json.dumps(normalize(graph), indent="\t", sort_keys=True, ensure_ascii=False) + "\n"


def nodes_by_name(graph):
    return {n.get("name"): n for n in graph.get("nodes", [])} if isinstance(graph, dict) else {}


def short(value, limit=60):
    if value is MISSING:
        return "(removed)"
    text = json.dumps(value, sort_keys=True, ensure_ascii=False)
    return text if len(text) <= limit else text[:limit - 3] + "..."


def diff_keys(o, n, node_path, positions):
    """Returns the differences between the keys (and parameters) of two nodes"""
    lines = []
    for key in sorted(set(o) | set(n)):
        if key in ("nodes", "connections", "name") or (key in LAYOUT_KEYS and not positions):
            continue
        if key == "parameters" and isinstance(o.get(key), dict) and isinstance(n.get(key), dict):
            for p in sorted(set(o[key]) | set(n[key])):
                if o[key].get(p, MISSING) != n[key].get(p, MISSING):
                    lines.append("~ %s:%s %s -> %s" % (node_path, p, short(o[key].get(p, MISSING)), short(n[key].get(p, MISSING))))
        elif o.get(key, MISSING) != n.get(key, MISSING):
            lines.append("~ %s.%s %s -> %s" % (node_path, key, short(o.get(key, MISSING)), short(n.get(key, MISSING))))
    return lines


def diff_graphs(old, new, path="", positions=False):
    """Returns the differences between two graphs, as lines of text"""
    lines = []
    if path == "":
        # Keys of the top level graph itself (its parameters, label...)
        lines += diff_keys(old, new, "(graph)", positions)
    old_nodes = nodes_by_name(old)
    new_nodes = nodes_by_name(new)
    for name in sorted(set(old_nodes) | set(new_nodes), key=str):
        node_path = path + str(name)
        if name not in new_nodes:
            lines.append("- node %s (%s)" % (node_path, old_nodes[name].get("type")))
            continue
        if name not in old_nodes:
            lines.append("+ node %s (%s)" % (node_path, new_nodes[name].get("type")))
            continue
        o, n = old_nodes[name], new_nodes[name]
        lines += diff_keys(o, n, node_path, positions)
        if "nodes" in o or "nodes" in n:
            lines += diff_graphs(o, n, node_path + "/", positions)
    old_connections = {connection_key(c) for c in old.get("connections", [])}
    new_connections = {connection_key(c) for c in new.get("connections", [])}
    for c in sorted(old_connections - new_connections, key=str):
        lines.append(format_connection("-", path, c))
    for c in sorted(new_connections - old_connections, key=str):
        lines.append(format_connection("+", path, c))
    return lines


class Merger:
    def __init__(self):
        self.conflicts = []

    def merge_value(self, base, ours, theirs, path):
        if ours == theirs:
            return ours
        if ours == base:
            return theirs
        if theirs == base:
            return ours
        if isinstance(ours, dict) and isinstance(theirs, dict):
            return self.merge_dict(base if isinstance(base, dict) else {}, ours, theirs, path)
        self.conflicts.append("%s: ours %s, theirs %s (kept ours)" % (path, short(ours), short(theirs)))
        return ours

    def merge_dict(self, base, ours, theirs, path):
        result = {}
        for key in list(ours.keys()) + [k for k in theirs.keys() if k not in ours]:
            b, o, t = base.get(key, MISSING), ours.get(key, MISSING), theirs.get(key, MISSING)
            key_path = "%s.%s" % (path, key) if path else str(key)
            if key == "nodes" and isinstance(o, list) and isinstance(t, list):
                result[key] = self.merge_nodes(b if isinstance(b, list) else [], o, t, path)
            elif key == "connections" and isinstance(o, list) and isinstance(t, list):
                result[key] = self.merge_connections(b if isinstance(b, list) else [], o, t, path)
            else:
                value = self.merge_value(b, o, t, key_path)
                if value is not MISSING:
                    result[key] = value
        return result

    def merge_nodes(self, base, ours, theirs, path):
        b, o, t = ({n.get("name"): n for n in nodes} for nodes in (base, ours, theirs))
        result = []
        for name in list(o.keys()) + [k for k in t.keys() if k not in o]:
            node_path = "%s/%s" % (path, name) if path else str(name)
            if name in o and name in t:
                result.append(self.merge_value(b.get(name, {}), o[name], t[name], node_path))
            elif name in o:
                # Removed by theirs: keep it only if ours changed it
                if name not in b:
                    result.append(o[name])
                elif o[name] != b[name]:
                    self.conflicts.append("%s: changed by ours, removed by theirs (kept)" % node_path)
                    result.append(o[name])
            else:
                if name not in b:
                    result.append(t[name])
                elif t[name] != b[name]:
                    self.conflicts.append("%s: removed by ours, changed by theirs (removed)" % node_path)
        return result

    def merge_connections(self, base, ours, theirs, path):
        b, o, t = ({connection_key(c): c for c in connections} for connections in (base, ours, theirs))
        keys = (set(o) & set(t)) | (set(o) - set(b)) | (set(t) - set(b))
        merged = {**t, **o}
        # An input can only have one connection: if both sides connected the
        # same input to different outputs, keep ours
        inputs = {}
        for k in keys:
            inputs.setdefault(input_order(merged[k]), []).append(k)
        for same_input in inputs.values():
            added_by_ours = [k for k in same_input if k in o and k not in t]
            added_by_theirs = [k for k in same_input if k in t and k not in o]
            if added_by_ours and added_by_theirs:
                self.conflicts.append("%s%s:%s: connected to %s by ours, to %s by theirs (kept ours)" % (
                    path + "/" if path else "", added_by_ours[0][2], added_by_ours[0][3],
                    ", ".join("%s:%s" % k[:2] for k in added_by_ours), ", ".join("%s:%s" % k[:2] for k in sorted(added_by_theirs, key=str))))
                keys -= set(added_by_theirs)
        return [merged[k] for k in sorted(keys, key=lambda k: (input_order(merged[k]), str(k)))]


# Validation against ptex.schema.json, with a small validator for the subset
# of JSON Schema it uses (so this tool keeps having no dependencies)

SCHEMA_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ptex.schema.json")
JSON_TYPES = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}


def format_connection(sign, path, c):
    """A connection key (from, from_port, to, to_port) as a diff line"""
    return "%s connection %s%s:%s -> %s%s:%s" % (sign, path, c[0], c[1], path, c[2], c[3])


# A JSON string, or a comma followed by the end of an array or object
TRAILING_COMMA = re.compile(r'"(?:[^"\\]|\\.)*"|,(\s*[\]}])', re.DOTALL)


def read_text(path):
    with open(path, encoding="utf-8-sig", newline="") as f:
        return f.read()


def loads_lenient(text):
    """Parses JSON, accepting the trailing commas that Godot's parser accepts"""
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # Remove trailing commas, but not in strings (GLSL code, expressions...)
        return json.loads(TRAILING_COMMA.sub(lambda m: m.group(1) if m.group(1) is not None else m.group(0), text))


def load_lenient(path):
    return loads_lenient(read_text(path))


def is_type(value, t):
    if t == "integer":
        return isinstance(value, int) and not isinstance(value, bool) or (isinstance(value, float) and value.is_integer())
    if t == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, JSON_TYPES[t])


class SchemaValidator:
    def __init__(self, schema):
        self.root = schema

    def resolve(self, ref):
        node = self.root
        for part in ref.lstrip("#/").split("/"):
            node = node[part]
        return node

    def errors(self, value, schema, path="$"):
        rv = []
        if "$ref" in schema:
            rv += self.errors(value, self.resolve(schema["$ref"]), path)
        if "type" in schema:
            types = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(is_type(value, t) for t in types):
                return rv + ["%s: expected %s, got %s" % (path, " or ".join(types), type(value).__name__)]
        if "const" in schema and value != schema["const"]:
            rv.append("%s: expected %r" % (path, schema["const"]))
        if "enum" in schema and value not in schema["enum"]:
            rv.append("%s: %r is not one of %s" % (path, value, schema["enum"]))
        if "minimum" in schema and is_type(value, "number") and value < schema["minimum"]:
            rv.append("%s: %r is less than %r" % (path, value, schema["minimum"]))
        if isinstance(value, dict):
            for k in schema.get("required", []):
                if k not in value:
                    rv.append("%s: missing %s" % (path, k))
            properties = schema.get("properties", {})
            for k, v in value.items():
                if k in properties:
                    rv += self.errors(v, properties[k], "%s.%s" % (path, k))
                elif schema.get("additionalProperties") is False:
                    rv.append("%s: unexpected key %s" % (path, k))
                elif isinstance(schema.get("additionalProperties"), dict):
                    rv += self.errors(v, schema["additionalProperties"], "%s.%s" % (path, k))
        if isinstance(value, list) and "items" in schema:
            for i, v in enumerate(value):
                rv += self.errors(v, schema["items"], "%s[%d]" % (path, i))
        for s in schema.get("allOf", []):
            rv += self.errors(value, s, path)
        if "anyOf" in schema and all(self.errors(value, s, path) for s in schema["anyOf"]):
            rv.append("%s: %s does not match any of the allowed forms" % (path, short(value)))
        if "if" in schema and not self.errors(value, schema["if"], path):
            rv += self.errors(value, schema.get("then", {}), path)
        return rv


def graph_errors(node, path="$"):
    """Checks that connections refer to nodes of their graph, recursively"""
    rv = []
    names = [n.get("name") for n in node.get("nodes", [])]
    for name in set(names):
        if names.count(name) > 1:
            rv.append("%s: several nodes are named %s" % (path, name))
    sources = {}
    for c in node.get("connections", []):
        for k in ("from", "to"):
            if c.get(k) not in names:
                rv.append("%s: connection %s:%s -> %s:%s refers to a missing node %s" % (path, c.get("from"), c.get("from_port"), c.get("to"), c.get("to_port"), c.get(k)))
        source = sources.setdefault(input_order(c), connection_key(c))
        if source != connection_key(c):
            rv.append("%s: the input %s:%s is connected to %s:%s and %s:%s (only the last one is loaded)" % (path, c.get("to"), c.get("to_port"), source[0], source[1], c.get("from"), c.get("from_port")))
    for n in node.get("nodes", []):
        rv += graph_errors(n, "%s.%s" % (path, n.get("name")))
    return rv


def validate(value, schema=None):
    """Returns the errors of a graph or node definition (an empty list if valid)"""
    if schema is None:
        schema = load(SCHEMA_PATH)
    return SchemaValidator(schema).errors(value, schema) + graph_errors(value)


def command_validate(argv):
    schema = load(SCHEMA_PATH)
    invalid = 0
    for path in argv:
        errors = validate(load_lenient(path), schema)
        print("%s: %s" % (path, "valid" if not errors else "%d error(s)" % len(errors)))
        for e in errors[:20]:
            print("  " + e)
        invalid += 1 if errors else 0
    return 1 if invalid else 0


def command_normalize(argv):
    sys.stdout.write(dumps(load_lenient(argv[0])))
    return 0


def command_diff(argv):
    lines = diff_graphs(load_lenient(argv[0]), load_lenient(argv[1]), positions="--positions" in argv)
    print("\n".join(lines) if lines else "no differences")
    return 0


def command_merge(argv):
    texts = [read_text(path) for path in argv[:3]]
    # git passes an empty base when both sides added the file
    base, ours, theirs = (loads_lenient(t) if t.strip() else {} for t in texts)
    merger = Merger()
    merged = merger.merge_value(base, ours, theirs, "")
    o = argv.index("-o") if "-o" in argv else -1
    output = argv[o + 1] if 0 <= o < len(argv) - 1 else None
    # Same layout as Material Maker's own files (sorted keys, tabs), with the
    # line endings of "ours"
    text = json.dumps(merged, indent="\t", sort_keys=True, ensure_ascii=False)
    if output:
        with open(output, "w", encoding="utf-8", newline="\r\n" if "\r\n" in texts[1] else "\n") as f:
            f.write(text)
    else:
        sys.stdout.write(text + "\n")
    for c in merger.conflicts:
        print("conflict: " + c, file=sys.stderr)
    return 1 if merger.conflicts else 0


# Commands: (function, minimum number of arguments)
COMMANDS = {
    "validate": (command_validate, 1),
    "normalize": (command_normalize, 1),
    "diff": (command_diff, 2),
    "merge": (command_merge, 3),
}


def main(argv):
    # Graphs contain non-ASCII text (node descriptions), and git reads the
    # output of textconv through a pipe, whose encoding is not UTF-8 on Windows
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    command = COMMANDS.get(argv[0]) if argv else None
    if command is None or len(argv) - 1 < command[1]:
        print(__doc__)
        return 2
    return command[0](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
