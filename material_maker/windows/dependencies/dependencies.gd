extends MMToolWindow
class_name MMDependenciesWindow


# Lists the external files a graph depends on (image and file parameters of
# all its nodes, including groups and remote controls), shows the missing
# ones, and can relink them, find them in a folder, or collect all of them
# into a folder. Each change is one undoable step. Files are only copied,
# never moved, deleted or overwritten.


const FILE_PARAMETER_TYPES : Array[String] = [ "image_path", "file" ]
## Maximum depth of subfolders searched for missing files
const MAX_SEARCH_DEPTH : int = 16

var graph_edit = null
var dependencies : Array[Dictionary] = []

var tree : Tree
var summary : Label


func _init() -> void:
	var vbox : VBoxContainer = create_layout("Dependencies", Vector2i(900, 500), Vector2i(600, 300))
	summary = Label.new()
	vbox.add_child(summary)
	tree = create_tree([ "Node", "File", "Status" ])
	tree.set_column_expand_ratio(1, 2)
	tree.set_column_expand(2, false)
	tree.set_column_custom_minimum_width(2, 80)
	vbox.add_child(tree)
	var buttons : HBoxContainer = HBoxContainer.new()
	vbox.add_child(buttons)
	add_button(buttons, "Relink selected...", relink_selected)
	add_button(buttons, "Find missing files in folder...", find_missing_in_folder)
	add_button(buttons, "Collect files into folder...", collect_files)
	add_spacer(buttons)
	add_button(buttons, "Close", queue_free)
	# The graph may have changed (undo, redo, edits) while the window was not focused
	focus_entered.connect(refresh)

func show_graph(ge) -> void:
	graph_edit = ge
	refresh()
	popup_centered()

## The directory of the project file, or "" if the graph was never saved
func get_project_dir() -> String:
	if graph_edit != null and graph_edit.save_path != "":
		return graph_edit.save_path.get_base_dir()
	return ""

## A path as stored in a parameter, with %PROJECT_PATH% and the other path
## tokens replaced
func resolve_path(path : String) -> String:
	if path.find("%") == -1:
		return path
	var previous_project_path : String = mm_loader.current_project_path
	mm_loader.current_project_path = get_project_dir()
	var rv : String = MMPaths.decode_path(path)
	mm_loader.current_project_path = previous_project_path
	return rv

## A shorter path for display, relative to the project as when saved
func display_path(path : String) -> String:
	var previous_project_path : String = mm_loader.current_project_path
	mm_loader.current_project_path = get_project_dir()
	var rv : String = MMPaths.encode_path(path)
	mm_loader.current_project_path = previous_project_path
	return rv

## A key that identifies a file whatever the path separators (and case on
## Windows, whose file systems are case-insensitive)
static func file_key(path : String) -> String:
	path = path.replace("\\", "/").simplify_path()
	return path.to_lower() if OS.get_name() == "Windows" else path

static func file_name(path : String) -> String:
	return path.replace("\\", "/").get_file()

## Returns the file dependencies of a generator and its children
static func collect_dependencies(generator : Node, rv : Array[Dictionary]) -> void:
	for c in generator.get_children():
		if not c is MMGenBase:
			continue
		for p in c.get_parameter_defs():
			if p.has("type") and p.type in FILE_PARAMETER_TYPES:
				var path = c.get_parameter(p.name)
				if path is String and path != "":
					rv.append({ generator=c, parameter=p.name, path=path })
		collect_dependencies(c, rv)

func refresh() -> void:
	if graph_edit == null or not is_instance_valid(graph_edit) or graph_edit.top_generator == null:
		return
	var selected_key : String = ""
	var selected : TreeItem = tree.get_selected()
	if selected != null and selected.get_metadata(0) < dependencies.size():
		selected_key = dependencies[selected.get_metadata(0)].key
	dependencies = []
	collect_dependencies(graph_edit.top_generator, dependencies)
	tree.clear()
	var root : TreeItem = tree.create_item()
	var missing : int = 0
	var files : Dictionary = {}
	for i in dependencies.size():
		var d : Dictionary = dependencies[i]
		d.resolved = resolve_path(d.path)
		d.key = file_key(d.resolved)
		d.exists = FileAccess.file_exists(d.resolved)
		files[d.key] = d.exists
		var item : TreeItem = tree.create_item(root)
		item.set_text(0, "%s (%s)" % [ d.generator.get_hier_name(), d.generator.get_type_name() ])
		item.set_text(1, display_path(d.resolved))
		item.set_tooltip_text(1, d.resolved)
		if d.exists:
			item.set_text(2, "OK")
		else:
			item.set_text(2, "Missing")
			item.set_custom_color(2, Color(1.0, 0.4, 0.4))
		item.set_metadata(0, i)
		if d.key == selected_key and tree.get_selected() == null:
			item.select(0)
	for k in files.keys():
		if not files[k]:
			missing += 1
	if dependencies.is_empty():
		summary.text = "This graph does not depend on external files"
	else:
		summary.text = "%d file(s), %d missing" % [ files.size(), missing ]

