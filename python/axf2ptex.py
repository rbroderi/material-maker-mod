"""axf2ptex: converts X-Rite AxF materials to Material Maker graphs.

    python python/axf2ptex.py [options] <material.axf> [<material.axf>...]

Needs numpy and h5py (pip install numpy h5py). For each AxF file, a graph
(<name>.ptex) and its textures (<name>_textures/) are written to the output
directory:

- SVBRDF materials (Lambert diffuse with a Ward, Cook-Torrance, Blinn-Phong or
  GGX specular lobe, optionally anisotropic, Fresnel and clear coat) become a
  Material node with albedo, metallic, roughness, normal and anisotropy maps.
  The specular workflow is converted to the metallic workflow.
- Car paints (CarPaint2: clear coat, Lambert and Cook-Torrance lobes tinted by
  an angular color table, and a flake BTF) become a Car Paint material node,
  that renders the measured model in the 3D preview and exports to Godot. A
  static PBR approximation (<name>_pbr.ptex) is written too.
- BTF materials (DPVF) are decoded and fitted to a Lambert + GGX SVBRDF.

Options:
  -o, --output <dir>  output directory (default: the AxF file's directory)
  --fit crop|stretch  non-square textures are cropped to a centered square
                      (default), or stretched
  --max-size <n>      maximum texture size (default 2048)
  --flake-size <n>    size of each flake BTF patch in the flake atlas
                      (default 240)
  --report <file>     writes the written graphs, warnings and errors as JSON
"""

import argparse
import json
import math
import os
import struct
import sys
import zlib

MISSING_MODULES = "axf2ptex needs numpy and h5py: pip install numpy h5py"
try:
    import numpy as np
    import h5py
    MISSING_MODULES = ""
except ImportError:
    pass

# Linear sRGB (D65) from CIE XYZ
XYZ_TO_SRGB = ((3.2404542, -1.5371385, -0.4985314),
               (-0.9692660, 1.8760108, 0.0415560),
               (0.0556434, -0.2040259, 1.0572252))
BRADFORD = ((0.8951, 0.2664, -0.1614), (-0.7502, 1.7135, 0.0367), (0.0389, -0.0685, 1.0296))
D65 = (0.95047, 1.0, 1.08883)
# Material node inputs (port indices)
MATERIAL_INPUTS = ["albedo_tex", "metallic_tex", "roughness_tex", "emission_tex", "normal_tex", "ao_tex", "depth_tex",
                   "opacity_tex", "sss_tex", "coat_tex", "coat_roughness_tex", "anisotropy_tex", "sheen_tex", "transmission_tex"]
DIELECTRIC_F0 = 0.04
# Car paint flake atlas: the flake BTF lookup table's cells (theta I rows,
# theta F columns)
CAR_PAINT_INPUTS = ["color_table", "flakes", "ambient"]


# ---------------------------------------------------------------- AxF reading

def text(value):
    value = value[()] if isinstance(value, h5py.Dataset) else value
    if isinstance(value, np.ndarray):
        value = value.ravel()[0] if value.size else b""
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value)


def axf_type(group):
    t = group.attrs.get("axf.type")
    if t is None:
        return ""
    return text(t[0] if isinstance(t, np.ndarray) else t)


class Resource:
    """An AxF resource: an image (V x U x channels, the first row is the top
    of the texture), or a uniform value"""

    def __init__(self, data, uniform, color_spec="", width_mm=0.0, height_mm=0.0):
        self.data = data
        self.uniform = uniform
        self.color_spec = color_spec
        self.width_mm = width_mm
        self.height_mm = height_mm


