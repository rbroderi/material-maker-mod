"""Tests of mm-cook, with fake Material Maker and mmr_render commands (and
EXR files rendered by Material Maker and mmr_render in data/)

    python -m pytest python/tests
"""

import inspect
import json
import os
import struct
import subprocess
import sys
import zlib

import pytest

PYTHON_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, PYTHON_DIR)

import mm_cook  # noqa: E402

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")


def write_exr(path, width, height, channels, compression=0):
    """Writes a scanline EXR file, channels is { name: (pixel type, values) }
    (pixel type 1: half, 2: float, values are raw bits)"""
    names = sorted(channels)
    header = b""

    def attribute(name, kind, value):
        return name.encode() + b"\0" + kind.encode() + b"\0" + struct.pack("<i", len(value)) + value
    channel_list = b"".join(n.encode() + b"\0" + struct.pack("<iiii", channels[n][0], 0, 1, 1) for n in names) + b"\0"
    header += attribute("channels", "chlist", channel_list)
    header += attribute("compression", "compression", bytes([ compression ]))
    window = struct.pack("<iiii", 0, 0, width - 1, height - 1)
    header += attribute("dataWindow", "box2i", window)
    header += attribute("displayWindow", "box2i", window)
    header += attribute("lineOrder", "lineOrder", b"\0")
    header += attribute("pixelAspectRatio", "float", struct.pack("<f", 1))
    header += attribute("screenWindowCenter", "v2f", struct.pack("<ff", 0, 0))
    header += attribute("screenWindowWidth", "float", struct.pack("<f", 1))
    lines_per_block = { 0: 1, 2: 1, 3: 16 }[compression]
    blocks = []
    for y in range(0, height, lines_per_block):
        data = b""
        for line in range(y, min(height, y + lines_per_block)):
            for n in names:
                pixel_type, values = channels[n]
                data += struct.pack("<%d%s" % (width, "H" if pixel_type == 1 else "I"), *values[line * width:(line + 1) * width])
        if compression:
            # Interleaving and predictor, then zlib
            t = bytearray(data[0::2] + data[1::2])
            p = t[0]
            for i in range(1, len(t)):
                d = (t[i] - p + 128 + 256) & 0xFF
                p = t[i]
                t[i] = d
            compressed = zlib.compress(bytes(t))
            if len(compressed) < len(data):
                data = compressed
        blocks.append(struct.pack("<ii", y, len(data)) + data)
    start = 8 + len(header) + 1 + 8 * len(blocks)
    offsets = []
    for b in blocks:
        offsets.append(start)
        start += len(b)
    with open(path, "wb") as f:
        f.write(struct.pack("<II", 20000630, 2) + header + b"\0")
        f.write(struct.pack("<%dQ" % len(offsets), *offsets))
        f.write(b"".join(blocks))


def float_bits(value):
    return struct.unpack("<I", struct.pack("<f", value))[0]


# EXR files


def test_exr_round_trip(tmp_path):
    values = [ float_bits(i / 7.0) for i in range(12 * 5) ]
    for compression in (0, 2, 3):
        path = str(tmp_path / ("c%d.exr" % compression))
        write_exr(path, 12, 5, { "R": (2, values), "A": (1, [ 0x3C00 ] * 60) }, compression)
        width, height, channels = mm_cook.read_exr(path)
        assert (width, height) == (12, 5)
        assert channels["R"] == (2, values)
        assert channels["A"] == (1, [ 0x3C00 ] * 60)


def test_half_conversions():
    assert mm_cook.half_to_float_bits(0x3C00) == float_bits(1.0)
    assert mm_cook.half_to_float_bits(0xC000) == float_bits(-2.0)
    assert mm_cook.float_bits_to_half(float_bits(1.0)) == 0x3C00
    assert mm_cook.float_bits_to_half(float_bits(0.1)) == 0x2E66  # (truncated)
    assert mm_cook.float_bits_to_half(float_bits(1e-6)) == 0  # (half subnormal)
    assert mm_cook.float_bits_to_half(float_bits(1e9)) == 0x7C00
    for h in range(0x0400, 0x7C00, 37):
        assert mm_cook.float_bits_to_half(mm_cook.half_to_float_bits(h)) == h


def test_compare_material_maker_render():
    # bricks rendered at 32x32 by Material Maker (--render, half floats, PIZ)
    # and mmr_render (--exr, floats, ZIP)
    for channel, output in (("albedo", 0), ("normal", 3)):
        mine = os.path.join(DATA, "bricks32_%s.exr" % channel)
        reference = os.path.join(DATA, "bricks32_Material_%d.exr" % output)
        assert os.path.getsize(reference) < 32 * 32 * 4 * 2  # (compressed)
        assert mm_cook.read_exr(reference)[2]["R"][0] == 1
        assert mm_cook.read_exr(mine)[2]["R"][0] == 2
        assert mm_cook.compare_exr(mine, reference) == ""
    assert "values differ" in mm_cook.compare_exr(os.path.join(DATA, "bricks32_albedo.exr"), os.path.join(DATA, "bricks32_Material_3.exr"))


