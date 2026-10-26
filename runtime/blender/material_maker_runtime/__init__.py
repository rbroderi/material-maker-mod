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

PACKAGE_KEY = "mmr_package"
PARAMETER_PREFIX = "mmr:"
# Output channels and how they are used
COLOR_CHANNELS = {"albedo", "emission"}


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


def read_manifest(path):
    with zipfile.ZipFile(path) as z:
        return json.loads(z.read("manifest.json"))


def cache_directory(material):
    d = os.path.join(tempfile.gettempdir(), "material_maker_runtime", bpy.path.clean_name(material.name))
    os.makedirs(d, exist_ok=True)
    return d


def parameter_values(material, manifest):
    """Values of the package's parameters stored on the material, as --set arguments"""
    rv = []
    for p in manifest.get("parameters", []):
        key = PARAMETER_PREFIX + p["name"]
        if key in material:
            v = material[key]
            text = ",".join("%g" % x for x in v) if hasattr(v, "__len__") else "%g" % v
            rv.append("%s=%s" % (p["name"], text))
    return rv


def render_textures(context, material):
    """Renders the package's outputs with the material's parameter values, and
    returns { channel: file path }"""
    package = bpy.path.abspath(material[PACKAGE_KEY])
    manifest = read_manifest(package)
    executable = find_mmr_render(context)
    if executable is None:
        raise RuntimeError("mmr_render was not found: set its path in the add-on preferences")
    out = cache_directory(material)
    command = [executable, package, "-o", out]
    for s in parameter_values(material, manifest):
        command += ["--set", s]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError("mmr_render failed: " + (result.stderr or result.stdout).strip())
    files = {}
    for channel in manifest.get("outputs", {}):
        path = os.path.join(out, channel + ".png")
        if os.path.isfile(path):
            files[channel] = path
    return files


def load_image(path, channel):
    image = bpy.data.images.load(path, check_existing=True)
    image.reload()
    image.colorspace_settings.name = "sRGB" if channel in COLOR_CHANNELS else "Non-Color"
    return image


def update_images(context, material):
    """Renders the textures again and reloads the material's images"""
    for channel, path in render_textures(context, material).items():
        load_image(path, channel)
    material["mmr_rendered"] = parameter_values(material, read_manifest(bpy.path.abspath(material[PACKAGE_KEY])))


