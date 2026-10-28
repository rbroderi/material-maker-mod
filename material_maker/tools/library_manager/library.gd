extends Node

var library_path : String = ""
var library_name : String = ""
var library_items : Array = []
var library_items_by_name : Dictionary = {}
var library_icons : Dictionary[String, ImageTexture] = {}
var read_only : bool = false

func _ready():
	pass

func create_library(path : String, lib_name : String) -> void:
	library_path = path
	library_name = lib_name
	library_items = []
	library_items_by_name = {}
	library_icons = {}
	read_only = false

func load_library(path : String, ro : bool = false, raw_data : String = "") -> bool:
	if raw_data == "":
		if OS.get_name() == "Android":
			path = path.replace("root://", "res://material_maker/")
		else:
			path = path.replace("root://", MMPaths.get_resource_dir()+"/")
		var file : FileAccess = FileAccess.open(path, FileAccess.READ)
		if file == null:
			print("Failed to open "+path)
			return false
		raw_data = file.get_as_text()
	var json = JSON.new()
	if json.parse(raw_data) == OK and json.get_data() is Dictionary:
		var data : Dictionary = json.get_data()
		library_path = path
		library_name = data.name if data.has("name") else ""
		library_items = data.lib
		read_only = ro
		for i in data.lib:
			library_items_by_name[i.tree_item] = i
			i['display_name'] = i.tree_item.get_slice('/', i.tree_item.get_slice_count('/') - 1)
			var texture : ImageTexture = ImageTexture.new()
			var image : Image = Image.new()
			if i.has("icon_data"):
				image.load_png_from_buffer(Marshalls.base64_to_raw(i.icon_data))
			elif i.has("icon"):
				image.load(path.get_basename()+"/"+i.icon+".png")
				i.icon_data = Marshalls.raw_to_base64(image.save_png_to_buffer())
			else:
				library_icons[i.tree_item] = null
				continue
			texture = ImageTexture.create_from_image(image)
			library_icons[i.tree_item] = texture
		print("Successfully read library %s" % path)
		return true
	else:
		print("%s is not a valid library file" % path)
	return false

func get_item(lib_name : String):
	for i in library_items:
		if lib_name == i.tree_item:
			return { name=i.tree_item, item=i, icon=library_icons[i.tree_item] }
	return null

## Returns the items of this library that match the filter.
## Also assigns each returned item a score of how well it matched.
func get_items(filter : String, disabled_sections : Array, aliased_items : Array) -> Array:
	var array : Array = []
	filter = filter.to_lower().strip_edges()
	for i in library_items:
		var include := true
		var result_quality := 1.0
		if filter:
			include = false
			if i.display_name.to_lower().begins_with(filter) or " "+filter in i.display_name.to_lower():
				include = true

			if not include:
				include = true
				result_quality = 0.8
				for word in filter.split(" "):
					if not word in i.display_name.to_lower():
						include = false

			if (not include) and i.has("name"):
				include = true
				result_quality = 0.8
				for word in filter.split(" "):
					if not word in i.name.to_lower():
						include = false

			if not include:
				result_quality = 0.6
				for alias_dict in aliased_items:
					if alias_dict.has(i.tree_item) and filter in alias_dict[i.tree_item]:
						if alias_dict[i.tree_item].begins_with(filter) or ","+filter in alias_dict[i.tree_item]:
							result_quality = 0.9
						include = true

			if not include:
				include = true
				result_quality = 0.4
				for word in filter.split(" "):
					if not word in i.tree_item.to_lower():
						include = false

			if not include:
				var aliases : String = ""
				for alias_dict in aliased_items:
					aliases += ","+alias_dict.get(i.tree_item, "")
				result_quality = fuzzy_quality(filter, i.tree_item.to_lower(), aliases)
				include = result_quality > 0.0

		if include:
			var slash_pos = i.tree_item.find("/")
			var section_name = i.tree_item.left(slash_pos) if slash_pos != -1 else i.tree_item
			if disabled_sections.find(section_name) == -1:
				array.push_back({ name=i.tree_item, item=i, icon=library_icons[i.tree_item], quality=result_quality})
	return array


## Typo tolerant matching, for items the filter does not match exactly (all
## exact matches score 0.4 or more, and the recent items bonus of the add node
## popup is at most 0.05, so a fuzzy match is never listed before an exact
## one). Returns:
## - 0.3 if each word of the filter matches a word of the item path or an alias
##   with at most one typo (words shorter than 4 characters must begin a word),
## - 0.1 to 0.25 if the characters of the filter appear in order in the item
##   path, starting at the beginning of a word and not too spread out (the more
##   compact the match, the higher the score),
## - 0 otherwise.
static func fuzzy_quality(filter : String, tree_item : String, aliases : String = "") -> float:
	if filter.length() < 3:
		return 0.0
	var words : PackedStringArray = tree_item.replace("/", " ").split(" ", false)
	words.append_array(aliases.split(",", false))
	var all_words_match : bool = true
	for filter_word in filter.split(" ", false):
		var found : bool = false
		for word in words:
			if filter_word.length() < 4:
				found = word.begins_with(filter_word)
			else:
				found = is_within_one_edit(filter_word, word) or is_within_one_edit(filter_word, word.left(filter_word.length()))
			if found:
				break
		if not found:
			all_words_match = false
			break
	if all_words_match:
		return 0.3
	# Subsequence, starting at the beginning of a word
	var characters : String = filter.replace(" ", "")
	var text : String = tree_item.replace("/", " ")
	var best_compactness : float = 0.0
	for start in text.length():
		if text[start] != characters[0] or (start > 0 and text[start-1] != " "):
			continue
		var position : int = start
		for c in characters.substr(1):
			position = text.find(c, position+1)
			if position == -1:
				break
		if position == -1:
			break
		best_compactness = maxf(best_compactness, float(characters.length())/float(position-start+1))
	if best_compactness < 0.5:
		return 0.0
	return 0.1+0.15*best_compactness