def test_compare(tmp_path):
    n = 4 * 4
    a, b, c = (str(tmp_path / f) for f in ("a.exr", "b.exr", "c.exr"))
    write_exr(a, 4, 4, { "R": (2, [ float_bits(0.1) ] * n) })
    # Single channel R: G and B are 0 and alpha is 1, as when Godot loads it
    write_exr(b, 4, 4, { "R": (1, [ 0x2E66 ] * n), "G": (1, [ 0 ] * n), "B": (1, [ 0 ] * n), "A": (1, [ 0x3C00 ] * n) })
    assert mm_cook.compare_exr(a, b) == ""
    write_exr(c, 4, 4, { "R": (1, [ 0x2E67 ] * n) })
    assert mm_cook.compare_exr(a, c) == "16/64 values differ"
    write_exr(c, 2, 2, { "R": (1, [ 0x2E66 ] * 4) })
    assert mm_cook.compare_exr(a, c).startswith("different size")


# Cooking with fake Material Maker and mmr_render commands

FAKE_MM = r'''
args = sys.argv[1:]
with open(os.environ["FAKE_MM_LOG"], "a") as f:
    f.write(" ".join(a if not a.endswith(".ptex") else os.path.basename(a) for a in args) + "\n")
if args == [ "--", "--help" ]:
    print("Godot Engine v4.7.2.fake\nMaterial Maker command line\n" + ("" if os.environ.get("FAKE_MM_NO_MMR") else "  material_maker --export-mmr [options] <files>"))
    sys.exit(0)
def option(name):
    return args[args.index(name) + 1]
graph = json.load(open(args[-1])) if args[-1].endswith(".ptex") and "BROKEN" not in open(args[-1]).read() else None
if graph is None:
    print("ERROR: cannot load " + args[-1])
    sys.exit(0)
if graph.get("hang"):
    time.sleep(60)
size = int(option("--size")) or 8
value = graph["value"]
if "--export-mmr" in args:
    path = os.path.join(option("-o"), os.path.splitext(os.path.basename(args[-1]))[0] + ".mmr")
    with zipfile.ZipFile(path, "w") as z:
        z.writestr("manifest.json", json.dumps({ "format": "mmr", "version": graph.get("version", 1), "value": value,
            "outputs": { "albedo": "p0", "height": "p1" }, "passes": [ { "name": "p0", "size": [ size, size ] }, { "name": "p1", "size": [ size, size ] } ] }))
    print("Exported " + path)
elif "--render" in args:
    os.makedirs(option("-o"), exist_ok=True)
    channel = int(option("--node").split(":")[1])
    n = size * size
    # half floats, PIZ in Material Maker
    write_exr(os.path.join(option("-o"), "x_Material_%d.exr" % channel), size, size,
              { c: (1, [ 0x3C00 if c == "A" else 0x3800 if channel == 0 else 0x3400 if c == "R" else 0 ] * n) for c in "RGBA" })
'''

FAKE_RENDER = r'''
args = sys.argv[1:]
manifest = json.loads(zipfile.ZipFile(args[0]).read("manifest.json"))
out = args[args.index("-o") + 1]
os.makedirs(out, exist_ok=True)
size = manifest["passes"][0]["size"][0]
n = size * size
for channel in manifest["outputs"]:
    v = float_bits(manifest["value"] if channel == "albedo" else 0.25)
    channels = { "R": (2, [ v ] * n) } if channel == "height" else { c: (2, [ float_bits(1.0) if c == "A" else v ] * n) for c in "RGBA" }
    write_exr(os.path.join(out, channel + ".exr"), size, size, channels, 3)
print("ok")
'''


