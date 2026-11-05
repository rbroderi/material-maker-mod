# Material Maker Runtime for Blender
#
# Imports Material Maker runtime packages (.mmr) as materials whose parameters
# can be changed in Blender. Textures are rendered by mmr_render (the C++
# runtime, see runtime/cpp), and the material uses them in a Principled BSDF.

import json
import os
import shutil
import subprocess
import tempfile
import uuid
import zipfile

import bpy
from bpy.props import BoolProperty, StringProperty
from bpy_extras.io_utils import ImportHelper

bl_info = {
    "name": "Material Maker Runtime",
    "author": "Material Maker contributors",
    "version": (1, 0, 0),
    "blender": (4, 2, 0),
    "location": "File > Import > Material Maker package (.mmr), Material Properties",
    "description": "Imports Material Maker runtime packages as materials with editable parameters",
    "category": "Import-Export",
}

# Custom properties of the materials made from packages
PACKAGE_KEY = "mmr_package"
PARAMETER_PREFIX = "mmr:"
# Size of the rendered textures (0: the size they were exported with)
SIZE_KEY = "mmr_size"
# Folder (in the temporary folder) the textures are rendered in
CACHE_KEY = "mmr_cache"
# What the current textures were rendered with (see render_signature)
RENDERED_KEY = "mmr_rendered"
# Error of the last render
ERROR_KEY = "mmr_error"
# Errors of reading a package's manifest
MANIFEST_ERRORS = (OSError, KeyError, ValueError, TypeError, zipfile.BadZipFile)
# Most recent package format version this add-on reads
FORMAT_VERSION = 1
# Outputs that hold colors (sRGB, as in Material Maker's exports), the others
# hold data
COLOR_CHANNELS = {"albedo", "emission"}
# Longest time a render may take, in seconds
RENDER_TIMEOUT = 600


def addon_preferences(context):
    addon = context.preferences.addons.get(__package__ or __name__)
    return addon.preferences if addon else None


def find_mmr_render(context):
    """The mmr_render executable: preferences, MMR_RENDER, next to the add-on, or the PATH"""
    prefs = addon_preferences(context)
    candidates = []
    if prefs and prefs.mmr_render:
        candidates.append(bpy.path.abspath(prefs.mmr_render))
    if os.environ.get("MMR_RENDER"):
        candidates.append(os.environ["MMR_RENDER"])
    here = os.path.dirname(os.path.abspath(__file__))
    candidates += [os.path.join(here, "mmr_render.exe"), os.path.join(here, "mmr_render")]
    for c in candidates:
        if c and os.path.isfile(c):
            return c
    return shutil.which("mmr_render")


def check_manifest(manifest):
    """Raises ValueError if a manifest is not one of a package this add-on reads"""
    if not isinstance(manifest, dict) or manifest.get("format") != "mmr":
        raise ValueError("not a runtime package")
    if int(manifest.get("version", 0)) > FORMAT_VERSION:
        raise ValueError("unsupported package version %s" % manifest["version"])
    outputs = manifest.get("outputs")
    if not isinstance(outputs, dict) or not outputs:
        raise ValueError("the package has no outputs")
    for p in manifest.get("parameters", []):
        if not isinstance(p, dict) or not isinstance(p.get("name"), str):
            raise ValueError("invalid parameter in the package")


# Manifests of packages by path, with the file time and size they were read at
# (the panel and the live update timer read them often)
_manifests = {}


def package_key(path):
    stat = os.stat(path)
    return (stat.st_mtime_ns, stat.st_size)


def read_manifest(path):
    """The manifest of a package (cached until the file changes, not to be
    modified)"""
    key = package_key(path)
    cached = _manifests.get(path)
    if cached is None or cached[0] != key:
        with zipfile.ZipFile(path) as z:
            manifest = json.loads(z.read("manifest.json"))
        check_manifest(manifest)
        cached = (key, manifest)
        _manifests[path] = cached
    return cached[1]


def package_path(material):
    return bpy.path.abspath(material[PACKAGE_KEY])


def cache_directory(material):
    """The folder of a material's textures (each material has its own, even if
    materials are renamed)"""
    if not material.get(CACHE_KEY):
        material[CACHE_KEY] = "%s_%s" % (bpy.path.clean_name(material.name), uuid.uuid4().hex[:8])
    d = os.path.join(tempfile.gettempdir(), "material_maker_runtime", material[CACHE_KEY])
    os.makedirs(d, exist_ok=True)
    return d


