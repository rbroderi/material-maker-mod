extends MMToolWindow
class_name MMDependenciesWindow


# Lists the external files a graph depends on (image and file parameters of
# all its nodes, including subgraphs), shows the missing ones, and can relink
# them, find them in a folder, or collect all of them into a folder.
# All changes are undoable.


const FILE_PARAMETER_TYPES : Array[String] = [ "image_path", "file" ]

var graph_edit = null
var dependencies : Array[Dictionary] = []

var tree : Tree
var summary : Label


func _init() -> void:
	var vbox : VBoxContainer = create_layout("Dependencies", Vector2i(900, 500), Vector2i(600, 300))
	summary = Label.new()
	vbox.add_child(summary)
	tree = create_tree([ "Node", "File", "Status" ])
	tree.set_column_expand_ratio(1, 3)
	vbox.add_child(tree)
	var buttons : HBoxContainer = HBoxContainer.new()
	vbox.add_child(buttons)
	add_button(buttons, "Relink selected...", relink_selected)
	add_button(buttons, "Find missing files in folder...", find_missing_in_folder)
	add_button(buttons, "Collect files into folder...", collect_files)
	add_spacer(buttons)
	add_button(buttons, "Close", queue_free)

func show_graph(ge) -> void:
	graph_edit = ge
	refresh()
	popup_centered()

## Returns the file dependencies of a generator and its children
static func collect_dependencies(generator : Node, rv : Array[Dictionary]) -> void:
	for c in MMCliTools.collect_generators(generator, func(_g): return true):
		for p in c.get_parameter_defs():
			if p.type in FILE_PARAMETER_TYPES:
				var path = c.get_parameter(p.name)
				if path is String and path != "":
					rv.append({ generator=c, parameter=p.name, path=path })

func refresh() -> void:
	dependencies = []
	collect_dependencies(graph_edit.top_generator, dependencies)
	tree.clear()
	var root : TreeItem = tree.create_item()
	var missing : int = 0
	for i in dependencies.size():
		var d : Dictionary = dependencies[i]
		var item : TreeItem = tree.create_item(root)
		item.set_text(0, "%s (%s)" % [ d.generator.get_hier_name(), d.generator.get_type_name() ])
		item.set_text(1, d.path)
		item.set_tooltip_text(1, d.path)
		if FileAccess.file_exists(d.path):
			item.set_text(2, "OK")
		else:
			item.set_text(2, "Missing")
			item.set_custom_color(2, Color(1.0, 0.4, 0.4))
			missing += 1
		item.set_metadata(0, i)
	summary.text = "%d file(s), %d missing" % [ dependencies.size(), missing ] if not dependencies.is_empty() else "This graph does not depend on external files"

## Changes the files of dependencies as one undoable step
func relink(changes : Array) -> void:
	if changes.is_empty():
		return
	var undo_actions : Array = []
	var redo_actions : Array = []
	for c in changes:
		var hier_name : String = c.dependency.generator.get_hier_name()
		undo_actions.append({ type="setparams", node=hier_name, params={ c.dependency.parameter: c.dependency.path } })
		redo_actions.append({ type="setparams", node=hier_name, params={ c.dependency.parameter: c.path } })
	graph_edit.undoredo.add("Relink dependencies", undo_actions, redo_actions)
	for a in redo_actions:
		graph_edit.undoredo_command(a)
	graph_edit.set_need_save()
	refresh()

func select_file_or_dir(file_mode : FileDialog.FileMode, dialog_title : String) -> String:
	var dialog = preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
	dialog.min_size = Vector2(500, 500)
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = file_mode
	dialog.title = dialog_title
	var files = await dialog.select_files()
	return files[0] if files.size() == 1 else ""

func relink_selected() -> void:
	var item : TreeItem = tree.get_selected()
	if item == null:
		return
	var d : Dictionary = dependencies[item.get_metadata(0)]
	var path : String = await select_file_or_dir(FileDialog.FILE_MODE_OPEN_FILE, "Relink %s" % d.path.get_file())
	if path != "":
		relink([ { dependency=d, path=path } ])

## Finds files with the given names in a folder and its subfolders
static func find_files(folder : String, names : Dictionary, found : Dictionary) -> void:
	var dir : DirAccess = DirAccess.open(folder)
	if dir == null:
		return
	for f in dir.get_files():
		if names.has(f) and not found.has(f):
			found[f] = folder.path_join(f)
	for d in dir.get_directories():
		find_files(folder.path_join(d), names, found)

## Relinks missing files to files with the same name in folder, returns
## the number of relinked files
func relink_missing_from_folder(folder : String) -> int:
	var names : Dictionary = {}
	for d in dependencies:
		if not FileAccess.file_exists(d.path):
			names[d.path.get_file()] = true
	var found : Dictionary = {}
	find_files(folder, names, found)
	var changes : Array = []
	for d in dependencies:
		if not FileAccess.file_exists(d.path) and found.has(d.path.get_file()):
			changes.append({ dependency=d, path=found[d.path.get_file()] })
	relink(changes)
	return changes.size()

func find_missing_in_folder() -> void:
	var folder : String = await select_file_or_dir(FileDialog.FILE_MODE_OPEN_DIR, "Find missing files in folder")
	if folder != "":
		var count : int = relink_missing_from_folder(folder)
		summary.text += " (%d relinked)" % count

## Copies all existing dependencies into folder and relinks them to the
## copies, returns the number of collected files
func collect_into_folder(folder : String) -> int:
	var changes : Array = []
	var copied : Dictionary = {}
	for d in dependencies:
		if not FileAccess.file_exists(d.path):
			continue
		var target : String = folder.path_join(d.path.get_file())
		if target == d.path:
			continue
		if not copied.has(d.path):
			# Avoid overwriting a different file with the same name
			var index : int = 1
			while FileAccess.file_exists(target) and not copied.values().has(target):
				target = folder.path_join("%s_%d.%s" % [ d.path.get_file().get_basename(), index, d.path.get_extension() ])
				index += 1
			if DirAccess.copy_absolute(d.path, target) != OK:
				continue
			copied[d.path] = target
		changes.append({ dependency=d, path=copied[d.path] })
	relink(changes)
	return copied.size()

func collect_files() -> void:
	var folder : String = await select_file_or_dir(FileDialog.FILE_MODE_OPEN_DIR, "Collect files into folder")
	if folder != "":
		var count : int = collect_into_folder(folder)
		summary.text += " (%d collected)" % count
