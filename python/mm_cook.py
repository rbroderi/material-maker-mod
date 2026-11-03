"""mm-cook: cooks Material Maker graphs (.ptex) into runtime packages (.mmr).

    python python/mm_cook.py [options] <inputs...>

Inputs are .ptex files, directories (searched recursively) or wildcards.
Packages are written to the output directory, with the same relative paths
for the graphs found in directories. Cooking is incremental: a package is
cooked again only when its graph (or a file it uses, such as an image), the
cooking options or Material Maker changed (the state is kept in
<output>/.mm_cook.json), unless --force is used.

Each graph is cooked by its own Material Maker process (with --export-mmr),
so a graph that fails or hangs does not stop the others (its previous
package, if any, is kept, and it is cooked again on the next run). Verified
packages are only verified again when they are cooked again.

Options:
  --mm <command>       Material Maker command (default: the MATERIAL_MAKER
                       environment variable, or material_maker in the PATH),
                       for example "godot --path ." in a source checkout
  -o, --output <dir>   output directory (default: cooked)
  --size <size>        size of the outputs in pixels (default: 0, the size
                       of the Material node)
  --jobs <n>           number of graphs cooked at the same time (default: 1)
  --force              cook (and verify) all packages
  --verify <mmr_render>  renders each package with mmr_render (the C++
                       runtime) and checks that its outputs are identical to
                       Material Maker's renders of the graph (as EXR files)
  --report <file>      writes a JSON report (packages, status, times)
  --timeout <seconds>  time limit of each Material Maker or mmr_render
                       process (default: 600)

Exit code: 0 if all packages were cooked (and verified), 1 if some were not,
2 for incorrect options (or if Material Maker or mmr_render are not found).
"""

import argparse
import concurrent.futures
import glob
import hashlib
import json
import os
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zipfile
import zlib

from material_maker_client import find_command

STATE_FILE = ".mm_cook.json"
# Material node outputs of the package channels (for --render --node Material:<n>)
CHANNEL_OUTPUTS = { "albedo": 0, "orm": 1, "emission": 2, "normal": 3, "height": 8 }
# Package format versions this version of mm-cook can verify
PACKAGE_VERSION = 1
# Godot errors that don't mean the export failed
GODOT_NOISE = ("Steam", "leaked", "still in use", "Pages in use", ".mtl")


class UsageError(Exception):
    pass


# Processes


def run(args, timeout):
    """Runs a command, returns (exit code, output). The exit code is None if
    the command timed out (it is then killed with its child processes)."""
    if os.name == "nt":
        kwargs = { "creationflags": subprocess.CREATE_NEW_PROCESS_GROUP }
    else:
        kwargs = { "start_new_session": True }
    try:
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, **kwargs)
    except OSError as e:
        return -1, str(e)
    try:
        output, _ = process.communicate(timeout=timeout)
        return process.returncode, output.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        kill_tree(process)
        try:
            output, _ = process.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            output = b""
        return None, output.decode("utf-8", "replace")


def kill_tree(process):
    # (godot_console and launchers start the real executable as a child)
    if os.name == "nt":
        subprocess.run([ "taskkill", "/F", "/T", "/PID", str(process.pid) ], capture_output=True)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
    process.kill()


def errors_of(output):
    """Error lines of Material Maker's output, without Godot's noise"""
    return [ l.strip() for l in output.splitlines() if l.startswith("ERROR: ") and not any(n in l for n in GODOT_NOISE) ]


def failure(what, code, output, timeout):
    if code is None:
        return "%s timed out after %d s" % (what, timeout)
    errors = errors_of(output)
    if not errors and code != 0:
        errors = [ l.strip() for l in output.strip().splitlines()[-2:] ]
    return what + " failed" + (": " + "; ".join(errors[:3]) if errors else "")


# Inputs and state


def find_inputs(inputs):
    """(file, relative path) for each .ptex file of the inputs"""
    found = []
    for i in inputs:
        if os.path.isdir(i):
            for root, dirs, files in os.walk(i):
                dirs.sort()
                for f in sorted(files):
                    if f.endswith(".ptex"):
                        path = os.path.join(root, f)
                        found.append((os.path.abspath(path), os.path.relpath(path, i)))
        else:
            matches = sorted(glob.glob(i)) if any(c in i for c in "*?[") else [ i ]
            if not matches:
                print("warning: nothing matches %s" % i, file=sys.stderr)
            for m in matches:
                if m.endswith(".ptex") and os.path.isfile(m):
                    found.append((os.path.abspath(m), os.path.basename(m)))
                elif not os.path.isdir(m):
                    print("warning: %s %s" % (m, "is not a .ptex file" if os.path.exists(m) else "was not found"), file=sys.stderr)
    return found


