@tool
extends MMGenBuffer
class_name MMGenAutoBuffer


# Automatic buffers are inserted by shader nodes in front of inputs whose
# source would be expensive to inline (see MMGenShader.should_auto_buffer()).
# They are children of their consumer, get their source explicitly instead of
# from graph connections, and are never serialized.


var source : OutputPort = null
## Index of the consumer's input this buffer feeds
var consumer_input : int = 0


func _init() -> void:
	version = VERSION_SIMPLE

func get_type_name() -> String:
	return "Automatic Buffer"

func get_description() -> String:
	var desc_list : PackedStringArray = PackedStringArray()
	desc_list.push_back(TranslationServer.translate("Automatic Buffer"))
	desc_list.push_back(TranslationServer.translate("Inserted automatically in front of an expensive input"))
	return "\n".join(desc_list)

func set_source(s : OutputPort) -> void:
	if source != null and s != null and source.generator == s.generator and source.output_index == s.output_index:
		return
	source = s
	update_shader()

func get_source(_input_index : int) -> OutputPort:
	return source

func get_targets(_output_index : int) -> Array:
	return []

func notify_output_change(_output_index : int) -> void:
	# The consumer must regenerate its code (e.g. when the buffer becomes
	# greyscale), but must not regenerate this buffer again
	var consumer = get_parent()
	if consumer != null and consumer.has_method("auto_buffer_output_changed"):
		consumer.auto_buffer_output_changed(consumer_input)