## Returns true if a can be changed into b with at most one insertion,
## deletion, substitution or transposition of adjacent characters (a plain
## edit distance counts a swap as two typos)
static func is_within_one_edit(a : String, b : String) -> bool:
	var length_difference : int = a.length()-b.length()
	if absi(length_difference) > 1:
		return false
	var i : int = 0
	while i < mini(a.length(), b.length()) and a[i] == b[i]:
		i += 1
	if i == a.length() or i == b.length():
		return true
	if length_difference == 1:
		return a.substr(i+1) == b.substr(i)
	if length_difference == -1:
		return a.substr(i) == b.substr(i+1)
	if a.substr(i+1) == b.substr(i+1):
		return true
	return i+1 < a.length() and a[i] == b[i+1] and a[i+1] == b[i] and a.substr(i+2) == b.substr(i+2)

func generate_node_sections(node_sections : Dictionary) -> void:
	for i in library_items:
		var section = i.tree_item
		var slash_position = section.find("/")
		if slash_position != -1:
			section = i.tree_item.left(slash_position)
		if !i.has("type"):
			continue
		var node_name = ""
		if mm_loader.predefined_generators.has(i.type):
			node_name = i.type
			i = mm_loader.predefined_generators[i.type]
		elif i.has("shader_model"):
			if i.shader_model.has("name"):
				node_name = i.shader_model.name
		elif i.has("label"):
			node_name = i.label
		elif i.has("type"):
			node_name = i.type
		if node_name != "":
			if not node_sections.has(node_name):
				node_sections[node_name] = section
#			else:
#				print(node_name+" already defined in "+section)


func get_sections() -> Array:
	var sections : Array = Array()
	for i in library_items:
		var section_name = i.tree_item.left(i.tree_item.find("/"))
		if sections.find(section_name) == -1:
			sections.push_back(section_name)
	return Array(sections)

func save_library() -> Error:
	var e: Error
	DirAccess.make_dir_recursive_absolute(library_path.get_base_dir())
	var file : FileAccess = FileAccess.open(library_path, FileAccess.WRITE)
	e = FileAccess.get_open_error()
	if file != null && e == OK:
		file.store_string(JSON.stringify({name=library_name, lib=library_items}, "\t", true))
		e = file.get_error()
		file.close()
	return e

func add_item(item_name : String, image : Image, data : Dictionary) -> void:
	if read_only:
		return
	data.tree_item = item_name
	data.display_name = data.tree_item.get_slice('/', data.tree_item.get_slice_count('/') - 1)

	var current_library_item = get_item(item_name)
	if current_library_item and current_library_item.item.has("icon_data"):
		data.icon_data = current_library_item.item.icon_data

	var new_library_items = []
	var inserted = false
	for i in library_items:
		if i.tree_item != item_name:
			new_library_items.push_back(i)
		elif !inserted:
			new_library_items.push_back(data)
			inserted = true
	if !inserted:
		new_library_items.push_back(data)
	library_items = new_library_items
	library_items_by_name[item_name] = data

	if image != null:
		data.icon_data = Marshalls.raw_to_base64(image.save_png_to_buffer())
		var texture : ImageTexture = ImageTexture.new()
		texture.set_image(image)
		library_icons[item_name] = texture
	save_library()

func remove_item(item_name : String) -> void:
	if read_only:
		return
	var new_library_items = []
	for i in library_items:
		if i.tree_item != item_name:
			new_library_items.push_back(i)
	library_items = new_library_items
	library_items_by_name.erase(item_name)
	library_icons.erase(item_name)
	save_library()

func rename_item(old_name : String, new_name : String) -> void:
	if read_only or library_items_by_name.has(new_name):
		return
	library_items_by_name[new_name] = library_items_by_name[old_name]
	library_icons[new_name] = library_icons[old_name]
	library_items_by_name[new_name].tree_item = new_name
	library_items_by_name.erase(old_name)
	library_icons.erase(old_name)
	save_library()

func update_item_icon(item_name : String, icon : Image) -> void:
	if read_only:
		return
	var data = library_items_by_name[item_name]
	data.icon_data = Marshalls.raw_to_base64(icon.save_png_to_buffer())
	library_icons[item_name] = ImageTexture.create_from_image(icon)
	save_library()
