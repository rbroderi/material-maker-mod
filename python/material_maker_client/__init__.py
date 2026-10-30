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
import shlex
import shutil
import socket
import subprocess
import time

__all__ = ["MaterialMaker", "MaterialMakerError", "color", "launch", "split_command", "find_command"]

DEFAULT_PORT = 7680
# Seconds between attempts to connect to a starting server
POLL_INTERVAL = 0.5


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


def _given(**params):
    """The parameters that are not None"""
    return {k: v for k, v in params.items() if v is not None}


def _link(from_node, from_port, to_node, to_port):
    return {"from": from_node, "from_port": from_port, "to": to_node, "to_port": to_port}


def split_command(command):
    """Splits a command line (such as 'godot --path .') into a list. A list
    is returned as is, and so is the path of an existing executable (even
    with spaces). On Windows, backslashes are kept and quotes are removed."""
    if not isinstance(command, str):
        return list(command)
    if os.path.isfile(command):
        return [command]
    if os.name != "nt":
        return shlex.split(command)
    # Non-POSIX splitting keeps backslashes but also the quotes
    return [a[1:-1] if len(a) > 1 and a[0] == a[-1] and a[0] in "\"'" else a for a in shlex.split(command, posix=False)]


def find_command(option=None):
    """The Material Maker command (as a list): option, else the MATERIAL_MAKER
    environment variable, else material_maker in the PATH. None if not found."""
    command = option or os.environ.get("MATERIAL_MAKER") or shutil.which("material_maker")
    return split_command(command) if command else None