@pytest.fixture
def fake(tmp_path, monkeypatch):
    # (the fake commands write EXR files with write_exr)
    header = "import json, os, struct, sys, time, zipfile, zlib\n" + inspect.getsource(write_exr) + inspect.getsource(float_bits)
    for name, source in (("fake_mm.py", FAKE_MM), ("fake_render.py", FAKE_RENDER)):
        (tmp_path / name).write_text(header + source)
    log = tmp_path / "mm.log"
    monkeypatch.setenv("FAKE_MM_LOG", str(log))
    monkeypatch.setenv("PYTHONDONTWRITEBYTECODE", "1")
    graphs = tmp_path / "graphs"
    (graphs / "sub").mkdir(parents=True)
    for name, value in (("a", 0.5), ("b", 0.5), ("sub/c", 0.5)):
        (graphs / (name + ".ptex")).write_text(json.dumps({ "value": value }))
    # mmr_render is called with the package only: the fake one is a .cmd/.sh wrapper
    if os.name == "nt":
        render = tmp_path / "fake_render.cmd"
        render.write_text('@"%s" "%s" %%*\n' % (sys.executable, tmp_path / "fake_render.py"))
    else:
        render = tmp_path / "fake_render.sh"
        render.write_text('#!/bin/sh\nexec "%s" "%s" "$@"\n' % (sys.executable, tmp_path / "fake_render.py"))
        render.chmod(0o755)

    class Fake:
        root = tmp_path
        mmr_render = str(render)

        def cook(self, *args):
            log.write_text("")
            report = tmp_path / "report.json"
            code = mm_cook.main([ "--mm", '"%s" "%s"' % (sys.executable, tmp_path / "fake_mm.py"),
                                  "-o", str(tmp_path / "out"), "--report", str(report) ] + list(args))
            calls = [ l for l in log.read_text().splitlines() if l and l != "-- --help" ]
            return code, json.loads(report.read_text()) if report.exists() else None, calls
    return Fake()


def statuses(report):
    return { os.path.basename(p["package"]): p["status"] for p in report["packages"] }


def test_incremental(fake):
    graphs = str(fake.root / "graphs")
    code, report, calls = fake.cook(graphs, "--jobs", "2")
    assert code == 0 and len(calls) == 3
    assert statuses(report) == { "a.mmr": "cooked", "b.mmr": "cooked", "c.mmr": "cooked" }
    assert os.path.isfile(fake.root / "out" / "sub" / "c.mmr")
    assert report["summary"] == { "cooked": 3, "up to date": 0, "error": 0 }
    code, report, calls = fake.cook(graphs, "--jobs", "2")
    assert code == 0 and calls == [] and set(statuses(report).values()) == { "up to date" }
    # Only changed graphs are cooked again, and all of them with other options
    (fake.root / "graphs" / "b.ptex").write_text(json.dumps({ "value": 0.75 }))
    code, report, calls = fake.cook(graphs)
    assert calls == [ "--export-mmr -o %s --size 0 b.ptex" % calls[0].split()[2] ]
    assert statuses(report)["b.mmr"] == "cooked"
    code, report, calls = fake.cook(graphs, "--size", "16")
    assert len(calls) == 3
    code, report, calls = fake.cook(graphs, "--size", "16", "--force")
    assert len(calls) == 3
    # A deleted package is cooked again
    os.remove(fake.root / "out" / "a.mmr")
    code, report, calls = fake.cook(graphs, "--size", "16")
    assert statuses(report) == { "a.mmr": "cooked", "b.mmr": "up to date", "c.mmr": "up to date" }


def test_used_files(fake):
    image = fake.root / "graphs" / "image.png"
    image.write_bytes(b"1")
    (fake.root / "graphs" / "a.ptex").write_text(json.dumps({ "value": 0.5, "nodes": [ { "parameters": { "image": "image.png" } } ] }))
    assert mm_cook.used_files(str(fake.root / "graphs" / "a.ptex")) == [ str(image) ]
    fake.cook(str(fake.root / "graphs"))
    image.write_bytes(b"2")
    code, report, calls = fake.cook(str(fake.root / "graphs"))
    assert len(calls) == 1 and statuses(report)["a.mmr"] == "cooked"


def test_errors(fake):
    graphs = str(fake.root / "graphs")
    assert fake.cook(graphs)[0] == 0
    (fake.root / "graphs" / "a.ptex").write_text("BROKEN")
    (fake.root / "graphs" / "d.ptex").write_text(json.dumps({ "value": 0.5, "hang": True }))
    (fake.root / "graphs" / "e.ptex").write_text(json.dumps({ "value": 0.5 }))
    code, report, calls = fake.cook(graphs, "--jobs", "2", "--timeout", "5")
    assert code == 1
    assert statuses(report) == { "a.mmr": "error", "b.mmr": "up to date", "c.mmr": "up to date", "d.mmr": "error", "e.mmr": "cooked" }
    errors = { os.path.basename(p["package"]): p.get("error") for p in report["packages"] }
    assert errors["a.mmr"].startswith("export failed: ERROR: cannot load")
    assert errors["d.mmr"] == "export timed out after 5 s"
    assert report["summary"] == { "cooked": 1, "up to date": 2, "error": 2 }
    # The previous package is kept, and cooked again when the graph is fixed
    assert os.path.isfile(fake.root / "out" / "a.mmr")
    (fake.root / "graphs" / "a.ptex").write_text(json.dumps({ "value": 0.5 }))
    os.remove(fake.root / "graphs" / "d.ptex")
    code, report, calls = fake.cook(graphs)
    assert code == 0 and statuses(report)["a.mmr"] == "cooked" and len(calls) == 1
    assert not [ f for f in os.listdir(fake.root / "out") if f.startswith(".mm_cook_") ]


