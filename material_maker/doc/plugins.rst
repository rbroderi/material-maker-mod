.. _plugins-section:

Plugins
=======

Plugins are folders that contain a **plugin.cfg** file, in the **plugins** folder of Material
Maker's user data folder (the *Tools > Plugins...* window has a button that opens it) or in the
**plugins** folder next to Material Maker. *Tools > Plugins...* lists them and enables or
disables them (changes are applied when Material Maker starts again).

.. code-block:: ini

    [plugin]
    name="My plugin"
    description="What it does"
    version="1.0"
    script="plugin.gd"          ; optional, extends MMPlugin
    nodes="nodes"               ; optional, a folder of nodes (.mmg files)
    library="library.json"      ; optional, a node library
    export_targets="exports"    ; optional, a folder of export targets (.mme files)
    enabled_by_default=true
    depends=["other_plugin", "another_plugin>=1.2"] ; optional, plugins it needs

**depends** lists the plugins (by folder name, optionally with a minimum version) that must be
loaded first. Dependencies that are only disabled by default are enabled when needed. A plugin
whose dependencies are missing, too old, disabled by the user, cannot be loaded or depend on it
again (a cycle) is not loaded, and *Tools > Plugins...* shows why. Enabling a plugin in that
window also enables its dependencies, and disabling one also disables the plugins that need it.

Export targets of plugins (**export_targets** folder) are listed with the Material node's own
targets. The user's export targets (edited in the material editor) override them, and plugin
targets that are left unchanged are not copied to the user's export targets.

A plugin's script extends **MMPlugin**. Its **_enable(api)** function is called when Material
Maker starts, and **_disable()** when it quits. The API object adds:

* menu items: **api.add_menu_item(label, callable, menu="Plugins", after="")**, in the
  **Plugins** menu, or in another menu (e.g. *File*) after one of its items (e.g. *Export
  material*)
* command line commands, run with **--plugin <command> [arguments]**:
  **api.add_command(name, callable)**, called with the arguments and returning the exit code
* export hooks, called after each material export with the material node, the exported file
  prefix and the export target: **api.add_export_hook(callable)**
* image file formats: **api.add_image_format(extension, description, callable)**, used wherever
  images are saved (texture exports, the 2D preview's export menu, whose file type list and file
  dialog show them). The callable receives the image, the file name and options, and returns an
  error code
* files that hold several images: **api.add_layered_image_format(extension, description,
  callable)**. The callable receives the file name and the layers (an array of **{ name, image,
  options }**), and returns an error code
* **api.get_main_window()**, the main window (null on the command line), to add panels or dialogs

**MMPlugins.load_plugin_file(plugin_id, file_name)** loads a file of another (loaded) plugin, for
example a script shared with the plugins that depend on it.

.. code-block:: gdscript

    extends MMPlugin

    func _enable(api) -> void:
        api.add_menu_item("Say hello", func(): print("Hello"))
        api.add_export_hook(func(material, prefix, target): print("exported ", prefix))

The **material_maker/plugins/example** folder contains an example plugin (disabled by default)
that adds a node, a menu item, a command, an export hook and an image format (Netpbm, with
an *Example/Netpbm* export target that saves the height map with 16 bits).

Image formats
-------------

Texture files of export targets (**"type": "texture"**) can have **"options"**, which are passed
to the image format that saves them (Material Maker's own PNG, JPEG, WebP and EXR formats ignore
them). Their meaning is up to each format; the usual ones are:

* **bits**: bits per component (e.g. 8, 16 or 32; numbers in export targets are floats, so
  use **int(options.bits)**)
* **srgb**: whether colors are sRGB encoded (by default, true for the Material node's albedo and
  emission **output**, and false for **expression** files)
* **grayscale**: whether to save a single channel (by default, true for outputs of type **f**)
* **alpha**: whether to keep the alpha channel (by default, true for outputs of type **rgba**)
* **normal_map**: whether the image is a normal map (e.g. to generate its mipmaps)

Texture files with a **"layer"** name are saved together, in a file of a layered format (the
texture files that have the same file name are the layers of that file):

.. code-block:: json

    { "type": "texture", "output": 13, "file_name": "$(path_prefix).layers",
      "layer": "roughness", "options": { "bits": 16 } }

**MMTexture.save_image(image, file_name, options)** saves an image in any of these formats
(chosen by the file extension), and **MMTexture.image_channels(format)** and
**MMTexture.image_bits(format)** give the channel count and the component size of a Godot image
format.
