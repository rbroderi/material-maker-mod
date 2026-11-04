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
    cli_modes=["--my-mode"]     ; optional, command line modes added by the script

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
* import formats: **api.add_import_format(extension, description, callable)**, whose files are
  imported as new material graphs by *File > Load*, drag and drop, the **load** JSON-RPC method and
  the command line. The callable receives the file's path and returns the graph (a dictionary, as
  in .ptex files, with optional **warnings**), or an empty dictionary on errors
* JSON-RPC methods (see :ref:`scripting-section`): **api.add_rpc_method(name, callable)**, called
  with the request's parameters (and, when the callable has 2 arguments, the RPC server, whose
  **fail(message)**, **require(params, names)**, **get_graph()** and **get_generator(graph,
  name)** report errors and give access to the current graph)
* command line commands, run with **--plugin <command> [arguments]**:
  **api.add_command(name, callable)**, called with the arguments and returning the exit code
* command line modes (also listed in **cli_modes**): **api.add_cli_mode(mode, callable, usage,
  options)**. The callable receives the command line tool (whose **process_graph_files(files,
  options, variation)** loads each graph, applies **--set**, **--seed** and **--variations**,
  and calls **variation(suffix, graph, file, options)**, and **expand_files(files)** expands
  wildcards), the files and the options. **options** maps the mode's own options to **{ key,
  type, help }** (type is TYPE_INT, TYPE_FLOAT, TYPE_STRING, or TYPE_BOOL for flags, and an
  optional **minimum**), and **usage** and the options' help are shown by **--help**
* sections of the 2D preview's export menu: **api.add_export_menu_section(callable)**, that
  receives the export menu (with **get_generator()**, **get_output()** and
  **export_notification(text)**) and returns a Control, whose optional
  **update(generator, output_index)** method is called when the previewed output changes
* export hooks, called after each material export with the material node, the exported file
  prefix and the export target: **api.add_export_hook(callable)**
* **api.get_main_window()**, the main window (null in command line and RPC modes), to add panels
  or dialogs

**MMPlugins.load_plugin_file(plugin_id, file_name)** loads a file of another (loaded) plugin, for
example a script shared with the plugins that depend on it.

.. code-block:: gdscript

    extends MMPlugin

    func _enable(api) -> void:
        api.add_menu_item("Say hello", func(): print("Hello"))
        api.add_rpc_method("hello", func(params): return "Hello " + params.get("name", ""))
        api.add_export_hook(func(material, prefix, target): print("exported ", prefix))

The **material_maker/plugins/example** folder contains an example plugin (disabled by default)
that adds a node, a menu item, an import format (.stripes files), an RPC method, a command, a
command line mode (**--example-thumbnails**), a section of the 2D preview's export menu and an
export hook.