def used_files(path):
    """The files a graph refers to (images, meshes...), that change its package"""
    try:
        with open(path, encoding="utf-8") as f:
            graph = json.load(f)
    except (OSError, ValueError):
        return []
    files = set()
    base = os.path.dirname(path)

    def walk(value):
        if isinstance(value, dict):
            for v in value.values():
                walk(v)
        elif isinstance(value, list):
            for v in value:
                walk(v)
        elif isinstance(value, str) and 0 < len(value) < 1024 and "." in value and "\n" not in value:
            for candidate in (value, os.path.join(base, value)):
                if os.path.isfile(candidate):
                    files.add(os.path.abspath(candidate))
                    break
    walk(graph)
    return sorted(files)


def fingerprint(path, options, version):
    h = hashlib.sha256()
    for f in [ path ] + used_files(path):
        h.update(f.encode() if f != path else b"")
        with open(f, "rb") as file:
            h.update(file.read())
    h.update(json.dumps(options, sort_keys=True).encode())
    h.update(version.encode())
    return h.hexdigest()


def file_identity(path):
    try:
        stat = os.stat(path)
        return "%s:%d:%d" % (os.path.abspath(path), stat.st_size, int(stat.st_mtime))
    except OSError:
        return path


def mm_identity(command, help_text):
    """(description, identity) of the version of Material Maker: Godot's
    version, the help (with the modes of the plugins), the executable (and its
    .pck file), or project.godot and the runtime export plugin for a source
    checkout ("godot --path <dir>")"""
    lines = [ l.strip() for l in help_text.splitlines() if l.startswith("Godot Engine") ]
    h = hashlib.sha256(help_text[help_text.find("Material Maker command line"):].encode())
    executable = shutil.which(command[0]) or command[0]
    files = [ executable, os.path.splitext(executable)[0] + ".pck" ]
    for f in files:
        h.update(file_identity(f).encode())
    if "--path" in command[:-1]:
        project = command[command.index("--path") + 1]
        files = [ os.path.join(project, "project.godot") ]
        files += sorted(glob.glob(os.path.join(project, "material_maker", "plugins", "runtime_export", "*.gd")))
        for f in files:
            if os.path.isfile(f):
                with open(f, "rb") as file:
                    h.update(file.read())
    return (lines[0] if lines else " ".join(command)), h.hexdigest()


def load_state(path):
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            state = json.load(f)
        if isinstance(state, dict):
            return { k: v for k, v in state.items() if isinstance(v, dict) }
    except (OSError, ValueError):
        pass
    print("warning: %s is invalid, all packages are cooked" % path, file=sys.stderr)
    return {}


def save_state(path, state):
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(temporary, path)


# EXR files (as written by Material Maker, i.e. Godot, and mmr_render)


