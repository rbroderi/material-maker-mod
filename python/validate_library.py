"""Validates node libraries and example materials by rendering them, for CI.

    python validate_library.py --mm "godot --path ." [--library material_maker/library/base.json]
                               [--examples material_maker/examples] [--filter text] [--size 32]

Each library item is created in an empty graph and its first output is
rendered; each example material's albedo output is rendered. An item fails
when the server returns an error, when nothing is rendered, when buffers are
still waiting to be rendered afterwards, when Material Maker prints errors
(such as shader compilation errors) while the item is validated, or when it
does not answer in time. Material Maker is restarted after each failure, so
that it does not affect the next items. The exit code is 1 if anything
fails. Material Maker runs without user interface (--rpc).
"""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from material_maker_client import MaterialMaker, MaterialMakerError, find_command  # noqa: E402

# Lines of Material Maker's output that make an item fail
ERROR_LINE = re.compile(r"SHADER ERROR|SCRIPT ERROR|Parse Error|^ERROR:|Cannot create pipeline|Error creating shader")
# Errors that are not caused by the items (Steam is not running)
IGNORED_LINE = re.compile(r"Steam may not be initialized")
# Seconds to wait for the output of an item after its last request
OUTPUT_DELAY = 0.1
# Seconds to wait for the render queue to be empty after an item is rendered
QUEUE_TIMEOUT = 10.0
# Number of error lines shown for an item
MAX_ERROR_LINES = 3


class Timeout(Exception):
    """Material Maker did not answer in time, or stopped"""


def matches(text, filters):
    """Whether text contains one of the filters (case insensitive)"""
    return any(f in text.lower() for f in filters)


def error_lines(lines):
    """The lines of Material Maker's output that report errors"""
    return [line for line in lines if ERROR_LINE.search(line) and not IGNORED_LINE.search(line)]


def port_in_use(port):
    try:
        socket.create_connection(("127.0.0.1", port), timeout=1).close()
        return True
    except OSError:
        return False


def kill(process):
    """Kills a process and its children (godot_console starts Godot as a child)"""
    if process.poll() is None:
        if os.name == "nt":
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(process.pid)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        process.kill()
    process.wait(30)


def describe_queue(queue):
    return "%d buffers left: %s" % (len(queue), ", ".join("%s %s" % (b.get("node") or b.get("name"), b.get("status")) for b in queue[:3]))


class Session:
    """A Material Maker process in --rpc mode whose output is collected"""

    def __init__(self, command, port, timeout, log=None, start_timeout=120.0, port_timeout=0.0):
        # (the port of a Material Maker that was just stopped can take a few
        # seconds to be freed)
        deadline = time.time() + port_timeout
        while port_in_use(port) and time.time() < deadline:
            time.sleep(0.5)
        if port_in_use(port):
            raise RuntimeError("port %d is already used (is Material Maker already running?)" % port)
        self.port = port
        self.timeout = timeout
        self.log = log
        self.lines = []
        self.read = 0
        self.lock = threading.Lock()
        self.mm = None
        args = list(command) + ["--rpc", "--rpc-port", str(port)]
        self.process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.reader = threading.Thread(target=self.read_output, daemon=True)
        self.reader.start()
        deadline = time.time() + start_timeout
        while self.mm is None:
            try:
                self.mm = MaterialMaker(port=port, timeout=timeout)
                # The server answers once the project is loaded
                self.mm.ping()
            except OSError:
                if self.mm is not None:
                    self.mm.close()
                    self.mm = None
                if self.process.poll() is not None or time.time() > deadline:
                    kill(self.process)
                    raise RuntimeError("Material Maker did not start a server on port %d (exit code %s)" % (port, self.process.returncode))
                time.sleep(0.5)

    def read_output(self):
        for data in self.process.stdout:
            line = data.decode("utf-8", "replace").rstrip()
            with self.lock:
                self.lines.append(line)
                self.write_log(line)

    def write_log(self, line):
        if self.log is not None:
            self.log.write(line + "\n")
            self.log.flush()

    def mark(self, name):
        """Writes the name of the item being validated in the log"""
        with self.lock:
            self.write_log("--- validate_library: %s" % name)

    def new_output(self):
        """The lines printed since the last call"""
        with self.lock:
            lines = self.lines[self.read:]
            self.read = len(self.lines)
        return lines

    def render_queue(self):
        """The render queue, read through a second connection (the first one
        may still be waiting for an answer), or None"""
        try:
            with MaterialMaker(port=self.port, timeout=10) as mm:
                return mm.render_queue()
        except (OSError, ValueError, MaterialMakerError):
            return None

    def run(self, check):
        """Runs check(mm) and returns its status; raises Timeout if Material
        Maker does not answer in time or stops"""
        try:
            return check(self.mm)
        except (OSError, ValueError) as e:
            try:
                self.process.wait(2)
            except subprocess.TimeoutExpired:
                pass
            if self.process.poll() is not None:
                raise Timeout("Material Maker stopped (exit code %d)" % self.process.returncode)
            message = "no answer after %gs" % self.timeout if isinstance(e, socket.timeout) else "connection error: %s" % e
            queue = self.render_queue()
            if queue:
                message += " (%s)" % describe_queue(queue)
            raise Timeout(message)

    def close(self, quit=True, timeout=30):
        """Quits Material Maker, or kills it if it does not quit in time
        (or if quit is False)"""
        try:
            if quit and self.process.poll() is None:
                self.mm._socket.settimeout(timeout)
                self.mm.quit()
                self.process.wait(timeout)
        except (OSError, ValueError, MaterialMakerError, subprocess.TimeoutExpired):
            print("Material Maker did not quit in %ds, killing it" % timeout, flush=True)
        finally:
            kill(self.process)
            self.mm.close()
            self.reader.join(10)


