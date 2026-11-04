extends LineEdit

class_name StringOption

@export var config_variable : String

func init_from_config(config : ConfigFile) -> void:
	if config.has_section_key("config", config_variable):
		text = str(config.get_value("config", config_variable))

func update_config(config : ConfigFile) -> void:
	config.set_value("config", config_variable, text.strip_edges())