## Changes the files of dependencies as one undoable step
func relink(changes : Array, action_name : String = "Relink dependencies") -> void:
	var undo_actions : Array = []
	var redo_actions : Array = []
	for c in changes:
		if not is_instance_valid(c.dependency.generator) or c.path == c.dependency.path:
			continue
		var hier_name : String = c.dependency.generator.get_hier_name()
		undo_actions.append({ type="setparams", node=hier_name, params={ c.dependency.parameter: c.dependency.path } })
		redo_actions.append({ type="setparams", node=hier_name, params={ c.dependency.parameter: c.path } })
	if redo_actions.is_empty():
		return
	# Undo in reverse order, so remote controls and the parameters they drive end up consistent
	undo_actions.reverse()
	graph_edit.undoredo.add(action_name, undo_actions, redo_actions)
	for a in redo_actions:
		graph_edit.undoredo_command(a)
	graph_edit.set_need_save()
	refresh()

func select_file_or_dir(file_mode : FileDialog.FileMode, dialog_title : String, current_dir : String = "") -> String:
	var dialog = preload("res://material_maker/windows/file_dialog/file_dialog.tscn").instantiate()
	dialog.min_size = Vector2(500, 500)
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.file_mode = file_mode
	dialog.title = dialog_title
	if current_dir != "" and DirAccess.dir_exists_absolute(current_dir):
		dialog.current_dir = current_dir
	var files = await dialog.select_files()
	return files[0] if files.size() == 1 else ""

## Relinks all references to a file (identified by its key), returns the
## number of changed references
func relink_file(key : String, path : String) -> int:
	var changes : Array = []
	for d in dependencies:
		if d.key == key:
			changes.append({ dependency=d, path=path })
	if not changes.is_empty():
		relink(changes, "Relink %s" % file_name(changes[0].dependency.path))
	return changes.size()

func relink_selected() -> void:
	var item : TreeItem = tree.get_selected()
	if item == null:
		return
	var d : Dictionary = dependencies[item.get_metadata(0)]
	var path : String = await select_file_or_dir(FileDialog.FILE_MODE_OPEN_FILE, "Relink %s" % file_name(d.path), d.resolved.get_base_dir())
	if path != "":
		# The list may have been refreshed while the file dialog was open
		relink_file(d.key, path)

## Finds files with the given (lower case) names in a folder and its
## subfolders. The first file found for each name is kept
static func find_files(folder : String, names : Dictionary, found : Dictionary, depth : int = 0) -> void:
	var dir : DirAccess = DirAccess.open(folder)
	if dir == null:
		return
	for f in dir.get_files():
		var n : String = f.to_lower()
		if names.has(n) and not found.has(n):
			found[n] = folder.path_join(f)
	if found.size() < names.size() and depth < MAX_SEARCH_DEPTH:
		for d in dir.get_directories():
			find_files(folder.path_join(d), names, found, depth+1)

## Relinks missing files to files with the same name in folder, returns
## the number of relinked files
func relink_missing_from_folder(folder : String) -> int:
	var names : Dictionary = {}
	for d in dependencies:
		if not d.exists:
			names[file_name(d.resolved).to_lower()] = true
	if names.is_empty():
		return 0
	var found : Dictionary = {}
	find_files(folder, names, found)
	var changes : Array = []
	var relinked : Dictionary = {}
	for d in dependencies:
		var n : String = file_name(d.resolved).to_lower()
		if not d.exists and found.has(n):
			changes.append({ dependency=d, path=found[n] })
			relinked[d.key] = true
	relink(changes, "Find missing files")
	return relinked.size()

func find_missing_in_folder() -> void:
	var folder : String = await select_file_or_dir(FileDialog.FILE_MODE_OPEN_DIR, "Find missing files in folder", get_project_dir())
	if folder != "":
		var count : int = relink_missing_from_folder(folder)
		summary.text += " (%d relinked)" % count

## Copies all existing dependencies into folder and relinks them to the
## copies, returns the number of collected files. A file that is already
## in the folder is not copied, and existing files are never overwritten:
## a copy gets a new name unless the existing file is identical
func collect_into_folder(folder : String) -> int:
	if not DirAccess.dir_exists_absolute(folder) and DirAccess.make_dir_recursive_absolute(folder) != OK:
		return 0
	var changes : Array = []
	# Target path for each collected file
	var copied : Dictionary = {}
	# Targets used by this collection
	var targets : Dictionary = {}
	for d in dependencies:
		if not d.exists:
			continue
		if not copied.has(d.key):
			var source_name : String = file_name(d.resolved)
			var target : String = folder.path_join(source_name)
			if file_key(target) == d.key:
				# Already in the folder
				continue
			var index : int = 1
			while targets.has(file_key(target)) or (FileAccess.file_exists(target) and FileAccess.get_md5(target) != FileAccess.get_md5(d.resolved)):
				target = folder.path_join("%s_%d" % [ source_name.get_basename(), index ])
				if source_name.get_extension() != "":
					target += "."+source_name.get_extension()
				index += 1
			if not FileAccess.file_exists(target) and DirAccess.copy_absolute(d.resolved, target) != OK:
				continue
			copied[d.key] = target
			targets[file_key(target)] = true
		changes.append({ dependency=d, path=copied[d.key] })
	relink(changes, "Collect dependencies")
	return copied.size()

func collect_files() -> void:
	var folder : String = await select_file_or_dir(FileDialog.FILE_MODE_OPEN_DIR, "Collect files into folder", get_project_dir())
	if folder != "":
		var count : int = collect_into_folder(folder)
		summary.text += " (%d collected)" % count