def test_verify(fake):
    graphs = str(fake.root / "graphs")
    code, report, calls = fake.cook(graphs, "--verify", fake.mmr_render, "--size", "4")
    assert code == 0, report
    assert all(p["verified"] and p["channels"] == { "albedo": "identical", "height": "identical" } for p in report["packages"])
    assert len(calls) == 3 * 3
    # Verified packages are not verified again
    code, report, calls = fake.cook(graphs, "--verify", fake.mmr_render, "--size", "4")
    assert code == 0 and calls == [] and all(p["verified"] for p in report["packages"])
    # A package whose renders differ from Material Maker's
    (fake.root / "graphs" / "b.ptex").write_text(json.dumps({ "value": 0.75 }))
    code, report, calls = fake.cook(graphs, "--verify", fake.mmr_render, "--size", "4")
    assert code == 1
    b = [ p for p in report["packages"] if p["package"].endswith("b.mmr") ][0]
    assert b["status"] == "error" and not b["verified"]
    assert b["error"] == "verification failed: albedo: 48/64 values differ"
    assert b["channels"] == { "albedo": "48/64 values differ", "height": "identical" }
    # ... is cooked and verified again on the next run
    code, report, calls = fake.cook(graphs, "--verify", fake.mmr_render, "--size", "4")
    assert code == 1 and len(calls) == 3
    # Packages of a later format version are cooked, but not verified
    (fake.root / "graphs" / "b.ptex").write_text(json.dumps({ "value": 0.5, "version": 2 }))
    code, report, calls = fake.cook(graphs)
    assert code == 0 and statuses(report)["b.mmr"] == "cooked"
    code, report, calls = fake.cook(graphs, "--verify", fake.mmr_render)
    assert code == 1 and statuses(report)["b.mmr"] == "error"
    assert report["packages"][1]["error"] == "verification failed: invalid package: unsupported package version 2"


def test_usage_errors(fake, tmp_path, capsys):
    graphs = str(fake.root / "graphs")
    assert fake.cook(str(tmp_path / "nothing"))[0] == 2
    assert fake.cook(graphs, "--verify", str(tmp_path / "no_mmr_render"))[0] == 2
    assert mm_cook.main([ "--mm", str(tmp_path / "no_mm"), graphs ]) == 2
    with pytest.raises(SystemExit) as e:
        mm_cook.main([ "--jobs", "0", graphs ])
    assert e.value.code == 2
    with pytest.raises(SystemExit):
        mm_cook.main([ "--size", "-1", graphs ])
    # Two graphs that would be cooked into the same package
    other = tmp_path / "other"
    other.mkdir()
    (other / "a.ptex").write_text(json.dumps({ "value": 0.5 }))
    assert fake.cook(str(fake.root / "graphs" / "a.ptex"), str(other / "a.ptex"))[0] == 2
    assert "same package" in capsys.readouterr().err
    # Material Maker without the Runtime export plugin
    os.environ["FAKE_MM_NO_MMR"] = "1"
    try:
        assert fake.cook(graphs)[0] == 2
    finally:
        del os.environ["FAKE_MM_NO_MMR"]
    assert "enable the Runtime export plugin" in capsys.readouterr().err


def test_command_line(fake):
    # The script runs as a command (exit code 2 without Material Maker)
    env = dict(os.environ, MATERIAL_MAKER="", PATH="")
    result = subprocess.run([ sys.executable, os.path.join(PYTHON_DIR, "mm_cook.py"), str(fake.root / "graphs") ],
                            capture_output=True, text=True, env=env, cwd=str(fake.root))
    assert result.returncode == 2 and "Material Maker was not found" in result.stderr

def test_sizes():
    # --size is a size in pixels (0: the Material node's), or <width>x<height>
    assert all(mm_cook.valid_size(s) for s in [ "0", "512", "512x256" ])
    assert not any(mm_cook.valid_size(s) for s in [ "-1", "x", "512x", "0x256", "512x256x2", "a" ])
    manifest = { "outputs": { "albedo": "p0", "normal": "p1" },
                 "passes": [ { "name": "p0", "size": [ 512, 256 ] }, { "name": "p1", "size": [ 64, 64 ] } ] }
    assert mm_cook.output_size(manifest, "albedo") == "512x256"
    assert mm_cook.output_size(manifest, "normal") == "64"
