extends MMPlugin


# The TX image format (see tx.gd)


const TX = preload("tx.gd")


func _enable(api : MMPlugins.API) -> void:
	api.add_image_format("tx", "TX texture (tiled, mip-mapped TIFF)", Callable(TX, "save_image"))