def render(mm, node, path, output, size):
    """Renders an output of a node and checks that a file was written"""
    if os.path.exists(path):
        os.remove(path)
    mm.render(node, path, output=output, size=size)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        raise MaterialMakerError(0, "nothing rendered")
    os.remove(path)


def check_render_queue(mm, timeout=None):
    """Fails if buffers are still waiting to be rendered after timeout
    seconds (nodes that have no output to render may still be rendering
    previews)"""
    deadline = time.time() + (QUEUE_TIMEOUT if timeout is None else timeout)
    while True:
        queue = mm.render_queue()
        if not queue:
            return
        if time.time() > deadline:
            raise MaterialMakerError(0, "renders not finished (%s)" % describe_queue(queue))
        time.sleep(0.1)


def check_library_item(mm, item, out_dir, size):
    """Creates a library item in an empty graph and renders its first output"""
    mm.new_graph()
    name = mm.create_node(item=item)
    if name != "Material" and mm.get_node(name)["outputs"]:
        render(mm, name, os.path.join(out_dir, "item.png"), 0, size)
    check_render_queue(mm)
    return "ok"


def check_example(mm, path, out_dir, size):
    """Loads an example material and renders its albedo"""
    mm.load(path)
    nodes = {n["name"]: n for n in mm.list_nodes()}
    # Some material types (e.g. unlit) have no exported outputs
    if "Material" in nodes and nodes["Material"]["outputs"]:
        render(mm, "Material", os.path.join(out_dir, "example.png"), 0, size)
    check_render_queue(mm)
    return "ok"


class Validator:
    """Validates items one at a time, and restarts Material Maker when it
    stops answering"""

    def __init__(self, command, port, timeout, log=None):
        self.command = command
        self.port = port
        self.timeout = timeout
        self.log = log
        self.session = None
        self.failures = []
        self.count = 0

    def start(self):
        self.session = Session(self.command, self.port, self.timeout, self.log, port_timeout=30.0)
        time.sleep(OUTPUT_DELAY)
        errors = error_lines(self.session.new_output())
        if errors:
            print("Material Maker printed errors when starting: " + " | ".join(errors[:MAX_ERROR_LINES]), flush=True)

    def validate(self, name, check):
        """Runs check(mm) (that returns a status), prints its status and time,
        and records its failure"""
        self.count += 1
        if self.session is None:
            self.start()
        self.session.mark(name)
        start = time.time()
        error = None
        try:
            status = self.session.run(check)
        except (MaterialMakerError, KeyError, TypeError, Timeout) as e:
            error = str(e)
        time.sleep(OUTPUT_DELAY)
        output_errors = error_lines(self.session.new_output())
        if output_errors:
            output_errors = "errors in the output: " + " | ".join(output_errors[:MAX_ERROR_LINES])
            error = output_errors if error is None else "%s (%s)" % (error, output_errors)
        if error is not None:
            status = "FAILED: %s" % error
            self.failures.append("%s: %s" % (name, error))
            # Failed or unfinished renders could make the next items fail
            # too, and a busy server would not answer a quit request
            self.stop(quit=False)
        print("%-60s %s (%.1fs)" % (name, status, time.time() - start), flush=True)

    def stop(self, quit=True):
        if self.session is not None:
            self.session.mark("(quit)")
            self.session.close(quit)
            self.session = None


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
    parser.add_argument("--timeout", type=float, default=120.0, help="seconds after which an item fails if Material Maker does not answer (it is then restarted)")
    parser.add_argument("--log", help="file where the output of Material Maker is written")
    args = parser.parse_args()
    libraries = args.library or ["material_maker/library/base.json"]
    command = find_command(args.mm)
    if command is None:
        sys.exit("Material Maker was not found: use --mm or the MATERIAL_MAKER environment variable")
    filters = [f.lower() for f in args.filter.split("|")]
    log = open(args.log, "w", encoding="utf-8") if args.log else None
    validator = Validator(command, args.port, args.timeout, log)
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
                    validator.validate(path, lambda mm: check_library_item(mm, item, out_dir, args.size))
        if args.examples:
            for file_name in sorted(os.listdir(args.examples)):
                if file_name.endswith(".ptex") and matches(file_name, filters):
                    path = os.path.abspath(os.path.join(args.examples, file_name))
                    validator.validate(file_name, lambda mm: check_example(mm, path, out_dir, args.size))
    finally:
        validator.stop()
        temp_dir.cleanup()
        if log is not None:
            log.close()
    print("\n%d validated, %d failed" % (validator.count, len(validator.failures)))
    for f in validator.failures:
        print("  " + f)
    return 1 if validator.failures else 0


if __name__ == "__main__":
    sys.exit(main())