def _port_in_use(port):
    try:
        socket.create_connection(("127.0.0.1", port), timeout=1).close()
        return True
    except OSError:
        return False


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

    def new_graph(self, template=None):
        """Creates a new material graph, optionally from an output template
        (see list_templates) that sets its export target"""
        return self.call("new_graph", **_given(template=template))

    def list_templates(self):
        """Output templates: new materials set up for an engine"""
        return self.call("list_templates")

    def load(self, path):
        """Loads a .ptex file. Returns True, or { "loaded": True, "missing": [...] }
        when the graph needs plugins, node types or features that are missing
        (nodes of unknown types are kept as placeholders)"""
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
        library item path ("Noise/Voronoi"). Returns its name."""
        params = {"type": type} if item is None else {"item": item}
        params.update(_given(name=name, position=None if position is None else list(position)))
        if parameters:
            params["parameters"] = parameters
        return self.call("create_node", **params)

    def delete_node(self, node):
        return self.call("delete_node", node=node)

    def connect(self, from_node, to_node, from_port=0, to_port=0):
        return self.call("connect", **_link(from_node, from_port, to_node, to_port))

    def disconnect(self, from_node, to_node, from_port=0, to_port=0):
        return self.call("disconnect", **_link(from_node, from_port, to_node, to_port))

    def set_parameter(self, node, parameter, value):
        return self.call("set_parameter", node=node, parameter=parameter, value=value)

    def set_parameters(self, values=None, **kwargs):
        """Sets parameters by remote parameter name or label, or "node:parameter" """
        values = dict(values or {}, **kwargs)
        return self.call("set_parameters", values=values)

    # Presets of the remote nodes

    def list_presets(self):
        """Returns the names of the presets of the graph's remote nodes"""
        return self.call("list_presets")

    def apply_preset(self, name):
        """Applies a preset to the remote nodes that have it"""
        return self.call("apply_preset", name=name)

    def save_preset(self, name, node=None):
        """Saves the current values of a remote node as a preset (node is
        needed when the graph has several remote nodes)"""
        return self.call("save_preset", **_given(name=name, node=node))

    def delete_preset(self, name, node=None):
        """Deletes a preset (by default, from all remote nodes)"""
        return self.call("delete_preset", **_given(name=name, node=node))

    def randomize_parameters(self, seed=None, node=None):
        """Sets random values (within their ranges) to the parameters of a
        remote node (by default, of all of them), and returns the seed"""
        return self.call("randomize_parameters", **_given(seed=seed, node=node))

    def reseed(self, offset=1):
        """Changes the seeds of all nodes that are not locked"""
        return self.call("reseed", offset=offset)

    # Output

    def render(self, node, path, output=0, size=1024, height=0):
        """Renders an output of a node to an image file (.png, .exr, .jpg or
        .webp), size pixels wide and height pixels high (0 for a square image)"""
        return self.call("render", node=node, path=_path(path), output=output, size=size, height=height)

    def render_queue(self):
        """Buffers that are not rendered yet, to diagnose renders that never finish"""
        return self.call("render_queue")

    def export_volume(self, node, path, output=0, resolution=128, extent=1.0, texel_format=""):
        """Exports a 3D texture or SDF output as a volume: OpenVDB (.vdb), 3D DDS
        (.dds) or KTX2 (.ktx2), sampled in a box of the given extent centered on
        the origin"""
        return self.call("export_volume", node=node, path=_path(path), output=output,
                         resolution=resolution, extent=extent, texel_format=texel_format)

    def render_path_traced(self, path, size=512, samples=64, transparent=False, thin_walled=False):
        """Path traced render of the 3D preview's object from the current view
        (GUI only), saved as a tone mapped PNG or a linear EXR"""
        return self.call("render_path_traced", path=_path(path), size=size, samples=samples,
                         transparent=transparent, thin_walled=thin_walled)

    def render_turntable(self, path, frames=36, size=256):
        """Full turn of the 3D preview's object (GUI only), saved as a sprite
        sheet, or a PNG sequence if path contains # (replaced by frame numbers)"""
        return self.call("render_turntable", path=_path(path), frames=frames, size=size)

    def list_export_targets(self):
        return self.call("list_export_targets")

    def export(self, target, prefix, size=0, height=0, udim=None):
        """Exports the material; prefix is the path of the files without extension
        (height: for non-square textures). udim exports UDIM tiles: True for
        the graph's tiles, or a list of tiles ("1001-1004,1011" or [1001, 1002])."""
        return self.call("export", **_given(target=target, prefix=_path(prefix), size=size, height=height, udim=udim))

    def undo(self):
        """Undoes the last change (with the user interface only)"""
        return self.call("undo")

    def redo(self):
        """Redoes the last undone change (with the user interface only)"""
        return self.call("redo")

    def export_mmr(self, path, size=0, height=0):
        """Exports a runtime package (.mmr) of the material, for engine runtimes
        (height: for non-square outputs)"""
        return self.call("export_mmr", path=_path(path), size=size, height=height)

    def quit(self):
        """Quits Material Maker (--rpc mode only)"""
        return self.call("quit")


def launch(command, port=DEFAULT_PORT, graph=None, show_window=False, timeout=120.0):
    """Starts Material Maker in --rpc mode and returns (process, client).

    command is the Material Maker executable, a list such as
    ["godot", "--path", "/path/to/material-maker"], or a command line
    (see split_command).
    """
    # Another server on this port would answer instead of the new one
    if _port_in_use(port):
        raise RuntimeError("port %d is already used (is Material Maker already running?)" % port)
    args = split_command(command) + ["--rpc", "--rpc-port", str(port)]
    if show_window:
        args.append("--show-window")
    if graph is not None:
        args.append(_path(graph))
    process = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.time() + timeout
    while True:
        client = None
        try:
            client = MaterialMaker(port=port)
            client.ping()
            return process, client
        except OSError:
            if client is not None:
                client.close()
            if process.poll() is not None:
                raise RuntimeError("Material Maker exited with code %d" % process.returncode)
            if time.time() > deadline:
                process.kill()
                raise TimeoutError("Material Maker did not start a server on port %d" % port)
            time.sleep(POLL_INTERVAL)
