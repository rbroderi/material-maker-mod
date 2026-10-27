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
	add_button(buttons, "Show changes", show_selected_changes)
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
		item.set_text(1, g.library_source.item)
		item.set_text(2, status.status)
		if status.status.begins_with("outdated"):
			item.set_custom_color(2, Color(1.0, 0.75, 0.3))
			outdated += 1
		elif status.status == "missing":
			item.set_custom_color(2, Color(1.0, 0.4, 0.4))
		item.set_metadata(0, i)
	summary.text = "%d instance(s), %d outdated" % [ instances.size(), outdated ] if not instances.is_empty() else "This graph has no nodes created from library graphs or custom shaders"

func update_instances(selected : Array) -> void:
	for g in selected:
		var status : Dictionary = MMLibraryInstances.get_status(g, library_manager)
		if status.item != null:
			await MMLibraryInstances.update_instance(g, status.item, graph_edit)
	refresh()

func update_selected() -> void:
	var item : TreeItem = tree.get_selected()
	if item != null:
		await update_instances([ instances[item.get_metadata(0)] ])

func update_all_outdated() -> void:
	var outdated : Array = instances.filter(func(g): return MMLibraryInstances.get_status(g, library_manager).status.begins_with("outdated"))
	await update_instances(outdated)

## Shows what updating the selected instance would change: its output before
## and after (rendered with unconnected inputs), and the changes of its
## definition
func show_selected_changes() -> void:
	var item : TreeItem = tree.get_selected()
	if item == null:
		return
	var generator : MMGenBase = instances[item.get_metadata(0)]
	var status : Dictionary = MMLibraryInstances.get_status(generator, library_manager)
	if status.item == null:
		return
	var old_data : Dictionary = generator.serialize()
	var new_data : Dictionary = MMLibraryInstances.get_updated_data(generator, status.item)
	var changes : PackedStringArray = MMLibraryInstances.describe_changes(old_data, new_data)
	var dialog : ConfirmationDialog = ConfirmationDialog.new()
	dialog.title = "Changes of %s" % generator.get_hier_name()
	dialog.ok_button_text = "Update"
	dialog.size = Vector2i(760, 560)
	var vbox : VBoxContainer = VBoxContainer.new()
	dialog.add_child(vbox)
	var previews : HBoxContainer = HBoxContainer.new()
	previews.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(previews)
	var preview_rects : Array[TextureRect] = []
	for t in [ "Current", "After update" ]:
		var column : VBoxContainer = VBoxContainer.new()
		previews.add_child(column)
		var label : Label = Label.new()
		label.text = t
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(label)
		var rect : TextureRect = TextureRect.new()
		rect.custom_minimum_size = Vector2(192, 192)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		column.add_child(rect)
		preview_rects.append(rect)
	var text : TextEdit = TextEdit.new()
	text.editable = false
	text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text.text = "\n".join(changes) if not changes.is_empty() else "The definition is the same (only the library item's hash changed)"
	vbox.add_child(text)
	dialog.confirmed.connect(func():
		await update_instances([ generator ])
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()
	preview_rects[0].texture = await render_preview(old_data)
	if is_instance_valid(dialog):
		preview_rects[1].texture = await render_preview(new_data)

## Renders the first output of a node, alone in a temporary graph
func render_preview(data : Dictionary) -> Texture2D:
	var graph = await mm_loader.create_gen({ nodes=[ data ], connections=[] })
	if graph == null:
		return null
	add_child(graph)
	var texture : Texture2D = null
	var generator = graph.get_node_or_null(NodePath(data.name))
	if generator is MMGenBase and not generator.get_output_defs().is_empty():
		# (after the automatic buffers the node needs)
		var image : Image = await MMCliTools.render_output_image(generator, 0, Vector2i(256, 256))
		if image != null:
			texture = ImageTexture.create_from_image(image)
	graph.queue_free()
	return texture