def default_value(parameter):
    """The value of a parameter in the package: a list of 4 floats for colors,
    an int for the seed (0 is the exported seed), a float otherwise"""
    value = parameter.get("default", 0)
    kind = parameter.get("type")
    if kind == "color":
        if isinstance(value, dict):
            value = [value.get(c, 1.0 if c == "a" else 0.0) for c in "rgba"]
        value = [float(x) for x in value][:4]
        return value + [1.0] * (4 - len(value))
    if kind == "seed":
        return int(value)
    return float(value)


def material_value(material, parameter):
    """The value of a parameter stored on the material (as default_value)"""
    key = PARAMETER_PREFIX + parameter["name"]
    if key not in material:
        return default_value(parameter)
    value = material[key]
    if parameter.get("type") == "color":
        return [float(x) for x in value]
    if parameter.get("type") == "seed":
        return int(value)
    return float(value)


def format_value(value):
    """A value as mmr_render's --set reads it. Floats are written with all
    their digits, so that mmr_render gets the same 32 bit floats as Material
    Maker"""
    if isinstance(value, list):
        return ",".join(repr(float(x)) for x in value)
    if isinstance(value, int):
        return str(value)
    return repr(float(value))


def parameter_values(material, manifest):
    """Values of the package's parameters stored on the material that are not
    the package's, as --set arguments (the others need not be set)"""
    rv = []
    for p in manifest.get("parameters", []):
        value = material_value(material, p)
        if value != default_value(p):
            rv.append("%s=%s" % (p["name"], format_value(value)))
    return rv


def texture_size(material):
    """Size of the rendered textures, 0 for the size of the package"""
    return max(0, int(material.get(SIZE_KEY, 0)))


def render_signature(material, manifest):
    """What the textures depend on: the package, parameter values and size"""
    path = package_path(material)
    return "\n".join([path, "%d:%d" % package_key(path)] + parameter_values(material, manifest)
                     + ["size=%d" % texture_size(material)])


def output_files(material, manifest):
    """The files of the package's outputs, { channel: file path }"""
    out = cache_directory(material)
    return {channel: os.path.join(out, channel + ".exr") for channel in manifest["outputs"]}


def render_textures(context, material, manifest):
    """Renders the package's outputs with the material's parameter values, and
    returns { channel: file path }"""
    package = package_path(material)
    if not os.path.isfile(package):
        raise RuntimeError("package %s not found" % package)
    executable = find_mmr_render(context)
    if executable is None:
        raise RuntimeError("mmr_render was not found: set its path in the add-on preferences")
    files = output_files(material, manifest)
    for path in files.values():
        if os.path.exists(path):
            os.remove(path)
    # Float EXR files hold the values of Material Maker's renders
    command = [executable, package, "-o", cache_directory(material), "--exr"]
    for s in parameter_values(material, manifest):
        command += ["--set", s]
    if texture_size(material) > 0:
        command += ["--size", str(texture_size(material))]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=RENDER_TIMEOUT,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError("mmr_render failed: %s" % e)
    if result.returncode != 0:
        raise RuntimeError("mmr_render failed: " + (result.stderr or result.stdout).strip())
    missing = [channel for channel, path in files.items() if not os.path.isfile(path)]
    if missing:
        raise RuntimeError("mmr_render did not write %s" % ", ".join(missing))
    return files


def load_image(material, path, channel):
    image = bpy.data.images.load(path, check_existing=True)
    if image.users == 0:
        image.name = "%s_%s" % (material.name, channel)
    image.colorspace_settings.name = "sRGB" if channel in COLOR_CHANNELS else "Non-Color"
    image.reload()
    return image


def has_transparency(image):
    """True if some pixels of an image are not opaque"""
    import numpy
    if image.channels < 4:
        return False
    pixels = numpy.empty(len(image.pixels), dtype=numpy.float32)
    image.pixels.foreach_get(pixels)
    return bool((pixels[3::4] < 1.0).any())


def rendered(material, manifest):
    """Remembers what the textures were rendered with"""
    material[RENDERED_KEY] = render_signature(material, manifest)
    if ERROR_KEY in material:
        del material[ERROR_KEY]


def update_images(context, material):
    """Renders the textures again and reloads the material's images"""
    manifest = read_manifest(package_path(material))
    for channel, path in render_textures(context, material, manifest).items():
        load_image(material, path, channel)
    rendered(material, manifest)


