@tool
class_name MMPaths

const WEBSITE_ADDRESS : String = "https://www.materialmaker.org"
#const WEBSITE_ADDRESS : String = "http://localhost:3000"

const STD_GENDEF_PATH = "res://addons/material_maker/nodes"

static func get_resource_dir() -> String:
	if Engine.is_editor_hint():
		return ProjectSettings.globalize_path("res://material_maker")
	return OS.get_executable_path().get_base_dir()

## A file path as saved in graphs: the project (while a project is being
## loaded or saved), user data and Material Maker directories are replaced
## by tokens
static func encode_path(path : String) -> String:
	if mm_loader.current_project_path != "":
		path = path.replace(mm_loader.current_project_path, "%PROJECT_PATH%")
	path = path.replace(OS.get_user_data_dir(), "%USER_DATA_PATH%")
	return path.replace(get_resource_dir(), "%MATERIAL_MAKER_PATH%")

## A file path saved in a graph (see encode_path). %PROJECT_PATH% is kept
## when no project is being loaded or saved
static func decode_path(path : String) -> String:
	if mm_loader.current_project_path != "":
		path = path.replace("%PROJECT_PATH%", mm_loader.current_project_path)
	path = path.replace("%USER_DATA_PATH%", OS.get_user_data_dir())
	return path.replace("%MATERIAL_MAKER_PATH%", get_resource_dir())

static func get_nodes_paths() -> Array:
	return [ STD_GENDEF_PATH, get_resource_dir()+"/nodes", "user://shared_nodes" ]