class AxFMaterial:
    def __init__(self, f, name):
        self.file = f
        self.group = f["com.xrite.Materials"][name]
        self.name = name
        self.resources = self.group["com.xrite.Resources"]

    def representation(self):
        return self.group["com.xrite.Representations"]["0"]

    def resource(self, location):
        """Reads a resource from its location (relative to the resources)"""
        location = location.decode() if isinstance(location, bytes) else location
        g = self.resources[location]
        if isinstance(g, h5py.Dataset):
            return Resource(read_data(g), True)
        if "Data" not in g and "0" in g:
            # A mip map: level 0
            g = g["0"]
        parent = g if "Layout" in g or "ColorSpec" in g else self.resources[location]
        data = read_data(g["Data"])
        uniform = axf_type(g) == "com.xrite.Uniform" or data.ndim < 3
        if not uniform:
            origin = text(parent["TextureOrigin"]) if "TextureOrigin" in parent else (text(g["TextureOrigin"]) if "TextureOrigin" in g else "TOP_LEFT")
            if origin.startswith("BOTTOM"):
                data = data[::-1]
        color_spec = text(parent["ColorSpec"]) if "ColorSpec" in parent else ""
        def mm(key):
            return float(np.asarray(parent[key][()])) if key in parent else 0.0
        return Resource(np.ascontiguousarray(data), uniform, color_spec, mm("WidthMM"), mm("HeightMM"))

    def color_matrix(self, color_spec):
        """Matrix converting colors of a color spec to linear sRGB (D65)"""
        if not color_spec:
            return np.eye(3)
        path = color_spec.replace("$(COLORSPECS)", "/com.xrite.ColorSpecs")
        if path not in self.file:
            return np.eye(3)
        spec = self.file[path]
        if "com.xrite.ColorMatrices/XYZ" in spec:
            # Rows are the XYZ of the primaries
            to_xyz = np.asarray(spec["com.xrite.ColorMatrices/XYZ"], dtype=np.float64).T
        else:
            return np.eye(3)
        white = to_xyz @ np.ones(3)
        # Bradford chromatic adaptation to D65
        bradford = np.array(BRADFORD)
        cone_src = bradford @ white
        cone_dst = bradford @ np.array(D65)
        adapt = np.linalg.inv(bradford) @ np.diag(cone_dst / cone_src) @ bradford
        return np.array(XYZ_TO_SRGB) @ adapt @ to_xyz


def read_data(dataset):
    data = np.asarray(dataset[()])
    # Half floats are stored as uint16
    if "half" in str(dataset.attrs.get("axf.datatype", "")):
        data = data.view(np.float16)
    return data.astype(np.float32)


def find_operands(group):
    """Representations below a summation, multiplication or filter operator"""
    if "com.xrite.Operands" in group:
        ops = group["com.xrite.Operands"]
        return [ops[k] for k in sorted(ops.keys(), key=lambda k: int(k) if k.isdigit() else 0)]
    if "com.xrite.Input" in group:
        return [group["com.xrite.Input"]]
    return []


def walk_models(group):
    """All the models (leaves) of a representation tree, with their filters"""
    t = axf_type(group)
    children = find_operands(group)
    if not children:
        return [group]
    models = []
    for c in children:
        models += walk_models(c)
    return models


def resource_locations(model, name):
    res = model.get("com.xrite.Resources")
    if res is None or name not in res:
        return []
    return [l for l in np.atleast_1d(res[name]["ResourceLocations"][()])]


# ---------------------------------------------------------------- Image output

def write_png(path, data):
    """Writes an 8-bit PNG (data: H x W x C uint8, C in 1, 3, 4)"""
    if data.ndim == 2:
        data = data[:, :, None]
    h, w, c = data.shape
    color_type = {1: 0, 3: 2, 4: 6}[c]
    raw = b"".join(b"\x00" + data[y].tobytes() for y in range(h))

    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, color_type, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


def to_srgb(linear):
    linear = np.clip(linear, 0.0, 1.0)
    return np.where(linear <= 0.0031308, linear * 12.92, 1.055 * np.power(linear, 1.0 / 2.4) - 0.055)


def quantize(values):
    return np.clip(np.round(values * 255.0), 0, 255).astype(np.uint8)


def resize(data, width, height):
    """Box/bilinear resampling of an H x W x C image"""
    h, w = data.shape[:2]
    if (h, w) == (height, width):
        return data
    # Box filter for integer downscaling, then bilinear
    while h >= 2 * height and w >= 2 * width:
        data = 0.25 * (data[0:h - h % 2:2, 0:w - w % 2:2] + data[1:h - h % 2:2, 0:w - w % 2:2] +
                       data[0:h - h % 2:2, 1:w - w % 2:2] + data[1:h - h % 2:2, 1:w - w % 2:2])
        h, w = data.shape[:2]
    y = (np.arange(height) + 0.5) * h / height - 0.5
    x = (np.arange(width) + 0.5) * w / width - 0.5
    y0 = np.clip(np.floor(y).astype(int), 0, h - 1)
    x0 = np.clip(np.floor(x).astype(int), 0, w - 1)
    y1 = np.clip(y0 + 1, 0, h - 1)
    x1 = np.clip(x0 + 1, 0, w - 1)
    fy = np.clip(y - y0, 0, 1)[:, None, None]
    fx = np.clip(x - x0, 0, 1)[None, :, None]
    return ((data[y0][:, x0] * (1 - fx) + data[y0][:, x1] * fx) * (1 - fy) +
            (data[y1][:, x0] * (1 - fx) + data[y1][:, x1] * fx) * fy)


