"""BTF support for axf2ptex: decodes AxF DPVF BTFs (per view PCA factorized
apparent reflectance, for 81 light and 81 view directions) and fits a
Lambert + isotropic GGX SVBRDF with normals.

- Normals and the diffuse color come from photometric stereo on the head-on
  view (lights between 15 and 60 degrees, so specular highlights are left
  out).
- The specular part is fitted on what is left, for view and light directions
  up to 60 degrees: for each texel, the GGX roughness among a set of
  roughnesses that explains it best, and its scale (F0).

A BTF also captures parallax, shadowing and interreflections, that an SVBRDF
cannot reproduce: the result is an approximation for real time engines."""

import numpy as np

import axf2ptex as axf_lib

MAX_THETA = np.radians(61.0)
ROUGHNESS_GRID = np.linspace(0.05, 0.9, 18)
# Light and view pairs of the specular fit: all those near the mirror
# direction, and some others
NEAR_SPECULAR = np.radians(25.0)
OTHER_PAIRS = 600


def directions(table):
    theta = np.asarray(table["Theta"], dtype=np.float64)
    phi = np.asarray(table["Phi"], dtype=np.float64)
    return np.stack([np.sin(theta) * np.cos(phi), np.sin(theta) * np.sin(phi), np.cos(theta)], axis=-1)


class Dpvf:
    """Decoder of a DPVF BTF: values (lights x texels) of a view and channel"""

    def __init__(self, axf):
        rep = axf.representation()
        res = rep["com.xrite.Resources/Chunks"]
        pairs = np.asarray(res["ChannelChunkPairs"])
        locations = np.asarray(res["ResourceLocations"])
        self.chunks = {(int(p["Channel"]), int(p["Chunk"])): axf.resources[l.decode() if isinstance(l, bytes) else l] for p, l in zip(pairs, locations)}
        self.lights = directions(rep["Lights"])
        self.views = directions(rep["Views"])
        group = axf.resources[locations[0].decode().rsplit("/", 1)[0]]
        self.width = int(np.asarray(group["WidthPixel"]))
        self.height = int(np.asarray(group["HeightPixel"]))
        self.color_spec = axf_lib.text(group["ColorSpec"]) if "ColorSpec" in group else ""
        self.decorrelating = np.asarray(rep["DecorrelatingTransform"], dtype=np.float64)
        self.cache = {}

    def factors(self, channel, view):
        key = (channel, view)
        if key not in self.cache:
            c = self.chunks[key]
            self.cache[key] = (np.asarray(c["MatrixU"], dtype=np.float32), np.asarray(c["MatrixSxV"], dtype=np.float32))
        return self.cache[key]

    def values(self, channel, view, lights):
        """Apparent reflectance (BRDF times cos theta light) of the texels for
        some lights of a view: lights x texels"""
        u, sxv = self.factors(channel, view)
        return u[lights] @ sxv.T


def ggx_specular(n, l, v, alpha):
    """GGX specular (F=1) times cos theta light: texels x pairs"""
    h = l + v
    h = h / np.linalg.norm(h, axis=-1, keepdims=True)
    nl = np.clip(np.einsum("tc,pc->tp", n, l), 0.0, 1.0)
    nv = np.clip(np.einsum("tc,pc->tp", n, v), 1e-3, 1.0)
    nh = np.clip(np.einsum("tc,pc->tp", n, h), 0.0, 1.0)
    a2 = alpha * alpha
    d = a2 / (np.pi * (nh * nh * (a2 - 1.0) + 1.0) ** 2)
    k = alpha / 2.0
    g = (nl / (nl * (1.0 - k) + k)) * (nv / (nv * (1.0 - k) + k))
    return d * g / (4.0 * np.maximum(nl, 1e-3) * nv) * nl


