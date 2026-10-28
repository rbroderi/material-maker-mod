@tool
extends RefCounted
class_name MMGenContext


var variants : Dictionary = {}
var parent_context : MMGenContext = null
## The uniform that holds the current iteration of the iterate buffer whose
## loop is generated ($iteration in shaders), or ""
var iteration_variable : String = ""

func _init(p = null) -> void:
	parent_context = p

func get_iteration_variable() -> String:
	if iteration_variable != "":
		return iteration_variable
	return parent_context.get_iteration_variable() if parent_context != null else ""

func has_variant(generator) -> bool:
	return variants.has(generator) or parent_context != null and parent_context.has_variant(generator)

func touch_variant(generator) -> void:
	if !variants.has(generator):
		variants[generator] = []
	if parent_context != null:
		parent_context.touch_variant(generator)

func get_variant(generator, variant) -> int:
	var rv = -1
	if variants.has(generator):
		rv = variants[generator].find(variant)
		if rv == -1:
			variants[generator].push_back(variant)
	else:
		variants[generator] = [variant]
	touch_variant(generator)
	return rv
