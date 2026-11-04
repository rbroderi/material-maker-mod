extends OptionButton

# A color space of the OpenColorIO config, saved by name in the configuration


@export var config_variable : String
## The text of a first item that saves "" (no item for "" if empty)
@export var none_text : String = ""


func _init() -> void:
	fit_to_longest_item = false
	clip_text = true

## Lists the color spaces of the current config (or of o, an OCIO object)
## grouped by family, with current (a name or an alias) selected (current is
## added if it is not listed, so a name that is not in the config is kept)
func set_color_spaces(current : String, o = null) -> void:
	MMColorManagement.fill_color_space_picker(self, current, none_text, o)

## The selected color space ("" for none_text)
func get_color_space() -> String:
	return MMColorManagement.get_picker_color_space(self)

func init_from_config(config : ConfigFile) -> void:
	var current : String = ""
	if config.has_section_key("config", config_variable):
		current = str(config.get_value("config", config_variable))
	set_color_spaces(current)

func update_config(config : ConfigFile) -> void:
	if item_count > 0:
		config.set_value("config", config_variable, get_color_space())

func _on_item_selected(_index : int) -> void:
	tooltip_text = get_color_space()

func _ready() -> void:
	item_selected.connect(_on_item_selected)