class Output:
    """Textures and nodes of a generated graph"""

    def __init__(self, directory, name, options):
        self.directory = directory
        self.name = name
        self.options = options
        self.texture_dir = os.path.join(directory, name + "_textures")
        self.nodes = []
        self.connections = []
        self.size = 0

    def fit(self, data):
        """A texture as written: square (cropped or stretched), at most
        max_size, power of two sizes are kept"""
        h, w = data.shape[:2]
        if h != w:
            if self.options.fit == "crop":
                s = min(h, w)
                data = data[(h - s) // 2:(h - s) // 2 + s, (w - s) // 2:(w - s) // 2 + s]
            else:
                s = max(h, w)
                data = resize(data, s, s)
        s = min(data.shape[0], self.options.max_size)
        if s != data.shape[0]:
            data = resize(data, s, s)
        self.size = max(self.size, data.shape[0])
        return data

    def texture(self, file_name, data, fit=True):
        """Writes a texture (floats in [0, 1], already encoded) and returns its
        path as stored in the graph"""
        os.makedirs(self.texture_dir, exist_ok=True)
        if fit:
            data = self.fit(data)
        write_png(os.path.join(self.texture_dir, file_name), quantize(data))
        return "%PROJECT_PATH%/" + self.name + "_textures/" + file_name

    def image_node(self, node_name, path, y):
        self.nodes.append({"name": node_name, "type": "image", "node_position": {"x": -600, "y": y},
                           "parameters": {"image": path, "color_space": 0}})
        return node_name

    def connect(self, from_node, from_port, to_node, to_port):
        self.connections.append({"from": from_node, "from_port": from_port, "to": to_node, "to_port": to_port})

    def write_graph(self, file_name, material, label):
        graph = {"connections": self.connections, "label": label, "name": "axf_import",
                 "node_position": {"x": 0, "y": 0}, "nodes": [material] + self.nodes,
                 "parameters": {}, "type": "graph"}
        path = os.path.join(self.directory, file_name)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(graph, f, indent="\t")
        return path


def size_parameter(size):
    """The Material node's size parameter (log2) for a texture size"""
    return int(min(max(round(math.log2(max(size, 16))), 4), 13))


# ---------------------------------------------------------------- SVBRDF

def perceived_brightness(c):
    return np.sqrt(0.299 * c[..., 0] ** 2 + 0.587 * c[..., 1] ** 2 + 0.114 * c[..., 2] ** 2)


def specular_to_metallic(diffuse, specular):
    """Converts diffuse and specular (F0) colors to base color and metallic
    (as glTF's KHR_materials_pbrSpecularGlossiness conversion)"""
    one_minus_specular = 1.0 - np.max(specular, axis=-1)
    d = perceived_brightness(diffuse)
    s = perceived_brightness(specular)
    a = DIELECTRIC_F0
    b = d * one_minus_specular / (1.0 - DIELECTRIC_F0) + s - 2.0 * DIELECTRIC_F0
    c = DIELECTRIC_F0 - s
    discriminant = np.maximum(b * b - 4.0 * a * c, 0.0)
    metallic = np.clip((-b + np.sqrt(discriminant)) / (2.0 * a), 0.0, 1.0)
    metallic = np.where(s < DIELECTRIC_F0, 0.0, metallic)
    m = metallic[..., None]
    from_diffuse = diffuse * (one_minus_specular / (1.0 - DIELECTRIC_F0) / np.maximum(1.0 - metallic, 1e-4))[..., None]
    from_specular = (specular - DIELECTRIC_F0 * (1.0 - m)) / np.maximum(m, 1e-4)
    base = np.clip(from_diffuse + (from_specular - from_diffuse) * m * m, 0.0, 1.0)
    return base, metallic


def lobe_alpha(model, lobes):
    """GGX alpha (x and y) of a specular lobe resource"""
    t = axf_type(model)
    params = lobes.data if lobes.data.ndim == 3 else lobes.data.reshape(1, 1, -1)
    if "BlinnPhong" in t:
        # Blinn-Phong exponent to Beckmann/GGX alpha
        alpha = np.sqrt(2.0 / (params + 2.0))
    else:
        # Ward and Cook-Torrance (Beckmann) slopes are close to GGX alphas
        alpha = params
    alpha = np.clip(alpha, 0.002, 1.0)
    if alpha.shape[-1] >= 2:
        return alpha[..., 0], alpha[..., 1]
    return alpha[..., 0], alpha[..., 0]


def convert_svbrdf(axf, out, warnings):
    rep = axf.representation()
    models = walk_models(rep)
    coat = axf_type(rep) == "com.xrite.ClearCoatFilter"
    diffuse = specular = normal = alphas = fresnel = None
    spec_model = None
    for m in models:
        t = axf_type(m)
        if "Diffuse" in t:
            for loc in resource_locations(m, "Color"):
                diffuse = axf.resource(loc)
            for loc in resource_locations(m, "Normal"):
                normal = axf.resource(loc)
        elif "Specular" in t:
            spec_model = m
            for loc in resource_locations(m, "Color"):
                specular = axf.resource(loc)
            for loc in resource_locations(m, "Lobes"):
                alphas = lobe_alpha(m, axf.resource(loc))
            for loc in resource_locations(m, "Fresnel"):
                fresnel = axf.resource(loc)
            for loc in resource_locations(m, "Normal"):
                normal = normal or axf.resource(loc)
            if "AnisoRotation" in m.get("com.xrite.Resources", {}):
                warnings.append("the anisotropy direction (AnisoRotation) is not imported: anisotropy is along the U axis")
        elif t:
            warnings.append("unsupported model %s" % t)
    if diffuse is None and specular is None:
        raise ValueError("no diffuse or specular model in the representation")

    def color(resource, default):
        if resource is None:
            return default
        data = resource.data
        if data.ndim < 3:
            data = np.broadcast_to(data.reshape(1, 1, -1)[..., :3], (1, 1, 3)) if data.size >= 3 else np.full((1, 1, 3), float(data.ravel()[0]))
        return np.einsum("ij,yxj->yxi", axf.color_matrix(resource.color_spec), data[..., :3])

    d = color(diffuse, np.zeros((1, 1, 3)))
    s = color(specular, np.zeros((1, 1, 3)))
    if fresnel is not None:
        # The specular color is scaled by the Fresnel reflectance at normal
        # incidence (F0)
        f0 = fresnel.data if fresnel.data.ndim == 3 else fresnel.data.reshape(1, 1, -1)
        s = s * f0[..., :1]
    shape = np.broadcast_shapes(d.shape[:2], s.shape[:2], *((alphas[0].shape[:2],) if alphas is not None else ()))
    d = np.broadcast_to(d, shape + (3,))
    s = np.broadcast_to(s, shape + (3,))
    base, metallic = specular_to_metallic(np.clip(d, 0, 1), np.clip(s, 0, 1))

    material = {"name": "Material", "type": "material", "node_position": {"x": 0, "y": 0},
                "parameters": {"albedo_color": {"type": "Color", "r": 1, "g": 1, "b": 1, "a": 1},
                               "metallic": 1.0, "roughness": 1.0, "normal": 1.0, "ao": 1.0,
                               "emission_energy": 1.0, "depth_scale": 0.0, "flags_transparent": False}}
    y = -300
    out.connect(out.image_node("albedo", out.texture("albedo.png", to_srgb(base)), y), 0, "Material", MATERIAL_INPUTS.index("albedo_tex"))
    y += 150
    out.connect(out.image_node("metallic", out.texture("metallic.png", metallic[..., None]), y), 0, "Material", MATERIAL_INPUTS.index("metallic_tex"))
    if alphas is not None:
        ax, ay = np.broadcast_to(alphas[0], shape), np.broadcast_to(alphas[1], shape)
        alpha = np.sqrt(ax * ay)
        y += 150
        out.connect(out.image_node("roughness", out.texture("roughness.png", np.sqrt(alpha)[..., None]), y), 0, "Material", MATERIAL_INPUTS.index("roughness_tex"))
        if not np.allclose(ax, ay):
            # Godot's anisotropy: alpha x = alpha / sqrt(1-0.9a), alpha y = alpha * sqrt(1-0.9a)
            ratio = np.minimum(ax, ay) / np.maximum(ax, ay)
            anisotropy = np.clip((1.0 - ratio) / 0.9, 0.0, 1.0)
            if np.mean(ay > ax) > 0.5:
                warnings.append("the material is mostly rougher along V than U: its anisotropy is imported along U")
            y += 150
            out.connect(out.image_node("anisotropy", out.texture("anisotropy.png", anisotropy[..., None]), y), 0, "Material", MATERIAL_INPUTS.index("anisotropy_tex"))
            material["parameters"]["anisotropy"] = 1.0
    else:
        material["parameters"]["roughness"] = 0.5
    if normal is not None and normal.data.ndim == 3:
        n = normal.data[..., :3]
        n = n / np.maximum(np.linalg.norm(n, axis=-1, keepdims=True), 1e-6)
        y += 150
        out.image_node("normal", out.texture("normal.png", n * 0.5 + 0.5), y)
        # The AxF normals are OpenGL tangent space normals
        out.nodes.append({"name": "normal_from_opengl", "type": "normal_map_convert", "node_position": {"x": -300, "y": y}, "parameters": {"op": 0}})
        out.connect("normal", 0, "normal_from_opengl", 0)
        out.connect("normal_from_opengl", 0, "Material", MATERIAL_INPUTS.index("normal_tex"))
    if coat:
        material["parameters"]["coat"] = 1.0
        material["parameters"]["coat_roughness"] = 0.0
    material["parameters"]["size"] = size_parameter(out.size)
    return material


# ---------------------------------------------------------------- Car paint

def fresnel_dielectric(cos_i, ior):
    """Fresnel reflectance of an interface (from the outside, n=ior)"""
    cos_i = np.clip(cos_i, 0.0, 1.0)
    sin_t2 = (1.0 - cos_i * cos_i) / (ior * ior)
    cos_t = np.sqrt(np.maximum(1.0 - sin_t2, 0.0))
    rs = (cos_i - ior * cos_t) / (cos_i + ior * cos_t)
    rp = (ior * cos_i - cos_t) / (ior * cos_i + cos_t)
    return 0.5 * (rs * rs + rp * rp)


class CarPaint:
    """The CarPaint2 model, evaluated as the Car Paint node's shader does"""

    def __init__(self, diffuse, lobes, table, ior, refraction):
        self.diffuse = diffuse          # Lambert albedo (scalar)
        self.lobes = lobes              # [ (coefficient, spread, F0) ]
        self.table = table              # theta D (rows) x theta H (columns) x RGB
        self.ior = ior
        self.refraction = refraction

    def table_lookup(self, theta_h, theta_d):
        n_d, n_h = self.table.shape[:2]
        x = np.clip(theta_h / (0.5 * np.pi), 0, 1) * (n_h - 1)
        y = np.clip(theta_d / (0.5 * np.pi), 0, 1) * (n_d - 1)
        x0 = np.floor(x).astype(int)
        y0 = np.floor(y).astype(int)
        x1 = np.minimum(x0 + 1, n_h - 1)
        y1 = np.minimum(y0 + 1, n_d - 1)
        fx = (x - x0)[..., None]
        fy = (y - y0)[..., None]
        t = self.table
        return (t[y0, x0] * (1 - fx) + t[y0, x1] * fx) * (1 - fy) + (t[y1, x0] * (1 - fx) + t[y1, x1] * fx) * fy

    def refract_cos(self, cos_theta):
        if not self.refraction:
            return cos_theta
        sin2 = (1.0 - cos_theta * cos_theta) / (self.ior * self.ior)
        return np.sqrt(np.maximum(1.0 - sin2, 0.0))

    def brdf(self, light, view):
        """BRDF (RGB) for unit light and view directions (..., 3), in the
        tangent frame (z is the normal), without flakes"""
        nl, nv = light[..., 2], view[..., 2]
        valid = (nl > 1e-3) & (nv > 1e-3)
        # Directions below the clear coat
        def refract(d):
            if not self.refraction:
                return d
            c = self.refract_cos(d[..., 2])
            s = np.sqrt(np.maximum(1.0 - c * c, 0.0))
            planar = d[..., :2]
            norm = np.maximum(np.linalg.norm(planar, axis=-1, keepdims=True), 1e-8)
            return np.concatenate([planar / norm * s[..., None], c[..., None]], axis=-1)
        l2, v2 = refract(light), refract(view)
        h = l2 + v2
        h /= np.maximum(np.linalg.norm(h, axis=-1, keepdims=True), 1e-8)
        nh = np.clip(h[..., 2], 1e-4, 1.0)
        vh = np.clip(np.sum(v2 * h, axis=-1), 0.0, 1.0)
        nl2 = np.clip(l2[..., 2], 1e-3, 1.0)
        nv2 = np.clip(v2[..., 2], 1e-3, 1.0)
        theta_h = np.arccos(nh)
        theta_d = np.arccos(np.clip(np.sum(l2 * h, axis=-1), -1.0, 1.0))
        g = np.minimum(1.0, np.minimum(2.0 * nh * nv2 / np.maximum(vh, 1e-4), 2.0 * nh * nl2 / np.maximum(vh, 1e-4)))
        specular = np.zeros_like(nh)
        for coeff, spread, f0 in self.lobes:
            if coeff <= 0.0:
                continue
            c2 = nh * nh
            d = np.exp((c2 - 1.0) / (c2 * spread * spread)) / (spread * spread * c2 * c2)
            f = f0 + (1.0 - f0) * (1.0 - vh) ** 5
            specular = specular + coeff * d * f
        specular = specular * g / (np.pi * nl2 * nv2)
        result = (self.diffuse / np.pi + specular)[..., None] * self.table_lookup(theta_h, theta_d)
        # Light crosses the clear coat twice
        transmission = (1.0 - fresnel_dielectric(nl, self.ior)) * (1.0 - fresnel_dielectric(nv, self.ior))
        return np.where(valid[..., None], result * transmission[..., None], 0.0)

    def directional_albedo(self, theta_v, n_theta=64, n_phi=96):
        """Reflectance under uniform lighting for a view angle (RGB), without
        the clear coat's own reflection"""
        t = (np.arange(n_theta) + 0.5) / n_theta * 0.5 * np.pi
        p = (np.arange(n_phi) + 0.5) / n_phi * 2.0 * np.pi
        tt, pp = np.meshgrid(t, p, indexing="ij")
        light = np.stack([np.sin(tt) * np.cos(pp), np.sin(tt) * np.sin(pp), np.cos(tt)], axis=-1)
        view = np.array([np.sin(theta_v), 0.0, np.cos(theta_v)])
        f = self.brdf(light, np.broadcast_to(view, light.shape))
        weight = (np.cos(tt) * np.sin(tt))[..., None] * (0.5 * np.pi / n_theta) * (2.0 * np.pi / n_phi)
        return np.sum(f * weight, axis=(0, 1))

    def specular_albedo(self, theta_v):
        diffuse = self.diffuse
        self.diffuse = 0.0
        a = self.directional_albedo(theta_v)
        self.diffuse = diffuse
        return a


def encode_flakes(data, scale):
    """Flake BTF values (around 0) to [0, 1]: square root companding"""
    v = np.clip(data / scale, -1.0, 1.0)
    return 0.5 + 0.5 * np.sign(v) * np.sqrt(np.abs(v))


def convert_car_paint(axf, out, warnings):
    rep = axf.representation()
    res = axf.resources
    cp = res["CarPaint2"]
    ior_location = resource_locations(rep, "IOR")
    ior = float(np.ravel(axf.resource(ior_location[0]).data)[0]) if ior_location else 1.5
    refraction = not bool(np.asarray(rep["NoRefraction"][()])) if "NoRefraction" in rep else True
    diffuse_value = np.ravel(axf.resource("CarPaint2/DiffuseModel/Color").data)
    diffuse = float(np.mean(diffuse_value))
    lobes = []
    flakes_model = table_resource = None
    for m in walk_models(rep):
        t = axf_type(m)
        if t == "com.xrite.CookTorranceSpecularModel":
            for loc in resource_locations(m, "Lobes"):
                lobes.append(tuple(float(v) for v in np.ravel(axf.resource(loc).data)[:3]))
        elif t == "com.xrite.TabulatedBrdf":
            table_resource = axf.resource(resource_locations(m, "Data")[0])
        elif t == "com.xrite.FlakesBtf":
            flakes_model = m
    if table_resource is None:
        raise ValueError("no BRDF color table")
    table = np.einsum("ij,yxj->yxi", axf.color_matrix(table_resource.color_spec), table_resource.data[..., :3])
    table = np.maximum(table, 0.0)
    paint = CarPaint(diffuse, lobes, table, ior, refraction)

    # Color table: theta D rows, theta H columns, stored as sRGB divided by its scale
    table_scale = float(max(table.max(), 1e-6))
    color_table_path = out.texture("color_table.png", to_srgb(table / table_scale), fit=False)
    # Directional albedo for ambient lighting, along theta V
    angles = (np.arange(64) + 0.5) / 64 * 0.5 * np.pi
    ambient = np.array([paint.directional_albedo(a) for a in angles])
    ambient_scale = float(max(ambient.max(), 1e-6))
    ambient_path = out.texture("ambient.png", np.repeat(to_srgb(ambient / ambient_scale)[None], 4, axis=0), fit=False)

    params = {
        "diffuse": diffuse, "ior": ior, "refraction": refraction,
        "color_table_scale": table_scale, "ambient_scale": ambient_scale,
        "flake_scale": 1.0, "flake_intensity": 1.0, "flake_tiling": 4.0,
        "flake_theta_f_slices": 24, "flake_theta_i_slices": 24, "flake_max_theta_f": 0, "flake_max_theta_i": 0,
    }
    for i in range(3):
        coeff, spread, f0 = lobes[i] if i < len(lobes) else (0.0, 0.5, 1.0)
        params["coeff%d" % i] = coeff
        params["spread%d" % i] = spread
        params["f0_%d" % i] = f0
    nodes = {"color_table": color_table_path, "ambient": ambient_path}
    if flakes_model is not None:
        lut = np.asarray(flakes_model["PatchesLookupTable"])
        locations = resource_locations(flakes_model, "Data")
        size = axf.options.flake_size
        rows, cols = lut.shape
        atlas = np.zeros((rows * size, cols * size, 3), dtype=np.float32)
        maximum = 1e-6
        patches = {}
        for (r, c), index in np.ndenumerate(lut):
            if index < 0:
                continue
            patch = axf.resource(locations[index])
            data = np.einsum("ij,yxj->yxi", axf.color_matrix(patch.color_spec), patch.data[..., :3])
            data = resize(data, size, size)
            patches[(r, c)] = data
            maximum = max(maximum, float(np.percentile(np.abs(data), 99.9)))
        for (r, c), data in patches.items():
            atlas[r * size:(r + 1) * size, c * size:(c + 1) * size] = encode_flakes(data, maximum)
        # Empty cells are 0 (encoded as 0.5)
        for (r, c), index in np.ndenumerate(lut):
            if index < 0:
                atlas[r * size:(r + 1) * size, c * size:(c + 1) * size] = 0.5
        nodes["flakes"] = out.texture("flakes.png", atlas, fit=False)
        params["flake_scale"] = maximum
        params["flake_theta_f_slices"] = int(np.asarray(flakes_model["NumThetaF"]))
        params["flake_theta_i_slices"] = int(np.asarray(flakes_model["NumThetaI"]))
        params["flake_max_theta_f"] = cols
        params["flake_max_theta_i"] = rows
    else:
        nodes["flakes"] = out.texture("flakes.png", np.full((4, 4, 3), 0.5), fit=False)
    material = {"name": "Material", "type": "material_car_paint", "node_position": {"x": 0, "y": 0}, "parameters": params}
    y = -200
    for i, input_name in enumerate(CAR_PAINT_INPUTS):
        out.connect(out.image_node(input_name, nodes[input_name], y), 0, "Material", i)
        y += 150
    return material, paint


def car_paint_pbr(axf, paint, out):
    """A static PBR approximation of a car paint (for exports to other
    engines): its reflectance seen from the front as the base color, metallic
    for the part reflected by the specular lobes (metallic flakes reflect
    tinted light), and a smooth clear coat"""
    total = paint.directional_albedo(0.2)
    specular = paint.specular_albedo(0.2)
    metallic = float(np.clip(np.mean(specular) / max(float(np.mean(total)), 1e-6), 0.0, 1.0))
    # Roughness of the lobes, weighted by what they reflect
    weights = [coeff * f0 for coeff, spread, f0 in paint.lobes]
    weight_sum = max(sum(weights), 1e-9)
    spread = sum(w * lobe[1] for w, lobe in zip(weights, paint.lobes)) / weight_sum
    srgb = to_srgb(np.clip(total, 0.0, 1.0))
    material = {"name": "Material", "type": "material", "node_position": {"x": 0, "y": 0},
                "parameters": {"albedo_color": {"type": "Color", "r": float(srgb[0]), "g": float(srgb[1]), "b": float(srgb[2]), "a": 1.0},
                               "metallic": float(math.sqrt(metallic)), "roughness": float(min(math.sqrt(max(spread, 0.002)), 1.0)),
                               "coat": 1.0, "coat_roughness": 0.0, "normal": 1.0, "ao": 1.0,
                               "emission_energy": 1.0, "depth_scale": 0.0, "flags_transparent": False, "size": 9}}
    return material


# ---------------------------------------------------------------- BTF

def convert_btf(axf, out, warnings):
    """Decodes a DPVF BTF and fits a Lambert + isotropic GGX SVBRDF"""
    import axf_btf
    return axf_btf.convert(axf, out, warnings)


# ---------------------------------------------------------------- Main

def convert(path, options):
    """Converts an AxF file, returns the written graphs and warnings"""
    directory = options.output or os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    written = []
    warnings = []
    with h5py.File(path, "r") as f:
        materials = list(f["com.xrite.Materials"].keys())
        for material_name in materials:
            axf = AxFMaterial(f, material_name)
            axf.options = options
            base = os.path.splitext(os.path.basename(path))[0] if len(materials) == 1 else material_name
            rep = axf.representation()
            kind = text(rep["RepresentationClass"]) if "RepresentationClass" in rep else axf_type(rep)
            out = Output(directory, base, options)
            if kind.startswith("CarPaint"):
                material, paint = convert_car_paint(axf, out, warnings)
                written.append(out.write_graph(base + ".ptex", material, base))
                pbr = Output(directory, base, options)
                written.append(pbr.write_graph(base + "_pbr.ptex", car_paint_pbr(axf, paint, pbr), base + " (PBR approximation)"))
            elif kind in ("SVBRDF", "com.xrite.Svbrdf") or "Svbrdf" in kind:
                material = convert_svbrdf(axf, out, warnings)
                written.append(out.write_graph(base + ".ptex", material, base))
            elif "Dpvf" in axf_type(rep) or kind.startswith("BTF"):
                material = convert_btf(axf, out, warnings)
                written.append(out.write_graph(base + ".ptex", material, base))
            else:
                warnings.append("%s: unsupported representation %s" % (material_name, kind))
    return written, warnings


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("inputs", nargs="+")
    parser.add_argument("-o", "--output", default="")
    parser.add_argument("--fit", choices=["crop", "stretch"], default="crop")
    parser.add_argument("--max-size", type=int, default=2048)
    parser.add_argument("--flake-size", type=int, default=240)
    parser.add_argument("--report", default="")
    options = parser.parse_args(argv)
    report = {"files": [], "warnings": [], "errors": []}
    if MISSING_MODULES:
        print("ERROR: " + MISSING_MODULES, file=sys.stderr)
        report["errors"].append(MISSING_MODULES)
        options.inputs = []
    for path in options.inputs:
        try:
            written, warnings = convert(path, options)
        except (OSError, KeyError, ValueError) as e:
            print("ERROR: %s: %s" % (path, e), file=sys.stderr)
            report["errors"].append("%s: %s" % (os.path.basename(path), e))
            continue
        for w in warnings:
            print("warning: %s: %s" % (os.path.basename(path), w), file=sys.stderr)
            report["warnings"].append("%s: %s" % (os.path.basename(path), w))
        for w in written:
            print("Wrote %s" % w)
            report["files"].append(os.path.abspath(w).replace("\\", "/"))
    if options.report:
        with open(options.report, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=1)
    return 1 if report["errors"] else 0


if __name__ == "__main__":
    sys.exit(main())
