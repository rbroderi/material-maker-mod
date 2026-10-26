"""Python client for the Material Maker JSON-RPC server.

Start Material Maker with a server, either with its user interface::

    material_maker --rpc-port 7680

or without (rendering still needs a GPU, the window is minimized)::

    material_maker --rpc --rpc-port 7680

then::

    from material_maker_client import MaterialMaker, color

    with MaterialMaker() as mm:
        mm.load("bricks.ptex")
        mm.set_parameters({"Hue": 0.3})
        mm.render("Material", "bricks.png", output=0, size=1024)
        mm.export("MaterialX/Standard Surface", "out/bricks")

Requests are JSON objects, one per line, over TCP on 127.0.0.1. Any method
of the server can also be called with ``mm.call("method", **params)``.
"""

import json
import os
import socket
import subprocess
import time

__all__ = ["MaterialMaker", "MaterialMakerError", "color", "launch"]

DEFAULT_PORT = 7680


class MaterialMakerError(Exception):
    """An error returned by the server"""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def color(r, g, b, a=1.0):
    """Returns a color parameter value"""
    return {"type": "Color", "r": r, "g": g, "b": b, "a": a}


def _path(path):
    return os.path.abspath(path).replace("\\", "/")


class MaterialMaker:
    """A connection to a Material Maker JSON-RPC server"""

    def __init__(self, host="127.0.0.1", port=DEFAULT_PORT, timeout=600.0):
        self._socket = socket.create_connection((host, port), timeout=timeout)
        self._file = self._socket.makefile("rwb")
        self._next_id = 1

    def close(self):
        self._file.close()
        self._socket.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def call(self, method, **params):
        """Calls a method of the server and returns its result"""
        request = {"jsonrpc": "2.0", "id": self._next_id, "method": method, "params": params}
        self._next_id += 1
        self._file.write((json.dumps(request) + "\n").encode("utf-8"))
        self._file.flush()
        line = self._file.readline()
        if not line:
            raise ConnectionError("Material Maker closed the connection")
        response = json.loads(line)
        if "error" in response:
            raise MaterialMakerError(response["error"].get("code"), response["error"].get("message"))
        return response.get("result")

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        return lambda **params: self.call(name, **params)

    # Graphs

    def ping(self):
        """Returns the version of Material Maker and whether it has a user interface"""
        return self.call("ping")

    def new_graph(self):
        """Creates a new material graph"""
        return self.call("new_graph")

    def load(self, path):
        """Loads a .ptex file"""
        return self.call("load", path=_path(path))

    def save(self, path):
        """Saves the current graph as a .ptex file"""
        return self.call("save", path=_path(path))

    # Nodes

    def list_nodes(self):
        """Returns the nodes of the current graph (name, type, inputs, outputs, parameters)"""
        return self.call("list_nodes")

    def get_node(self, node):
        return self.call("get_node", node=node)

    def list_connections(self):
        return self.call("list_connections")

    def list_parameters(self):
        """Returns the parameters as "name (label) = value" and "node:parameter = value" lines"""
        return self.call("list_parameters")

    def create_node(self, type=None, name=None, position=None, parameters=None, item=None):
        """Creates a node from a generator type ("perlin"), a library item
        dictionary (item=...) or, when the user interface is running, a
        library item path ("Noise/Perlin"). Returns its name."""
        params = {"type": type} if item is None else {"item": item}
        if name is not None:
            params["name"] = name
        if position is not None:
            params["position"] = list(position)
        if parameters:
            params["parameters"] = parameters
        return self.call("create_node", **params)

    def delete_node(self, node):
        return self.call("delete_node", node=node)

    def connect(self, from_node, to_node, from_port=0, to_port=0):
        return self.call("connect", **{"from": from_node, "from_port": from_port, "to": to_node, "to_port": to_port})

    def disconnect(self, from_node, to_node, from_port=0, to_port=0):
        return self.call("disconnect", **{"from": from_node, "from_port": from_port, "to": to_node, "to_port": to_port})

    def set_parameter(self, node, parameter, value):
        return self.call("set_parameter", node=node, parameter=parameter, value=value)

    def set_parameters(self, values=None, **kwargs):
        """Sets parameters by remote parameter name or label, or "node:parameter" """
        values = dict(values or {}, **kwargs)
        return self.call("set_parameters", values=values)

    def reseed(self, offset=1):
        """Changes the seeds of all nodes that are not locked"""
        return self.call("reseed", offset=offset)

    # Output

    def render(self, node, path, output=0, size=1024):
        """Renders an output of a node to an image file (.png or .exr)"""
        return self.call("render", node=node, path=_path(path), output=output, size=size)

    def list_export_targets(self):
        return self.call("list_export_targets")

    def export(self, target, prefix, size=0):
        """Exports the material; prefix is the path of the files without extension"""
        return self.call("export", target=target, prefix=_path(prefix), size=size)

    def export_mmr(self, path, size=0):
        """Exports a runtime package (.mmr) of the material, for engine runtimes"""
        return self.call("export_mmr", path=_path(path), size=size)

    def quit(self):
        """Quits Material Maker (--rpc mode only)"""
        return self.call("quit")


def launch(command, port=DEFAULT_PORT, graph=None, show_window=False, timeout=120.0):
    """Starts Material Maker in --rpc mode and returns (process, client).

    command is the Material Maker executable, or a list such as
    ["godot", "--path", "/path/to/material-maker"].
    """
    if isinstance(command, str):
        command = [command]
    # Another server on this port would answer instead of the new one
    try:
        socket.create_connection(("127.0.0.1", port), timeout=1).close()
        raise RuntimeError("port %d is already used (is Material Maker already running?)" % port)
    except OSError:
        pass
    args = list(command) + ["--rpc", "--rpc-port", str(port)]
    if show_window:
        args.append("--show-window")
    if graph is not None:
        args.append(_path(graph))
    process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + timeout
    while True:
        try:
            client = MaterialMaker(port=port)
            client.ping()
            return process, client
        except OSError:
            if process.poll() is not None:
                raise RuntimeError("Material Maker exited with code %d" % process.returncode)
            if time.time() > deadline:
                process.kill()
                raise TimeoutError("Material Maker did not start a server on port %d" % port)
            time.sleep(0.5)
