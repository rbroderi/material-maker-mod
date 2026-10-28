extends MMToolWindow
class_name MMLibraryInstancesWindow


# Lists the nodes of a graph that were created from library items that embed
# their definition, shows which ones are outdated, and updates them (see
# MMLibraryInstances).


var graph_edit = null
var library_manager = null
var instances : Array = []

var tree : Tree
var summary : Label


func _init() -> void:
	var vbox : VBoxContainer = create_layout("Library instances", Vector2i(800, 450), Vector2i(600, 300))
	summary = Label.new()
	vbox.add_child(summary)
	tree = create_tree([ "Node", "Library item", "Status" ])
	vbox.add_child(tree)
	var buttons : HBoxContainer = HBoxContainer.new()
	vbox.add_child(buttons)
	add_button(buttons, "Update selected", update_selected)
	add_button(buttons, "Update all outdated", update_all_outdated)
	add_spacer(buttons)
	add_button(buttons, "Close", queue_free)

func show_graph(ge, lm) -> void:
	graph_edit = ge
	library_manager = lm
	refresh()
	popup_centered()

func refresh() -> void:
	instances = MMLibraryInstances.collect_instances(graph_edit.top_generator)
	tree.clear()
	var root : TreeItem = tree.create_item()
	var outdated : int = 0
	for i in instances.size():
		var g : MMGenBase = instances[i]
		var status : Dictionary = MMLibraryInstances.get_status(g, library_manager)
		var item : TreeItem = tree.create_item(root)
		item.set_text(0, "%s (%s)" % [ g.get_hier_name(), g.get_type_name() ])
		item.set_text(1, g.library_source.get("item", ""))
		item.set_text(2, status.status)
		if status.status.begins_with("outdated"):
			item.set_custom_color(2, Color(1.0, 0.75, 0.3))
			outdated += 1
		elif status.status == "missing":
			item.set_custom_color(2, Color(1.0, 0.4, 0.4))
		item.set_metadata(0, i)
	summary.text = "%d instance(s), %d outdated" % [ instances.size(), outdated ] if not instances.is_empty() else "This graph has no nodes created from library graphs or custom shaders"

## Updates instances (a single undoable step)
func update_instances(selected : Array) -> void:
	graph_edit.undoredo.start_group()
	for g in selected:
		var status : Dictionary = MMLibraryInstances.get_status(g, library_manager)
		if status.item != null:
			await MMLibraryInstances.update_instance(g, status.item, graph_edit)
	graph_edit.undoredo.end_group()
	refresh()

func update_selected() -> void:
	var item : TreeItem = tree.get_selected()
	if item != null:
		await update_instances([ instances[item.get_metadata(0)] ])

func update_all_outdated() -> void:
	var outdated : Array = instances.filter(func(g): return MMLibraryInstances.get_status(g, library_manager).status.begins_with("outdated"))
	await update_instances(outdated)
