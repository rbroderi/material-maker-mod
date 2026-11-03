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
* node types: **api.add_node_type(type, script)** (see below)
* **api.get_main_window()**, the main window (null on the command line), to add panels or dialogs

**MMPlugins.load_plugin_file(plugin_id, file_name)** loads a file of another (loaded) plugin, for
example a script shared with the plugins that depend on it.

.. code-block:: gdscript

    extends MMPlugin

    func _enable(api) -> void:
        api.add_menu_item("Say hello", func(): print("Hello"))
        api.add_export_hook(func(material, prefix, target): print("exported ", prefix))

Node types
----------

Nodes that a node definition (a **.mmg** file in the **nodes** folder) cannot describe, for
example nodes that generate their texture on the CPU, can be implemented by a generator script
that extends **MMGenBase** (or one of its subclasses, such as **MMGenTexture**) and registered
with **api.add_node_type(type, script)**. **type** is the node's type in graph files and node
libraries, and the script's **get_type()** must return it. Its parameters
(**get_parameter_defs()**) and seed are saved with the node, and **_serialize(data)** returns
the node's data with anything else it saves (and **_deserialize(data)** reads it). Nodes of this
type load from graphs, and the plugin's library can list them (with **"type": "<type>"**
items). The types of Material Maker's nodes and node definitions cannot be replaced, and a type
that another plugin already added is not replaced either (plugins are loaded after their
dependencies). Nodes of a plugin that is not installed or enabled are loaded as placeholders
(see below).

.. code-block:: gdscript

    extends MMPlugin

    func _enable(api) -> void:
        api.add_node_type("my_node", load(api.plugin_path.path_join("my_node.gd")))

Materials that need plugins
---------------------------

When a material is saved, the plugins its nodes come from (node types and node definitions of
plugins, also in subgraphs) are saved in its **requires** dictionary, with the installed version
of each plugin as minimum version, and the type of each of those nodes. Materials that use no
plugin nodes have no **requires** dictionary.

.. code-block:: json

    "requires": {
        "plugins": { "example": ">=1.0" },
        "node_types": { "example_maze": "example", "example_stripes": "example" }
    }

When a material is loaded, Material Maker checks that those plugins are installed, enabled
and recent enough, and that they have those node types. If not, a *Missing requirements*
dialog names the missing plugins (installed but disabled, not installed, too old or that could
not be loaded) and their nodes (on the command line, an error is printed instead, the material
is skipped, and the exit code is 2, see :doc:`command_line`). Those nodes are loaded as magenta placeholders: their tooltip names the
plugin, and they are saved unchanged with the material, with the plugins they need, so the
material is complete again once the plugin is enabled.

Graph files written by other tools can also list node types (**"node_types": ["type", ...]**)
and a minimum version of Material Maker (**"material_maker": ">=1.4"**). When the material is
saved, the plugins it lists that are not available are kept (Material Maker cannot tell whether
they are still needed), and so are higher minimum versions of plugins and the requirements that
Material Maker does not know (they are ignored when loading).

The **material_maker/plugins/example** folder contains an example plugin (disabled by default)
that adds two nodes (a node definition, and a node type that generates a maze) in a library, a
menu item, a command and an export hook.