def socket(sockets, identifier):
    """A socket by identifier (Mix nodes have several sockets of each name,
    one for each data type)"""
    return next(s for s in sockets if s.identifier == identifier)


def build_material(context, material, manifest):
    """A Principled BSDF using the package's outputs, with the Material node's
    settings (as Material Maker's Godot runtime)"""
    files = render_textures(context, material, manifest)
    settings = manifest.get("material", {})
    if hasattr(material, "use_nodes") and not material.use_nodes:
        material.use_nodes = True
    tree = material.node_tree
    tree.nodes.clear()
    nodes, links = tree.nodes, tree.links
    output = nodes.new("ShaderNodeOutputMaterial")
    output.location = (400, 0)
    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.location = (100, 0)
    links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])

    def texture(channel, y):
        node = nodes.new("ShaderNodeTexImage")
        node.image = load_image(material, files[channel], channel)
        node.label = channel
        node.location = (-900, y)
        return node

    def separate(node, y):
        rv = nodes.new("ShaderNodeSeparateColor")
        rv.location = (-600, y)
        links.new(node.outputs["Color"], rv.inputs["Color"])
        return rv

    def multiply(socket, value, y):
        math = nodes.new("ShaderNodeMath")
        math.operation = "MULTIPLY"
        math.location = (-350, y)
        links.new(socket, math.inputs[0])
        math.inputs[1].default_value = value
        return math.outputs[0]

    color = (list(settings.get("albedo_color", [1.0, 1.0, 1.0, 1.0])) + [1.0] * 4)[:4]
    if "albedo" in files:
        albedo = texture("albedo", 300)
        tint = nodes.new("ShaderNodeMix")
        tint.data_type = "RGBA"
        tint.blend_type = "MULTIPLY"
        tint.location = (-350, 300)
        tint.inputs["Factor"].default_value = 1.0
        links.new(albedo.outputs["Color"], socket(tint.inputs, "A_Color"))
        socket(tint.inputs, "B_Color").default_value = color
        links.new(socket(tint.outputs, "Result_Color"), bsdf.inputs["Base Color"])
        # Transparent if the material is and its opacity is used
        if settings.get("flags_transparent", False) and has_transparency(albedo.image):
            links.new(multiply(albedo.outputs["Alpha"], color[3], 450), bsdf.inputs["Alpha"])
    else:
        bsdf.inputs["Base Color"].default_value = color
    if "orm" in files:
        # Occlusion, roughness and metallic in red, green and blue (the
        # renderers compute occlusion)
        orm = separate(texture("orm", 0), 0)
        links.new(multiply(orm.outputs["Green"], settings.get("roughness", 1.0), 50), bsdf.inputs["Roughness"])
        links.new(multiply(orm.outputs["Blue"], settings.get("metallic", 1.0), -50), bsdf.inputs["Metallic"])
    else:
        bsdf.inputs["Roughness"].default_value = settings.get("roughness", 1.0)
        bsdf.inputs["Metallic"].default_value = settings.get("metallic", 0.0)
    if "normal" in files:
        normal = texture("normal", -300)
        normal_map = nodes.new("ShaderNodeNormalMap")
        normal_map.location = (-350, -300)
        normal_map.inputs["Strength"].default_value = settings.get("normal", 1.0)
        links.new(normal.outputs["Color"], normal_map.inputs["Color"])
        links.new(normal_map.outputs["Normal"], bsdf.inputs["Normal"])
    if "emission" in files:
        emission = texture("emission", -600)
        links.new(emission.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = settings.get("emission_energy", 1.0)
    if "height" in files and settings.get("depth_scale", 0.0) > 0.0:
        height = separate(texture("height", -900), -900)
        displacement = nodes.new("ShaderNodeDisplacement")
        displacement.location = (100, -500)
        displacement.inputs["Scale"].default_value = 0.1 * settings["depth_scale"]
        links.new(height.outputs["Red"], displacement.inputs["Height"])
        links.new(displacement.outputs["Displacement"], output.inputs["Displacement"])
    rendered(material, manifest)


def add_parameters(material, manifest):
    """The package's parameters as custom properties of the material"""
    for p in manifest.get("parameters", []):
        key = PARAMETER_PREFIX + p["name"]
        value = default_value(p)
        material[key] = value
        ui = material.id_properties_ui(key)
        description = p.get("label") or p["name"]
        if p.get("type") == "color":
            # Material Maker's colors are not converted to linear
            ui.update(subtype="COLOR_GAMMA", min=0.0, max=1.0, description=description)
        elif p.get("type") == "seed":
            # The seed of all random nodes (as Material Maker's --seed, 0 is
            # the exported seed)
            ui.update(min=0, max=max(1, int(p.get("max", 1000))), description="Seed of the random nodes")
        else:
            ui.update(min=float(p.get("min", 0.0)), max=float(p.get("max", 1.0)),
                      step=max(1, int(100 * float(p.get("step", 0.0) or 0.01))), description=description)


def set_parameters(material, manifest, values):
    """Sets parameters (by name or label) of a material, returns the ones it
    does not have"""
    unknown = []
    for name, value in values.items():
        parameter = next((p for p in manifest.get("parameters", []) if name in (p["name"], p.get("label"))), None)
        key = PARAMETER_PREFIX + parameter["name"] if parameter else None
        if key not in material:
            unknown.append(name)
        elif parameter.get("type") == "color":
            material[key] = default_value(dict(parameter, default=value))
        elif parameter.get("type") == "seed":
            material[key] = int(value)
        else:
            material[key] = float(value)
    return unknown


class MMR_OT_import(bpy.types.Operator, ImportHelper):
    """Import a Material Maker runtime package (.mmr) as a material"""
    bl_idname = "material_maker.import_mmr"
    bl_label = "Import Material Maker package"
    bl_options = {"REGISTER", "UNDO"}
    filename_ext = ".mmr"
    filter_glob: StringProperty(default="*.mmr", options={"HIDDEN"})
    assign: BoolProperty(name="Assign to selected objects", default=True)

    def execute(self, context):
        try:
            manifest = read_manifest(self.filepath)
        except MANIFEST_ERRORS as e:
            self.report({"ERROR"}, "Not a Material Maker package: %s" % e)
            return {"CANCELLED"}
        material = bpy.data.materials.new(manifest.get("name") or os.path.splitext(os.path.basename(self.filepath))[0])
        material[PACKAGE_KEY] = self.filepath
        material[SIZE_KEY] = 0
        material.id_properties_ui(SIZE_KEY).update(min=0, max=16384, description="Size of the rendered textures (0: the exported size)")
        add_parameters(material, manifest)
        try:
            build_material(context, material, manifest)
        except (RuntimeError, OSError) as e:
            bpy.data.materials.remove(material)
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}
        if self.assign:
            for o in context.selected_objects:
                if hasattr(o.data, "materials"):
                    if o.data.materials:
                        o.data.materials[0] = material
                    else:
                        o.data.materials.append(material)
        self.report({"INFO"}, "Imported %s" % material.name)
        return {"FINISHED"}


