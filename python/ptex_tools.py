"""Tools for Material Maker graphs (.ptex files) in version control.

    python ptex_tools.py normalize <file.ptex>
        prints the graph as canonical JSON (sorted keys, nodes sorted by name,
        sorted connections), for line based diffs
    python ptex_tools.py diff <old.ptex> <new.ptex> [--positions]
        prints the nodes, parameters and connections that changed
    python ptex_tools.py merge <base.ptex> <ours.ptex> <theirs.ptex> [-o <out.ptex>]
        three-way merge: nodes are matched by name, connections are sets, and
        subgraphs and parameters are merged recursively. Conflicting changes
        keep "ours" and are listed; the exit code is 1 if there are conflicts.

Git setup (from the repository root):

    git config diff.ptex.textconv "python python/ptex_tools.py normalize"
    git config merge.ptex.name "Material Maker graph merge"
    git config merge.ptex.driver "python python/ptex_tools.py merge %O %A %B -o %A"

and in .gitattributes:

    *.ptex diff=ptex merge=ptex
"""

import json
import sys

# Keys that only affect the layout of the graph editor
LAYOUT_KEYS = {"node_position", "scroll_offset", "zoom"}


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def connection_key(c):
    return (c.get("from"), c.get("from_port"), c.get("to"), c.get("to_port"))


def normalize(graph):
    """Returns a copy of a graph with nodes and connections in a stable order"""
    if isinstance(graph, dict):
        result = {k: normalize(v) for k, v in graph.items()}
        if isinstance(result.get("nodes"), list):
            result["nodes"] = sorted(result["nodes"], key=lambda n: str(n.get("name", "")))
        if isinstance(result.get("connections"), list):
            result["connections"] = sorted(result["connections"], key=lambda c: tuple(str(v) for v in connection_key(c)))
        return result
    if isinstance(graph, list):
        return [normalize(v) for v in graph]
    return graph


def dumps(graph):
    return json.dumps(normalize(graph), indent="\t", sort_keys=True, ensure_ascii=False) + "\n"


def nodes_by_name(graph):
    return {n.get("name"): n for n in graph.get("nodes", [])} if isinstance(graph, dict) else {}


def short(value, limit=60):
    text = json.dumps(value, sort_keys=True, ensure_ascii=False)
    return text if len(text) <= limit else text[:limit - 3] + "..."


def diff_graphs(old, new, path="", positions=False):
    """Returns the differences between two graphs, as lines of text"""
    lines = []
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
        for key in sorted(set(o) | set(n)):
            if key in ("nodes", "connections", "name") or (key in LAYOUT_KEYS and not positions):
                continue
            if key == "parameters" and isinstance(o.get(key), dict) and isinstance(n.get(key), dict):
                for p in sorted(set(o[key]) | set(n[key])):
                    if o[key].get(p) != n[key].get(p):
                        lines.append("~ %s:%s %s -> %s" % (node_path, p, short(o[key].get(p)), short(n[key].get(p))))
            elif o.get(key) != n.get(key):
                lines.append("~ %s.%s %s -> %s" % (node_path, key, short(o.get(key)), short(n.get(key))))
        if "nodes" in o or "nodes" in n:
            lines += diff_graphs(o, n, node_path + "/", positions)
    old_connections = {connection_key(c) for c in old.get("connections", [])}
    new_connections = {connection_key(c) for c in new.get("connections", [])}
    for c in sorted(old_connections - new_connections, key=str):
        lines.append("- connection %s%s:%s -> %s%s:%s" % (path, c[0], c[1], path, c[2], c[3]))
    for c in sorted(new_connections - old_connections, key=str):
        lines.append("+ connection %s%s:%s -> %s%s:%s" % (path, c[0], c[1], path, c[2], c[3]))
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
        missing = object()
        for key in list(ours.keys()) + [k for k in theirs.keys() if k not in ours]:
            b, o, t = base.get(key, missing), ours.get(key, missing), theirs.get(key, missing)
            key_path = "%s.%s" % (path, key) if path else str(key)
            if key == "nodes" and isinstance(o, list) and isinstance(t, list):
                result[key] = self.merge_nodes(b if isinstance(b, list) else [], o, t, path)
            elif key == "connections" and isinstance(o, list) and isinstance(t, list):
                result[key] = self.merge_connections(b if isinstance(b, list) else [], o, t)
            else:
                value = self.merge_value(b, o, t, key_path)
                if value is not missing:
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

    @staticmethod
    def merge_connections(base, ours, theirs):
        b, o, t = ({connection_key(c): c for c in connections} for connections in (base, ours, theirs))
        keys = (set(o) & set(t)) | (set(o) - set(b)) | (set(t) - set(b))
        merged = {**t, **o}
        return [merged[k] for k in sorted(keys, key=str)]


def main(argv):
    if len(argv) >= 2 and argv[0] == "normalize":
        sys.stdout.write(dumps(load(argv[1])))
        return 0
    if len(argv) >= 3 and argv[0] == "diff":
        lines = diff_graphs(load(argv[1]), load(argv[2]), positions="--positions" in argv)
        print("\n".join(lines) if lines else "no differences")
        return 0
    if len(argv) >= 4 and argv[0] == "merge":
        merger = Merger()
        merged = merger.merge_value(load(argv[1]), load(argv[2]), load(argv[3]), "")
        output = argv[argv.index("-o") + 1] if "-o" in argv else None
        text = json.dumps(merged, indent="\t", ensure_ascii=False)
        if output:
            with open(output, "w", encoding="utf-8") as f:
                f.write(text)
        else:
            sys.stdout.write(text + "\n")
        for c in merger.conflicts:
            print("conflict: " + c, file=sys.stderr)
        return 1 if merger.conflicts else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