def convert(axf, out, warnings):
    btf = Dpvf(axf)
    texels = btf.width * btf.height
    lights, views = btf.lights, btf.views
    head_on = int(np.argmax(views[:, 2]))
    # Photometric stereo on the head-on view, without the specular highlight
    light_theta = np.arccos(np.clip(lights[:, 2], -1, 1))
    ps = np.where((light_theta > np.radians(14.0)) & (light_theta < MAX_THETA))[0]
    l_ps = lights[ps]
    y = btf.values(0, head_on, ps).astype(np.float64)          # lights x texels
    g = np.linalg.lstsq(l_ps, y, rcond=None)[0].T              # texels x 3
    albedo_y = np.linalg.norm(g, axis=1)
    n = g / np.maximum(albedo_y[:, None], 1e-8)
    n[n[:, 2] < 0.2] = [0.0, 0.0, 1.0]
    n /= np.linalg.norm(n, axis=1, keepdims=True)
    # Light and view pairs of the specular fit (views and lights up to 60
    # degrees)
    view_theta = np.arccos(np.clip(views[:, 2], -1, 1))
    rng = np.random.default_rng(0)
    selected = {}
    for v in np.where(view_theta < MAX_THETA)[0]:
        ls = np.where(light_theta < MAX_THETA)[0]
        h = lights[ls] + views[v]
        theta_h = np.arccos(np.clip(h[:, 2] / np.linalg.norm(h, axis=1), -1, 1))
        selected[v] = list(ls[theta_h < NEAR_SPECULAR])
    others = [(v, l) for v in selected for l in np.where(light_theta < MAX_THETA)[0] if l not in selected[v]]
    for i in rng.choice(len(others), size=min(OTHER_PAIRS, len(others)), replace=False):
        selected[others[i][0]].append(others[i][1])
    pair_l, pair_v, samples = [], [], []
    for v, ls in selected.items():
        ls = np.array(sorted(ls))
        pair_l.append(lights[ls])
        pair_v.append(np.repeat(views[v][None], len(ls), axis=0))
        samples.append(btf.values(0, v, ls))                   # lights x texels
    pair_l = np.concatenate(pair_l)
    pair_v = np.concatenate(pair_v)
    samples = np.concatenate(samples).T.astype(np.float32)     # texels x pairs
    # A gray specular reflection in the decorrelated channels
    gray_dec = np.linalg.solve(btf.decorrelating.T, np.ones(3))
    head_on_values = [btf.values(c, head_on, ps).astype(np.float64) for c in range(3)]
    shading = np.clip(l_ps @ n.T, 0.0, 1.0)                    # lights x texels
    head_on_v = np.repeat(views[head_on][None], len(ps), axis=0)
    spec_scale = np.zeros(texels)
    spec_alpha = np.full(texels, ROUGHNESS_GRID[-1] ** 2)
    # Alternate the diffuse fit (without the specular reflection) and the
    # specular fit (without the diffuse reflection)
    for iteration in range(3):
        spec_head_on = np.zeros((len(ps), texels))
        for a in np.unique(spec_alpha):
            mask = spec_alpha == a
            spec_head_on[:, mask] = ggx_specular(n[mask], l_ps, head_on_v, a).T * spec_scale[mask]
        if iteration > 0:
            # Normals again, without the specular reflection
            g = np.linalg.lstsq(l_ps, head_on_values[0] - spec_head_on * gray_dec[0], rcond=None)[0].T
            n = g / np.maximum(np.linalg.norm(g, axis=1, keepdims=True), 1e-8)
            n[n[:, 2] < 0.2] = [0.0, 0.0, 1.0]
            n /= np.linalg.norm(n, axis=1, keepdims=True)
            shading = np.clip(l_ps @ n.T, 0.0, 1.0)
        # Diffuse (albedo / pi) of each decorrelated channel
        diffuse_dec = np.zeros((texels, 3))
        for c in range(3):
            values = head_on_values[c] - spec_head_on * gray_dec[c]
            diffuse_dec[:, c] = np.sum(values * shading, axis=0) / np.maximum(np.sum(shading * shading, axis=0), 1e-8)
        diffuse_model = diffuse_dec[:, 0][:, None] * np.clip(n @ pair_l.T, 0.0, 1.0)
        residual = samples - diffuse_model
        best_error = np.full(texels, np.inf)
        total = np.sum(residual * residual, axis=1)
        for r in ROUGHNESS_GRID:
            alpha = r * r
            basis = ggx_specular(n, pair_l, pair_v, alpha)     # texels x pairs
            bb = np.sum(basis * basis, axis=1)
            rb = np.sum(residual * basis, axis=1)
            scale = np.clip(rb / np.maximum(bb, 1e-12), 0.0, None)
            error = total - 2.0 * scale * rb + scale * scale * bb
            better = error < best_error
            best_error[better] = error[better]
            spec_scale[better] = scale[better] / gray_dec[0]
            spec_alpha[better] = alpha
    best_alpha = spec_alpha
    # Decorrelated channels to RGB (rgb = transform transposed x channels,
    # the first channel is the gray level), then the color spec to linear sRGB
    rgb = diffuse_dec @ btf.decorrelating * np.pi
    rgb = rgb @ axf.color_matrix(btf.color_spec).T
    specular = np.repeat(spec_scale[:, None], 3, axis=1)

    h, w = btf.height, btf.width
    def image(a):
        return a.reshape(h, w, -1)
    # Texture orientation: the normals' y axis is up when the curl of their
    # slopes is smallest
    nimg = image(n)
    nz = np.maximum(nimg[..., 2], 0.2)
    sx, sy = -nimg[..., 0] / nz, -nimg[..., 1] / nz
    curl_up = np.mean((np.gradient(sx, axis=0) + np.gradient(sy, axis=1)) ** 2)
    curl_down = np.mean((np.gradient(sx, axis=0) - np.gradient(sy, axis=1)) ** 2)
    flip = curl_down < curl_up
    def oriented(a):
        return a[::-1] if flip else a

    base, metallic = axf_lib.specular_to_metallic(np.clip(image(rgb), 0, 1), np.clip(image(specular), 0, 1))
    roughness = np.sqrt(image(best_alpha[:, None]))
    normal = oriented(nimg) * 0.5 + 0.5
    warnings.append("BTF fitted to an SVBRDF: parallax, self-shadowing and interreflections are not reproduced")
    material = {"name": "Material", "type": "material", "node_position": {"x": 0, "y": 0},
                "parameters": {"albedo_color": {"type": "Color", "r": 1, "g": 1, "b": 1, "a": 1},
                               "metallic": 1.0, "roughness": 1.0, "normal": 1.0, "ao": 1.0,
                               "emission_energy": 1.0, "depth_scale": 0.0, "flags_transparent": False}}
    ports = axf_lib.MATERIAL_INPUTS
    y_pos = -300
    out.connect(out.image_node("albedo", out.texture("albedo.png", axf_lib.to_srgb(oriented(base))), y_pos), 0, "Material", ports.index("albedo_tex"))
    y_pos += 150
    out.connect(out.image_node("metallic", out.texture("metallic.png", oriented(metallic[..., None])), y_pos), 0, "Material", ports.index("metallic_tex"))
    y_pos += 150
    out.connect(out.image_node("roughness", out.texture("roughness.png", oriented(roughness)), y_pos), 0, "Material", ports.index("roughness_tex"))
    y_pos += 150
    out.image_node("normal", out.texture("normal.png", normal), y_pos)
    out.nodes.append({"name": "normal_from_opengl", "type": "normal_map_convert", "node_position": {"x": -300, "y": y_pos}, "parameters": {"op": 0}})
    out.connect("normal", 0, "normal_from_opengl", 0)
    out.connect("normal_from_opengl", 0, "Material", ports.index("normal_tex"))
    material["parameters"]["size"] = axf_lib.size_parameter(out.size)
    # Fit quality, for the report
    explained = 1.0 - np.sum(best_error) / max(float(np.sum(samples.astype(np.float64) ** 2)), 1e-12)
    warnings.append("BTF fit: %.1f%% of the signal explained (normal map %s)" % (100.0 * explained, "flipped" if flip else "as is"))
    return material
