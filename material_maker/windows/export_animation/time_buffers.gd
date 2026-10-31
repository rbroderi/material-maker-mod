extends RefCounted

## Helpers that render the Buffer and Iterate Buffer nodes whose inputs use
## $time at a given time (MMComputeShader.fixed_time), for windows that show
## or export a graph at times other than the current time


## The names of the given buffers and of the buffers they depend on, directly
## or not
static func get_dependencies(buffer_names : Array) -> Array[String]:
	var rv : Array[String] = []
	var to_visit : Array = buffer_names.duplicate()
	while not to_visit.is_empty():
		var buffer_name : String = to_visit.pop_back()
		if rv.has(buffer_name) or not mm_deps.buffers.has(buffer_name):
			continue
		rv.append(buffer_name)
		to_visit.append_array(mm_deps.buffers[buffer_name].dependencies)
		# The output of an Iterate Buffer depends on its other buffers
		var object : Object = mm_deps.buffers[buffer_name].object
		if object is MMGenIterateBuffer:
			to_visit.append_array([ object.buffer_name_init_input, object.buffer_name_loop_input ])
	return rv

## The Buffer and Iterate Buffer nodes among the given buffers whose inputs
## use $time
static func get_animated_buffers(buffer_names : Array[String]) -> Array:
	var rv : Array = []
	for buffer_name in buffer_names:
		var generator : Object = mm_deps.buffers[buffer_name].object
		if (generator is MMGenBuffer or generator is MMGenIterateBuffer) and not generator.is_paused and not rv.has(generator):
			for i in generator.get_input_defs().size():
				var source : MMGenBase.OutputPort = generator.get_source(i)
				if source == null:
					continue
				var code : MMGenBase.ShaderCode = source.generator.get_shader_code("uv", source.output_index, MMGenContext.new())
				var code_string : String = code.defs+code.code+str(code.output_values.values())
				for g in code.globals:
					code_string += g.code
				if code_string.contains("elapsed_time"):
					rv.append(generator)
					break
	return rv

## Invalidates Buffer and Iterate Buffer nodes, so they are rendered again
static func invalidate_buffers(generators : Array) -> void:
	for generator in generators:
		if not is_instance_valid(generator):
			continue
		if generator is MMGenIterateBuffer:
			generator.set_current_iteration(0)
			mm_deps.buffer_invalidate(generator.buffer_name_init_input)
		else:
			mm_deps.buffer_invalidate("o%d_tex" % generator.get_instance_id())

## Renders the given buffers again (at MMComputeShader.fixed_time), and waits
## until they and the given buffers that depend on them are rendered
static func render_buffers(generators : Array, buffer_names : Array[String]) -> void:
	invalidate_buffers(generators)
	while true:
		await mm_deps.get_tree().process_frame
		var rendering : bool = false
		for buffer_name in buffer_names:
			var buffer = mm_deps.buffers.get(buffer_name)
			# Buffers waiting for a buffer that failed are not rendered
			if buffer != null and (buffer.status == buffer.Updating or buffer.status == buffer.UpdatingInvalidated or (buffer.status == buffer.Invalidated and buffer.pending_dependencies == 0)):
				rendering = true
				break
		if not rendering:
			break
