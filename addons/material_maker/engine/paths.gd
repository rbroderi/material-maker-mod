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
## by tokens. A directory is only replaced at the start of the path, and only
## if it is the whole path or is followed by a slash (so a project in
## C:/x/proj does not match C:/x/proj2/a.png). Both slash styles are
## accepted, and the case is ignored on Windows. The first directory that
## matches is used, in the order above
static func encode_path(path : String) -> String:
	var tokens : Array = []
	if mm_loader.current_project_path != "":
		tokens.append([ mm_loader.current_project_path, "%PROJECT_PATH%" ])
	tokens.append([ OS.get_user_data_dir(), "%USER_DATA_PATH%" ])
	tokens.append([ get_resource_dir(), "%MATERIAL_MAKER_PATH%" ])
	var normalized_path : String = path.replace("\\", "/")
	var compared_path : String = normalized_path
	if OS.get_name() == "Windows":
		compared_path = compared_path.to_lower()
	for t in tokens:
		var dir : String = t[0].replace("\\", "/")
		while dir.ends_with("/"):
			dir = dir.left(-1)
		if dir == "":
			continue
		var compared_dir : String = dir.to_lower() if OS.get_name() == "Windows" else dir
		if compared_path == compared_dir:
			return t[1]
		if compared_path.begins_with(compared_dir + "/"):
			return t[1] + normalized_path.substr(dir.length())
	return path

## A file path saved in a graph (see encode_path). %PROJECT_PATH% is kept
## when no project is being loaded or saved
static func decode_path(path : String) -> String:
	if mm_loader.current_project_path != "":
		path = path.replace("%PROJECT_PATH%", mm_loader.current_project_path)
	path = path.replace("%USER_DATA_PATH%", OS.get_user_data_dir())
	return path.replace("%MATERIAL_MAKER_PATH%", get_resource_dir())

static func get_nodes_paths() -> Array:
	return [ STD_GENDEF_PATH, get_resource_dir()+"/nodes", "user://shared_nodes" ]
