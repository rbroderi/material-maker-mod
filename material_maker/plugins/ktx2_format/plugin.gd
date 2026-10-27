extends MMPlugin


# The KTX2 image format (see ktx2.gd, also used by the volume_export plugin
# for 3D textures)


const KTX2 = preload("ktx2.gd")


func _enable(api : MMPlugins.API) -> void:
	api.add_image_format("ktx2", "KTX2 texture", Callable(KTX2, "save_image"))
