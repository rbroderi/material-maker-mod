"""Validates node libraries and example materials by rendering them, for CI.

    python validate_library.py --mm "godot --path ." [--library material_maker/library/base.json]
                               [--examples material_maker/examples] [--filter text] [--size 32]

Each library item is created in an empty graph and its first output is
rendered; each example material's albedo output is rendered. The exit code is
1 if anything fails. Material Maker runs without user interface (--rpc).
"""

import argparse
import json
import os
import shlex
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from material_maker_client import MaterialMakerError, launch  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mm", default="material_maker", help="command that starts Material Maker")
    parser.add_argument("--library", action="append", help="library files (default: material_maker/library/base.json)")
    parser.add_argument("--examples", default=None, help="directory of example .ptex files")
    parser.add_argument("--filter", default="", help="only validate items whose path contains this text")
    parser.add_argument("--size", type=int, default=32)
    parser.add_argument("--start", type=int, default=0, help="index of the first library item")
    parser.add_argument("--limit", type=int, default=0, help="maximum number of library items")
    parser.add_argument("--port", type=int, default=7695)
    args = parser.parse_args()
    libraries = args.library or ["material_maker/library/base.json"]
    # Non POSIX splitting keeps Windows paths, but also their quotes
    command = [a.strip('"') for a in shlex.split(args.mm, posix=os.name != "nt")]
    process, mm = launch(command, port=args.port)
    failures = []
    count = 0
    out_dir = tempfile.mkdtemp(prefix="mm_validate_")
    try:
        for library in libraries:
            with open(library, encoding="utf-8") as f:
                items = json.load(f)["lib"]
            items = items[args.start:args.start + args.limit] if args.limit > 0 else items[args.start:]
            for item in items:
                path = item.get("tree_item", item.get("name", "?"))
                if args.filter.lower() not in path.lower():
                    continue
                count += 1
                start = time.time()
                try:
                    mm.new_graph()
                    name = mm.create_node(item=item)
                    if name != "Material" and mm.get_node(name)["outputs"]:
                        output = os.path.join(out_dir, "item.png")
                        mm.render(name, output, output=0, size=args.size)
                        if not os.path.exists(output) or os.path.getsize(output) == 0:
                            raise MaterialMakerError(0, "nothing rendered")
                        os.remove(output)
                    status = "ok"
                    queue = mm.call("render_queue")
                    if queue:
                        status += " (%d buffers left: %s)" % (len(queue), ", ".join("%s %s" % (b["node"], b["status"]) for b in queue[:3]))
                except (MaterialMakerError, KeyError) as e:
                    status = "FAILED: %s" % e
                    failures.append("%s: %s" % (path, e))
                print("%-60s %s (%.1fs)" % (path, status, time.time() - start), flush=True)
        if args.examples:
            for file_name in sorted(os.listdir(args.examples)):
                if not file_name.endswith(".ptex") or args.filter.lower() not in file_name.lower():
                    continue
                count += 1
                start = time.time()
                try:
                    mm.load(os.path.join(args.examples, file_name))
                    nodes = {n["name"]: n for n in mm.list_nodes()}
                    # Some material types (e.g. unlit) have no exported outputs
                    if "Material" in nodes and nodes["Material"]["outputs"]:
                        mm.render("Material", os.path.join(out_dir, "example.png"), output=0, size=args.size)
                    status = "ok"
                except MaterialMakerError as e:
                    status = "FAILED: %s" % e
                    failures.append("%s: %s" % (file_name, e))
                print("%-60s %s (%.1fs)" % (file_name, status, time.time() - start), flush=True)
    finally:
        try:
            mm.quit()
        except Exception:
            process.kill()
        process.wait(60)
    print("\n%d validated, %d failed" % (count, len(failures)))
    for f in failures:
        print("  " + f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
