extends MMPlugin


# Multi-layer OpenEXR files (see exr_layers.gd)


const ExrLayers = preload("exr_layers.gd")


func _enable(api : MMPlugins.API) -> void:
	api.add_layered_image_format("exr", "Multi-layer OpenEXR", Callable(ExrLayers, "save_layers"))