def read_exr(path):
    """Reads a scanline EXR file (uncompressed, ZIP, ZIPS or PIZ), returns
    (width, height, { channel: (pixel type, values) }), where values are the
    raw bits (16 bits for half floats, 32 bits for floats) of each pixel"""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 8 or struct.unpack_from("<I", data, 0)[0] != 20000630:
        raise ValueError("not an EXR file")
    if struct.unpack_from("<I", data, 4)[0] & 0x1600:
        raise ValueError("tiled, deep or multipart EXR files are not supported")
    pos = 8
    attributes = {}
    while data[pos] != 0:
        end = data.index(b"\0", pos)
        name = data[pos:end].decode()
        end2 = data.index(b"\0", end + 1)
        size = struct.unpack_from("<i", data, end2 + 1)[0]
        attributes[name] = data[end2 + 5:end2 + 5 + size]
        pos = end2 + 5 + size
    pos += 1
    channels = []
    raw = attributes["channels"]
    i = 0
    while raw[i] != 0:
        end = raw.index(b"\0", i)
        pixel_type, _linear, x_sampling, y_sampling = struct.unpack_from("<iiii", raw, end + 1)
        if pixel_type not in (1, 2) or x_sampling != 1 or y_sampling != 1:
            raise ValueError("unsupported channel " + raw[i:end].decode())
        channels.append((raw[i:end].decode(), pixel_type))
        i = end + 17
    compression = attributes["compression"][0]
    lines_per_block = { 0: 1, 2: 1, 3: 16, 4: 32 }.get(compression)
    if lines_per_block is None:
        raise ValueError("unsupported EXR compression %d" % compression)
    x0, y0, x1, y1 = struct.unpack("<iiii", attributes["dataWindow"])
    width, height = x1 - x0 + 1, y1 - y0 + 1
    sizes = [ 2 if t == 1 else 4 for _, t in channels ]
    line_size = width * sum(sizes)
    blocks = (height + lines_per_block - 1) // lines_per_block
    offsets = struct.unpack_from("<%dQ" % blocks, data, pos)
    pixels = bytearray(line_size * height)
    for offset in offsets:
        y, size = struct.unpack_from("<ii", data, offset)
        lines = min(lines_per_block, y1 + 1 - y)
        block = data[offset + 8:offset + 8 + size]
        expected = line_size * lines
        if size < expected:
            if compression in (2, 3):
                block = unzip_block(block)
            elif compression == 4:
                block = unpiz_block(block, expected, width, lines, sizes)
        if len(block) != expected:
            raise ValueError("invalid EXR block at line %d" % y)
        start = (y - y0) * line_size
        pixels[start:start + expected] = block
    result = {}
    view = memoryview(pixels)
    offset = 0
    for (name, pixel_type), size in zip(channels, sizes):
        values = []
        fmt = "<%d%s" % (width, "H" if size == 2 else "I")
        for y in range(height):
            values.extend(struct.unpack_from(fmt, view, y * line_size + offset))
        result[name] = (pixel_type, values)
        offset += width * size
    return width, height, result


def unzip_block(block):
    t = bytearray(zlib.decompress(block))
    for i in range(1, len(t)):
        t[i] = (t[i - 1] + t[i] - 128) & 0xFF
    out = bytearray(len(t))
    half = (len(t) + 1) // 2
    out[0::2] = t[:half]
    out[1::2] = t[half:]
    return bytes(out)


HUF_DECBITS = 14
HUF_ENCSIZE = (1 << 16) + 1