def report_render(operator, context, material):
    try:
        update_images(context, material)
    except MANIFEST_ERRORS + (RuntimeError,) as e:
        material[ERROR_KEY] = str(e)
        operator.report({"ERROR"}, str(e))
        return {"CANCELLED"}
    return {"FINISHED"}


class MMR_OT_update(bpy.types.Operator):
    """Render the material's textures with its current parameters"""
    bl_idname = "material_maker.update_mmr"
    bl_label = "Update textures"

    def execute(self, context):
        material = context.material
        if material is None or PACKAGE_KEY not in material:
            return {"CANCELLED"}
        return report_render(self, context, material)


class MMR_OT_apply_preset(bpy.types.Operator):
    """Apply a preset of the package (saved parameter values)"""
    bl_idname = "material_maker.apply_mmr_preset"
    bl_label = "Apply preset"
    bl_options = {"REGISTER", "UNDO"}
    preset: StringProperty()

    def execute(self, context):
        material = context.material
        if material is None or PACKAGE_KEY not in material:
            return {"CANCELLED"}
        try:
            manifest = read_manifest(package_path(material))
        except MANIFEST_ERRORS as e:
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}
        values = manifest.get("presets", {}).get(self.preset)
        if values is None:
            self.report({"ERROR"}, "No preset %s" % self.preset)
            return {"CANCELLED"}
        unknown = set_parameters(material, manifest, values)
        if unknown:
            self.report({"WARNING"}, "Unknown parameters: %s" % ", ".join(unknown))
        return report_render(self, context, material)


