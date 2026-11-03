extends AcceptDialog


# Lists the plugins (see MMPlugins), and enables or disables them (when
# Material Maker starts again)


func _ready() -> void:
	title = "Plugins"
	var box : VBoxContainer = VBoxContainer.new()
	var scroll : ScrollContainer = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(520, 260)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var list : VBoxContainer = VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	box.add_child(scroll)
	if MMPlugins.plugins.is_empty():
		var empty : Label = Label.new()
		empty.text = "No plugin found. Plugins are folders with a plugin.cfg file in:\n"+"\n".join(MMPlugins.get_plugin_dirs().map(func(d): return ProjectSettings.globalize_path(d)))
		list.add_child(empty)
	var checks : Dictionary = {}
	for p in MMPlugins.plugins:
		var check : CheckBox = CheckBox.new()
		check.text = "%s %s" % [ p.name, p.version ]
		check.button_pressed = p.enabled
		# Enabling a plugin enables its dependencies, disabling it disables
		# the plugins that depend on it
		check.toggled.connect(func(v):
			for id in MMPlugins.set_plugin_enabled(p.id, v):
				if checks.has(id):
					checks[id].set_pressed_no_signal(v))
		checks[p.id] = check
		list.add_child(check)
		var description : Label = Label.new()
		description.text = p.description
		if not p.depends.is_empty():
			description.text += "\nNeeds: "+", ".join(p.depends)
		if p.error != "":
			description.text += "\nError: "+p.error
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		description.custom_minimum_size.x = 480
		description.modulate = Color(1, 1, 1, 0.7) if p.error == "" else Color(1, 0.5, 0.4)
		list.add_child(description)
	var note : Label = Label.new()
	note.text = "Changes are applied when Material Maker starts again."
	box.add_child(note)
	var open_folder : Button = Button.new()
	open_folder.text = "Open the user plugins folder"
	open_folder.pressed.connect(func():
		DirAccess.make_dir_recursive_absolute("user://plugins")
		OS.shell_open(ProjectSettings.globalize_path("user://plugins")))
	box.add_child(open_folder)
	add_child(box)
	confirmed.connect(queue_free)
	canceled.connect(queue_free)
