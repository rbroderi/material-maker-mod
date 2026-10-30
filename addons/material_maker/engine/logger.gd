extends Node
class_name MMLogger

var logger : Object = null

func _ready():
	# Without the class cache (a fresh clone that was never imported), the
	# scripts that use the MM* classes do not parse and the application
	# would hang without an error
	if not Engine.is_editor_hint() and not FileAccess.file_exists("res://.godot/global_script_class_cache.cfg"):
		printerr("ERROR: The project was not imported. Run Godot once with: --headless --path <Material Maker folder> --import")
		get_tree().quit(1)

func set_logger(l : Object):
	logger = l

# Called when the node enters the scene tree for the first time.
func write(l: String, m : String):
	if logger:
		logger.write(l, m)
	elif l == "":
		print(m)
	else:
		print(l+": "+m)

func debug(m : String):
	write("DEBUG", m)

func message(m : String):
	write("", m)

func warning(m : String):
	write("WARNING", m)

func error(m : String):
	write("ERROR", m)
