"""Checks mmr_render on a test package (for CI, where it can run on a software
Vulkan driver such as lavapipe): the outputs are written with the package's
size, and changing the seed changes the albedo.

    python runtime/cpp/tests/check_render.py <mmr_render executable>
"""

import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PACKAGE = os.path.join(HERE, "bricks.mmr")
OUTPUTS = [ "albedo", "orm", "normal", "height" ]


def png_size(path):
    with open(path, "rb") as f:
        header = f.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("%s is not a PNG file" % path)
    return struct.unpack(">II", header[16:24])


def render(executable, out, *extra):
    result = subprocess.run([ executable, PACKAGE, "-o", out, *extra ], capture_output=True, text=True)
    print(result.stdout.strip())
    if result.returncode != 0:
        print(result.stderr)
        sys.exit("mmr_render failed")


def main():
    executable = os.path.abspath(sys.argv[1])
    failures = []
    with tempfile.TemporaryDirectory() as base:
        default = os.path.join(base, "default")
        seeded = os.path.join(base, "seed3")
        half = os.path.join(base, "half")
        render(executable, default)
        render(executable, seeded, "--set", "seed=3")
        render(executable, half, "--size", "128")
        for o in OUTPUTS:
            path = os.path.join(default, o + ".png")
            if not os.path.exists(path):
                failures.append("no %s output" % o)
            elif png_size(path) != (256, 256):
                failures.append("%s is %s, not 256x256" % (o, png_size(path)))
            half_path = os.path.join(half, o + ".png")
            if not os.path.exists(half_path) or png_size(half_path) != (128, 128):
                failures.append("--size 128: %s is missing or not 128x128" % o)
        with open(os.path.join(default, "albedo.png"), "rb") as a, open(os.path.join(seeded, "albedo.png"), "rb") as b:
            if a.read() == b.read():
                failures.append("the seed does not change the albedo")
    for f in failures:
        print("FAIL", f)
    print("OK" if not failures else "FAILED")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
