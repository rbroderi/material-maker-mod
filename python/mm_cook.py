"""mm-cook: cooks Material Maker graphs (.ptex) into runtime packages (.mmr),
like Substance's sbscooker cooks .sbs files into .sbsar files.

    python python/mm_cook.py [options] <inputs...>

Inputs are .ptex files, directories (searched recursively) or wildcards.
Packages are written to the output directory (with the same relative paths
for directories). Cooking is incremental: a package is cooked again only when
its graph, the cooking options or Material Maker's version changed (the
state is kept in <output>/.mm_cook.json), unless --force is used.

Options:
  --mm <command>       Material Maker command (default: the MATERIAL_MAKER
                       environment variable, or material_maker in the PATH),
                       for example "godot --path ." in a source checkout
  -o, --output <dir>   output directory (default: cooked)
  --size <size>        size of the outputs, or <width>x<height> (default:
                       the material's size)
  --jobs <n>           number of Material Maker processes (default: 1)
  --force              cook all packages
  --verify <mmr_render>  renders each package with mmr_render (C++ runtime)
                       and checks its outputs
  --report <file>      writes a JSON report (packages, status, times)

Exit code: 0 if all packages were cooked (and verified), 1 otherwise.
"""

import argparse
import concurrent.futures
import glob
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import zipfile

from material_maker_client import find_command

STATE_FILE = ".mm_cook.json"
# Godot errors that don't mean the export failed
GODOT_NOISE = ("Steam", "leaked", "still in use", "Pages in use")


def find_inputs(inputs):
    """(file, relative path) for each .ptex file of the inputs"""
    found = []
    for i in inputs:
        if os.path.isdir(i):
            for root, _dirs, files in os.walk(i):
                for f in sorted(files):
                    if f.endswith(".ptex"):
                        path = os.path.join(root, f)
                        found.append((os.path.abspath(path), os.path.relpath(path, i)))
        else:
            matches = glob.glob(i) if any(c in i for c in "*?[") else [i]
            for m in sorted(matches):
                if m.endswith(".ptex") and os.path.isfile(m):
                    found.append((os.path.abspath(m), os.path.basename(m)))
                else:
                    print("warning: %s is not a .ptex file" % m, file=sys.stderr)
    return found


def mm_command(option):
    command = find_command(option)
    if command is None:
        sys.exit("Material Maker was not found: use --mm or the MATERIAL_MAKER environment variable")
    return command


def mm_version(command):
    """Material Maker's version (from its --help, empty if unknown)"""
    try:
        result = subprocess.run(command + ["--", "--help"], capture_output=True, text=True, timeout=120)
        for line in result.stdout.splitlines():
            if line.startswith("Godot Engine") or "Material Maker" in line:
                return line.strip()
    except (OSError, subprocess.TimeoutExpired):
        pass
    return ""


def fingerprint(path, options, version):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read())
    h.update(json.dumps(options, sort_keys=True).encode())
    h.update(version.encode())
    return h.hexdigest()


def package_path(out_dir, path):
    """The package written by --export-mmr for a graph"""
    return os.path.join(out_dir, os.path.splitext(os.path.basename(path))[0] + ".mmr")


def godot_errors(output):
    """Error lines of Material Maker's output, without Godot's noise"""
    return [ l for l in output.splitlines() if l.startswith("ERROR: ") and not any(n in l for n in GODOT_NOISE) ]


def cook(command, path, out_dir, size):
    """Cooks a graph, returns an error message (or "")"""
    os.makedirs(out_dir, exist_ok=True)
    args = command + [ "--export-mmr", "-o", out_dir ] + ([ "--size", size ] if size else []) + [ path ]
    result = subprocess.run(args, capture_output=True, text=True)
    if not os.path.isfile(package_path(out_dir, path)):
        errors = godot_errors(result.stdout + result.stderr)
        return "no package written" + (": " + "; ".join(errors[:3]) if errors else "")
    return ""


def verify(mmr_render, package):
    """Renders a package with mmr_render, returns an error message (or "")"""
    try:
        manifest = json.loads(zipfile.ZipFile(package).read("manifest.json"))
    except (OSError, KeyError, ValueError, zipfile.BadZipFile) as e:
        return "invalid package: %s" % e
    with tempfile.TemporaryDirectory() as out:
        result = subprocess.run([ mmr_render, package, "-o", out ], capture_output=True, text=True)
        if result.returncode != 0:
            return "mmr_render failed: " + (result.stderr or result.stdout).strip()[:300]
        missing = [ o for o in manifest.get("outputs", {}) if not os.path.isfile(os.path.join(out, o + ".png")) ]
        if missing:
            return "outputs not rendered: " + ", ".join(missing)
    return ""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("inputs", nargs="+")
    parser.add_argument("--mm")
    parser.add_argument("-o", "--output", default="cooked")
    parser.add_argument("--size", default="")
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--verify", default="")
    parser.add_argument("--report", default="")
    args = parser.parse_args()
    command = mm_command(args.mm)
    if args.verify:
        # Relative paths with / are not found by Windows' CreateProcess
        args.verify = os.path.abspath(args.verify)
        if not os.path.isfile(args.verify):
            sys.exit("mmr_render was not found: " + args.verify)
    inputs = find_inputs(args.inputs)
    if not inputs:
        sys.exit("no .ptex file in the inputs")
    os.makedirs(args.output, exist_ok=True)
    state_path = os.path.join(args.output, STATE_FILE)
    state = {}
    if os.path.isfile(state_path):
        try:
            with open(state_path) as f:
                state = json.load(f)
        except ValueError:
            print("warning: %s is invalid, all packages are cooked" % state_path, file=sys.stderr)
    version = mm_version(command)
    options = { "size": args.size }

    def process(item):
        path, relative = item
        out_dir = os.path.join(args.output, os.path.dirname(relative))
        package = package_path(out_dir, path)
        key = os.path.relpath(package, args.output)
        digest = fingerprint(path, options, version)
        entry = { "input": path, "package": os.path.abspath(package) }
        if not args.force and state.get(key) == digest and os.path.isfile(package):
            entry["status"] = "up to date"
        else:
            start = time.time()
            error = cook(command, path, out_dir, args.size)
            entry["time"] = round(time.time() - start, 2)
            entry["status"] = "error" if error else "cooked"
            if error:
                entry["error"] = error
            else:
                state[key] = digest
        if args.verify and entry["status"] != "error":
            error = verify(args.verify, package)
            entry["verified"] = error == ""
            if error:
                entry["status"] = "error"
                entry["error"] = error
                state.pop(key, None)
        print("%-11s %s%s" % (entry["status"], key, (": " + entry["error"]) if "error" in entry else ""), flush=True)
        return entry

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as executor:
        report = list(executor.map(process, inputs))
    with open(state_path, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    if args.report:
        with open(args.report, "w") as f:
            json.dump({ "version": version, "options": options, "packages": report }, f, indent=1)
    counts = { s: sum(1 for e in report if e["status"] == s) for s in ("cooked", "up to date", "error") }
    print("%d cooked, %d up to date, %d errors" % (counts["cooked"], counts["up to date"], counts["error"]))
    sys.exit(1 if counts["error"] else 0)


if __name__ == "__main__":
    main()
