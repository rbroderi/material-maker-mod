"""Tests of validate_library (python -m unittest discover python/tests)

The tests run this file as a fake Material Maker server, whose library items
render, fail, print errors, hang or crash depending on their names.
"""
import json
import os
import socket
import socketserver
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import validate_library  # noqa: E402


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class FakeHandler(socketserver.StreamRequestHandler):
    """Answers JSON-RPC requests like Material Maker's server"""

    def handle(self):
        for line in self.rfile:
            request = json.loads(line)
            result = self.server.call(request["method"], request["params"])
            if isinstance(result, Exception):
                response = {"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32000, "message": str(result)}}
            else:
                response = {"jsonrpc": "2.0", "id": request["id"], "result": result}
            self.wfile.write((json.dumps(response) + "\n").encode("utf-8"))
            self.wfile.flush()


class FakeServer(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def __init__(self, port):
        super().__init__(("127.0.0.1", port), FakeHandler)
        self.node = None

    def call(self, method, params):
        if method == "ping":
            return {"version": "fake", "gui": False}
        if method == "new_graph":
            self.node = None
            return True
        if method == "create_node":
            self.node = params["item"]["name"]
            if self.node == "crash":
                os._exit(3)
            if self.node.startswith("shader_"):
                print("COMPUTE SHADER ERROR: 0:12: 'foo' : undeclared identifier", flush=True)
            return self.node
        if method == "get_node":
            return {"name": self.node, "outputs": [] if self.node == "no_output" else [{"type": "rgba"}]}
        if method == "render":
            if self.node == "hang":
                time.sleep(3600)
            if self.node.endswith("render_error"):
                return Exception("buffers failed to render: Buffer")
            if self.node != "nothing_rendered":
                with open(params["path"], "wb") as f:
                    f.write(b"png")
            return params["path"]
        if method == "render_queue":
            if self.node in ("hang", "stuck"):
                return [{"name": "o1", "node": "Buffer", "status": "Invalidated", "pending": []}]
            return []
        if method == "quit":
            threading.Thread(target=lambda: (time.sleep(0.1), os._exit(0))).start()
            return True
        return Exception("Unknown method '%s'" % method)


def serve():
    port = int(sys.argv[sys.argv.index("--rpc-port") + 1])
    print("JSON-RPC server listening on 127.0.0.1:%d" % port, flush=True)
    FakeServer(port).serve_forever()


class ValidateLibraryTest(unittest.TestCase):
    def setUp(self):
        validate_library.QUEUE_TIMEOUT = 0.5
        self.out_dir = tempfile.TemporaryDirectory()
        self.validator = validate_library.Validator([sys.executable, __file__], free_port(), 3)

    def tearDown(self):
        self.validator.stop()
        self.out_dir.cleanup()

    def check(self, name):
        item = {"name": name, "type": name}
        self.validator.validate(name, lambda mm: validate_library.check_library_item(mm, item, self.out_dir.name, 32))
        return [f for f in self.validator.failures if f.startswith(name + ":")]

    def test_ok(self):
        self.assertEqual(self.check("ok"), [])
        self.assertEqual(self.check("no_output"), [])
        self.assertEqual(os.listdir(self.out_dir.name), [])

    def test_errors(self):
        self.assertIn("buffers failed to render", self.check("render_error")[0])
        self.assertIn("nothing rendered", self.check("nothing_rendered")[0])
        self.assertIn("renders not finished (1 buffers left: Buffer Invalidated)", self.check("stuck")[0])
        self.assertIn("SHADER ERROR: 0:12", self.check("shader_error")[0])
        # Output errors are added to the error of the item
        failure = self.check("shader_render_error")[0]
        self.assertIn("buffers failed to render: Buffer (errors in the output: COMPUTE SHADER ERROR", failure)
        # Errors are only reported for the item that printed them, and
        # Material Maker is restarted after each failure
        self.assertIsNone(self.validator.session)
        self.assertEqual(self.check("ok"), [])
        self.assertIsNotNone(self.validator.session)
        self.assertEqual(self.validator.count, 6)

    def test_hang_and_crash_restart(self):
        failure = self.check("hang")[0]
        self.assertIn("no answer after 3s", failure)
        self.assertIn("1 buffers left: Buffer Invalidated", failure)
        self.assertIsNone(self.validator.session)
        self.assertIn("Material Maker stopped (exit code 3)", self.check("crash")[0])
        self.assertEqual(self.check("ok"), [])
        self.assertEqual(len(self.validator.failures), 2)

    def test_log(self):
        with tempfile.TemporaryFile("w+", encoding="utf-8") as log:
            self.validator.log = log
            self.check("shader_error")
            log.seek(0)
            lines = log.read().splitlines()
        self.assertIn("JSON-RPC server listening on 127.0.0.1:%d" % self.validator.port, lines)
        marker = lines.index("--- validate_library: shader_error")
        self.assertTrue(lines[marker + 1].startswith("COMPUTE SHADER ERROR"))

    def test_error_lines(self):
        lines = ["ERROR: Cannot open file", "   at: foo (bar.cpp:1)", "COMPUTE SHADER ERROR: x", "SCRIPT ERROR: Invalid call", "No ERROR: here",
                 "ERROR: Apps class not found, Steam may not be initialized: isSubscribed"]
        self.assertEqual(validate_library.error_lines(lines), [lines[0], lines[2], lines[3]])

    def test_matches(self):
        self.assertTrue(validate_library.matches("Noise/Voronoi", ["voronoi", "perlin"]))
        self.assertFalse(validate_library.matches("Noise/Voronoi", ["perlin"]))
        self.assertTrue(validate_library.matches("Noise/Voronoi", [""]))


if __name__ == "__main__":
    serve()
