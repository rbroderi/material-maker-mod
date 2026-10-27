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
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from material_maker_client import MaterialMakerError, find_command, launch  # noqa: E402


def matches(text, filters):
    """Whether text contains one of the filters (case insensitive)"""
    return any(f in text.lower() for f in filters)


def validate(name, check, failures, errors=(MaterialMakerError,)):
    """Runs check() (that returns a status), prints its status and time, and
    records its failure"""
    start = time.time()
    try:
        status = check()
    except errors as e:
        status = "FAILED: %s" % e
        failures.append("%s: %s" % (name, e))
    print("%-60s %s (%.1fs)" % (name, status, time.time() - start), flush=True)


def check_library_item(mm, item, out_dir, size):
    """Creates a library item in an empty graph and renders its first output"""
    mm.new_graph()
    name = mm.create_node(item=item)
    if name != "Material" and mm.get_node(name)["outputs"]:
        output = os.path.join(out_dir, "item.png")
        mm.render(name, output, output=0, size=size)
        if not os.path.exists(output) or os.path.getsize(output) == 0:
            raise MaterialMakerError(0, "nothing rendered")
        os.remove(output)
    status = "ok"
    queue = mm.call("render_queue")
    if queue:
        status += " (%d buffers left: %s)" % (len(queue), ", ".join("%s %s" % (b["node"], b["status"]) for b in queue[:3]))
    return status


def check_example(mm, path, out_dir, size):
    """Loads an example material and renders its albedo"""
    mm.load(path)
    nodes = {n["name"]: n for n in mm.list_nodes()}
    # Some material types (e.g. unlit) have no exported outputs
    if "Material" in nodes and nodes["Material"]["outputs"]:
        mm.render("Material", os.path.join(out_dir, "example.png"), output=0, size=size)
    return "ok"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mm", help="command that starts Material Maker (default: the MATERIAL_MAKER environment variable, or material_maker)")
    parser.add_argument("--library", action="append", help="library files (default: material_maker/library/base.json)")
    parser.add_argument("--examples", default=None, help="directory of example .ptex files")
    parser.add_argument("--filter", default="", help="only validate items whose path contains this text (several texts are separated by |)")
    parser.add_argument("--size", type=int, default=32)
    parser.add_argument("--start", type=int, default=0, help="index of the first library item")
    parser.add_argument("--limit", type=int, default=0, help="maximum number of library items")
    parser.add_argument("--port", type=int, default=7695)
    args = parser.parse_args()
    libraries = args.library or ["material_maker/library/base.json"]
    command = find_command(args.mm)
    if command is None:
        sys.exit("Material Maker was not found: use --mm or the MATERIAL_MAKER environment variable")
    process, mm = launch(command, port=args.port)
    failures = []
    count = 0
    filters = [f.lower() for f in args.filter.split("|")]
    temp_dir = tempfile.TemporaryDirectory(prefix="mm_validate_")
    out_dir = temp_dir.name
    try:
        for library in libraries:
            with open(library, encoding="utf-8") as f:
                items = json.load(f)["lib"]
            items = items[args.start:args.start + args.limit] if args.limit > 0 else items[args.start:]
            for item in items:
                path = item.get("tree_item", item.get("name", "?"))
                if matches(path, filters):
                    count += 1
                    validate(path, lambda: check_library_item(mm, item, out_dir, args.size), failures, (MaterialMakerError, KeyError))
        if args.examples:
            for file_name in sorted(os.listdir(args.examples)):
                if file_name.endswith(".ptex") and matches(file_name, filters):
                    count += 1
                    validate(file_name, lambda: check_example(mm, os.path.join(args.examples, file_name), out_dir, args.size), failures)
    finally:
        try:
            mm.quit()
        except Exception:
            process.kill()
        process.wait(60)
        temp_dir.cleanup()
    print("\n%d validated, %d failed" % (count, len(failures)))
    for f in failures:
        print("  " + f)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
