extends RefCounted

## Helpers that render the buffer nodes (Buffer, Iterate Buffer, Iterate
## Buffer v2, FX-Map and GPU reductions such as Statistics) whose inputs use
## $time at a given time (MMComputeShader.fixed_time), for windows and command
## line modes that show or export a graph at times other than the current time


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
		# The outputs of Iterate Buffers depend on their other buffers
		var object : Object = mm_deps.buffers[buffer_name].object
		if object is MMGenIterateBuffer:
			to_visit.append_array([ object.buffer_name_init_input, object.buffer_name_loop_input ])
		elif object is MMGenIterateBufferV2:
			to_visit.append_array([ object.buffer_name_init, object.buffer_name_loop ])
	return rv

## The buffer nodes among the given buffers whose inputs use $time
static func get_animated_buffers(buffer_names : Array[String]) -> Array:
	var rv : Array = []
	for buffer_name in buffer_names:
		var generator : Object = mm_deps.buffers[buffer_name].object
		if not rv.has(generator) and is_animated_buffer(generator):
			rv.append(generator)
	return rv

## True if generator is a buffer node (that is not paused) and one of its
## inputs uses $time
static func is_animated_buffer(generator : Object) -> bool:
	if not (generator is MMGenBuffer or generator is MMGenIterateBuffer or generator is MMGenIterateBufferV2 or generator is MMGenGpuReduction or generator is MMGenSbsFxMap):
		return false
	if generator.get("is_paused") == true:
		return false
	for i in generator.get_input_defs().size():
		var source : MMGenBase.OutputPort = generator.get_source(i)
		if source == null:
			continue
		var code : MMGenBase.ShaderCode = source.generator.get_shader_code("uv", source.output_index, MMGenContext.new())
		var code_string : String = code.defs+code.code+str(code.output_values.values())
		for g in code.globals:
			code_string += g.code
		if code_string.contains("elapsed_time"):
			return true
	return false

## Invalidates buffer nodes, so they are rendered again (iterations start
## again)
static func invalidate_buffers(generators : Array) -> void:
	for generator in generators:
		if not is_instance_valid(generator):
			continue
		if generator is MMGenIterateBuffer:
			generator.set_current_iteration(0)
			mm_deps.buffer_invalidate(generator.buffer_name_init_input)
		elif generator is MMGenIterateBufferV2:
			generator.set_current_iteration(0)
			mm_deps.buffer_invalidate(generator.buffer_name_init)
		else:
			for buffer_name in mm_deps.buffers.keys():
				if mm_deps.buffers[buffer_name].object == generator:
					mm_deps.buffer_invalidate(buffer_name)

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