class MMR_PT_material(bpy.types.Panel):
    bl_label = "Material Maker"
    bl_space_type = "PROPERTIES"
    bl_region_type = "WINDOW"
    bl_context = "material"

    @classmethod
    def poll(cls, context):
        return context.material is not None and PACKAGE_KEY in context.material

    def draw(self, context):
        material = context.material
        layout = self.layout
        layout.label(text=os.path.basename(material[PACKAGE_KEY]), icon="PACKAGE")
        try:
            manifest = read_manifest(package_path(material))
        except MANIFEST_ERRORS:
            layout.label(text="The package cannot be read", icon="ERROR")
            return
        for p in manifest.get("parameters", []):
            key = PARAMETER_PREFIX + p["name"]
            if key in material:
                layout.prop(material, '["%s"]' % bpy.utils.escape_identifier(key), text=p.get("label") or p["name"])
        presets = manifest.get("presets", {})
        if presets:
            box = layout.box()
            box.label(text="Presets")
            row = box.row(align=True)
            for name in presets:
                row.operator(MMR_OT_apply_preset.bl_idname, text=name).preset = name
        if SIZE_KEY in material:
            layout.prop(material, '["%s"]' % SIZE_KEY, text="Texture size (0: exported)")
        if material.get(ERROR_KEY):
            layout.label(text=material[ERROR_KEY], icon="ERROR")
        prefs = addon_preferences(context)
        row = layout.row()
        row.operator(MMR_OT_update.bl_idname, icon="FILE_REFRESH")
        if prefs:
            row.prop(prefs, "live_update")


class MMR_Preferences(bpy.types.AddonPreferences):
    bl_idname = __package__ or __name__
    mmr_render: StringProperty(name="mmr_render executable", subtype="FILE_PATH",
                               description="The renderer of runtime packages (built from runtime/cpp of Material Maker's source)")
    live_update: BoolProperty(name="Live update", default=True,
                              description="Render the textures again when parameters change")

    def draw(self, context):
        self.layout.prop(self, "mmr_render")
        found = find_mmr_render(context)
        self.layout.label(text="Using: %s" % found if found else "mmr_render not found", icon="CHECKMARK" if found else "ERROR")
        self.layout.prop(self, "live_update")


def needs_render(material, manifest):
    """True if the parameters, size or package changed since the textures
    were rendered, or if the textures are missing (as when a .blend file is
    opened after the temporary folder was cleaned)"""
    if material.get(RENDERED_KEY) != render_signature(material, manifest):
        return True
    return material.get(ERROR_KEY) is None and not all(os.path.isfile(f) for f in output_files(material, manifest).values())


def live_update_timer():
    """Renders the textures of materials whose parameters changed"""
    context = bpy.context
    prefs = addon_preferences(context)
    if prefs is None or prefs.live_update:
        for material in bpy.data.materials:
            if PACKAGE_KEY not in material or material.library is not None:
                continue
            try:
                manifest = read_manifest(package_path(material))
                if not needs_render(material, manifest):
                    continue
                update_images(context, material)
            except MANIFEST_ERRORS + (RuntimeError,) as e:
                # Not tried again until something changes (properties are
                # only written when they change, as writing them redraws)
                try:
                    signature = render_signature(material, read_manifest(package_path(material)))
                except MANIFEST_ERRORS:
                    signature = ""
                for key, value in ((ERROR_KEY, str(e)), (RENDERED_KEY, signature)):
                    if material.get(key) != value:
                        material[key] = value
    return 0.5


def menu_import(self, context):
    self.layout.operator(MMR_OT_import.bl_idname, text="Material Maker package (.mmr)")


CLASSES = (MMR_Preferences, MMR_OT_import, MMR_OT_update, MMR_OT_apply_preset, MMR_PT_material)


def register():
    for c in CLASSES:
        bpy.utils.register_class(c)
    bpy.types.TOPBAR_MT_file_import.append(menu_import)
    if not bpy.app.timers.is_registered(live_update_timer):
        bpy.app.timers.register(live_update_timer, first_interval=1.0, persistent=True)


def unregister():
    if bpy.app.timers.is_registered(live_update_timer):
        bpy.app.timers.unregister(live_update_timer)
    bpy.types.TOPBAR_MT_file_import.remove(menu_import)
    for c in reversed(CLASSES):
        bpy.utils.unregister_class(c)
