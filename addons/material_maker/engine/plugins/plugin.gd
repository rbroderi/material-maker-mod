extends RefCounted
class_name MMPlugin


# Base class of the scripts of Material Maker plugins (see MMPlugins). A
# plugin's script extends it and registers what it adds in _enable():
#
#	extends MMPlugin
#
#	func _enable(api : MMPlugins.API) -> void:
#		api.add_menu_item("Say hello", func(): mm_globals.set_tip_text("Hello", 3))
#		api.add_command("hello", func(arguments): print("Hello ", " ".join(arguments)); return 0)


## Called when the plugin is loaded (at startup, if it is enabled)
func _enable(_api : MMPlugins.API) -> void:
	pass

## Called when Material Maker quits
func _disable() -> void:
	pass
