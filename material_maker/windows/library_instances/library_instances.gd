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
var show_changes_button : Button

# Size of the before and after renders of the changes dialog
const PREVIEW_SIZE : int = 256


func _init() -> void:
	var vbox : VBoxContainer = create_layout("Library instances", Vector2i(800, 450), Vector2i(600, 300))
	summary = Label.new()
	vbox.add_child(summary)
	tree = create_tree([ "Node", "Library item", "Status" ])
	tree.item_selected.connect(update_buttons)
	tree.item_activated.connect(show_selected_changes)
	vbox.add_child(tree)
	var buttons : HBoxContainer = HBoxContainer.new()
	vbox.add_child(buttons)
	show_changes_button = add_button(buttons, "Show changes", show_selected_changes)
	show_changes_button.tooltip_text = "Show what updating the selected instance would change"
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
	update_buttons()

## The selected instance and its status ({ generator, status, item }), or
## an empty dictionary
func get_selected_instance() -> Dictionary:
	var item : TreeItem = tree.get_selected()
	if item == null or not is_instance_valid(instances[item.get_metadata(0)]):
		return {}
	var generator : MMGenBase = instances[item.get_metadata(0)]
	var rv : Dictionary = MMLibraryInstances.get_status(generator, library_manager)
	rv.generator = generator
	return rv

func update_buttons() -> void:
	var selected : Dictionary = get_selected_instance()
	# (there is nothing to show for missing and up to date instances)
	show_changes_button.disabled = selected.is_empty() or selected.item == null or selected.status == "up to date"

## Updates instances (a single undoable step)
func update_instances(selected : Array) -> void:
	graph_edit.undoredo.start_group()
	for g in selected:
		if not is_instance_valid(g) or not g.is_inside_tree():
			continue
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

## Shows what updating the selected instance would change: its first output
## before and after (rendered alone, with unconnected inputs) and the changes
## of its definition. The dialog's OK button updates it.
func show_selected_changes() -> void:
	var selected : Dictionary = get_selected_instance()
	if selected.is_empty() or selected.item == null or selected.status == "up to date":
		return
	var generator : MMGenBase = selected.generator
	var dialog : ConfirmationDialog = ConfirmationDialog.new()
	dialog.title = "Changes of %s" % generator.get_hier_name()
	dialog.ok_button_text = "Update"
	dialog.size = Vector2i(760, 600)
	var vbox : VBoxContainer = VBoxContainer.new()
	dialog.add_child(vbox)
	var status : Label = Label.new()
	status.text = "%s: %s" % [ generator.library_source.get("item", ""), selected.status ]
	vbox.add_child(status)
	var previews : HBoxContainer = HBoxContainer.new()
	previews.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(previews)
	var preview_rects : Array = []
	for t in [ "Current", "After update" ]:
		var column : VBoxContainer = VBoxContainer.new()
		previews.add_child(column)
		var label : Label = Label.new()
		label.text = t
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		column.add_child(label)
		var rect : TextureRect = TextureRect.new()
		rect.custom_minimum_size = Vector2(PREVIEW_SIZE, PREVIEW_SIZE)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		column.add_child(rect)
		preview_rects.append(rect)
	var text : TextEdit = TextEdit.new()
	text.editable = false
	text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	text.text = "Comparing..."
	vbox.add_child(text)
	dialog.confirmed.connect(func():
		await update_instances([ generator ])
		dialog.queue_free())
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()
	show_changes(dialog, text, preview_rects, generator.serialize(), MMLibraryInstances.get_updated_data(generator, selected.item), selected.item, get_tree())

## Fills the changes dialog. The instance and its updated version are
## compared and rendered as copies, in a temporary node outside of the edited
## graph that is freed once they are rendered (this is static so that it
## completes and frees them even if the window is closed meanwhile).
static func show_changes(dialog : Window, text : TextEdit, preview_rects : Array, old_data : Dictionary, new_data : Dictionary, item : Dictionary, scene_tree : SceneTree) -> void:
	var holder : Node = Node.new()
	holder.name = "library_instance_changes"
	scene_tree.root.add_child(holder)
	var generators : Array = []
	for data in [ old_data, new_data ]:
		var graph = await mm_loader.create_gen({ nodes=[ data.duplicate(true) ], connections=[] })
		var generator = null
		if graph != null:
			holder.add_child(graph)
			generator = graph.get_node_or_null(NodePath(data.name))
		generators.append(generator)
	# (the updated version is compared once loaded, as the instance was)
	var changes : PackedStringArray = MMLibraryInstances.describe_changes(old_data, generators[1].serialize() if generators[1] is MMGenBase else new_data, item)
	if is_instance_valid(dialog):
		text.text = "\n".join(changes) if not changes.is_empty() else "Nothing this node uses changed in the library item"
	# Render the outputs once the buffers they use (including the automatic
	# buffers their shaders create) are rendered
	await wait_for_renders(holder)
	for i in generators.size():
		var texture : Texture2D = null
		if is_instance_valid(dialog) and generators[i] is MMGenBase and not generators[i].get_output_defs().is_empty():
			var image : Image = await MMCliTools.render_output_image(generators[i], 0, Vector2i(PREVIEW_SIZE, PREVIEW_SIZE))
			if image != null:
				texture = ImageTexture.create_from_image(image)
		if is_instance_valid(dialog):
			preview_rects[i].texture = texture
	# (freeing a buffer generator while it renders left mm_deps updating forever)
	await wait_for_renders(holder)
	holder.queue_free()

## Waits until the buffers of the temporary graphs are rendered (for at most
## max_frames)
static func wait_for_renders(holder : Node, max_frames : int = 600) -> void:
	var idle_frames : int = 0
	for i in max_frames:
		if not holder.is_inside_tree():
			return
		await holder.get_tree().process_frame
		idle_frames = 0 if has_buffers(holder, [ mm_deps.Buffer.Invalidated, mm_deps.Buffer.Updating, mm_deps.Buffer.UpdatingInvalidated ]) else idle_frames+1
		if idle_frames >= 3:
			return
	# (freeing a buffer while it renders would block the next renders)
	while holder.is_inside_tree() and has_buffers(holder, [ mm_deps.Buffer.Updating, mm_deps.Buffer.UpdatingInvalidated ]):
		await holder.get_tree().process_frame

## Returns true if a buffer of the temporary graphs has one of the statuses
static func has_buffers(holder : Node, statuses : Array) -> bool:
	for b in mm_deps.buffers.values():
		if is_instance_valid(b.object) and b.object is Node and holder.is_ancestor_of(b.object) and b.status in statuses:
			return true
	return false