def unpiz_block(block, expected, width, lines, sizes):
    """Decompresses a PIZ block (OpenEXR's wavelet and Huffman compression)"""
    minimum, maximum = struct.unpack_from("<HH", block, 0)
    pos = 4
    bitmap = bytearray(8192)
    if maximum >= 8192:
        raise ValueError("invalid PIZ bitmap")
    if minimum <= maximum:
        bitmap[minimum:maximum + 1] = block[pos:pos + maximum - minimum + 1]
        pos += maximum - minimum + 1
    lut = [ 0 ] + [ i for i in range(max(1, minimum * 8), (maximum + 1) * 8) if bitmap[i >> 3] & (1 << (i & 7)) ]
    max_value = len(lut) - 1
    length = struct.unpack_from("<i", block, pos)[0]
    pos += 4
    values = huffman_decode(block[pos:pos + length], expected // 2)
    # Each channel is a width x lines x (size / 2) block of 16 bit values
    start = 0
    starts = []
    for size in sizes:
        starts.append(start)
        words = size // 2
        for j in range(words):
            wavelet_decode(values, start + j, width, words, lines, width * words, max_value)
        start += width * lines * words
    values = [ lut[v] for v in values ]
    out = []
    for y in range(lines):
        for c, size in enumerate(sizes):
            n = width * size // 2
            s = starts[c] + y * n
            out.extend(values[s:s + n])
    return struct.pack("<%dH" % len(out), *out)


def huffman_decode(data, count):
    if len(data) < 20:
        raise ValueError("invalid PIZ data")
    im, iM, _table_length, n_bits = struct.unpack_from("<IIII", data, 0)
    if im >= HUF_ENCSIZE or iM >= HUF_ENCSIZE:
        raise ValueError("invalid PIZ Huffman table")
    # Code lengths (run-length coded), then canonical codes
    lengths = [ 0 ] * HUF_ENCSIZE
    pos = 20
    c = 0
    lc = 0
    i = im
    while i <= iM:
        while lc < 6:
            c = (c << 8) | data[pos]
            pos += 1
            lc += 8
        lc -= 6
        l = (c >> lc) & 63
        c &= (1 << lc) - 1
        if l == 63:
            while lc < 8:
                c = (c << 8) | data[pos]
                pos += 1
                lc += 8
            lc -= 8
            run = ((c >> lc) & 0xFF) + 6
            c &= (1 << lc) - 1
            if i + run > iM + 1:
                raise ValueError("invalid PIZ Huffman table")
            i += run
            continue
        if l >= 59:
            run = l - 59 + 2
            if i + run > iM + 1:
                raise ValueError("invalid PIZ Huffman table")
            i += run
            continue
        lengths[i] = l
        i += 1
    counts = [ 0 ] * 59
    for l in lengths[im:iM + 1]:
        counts[l] += 1
    code = 0
    for l in range(58, 0, -1):
        next_code = (code + counts[l]) >> 1
        counts[l] = code
        code = next_code
    codes = [ 0 ] * HUF_ENCSIZE
    for s in range(im, iM + 1):
        l = lengths[s]
        if l > 0:
            codes[s] = counts[l]
            counts[l] += 1
    # Decoding table: short codes (<= 14 bits) fill all their entries, long
    # codes are listed in the entry of their first 14 bits
    short_length = [ 0 ] * (1 << HUF_DECBITS)
    short_symbol = [ 0 ] * (1 << HUF_DECBITS)
    long_symbols = {}
    for s in range(im, iM + 1):
        l = lengths[s]
        if l == 0:
            continue
        code = codes[s]
        if code >> l:
            raise ValueError("invalid PIZ Huffman code")
        if l > HUF_DECBITS:
            long_symbols.setdefault(code >> (l - HUF_DECBITS), []).append(s)
        else:
            first = code << (HUF_DECBITS - l)
            for e in range(first, first + (1 << (HUF_DECBITS - l))):
                if short_length[e]:
                    raise ValueError("invalid PIZ Huffman code")
                short_length[e] = l
                short_symbol[e] = s
    # Decoding (iM is the run-length code: the previous value repeated)
    out = []
    append = out.append
    data_end = pos + (n_bits + 7) // 8
    if data_end > len(data):
        raise ValueError("truncated PIZ data")
    c = 0
    lc = 0
    mask = (1 << HUF_DECBITS) - 1

    def emit(symbol):
        nonlocal c, lc, pos
        if symbol == iM:
            if lc < 8:
                c = (c << 8) | data[pos]
                pos += 1
                lc += 8
            lc -= 8
            repeat = (c >> lc) & 0xFF
            if not out or len(out) + repeat > count:
                raise ValueError("invalid PIZ run")
            out.extend([ out[-1] ] * repeat)
        else:
            append(symbol)

    while pos < data_end:
        c = ((c << 8) | data[pos]) & 0xFFFFFFFFFFFFFFFF
        pos += 1
        lc += 8
        while lc >= HUF_DECBITS:
            e = (c >> (lc - HUF_DECBITS)) & mask
            l = short_length[e]
            if l:
                lc -= l
                emit(short_symbol[e])
            else:
                for s in long_symbols.get(e, ()):
                    l = lengths[s]
                    while lc < l and pos < data_end:
                        c = ((c << 8) | data[pos]) & 0xFFFFFFFFFFFFFFFF
                        pos += 1
                        lc += 8
                    if lc >= l and codes[s] == (c >> (lc - l)) & ((1 << l) - 1):
                        lc -= l
                        emit(s)
                        break
                else:
                    raise ValueError("invalid PIZ Huffman code")
            if len(out) > count:
                raise ValueError("invalid PIZ data")
    skip = (8 - n_bits) & 7
    c >>= skip
    lc -= skip
    while lc > 0:
        e = (c << (HUF_DECBITS - lc)) & mask
        l = short_length[e]
        if not l or l > lc:
            raise ValueError("invalid PIZ Huffman code")
        lc -= l
        emit(short_symbol[e])
    if len(out) != count:
        raise ValueError("invalid PIZ data size")
    return out


def wavelet_decode(v, start, nx, ox, ny, oy, max_value):
    """OpenEXR's 2D Haar wavelet decoding, in place"""
    w14 = max_value < (1 << 14)

    def dec(l, h):
        if w14:
            ls = l - 0x10000 if l & 0x8000 else l
            hs = h - 0x10000 if h & 0x8000 else h
            a = ls + (hs & 1) + (hs >> 1)
            return a & 0xFFFF, (a - hs) & 0xFFFF
        b = (l - (h >> 1)) & 0xFFFF
        return (h + b - 0x8000) & 0xFFFF, b

    n = min(nx, ny)
    p = 1
    while p <= n:
        p <<= 1
    p >>= 1
    p2 = p
    p >>= 1
    while p >= 1:
        oy1, oy2, ox1, ox2 = oy * p, oy * p2, ox * p, ox * p2
        ey = start + oy * (ny - p2)
        py = start
        while py <= ey:
            ex = py + ox * (nx - p2)
            px = py
            while px <= ex:
                p01 = px + ox1
                p10 = px + oy1
                p11 = p10 + ox1
                i00, i10 = dec(v[px], v[p10])
                i01, i11 = dec(v[p01], v[p11])
                v[px], v[p01] = dec(i00, i01)
                v[p10], v[p11] = dec(i10, i11)
                px += ox2
            if nx & p:
                p10 = px + oy1
                v[px], v[p10] = dec(v[px], v[p10])
            py += oy2
        if ny & p:
            ex = py + ox * (nx - p2)
            px = py
            while px <= ex:
                p01 = px + ox1
                v[px], v[p01] = dec(v[px], v[p01])
                px += ox2
        p2 = p
        p >>= 1


def half_to_float_bits(h):
    sign = (h & 0x8000) << 16
    exponent = (h >> 10) & 0x1F
    mantissa = h & 0x3FF
    if exponent == 0:
        if mantissa == 0:
            return sign
        exponent = 127 - 15 + 1
        while not mantissa & 0x400:
            mantissa <<= 1
            exponent -= 1
        return sign | (exponent << 23) | ((mantissa & 0x3FF) << 13)
    if exponent == 31:
        return sign | 0x7F800000 | (mantissa << 13)
    return sign | ((exponent - 15 + 127) << 23) | (mantissa << 13)


def float_bits_to_half(x):
    """Godot's conversion of floats to half floats when it writes EXR files
    (mantissa truncated, half subnormals flushed to 0)"""
    sign = x >> 31
    mantissa = x & 0x7FFFFF
    exponent = x & 0x7F800000
    if exponent >= 0x47800000:
        if mantissa and exponent == 0x7F800000:
            return (sign << 15) | 0x7C00 | (mantissa >> 13)
        return (sign << 15) | 0x7C00
    if exponent <= 0x38000000:
        return 0
    return (sign << 15) | (((exponent >> 23) - 112) << 10) | (mantissa >> 13)


def exr_rgba(path):
    """(width, height, { "R", "G", "B", "A": float bits, half flag }) of an EXR
    file as Godot loads it (missing color channels are 0, alpha is 1, Y is grey)"""
    width, height, channels = read_exr(path)
    if "Y" in channels and "R" not in channels:
        channels["R"] = channels["G"] = channels["B"] = channels["Y"]
    n = width * height
    rgba = {}
    for name, default in (("R", 0), ("G", 0), ("B", 0), ("A", 0x3F800000)):
        pixel_type, values = channels.get(name, (2, [ default ] * n))
        rgba[name] = ([ half_to_float_bits(v) for v in values ] if pixel_type == 1 else values, pixel_type == 1)
    return width, height, rgba


def compare_exr(mine, reference):
    """Compares two EXR files bit for bit (if they differ, after Godot's EXR
    round trip on both sides). Returns "" if they are identical, else a
    description of the difference."""
    w1, h1, a = exr_rgba(mine)
    w2, h2, b = exr_rgba(reference)
    if (w1, h1) != (w2, h2):
        return "different size %dx%d, Material Maker %dx%d" % (w1, h1, w2, h2)
    different = 0
    for c in "RGBA":
        x, y = a[c][0], b[c][0]
        if x == y:
            continue
        x = [ float_bits_to_half(v) for v in x ]
        y = [ float_bits_to_half(v) for v in y ]
        different += sum(1 for i, j in zip(x, y) if i != j)
    if different:
        return "%d/%d values differ" % (different, w1 * h1 * 4)
    return ""


# Cooking and verifying


def cook(command, path, package, size, timeout):
    """Cooks a graph into a package (replaced only if the export succeeds),
    returns an error message (or "")"""
    out_dir = os.path.dirname(package)
    os.makedirs(out_dir, exist_ok=True)
    temporary = tempfile.mkdtemp(prefix=".mm_cook_", dir=out_dir)
    try:
        args = command + [ "--export-mmr", "-o", temporary, "--size", str(size), path ]
        code, output = run(args, timeout)
        exported = os.path.join(temporary, os.path.splitext(os.path.basename(path))[0] + ".mmr")
        if code is not None and not errors_of(output) and os.path.isfile(exported):
            try:
                read_manifest(exported, False)
            except ValueError as e:
                return "invalid package: %s" % e
            os.replace(exported, package)
            return ""
        return failure("export", code, output, timeout)
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


def read_manifest(package, check_version=True):
    try:
        with zipfile.ZipFile(package) as z:
            manifest = json.loads(z.read("manifest.json"))
    except (OSError, KeyError, ValueError, zipfile.BadZipFile) as e:
        raise ValueError(str(e))
    if not isinstance(manifest, dict) or manifest.get("format") != "mmr":
        raise ValueError("not a runtime package")
    version = manifest.get("version")
    if check_version and (not isinstance(version, int) or version < 1 or version > PACKAGE_VERSION):
        raise ValueError("unsupported package version %s" % version)
    if not isinstance(manifest.get("outputs"), dict) or not manifest["outputs"]:
        raise ValueError("no outputs")
    return manifest


def output_size(manifest, channel):
    for p in manifest.get("passes", []):
        if isinstance(p, dict) and p.get("name") == manifest["outputs"][channel]:
            return int(p["size"][0])
    raise ValueError("no pass for output %s" % channel)


def verify(command, mmr_render, path, package, timeout):
    """Renders a package with mmr_render and compares its outputs with
    Material Maker's renders of the graph, returns (error message or "",
    { channel: result })"""
    try:
        manifest = read_manifest(package)
        unknown = [ c for c in manifest["outputs"] if c not in CHANNEL_OUTPUTS ]
        if unknown:
            return "unknown outputs " + ", ".join(unknown), {}
        sizes = { c: output_size(manifest, c) for c in manifest["outputs"] }
    except (ValueError, KeyError, TypeError, IndexError) as e:
        return "invalid package: %s" % e, {}
    temporary = tempfile.mkdtemp(prefix="mm_cook_verify_")
    try:
        return verify_outputs(command, mmr_render, path, package, timeout, manifest, sizes, temporary)
    finally:
        shutil.rmtree(temporary, ignore_errors=True)


def verify_outputs(command, mmr_render, path, package, timeout, manifest, sizes, temporary):
    rendered = os.path.join(temporary, "mmr")
    code, output = run([ mmr_render, package, "-o", rendered, "--exr" ], timeout)
    if code != 0:
        return failure("mmr_render", code, output.replace("error: ", "ERROR: "), timeout), {}
    results = {}
    for channel in sorted(manifest["outputs"]):
        mine = os.path.join(rendered, channel + ".exr")
        reference_dir = os.path.join(temporary, channel)
        # (with the stored seed and parameter values, as mmr_render without --set)
        args = command + [ "--render", "--node", "Material:%d" % CHANNEL_OUTPUTS[channel], "--format", "exr",
                           "--size", str(sizes[channel]), "-o", reference_dir, path ]
        code, output = run(args, timeout)
        references = glob.glob(os.path.join(reference_dir, "*.exr"))
        if code is None or errors_of(output) or len(references) != 1:
            results[channel] = failure("render", code, output, timeout)
        elif not os.path.isfile(mine):
            results[channel] = "not rendered by mmr_render"
        else:
            try:
                results[channel] = compare_exr(mine, references[0]) or "identical"
            except (OSError, ValueError, KeyError, IndexError, struct.error) as e:
                results[channel] = "cannot compare: %s" % e
    different = [ "%s: %s" % (c, r) for c, r in sorted(results.items()) if r != "identical" ]
    return "; ".join(different), results


def mm_help(command, timeout):
    code, output = run(command + [ "--", "--help" ], timeout)
    if code is None:
        raise UsageError("Material Maker did not answer (%s) in %d s" % (" ".join(command), timeout))
    if "Material Maker command line" not in output:
        raise UsageError("%s is not Material Maker: %s" % (" ".join(command), output.strip()[-300:]))
    if "--export-mmr" not in output:
        raise UsageError("this version of Material Maker cannot export runtime packages (--export-mmr): enable the Runtime export plugin")
    return output


def parse_arguments(argv):
    parser = argparse.ArgumentParser(prog="mm-cook", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("inputs", nargs="+")
    parser.add_argument("--mm")
    parser.add_argument("-o", "--output", default="cooked")
    parser.add_argument("--size", type=int, default=0)
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--verify", default="")
    parser.add_argument("--report", default="")
    parser.add_argument("--timeout", type=float, default=600)
    args = parser.parse_args(argv)
    if args.size < 0:
        parser.error("incorrect size %d" % args.size)
    if args.jobs < 1:
        parser.error("incorrect number of jobs %d" % args.jobs)
    if args.timeout <= 0:
        parser.error("incorrect timeout %g" % args.timeout)
    return args


def main(argv=None):
    args = parse_arguments(argv)
    try:
        return cook_all(args)
    except UsageError as e:
        print("mm-cook: error: %s" % e, file=sys.stderr)
        return 2


def cook_all(args):
    command = find_command(args.mm)
    if command is None:
        raise UsageError("Material Maker was not found: use --mm or the MATERIAL_MAKER environment variable")
    mmr_render = ""
    if args.verify:
        # (relative paths with / are not found by Windows' CreateProcess)
        mmr_render = shutil.which(args.verify) or args.verify
        if not os.path.isfile(mmr_render):
            raise UsageError("mmr_render was not found: " + args.verify)
        mmr_render = os.path.abspath(mmr_render)
    inputs = find_inputs(args.inputs)
    if not inputs:
        raise UsageError("no .ptex file in the inputs")
    output = os.path.abspath(args.output)
    # Graphs that would be cooked into the same package
    packages = {}
    for path, relative in inputs:
        package = os.path.join(output, os.path.splitext(relative)[0] + ".mmr")
        if package in packages and packages[package] != path:
            raise UsageError("%s and %s would be cooked into the same package" % (packages[package], path))
        packages[package] = path
    inputs = [ (path, package) for package, path in packages.items() ]
    description, version = mm_identity(command, mm_help(command, args.timeout))
    os.makedirs(output, exist_ok=True)
    state_path = os.path.join(output, STATE_FILE)
    state = load_state(state_path)
    options = { "size": args.size }
    verifier = file_identity(mmr_render) if mmr_render else ""
    lock = threading.Lock()

    def process(item):
        path, package = item
        key = os.path.relpath(package, output).replace(os.sep, "/")
        digest = fingerprint(path, options, version)
        entry = { "input": path, "package": package }
        start = time.time()
        try:
            previous = cook_one(path, package, key, digest, entry)
        except Exception as e:  # (an unexpected error stops only this package)
            entry["status"] = "error"
            entry["error"] = "%s: %s" % (type(e).__name__, e)
        entry["time"] = round(time.time() - start, 2)
        with lock:
            if entry["status"] != "error":
                state[key] = previous
            save_state(state_path, state)
            label = entry["status"] + (" (verified)" if entry.get("verified") else "")
            print("%-22s %s%s" % (label, key, (": " + entry["error"]) if "error" in entry else " (%.1f s)" % entry["time"]), flush=True)
        return entry

    def cook_one(path, package, key, digest, entry):
        """Cooks (if needed) and verifies a package, returns its state"""
        previous = dict(state.get(key, {}))
        if not args.force and previous.get("digest") == digest and os.path.isfile(package):
            entry["status"] = "up to date"
        else:
            with lock:
                state.pop(key, None)
            error = cook(command, path, package, args.size, args.timeout)
            entry["status"] = "error" if error else "cooked"
            if error:
                entry["error"] = error
            previous = { "digest": digest }
        if mmr_render and entry["status"] != "error":
            if not args.force and previous.get("verified") == verifier:
                entry["verified"] = True
            else:
                error, results = verify(command, mmr_render, path, package, args.timeout)
                entry["verified"] = error == ""
                entry["channels"] = results
                if error:
                    entry["status"] = "error"
                    entry["error"] = "verification failed: " + error
                else:
                    previous["verified"] = verifier
        return previous

    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as executor:
        report = list(executor.map(process, inputs))
    counts = { s: sum(1 for e in report if e["status"] == s) for s in ("cooked", "up to date", "error") }
    if args.report:
        with open(args.report, "w", encoding="utf-8") as f:
            json.dump({ "material_maker": description, "options": options, "verify": mmr_render, "packages": report,
                        "summary": counts }, f, indent=1)
    print("%d cooked, %d up to date, %d errors" % (counts["cooked"], counts["up to date"], counts["error"]))
    return 1 if counts["error"] else 0


if __name__ == "__main__":
    sys.exit(main())
