extends OptionButton

# A color space of the OpenColorIO config, saved by name in the configuration


@export var config_variable : String
## The text of a first item that saves "" (no item for "" if empty)
@export var none_text : String = ""


func _init() -> void:
	fit_to_longest_item = false
	clip_text = true

## Lists color spaces, with current selected (current is added if it is not
## listed, so a name that is not in the config is kept)
func set_color_spaces(color_spaces : PackedStringArray, current : String) -> void:
	clear()
	if none_text != "":
		add_item(none_text)
		set_item_metadata(0, "")
	for s in color_spaces:
		add_item(s)
		set_item_metadata(item_count-1, s)
	if current != "" and not current in color_spaces:
		add_item("%s (not in config)" % current)
		set_item_metadata(item_count-1, current)
	selected = -1
	for i in item_count:
		if get_item_metadata(i) == current:
			selected = i
	if selected == -1 and item_count > 0:
		selected = 0
	tooltip_text = get_color_space()

## The selected color space ("" for none_text)
func get_color_space() -> String:
	return get_item_metadata(selected) if selected != -1 else ""

func init_from_config(config : ConfigFile) -> void:
	var current : String = ""
	if config.has_section_key("config", config_variable):
		current = str(config.get_value("config", config_variable))
	set_color_spaces(MMColorManagement.get_color_spaces(), current)

func update_config(config : ConfigFile) -> void:
	if item_count > 0:
		config.set_value("config", config_variable, get_color_space())

func _on_item_selected(_index : int) -> void:
	tooltip_text = get_color_space()

func _ready() -> void:
	item_selected.connect(_on_item_selected)
