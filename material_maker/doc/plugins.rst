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
* function graph operations (Pixel Processor nodes): **api.add_function_graph_op(name,
  operands, compile_callable, globals=[])**. **operands** are the keys of the node that
  reference other nodes. **compile_callable** receives the compiler
  (**MMFunctionGraph.Compiler**), the node id, the node, the operation and the operand ids,
  sets the node's type in **compiler.types** and returns its GLSL expression
  (**compiler.value_of(id)** is the expression of an operand and **compiler.types[id]** its
  type), or calls **compiler.error(node_id, message)** and returns an empty string. It can add
  statements before the node's to **compiler.code**, globals with
  **compiler.add_global(definition)**, and read **compiler.variables** and **compiler.graph**
  (the whole function graph). **globals** are GLSL definitions that are added once per shader
  when the operation is used. Built-in operations cannot be replaced, and graphs that use an
  operation that is not available (e.g. its plugin is disabled) show an error
* command line commands, run with **--plugin <command> [arguments]**:
  **api.add_command(name, callable)**, called with the arguments and returning the exit code
* export hooks, called after each material export with the material node, the exported file
  prefix and the export target: **api.add_export_hook(callable)**
* **api.get_main_window()**, the main window (null on the command line), to add panels or dialogs

**MMPlugins.load_plugin_file(plugin_id, file_name)** loads a file of another (loaded) plugin, for
example a script shared with the plugins that depend on it.

.. code-block:: gdscript

    extends MMPlugin

    func _enable(api) -> void:
        api.add_menu_item("Say hello", func(): print("Hello"))
        api.add_export_hook(func(material, prefix, target): print("exported ", prefix))

The **material_maker/plugins/example** folder contains an example plugin (disabled by default)
that adds a node, a menu item, a command and an export hook.