def build_material(context, material, manifest):
    """A Principled BSDF using the package's outputs, with the Material node's
    settings (as Material Maker's Godot runtime)"""
    files = render_textures(context, material)
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
        node.image = load_image(files[channel], channel)
        node.label = channel
        node.location = (-700, y)
        return node

    def multiply(socket, value, y):
        math = nodes.new("ShaderNodeMath")
        math.operation = "MULTIPLY"
        math.location = (-200, y)
        links.new(socket, math.inputs[0])
        math.inputs[1].default_value = value
        return math.outputs[0]

    color = settings.get("albedo_color", [1.0, 1.0, 1.0, 1.0])
    if "albedo" in files:
        albedo = texture("albedo", 300)
        tint = nodes.new("ShaderNodeMix")
        tint.data_type = "RGBA"
        tint.blend_type = "MULTIPLY"
        tint.location = (-300, 300)
        tint.inputs["Factor"].default_value = 1.0
        links.new(albedo.outputs["Color"], tint.inputs["A"])
        tint.inputs["B"].default_value = color
        links.new(tint.outputs["Result"], bsdf.inputs["Base Color"])
        if settings.get("flags_transparent", False):
            links.new(albedo.outputs["Alpha"], bsdf.inputs["Alpha"])
    else:
        bsdf.inputs["Base Color"].default_value = color
    if "orm" in files:
        # Occlusion, roughness and metallic in red, green and blue
        orm = texture("orm", 0)
        separate = nodes.new("ShaderNodeSeparateColor")
        separate.location = (-400, 0)
        links.new(orm.outputs["Color"], separate.inputs["Color"])
        links.new(multiply(separate.outputs["Green"], settings.get("roughness", 1.0), 50), bsdf.inputs["Roughness"])
        links.new(multiply(separate.outputs["Blue"], settings.get("metallic", 1.0), -50), bsdf.inputs["Metallic"])
    else:
        bsdf.inputs["Roughness"].default_value = settings.get("roughness", 1.0)
        bsdf.inputs["Metallic"].default_value = 0.0
    if "normal" in files:
        normal = texture("normal", -300)
        normal_map = nodes.new("ShaderNodeNormalMap")
        normal_map.location = (-200, -300)
        normal_map.inputs["Strength"].default_value = settings.get("normal", 1.0)
        links.new(normal.outputs["Color"], normal_map.inputs["Color"])
        links.new(normal_map.outputs["Normal"], bsdf.inputs["Normal"])
    if "emission" in files:
        emission = texture("emission", -600)
        links.new(emission.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = settings.get("emission_energy", 1.0)
    if "height" in files and settings.get("depth_scale", 0.0) > 0.0:
        height = texture("height", -900)
        displacement = nodes.new("ShaderNodeDisplacement")
        displacement.location = (100, -500)
        displacement.inputs["Scale"].default_value = 0.1 * settings["depth_scale"]
        links.new(height.outputs["Color"], displacement.inputs["Height"])
        links.new(displacement.outputs["Displacement"], output.inputs["Displacement"])
    material["mmr_rendered"] = parameter_values(material, manifest)


def add_parameters(material, manifest):
    """The package's parameters as custom properties of the material"""
    for p in manifest.get("parameters", []):
        key = PARAMETER_PREFIX + p["name"]
        default = p.get("default", 0.0)
        if p.get("type") == "color":
            material[key] = [float(x) for x in default]
            material.id_properties_ui(key).update(subtype="COLOR", min=0.0, max=1.0, description=p.get("label", p["name"]))
        else:
            material[key] = float(default)
            material.id_properties_ui(key).update(min=float(p.get("min", 0.0)), max=float(p.get("max", 1.0)),
                                                  step=max(1, int(100 * float(p.get("step", 0.0) or 0.01))),
                                                  description=p.get("label", p["name"]))


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
        except (OSError, KeyError, ValueError, zipfile.BadZipFile) as e:
            self.report({"ERROR"}, "Not a Material Maker package: %s" % e)
            return {"CANCELLED"}
        material = bpy.data.materials.new(manifest.get("name") or os.path.splitext(os.path.basename(self.filepath))[0])
        material[PACKAGE_KEY] = self.filepath
        add_parameters(material, manifest)
        try:
            build_material(context, material, manifest)
        except RuntimeError as e:
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


class MMR_OT_update(bpy.types.Operator):
    """Render the material's textures with its current parameters"""
    bl_idname = "material_maker.update_mmr"
    bl_label = "Update textures"

    def execute(self, context):
        material = context.material
        if material is None or PACKAGE_KEY not in material:
            return {"CANCELLED"}
        try:
            update_images(context, material)
        except RuntimeError as e:
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}
        return {"FINISHED"}


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
        manifest = read_manifest(bpy.path.abspath(material[PACKAGE_KEY]))
        values = manifest.get("presets", {}).get(self.preset)
        if values is None:
            self.report({"ERROR"}, "No preset %s" % self.preset)
            return {"CANCELLED"}
        for name, value in values.items():
            key = PARAMETER_PREFIX + name
            if key in material:
                material[key] = [float(x) for x in value] if isinstance(value, list) else float(value)
        try:
            update_images(context, material)
        except RuntimeError as e:
            self.report({"ERROR"}, str(e))
            return {"CANCELLED"}
        return {"FINISHED"}


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
            manifest = read_manifest(bpy.path.abspath(material[PACKAGE_KEY]))
        except (OSError, KeyError, ValueError, zipfile.BadZipFile):
            layout.label(text="The package cannot be read", icon="ERROR")
            return
        for p in manifest.get("parameters", []):
            key = PARAMETER_PREFIX + p["name"]
            if key in material:
                layout.prop(material, '["%s"]' % key, text=p.get("label") or p["name"])
        presets = manifest.get("presets", {})
        if presets:
            box = layout.box()
            box.label(text="Presets")
            row = box.row(align=True)
            for name in presets:
                row.operator(MMR_OT_apply_preset.bl_idname, text=name).preset = name
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


def live_update_timer():
    """Renders the textures of materials whose parameters changed"""
    context = bpy.context
    prefs = addon_preferences(context)
    if prefs is None or prefs.live_update:
        for material in bpy.data.materials:
            if PACKAGE_KEY not in material:
                continue
            try:
                manifest = read_manifest(bpy.path.abspath(material[PACKAGE_KEY]))
                if list(material.get("mmr_rendered", [])) != parameter_values(material, manifest):
                    update_images(context, material)
            except (OSError, KeyError, ValueError, RuntimeError, zipfile.BadZipFile):
                pass
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
