extends Node


signal updated

class Buffer:
	enum {
		Invalidated,
		Updating,
		UpdatingInvalidated,
		Updated,
		Error
	}
	
	var name : String
	var object : Object
	var dependencies : Array
	var pending_dependencies : int
	var status : int
	var renders : int
	var shader_generations : int
	## The buffer's texture was freed after its last reader was rendered
	## (it still counts as updated, see restore_buffer())
	var released : bool = false
	var restoring : bool = false
	
	const STATUS = ["Invalidated","Updating","UpdatingInvalidated","Updated","Error"]
	
	func _init(n : String, o : Object = null):
		name = n
		object = o
		dependencies = []
		pending_dependencies = 0
		status = Updated
		renders = 0
		shader_generations = 0


var dependencies : Dictionary = {}
var dependencies_values : Dictionary = {}
var buffers : Dictionary[String, Buffer] = {}

var reset_stats : bool = true
var render_queue_size : int = 0

## Set while nodes are moved to another parent (e.g. into a new group), so
## their buffers are kept when they leave the tree
var moving_nodes : bool = false

## Incremented whenever a dependency is updated (e.g. each iteration of an
## Iterate Buffer), so waiting code can tell slow renders from stuck ones
var render_progress : int = 0

## When buffers are freed after their last reader was rendered (see
## design/buffer_lifetimes.md)
enum { RELEASE_NEVER, RELEASE_DURING_EXPORTS, RELEASE_ALWAYS }
var release_mode : int = RELEASE_NEVER
## Number of running exports (buffers are released during exports in
## RELEASE_DURING_EXPORTS mode)
var exports_running : int = 0
## Render order of the buffers (depth first), recalculated when dependencies change
var render_order : Array[String] = []
var render_order_dirty : bool = true

signal buffer_restored(buffer_name : String)


signal render_queue_empty


func create_buffer(buffer_name : String, object : Object = null):
	if buffers.has(buffer_name):
		assert(buffers[buffer_name].object == object)
		return
	buffers[buffer_name] = Buffer.new(buffer_name, object)
	render_order_dirty = true
	buffer_invalidate(buffer_name)
	if object is Node and not object.is_connected("tree_exiting", self.delete_buffers_from_object.bind(object)):
		object.connect("tree_exiting", self.delete_buffers_from_object.bind(object))

func delete_buffer(buffer_name : String):
	# If the buffer is being rendered, its object is being freed and its render
	# coroutine will never return, so the update loop that awaits it would be
	# stuck forever: a new update loop takes over
	var was_updating : bool = buffers.has(buffer_name) and buffers[buffer_name].status in [ Buffer.Updating, Buffer.UpdatingInvalidated ]
	buffer_clear_dependencies(buffer_name)
	buffers.erase(buffer_name)
	render_order_dirty = true
	if dependencies.has(buffer_name):
		# The buffer has just been invalidated, so the buffers that depend on
		# it count it as a pending dependency: release them so they can be
		# rendered again
		for b in dependencies[buffer_name]:
			if buffers.has(b):
				buffers[b].dependencies.erase(buffer_name)
				if buffers[b].pending_dependencies > 0:
					buffers[b].pending_dependencies -= 1
		dependencies.erase(buffer_name)
		update()
	dependencies_values.erase(buffer_name)
	if was_updating and updating:
		updating = false
		update_scheduled = false
		update_generation += 1
		update()

func delete_buffers_from_object(object : Object):
	if moving_nodes:
		return
	var remove_buffers : Array = []
	for b in buffers.keys():
		if buffers[b].object == object:
			remove_buffers.append(b)
	for b in remove_buffers:
		delete_buffer(b)

var released_objects : Dictionary[String, bool] = {}
var object_value_regex : RegEx = RegEx.create_from_string("^(?:p_|seed_)?o(\\d+)(?:_|$)")

## Releases the values of the dependencies of an object that is being freed
## (named o<id>_..., p_o<id>_... or seed_o<id>), such as the texture of an
## Image node. Objects freed in the same frame are released together.
func release_object_values(object_id : int):
	if released_objects.is_empty():
		do_release_object_values.call_deferred()
	released_objects[str(object_id)] = true

func do_release_object_values():
	for d in dependencies_values.keys():
		var m : RegExMatch = object_value_regex.search(d)
		if m != null and released_objects.has(m.get_string(1)):
			dependencies_values.erase(d)
	released_objects.clear()

func buffer_clear_dependencies(buffer_name : String):
	assert(buffers.has(buffer_name))
	reset_stats = true
	render_order_dirty = true
	var b : Buffer = buffers[buffer_name]
	for d in b.dependencies:
		if dependencies.has(d):
			var dep_index = dependencies[d].find(buffer_name)
			assert(dep_index != -1)
			if dependencies[d].size() == 1:
				dependencies.erase(d)
				if dependencies_values.has(d) and ! (dependencies_values[d] is MMTexture):
					dependencies_values.erase(d)
			else:
				dependencies[d].remove_at(dep_index)
				assert(dependencies[d].find(buffer_name) == -1)
	b.dependencies = []
	b.pending_dependencies = 0
	buffer_invalidate(buffer_name)

func buffer_add_dependency(buffer_name : String, dependency_name : String):
	var buffer : Buffer = buffers[buffer_name]
	if buffer.dependencies.find(dependency_name) != -1:
		return null
	reset_stats = true
	render_order_dirty = true
	buffer.dependencies.append(dependency_name)
	if ! dependencies.has(dependency_name):
		dependencies[dependency_name] = []
	if dependencies[dependency_name].find(buffer_name) == -1:
		dependencies[dependency_name].push_back(buffer_name)
		if buffers.has(dependency_name) and buffers[dependency_name].status != Buffer.Updated:
			buffer.pending_dependencies += 1
	buffer_invalidate(buffer_name)
	return dependencies_values[dependency_name] if dependencies_values.has(dependency_name) else null

func buffer_has_pending_dependencies(buffer_name : String) -> bool:
	return buffers[buffer_name].pending_dependencies > 0

func buffer_invalidate(buffer_name):
	assert(buffers.has(buffer_name))
	var buffer : Buffer = buffers[buffer_name]
	match buffer.status:
		Buffer.Invalidated, Buffer.UpdatingInvalidated:
			return
		Buffer.Updated:
			buffer.status = Buffer.Invalidated
			buffer.released = false
			if dependencies.has(buffer_name):
				for d in dependencies[buffer_name]:
					var b : Buffer = buffers[d]
					b.pending_dependencies += 1
					buffer_invalidate(d)
		_:
			buffer.status = Buffer.UpdatingInvalidated
	update()
	if buffer.object != null and buffer.object.has_method("on_dep_buffer_invalidated"):
		buffer.object.on_dep_buffer_invalidated(buffer_name)

## Invalidates a buffer that could not be rendered (e.g. because its generator
## was paused when it was invalidated), so it is rendered again
func buffer_retry(buffer_name : String) -> void:
	if buffers.has(buffer_name) and buffers[buffer_name].status == Buffer.Error:
		buffer_invalidate(buffer_name)

func dependency_update(dependency_name : String, value = null, internal : bool = false):
	render_progress += 1
	var need_update : bool = false
	var is_buffer_just_updated : bool = false
	if value != null:
		dependencies_values[dependency_name] = value
	#print("%s = %s" % [ dependency_name, str(value) ])
	if buffers.has(dependency_name) and buffers[dependency_name].restoring:
		# A released buffer was rendered again: its readers are up to date
		var b : Buffer = buffers[dependency_name]
		b.restoring = false
		b.released = false
		b.renders += 1
		buffer_restored.emit(dependency_name)
		return
	if buffers.has(dependency_name):
		var b : Buffer = buffers[dependency_name]
		match b.status:
			Buffer.Invalidated:
				#print_debug("Buffer %s (updating) should not be invalidated" % dependency_name)
				#is_buffer_just_updated = true
				update()
				return
			Buffer.UpdatingInvalidated:
				#print_debug("Buffer %s (updating) reset to invalidated status" % dependency_name)
				b.status = Buffer.Invalidated
				update()
				return
			Buffer.Updated:
				print_debug("Buffer %s updated again?" % dependency_name)
				pass
			_:
				#print_debug("Buffer %s updated" % dependency_name)
				is_buffer_just_updated = true
		b.status = Buffer.Updated
		b.renders += 1
		if is_buffer_just_updated and is_releasing():
			release_unused_dependencies(dependency_name)
	if ! internal:
		#print("Resetting stats because of %s" % dependency_name)
		reset_stats = true
	if dependencies.has(dependency_name):
		for d in dependencies[dependency_name]:
			assert(buffers.has(d))
			var b : Buffer = buffers[d]
			if is_buffer_just_updated:
				b.pending_dependencies -= 1
				if b.pending_dependencies == 0:
					need_update = true
			if b.object.has_method("on_dep_update_value") and await b.object.on_dep_update_value(d, dependency_name, value):
				continue
			buffer_invalidate(d)
			need_update = true
	update()

func dependencies_update(dependency_values : Dictionary):
	for k in dependency_values.keys():
		dependency_update(k, dependency_values[k])

var updating : bool = false
var update_scheduled : bool = false
## Incremented when an update loop replaces a stuck one
var update_generation : int = 0

func update():
	if update_scheduled:
		return
	update_scheduled = true
	if !updating:
		do_update.call_deferred()

# on_dep_update_buffer:
# - returns true if update was performed immediately, set to updated
# - if returns false or a gdScriptFunctionState, set to updating

func do_update():
	updating = true
	var generation : int = update_generation
	while update_scheduled:
		update_scheduled = false
		var invalidated_buffers : int = 0
		var releasing : bool = is_releasing()
		for b in (get_render_order().duplicate() if releasing else buffers.keys()):
			if ! buffers.has(b):
				continue
			var buffer : Buffer = buffers[b]
			# Buffers that failed to render are not pending (they would block
			# everything that waits for an empty render queue)
			if buffer.object != null and buffer.object is MMGenBase and buffer.status != Buffer.Updated and buffer.status != Buffer.Error:
				invalidated_buffers += 1
			if (buffer.status == Buffer.Invalidated or buffer.status == Buffer.UpdatingInvalidated) and buffer.pending_dependencies == 0:
				if buffer.object.has_method("on_dep_update_buffer"):
					buffer.status = Buffer.Updating
					# Released inputs are rendered again first
					for d in buffer.dependencies:
						if buffers.has(d) and buffers[d].released:
							await restore_buffer(d)
					if generation != update_generation:
						return
					var status = await buffer.object.on_dep_update_buffer(b)
					if generation != update_generation:
						# A newer update loop took over (see delete_buffer)
						return
					if status is bool and ! status:
						buffer.status = Buffer.Error
		if reset_stats:
			render_queue_size = invalidated_buffers
			reset_stats = false
		get_tree().call_group("render_counter", "on_counter_change", render_queue_size, invalidated_buffers)
		if invalidated_buffers == 0:
			emit_signal("render_queue_empty")
	updating = false
	updated.emit()

func is_releasing() -> bool:
	match release_mode:
		RELEASE_ALWAYS:
			return true
		RELEASE_DURING_EXPORTS:
			return exports_running > 0
	return false

## Starts or ends an export (buffers may be released during exports)
func set_exporting(exporting : bool) -> void:
	exports_running = max(0, exports_running+(1 if exporting else -1))

## Buffers can be released if they are rendered by generators that can render
## them again, and only read by other generators' buffers (previews, the
## material and widgets keep their inputs)
func can_release(buffer_name : String) -> bool:
	var buffer : Buffer = buffers[buffer_name]
	if buffer.released or buffer.status != Buffer.Updated or buffer.object == null or not buffer.object.has_method("release_buffer"):
		return false
	if not dependencies.has(buffer_name) or dependencies[buffer_name].is_empty():
		return false
	for r in dependencies[buffer_name]:
		if not buffers.has(r):
			return false
		var reader : Buffer = buffers[r]
		if reader.status != Buffer.Updated or not reader.object is MMGenBase or reader.object is MMGenMaterial:
			return false
		# Iterate buffers read their inputs again in each iteration
		if reader.object is MMGenIterateBuffer or reader.object is MMGenIterateBufferV2:
			return false
	return true

## Releases the inputs of a buffer that has just been rendered, if all their
## readers are rendered
func release_unused_dependencies(buffer_name : String) -> void:
	for d in buffers[buffer_name].dependencies:
		if buffers.has(d) and can_release(d):
			var buffer : Buffer = buffers[d]
			if buffer.object.release_buffer(d):
				buffer.released = true

## Releases all buffers that can be released (when releasing is enabled)
func release_unused_buffers() -> void:
	if not is_releasing():
		return
	for b in buffers.keys():
		if can_release(b) and buffers[b].object.release_buffer(b):
			buffers[b].released = true

## Renders a released buffer again (its inputs first), without invalidating
## its readers
func restore_buffer(buffer_name : String) -> void:
	if not buffers.has(buffer_name):
		return
	var buffer : Buffer = buffers[buffer_name]
	if not buffer.released:
		return
	if buffer.restoring:
		while buffers.has(buffer_name) and buffers[buffer_name].restoring:
			await buffer_restored
		return
	buffer.restoring = true
	for d in buffer.dependencies:
		if buffers.has(d) and buffers[d].released:
			await restore_buffer(d)
	if not buffers.has(buffer_name) or not is_instance_valid(buffer.object):
		return
	var status = await buffer.object.on_dep_update_buffer(buffer_name)
	if buffer.restoring:
		# Rendering failed (or did not call dependency_update)
		buffer.restoring = false
		if status is bool and ! status:
			buffer.status = Buffer.Error
		buffer_restored.emit(buffer_name)

## Buffers in depth first order from the buffers no buffer reads, inputs read
## by more buffers first: inputs are rendered just before their readers so
## they can be released early
func get_render_order() -> Array[String]:
	if not render_order_dirty:
		return render_order
	render_order = []
	var visited : Dictionary = {}
	var roots : Array[String] = []
	for b in buffers.keys():
		var has_buffer_reader : bool = false
		if dependencies.has(b):
			for r in dependencies[b]:
				if buffers.has(r):
					has_buffer_reader = true
					break
		if not has_buffer_reader:
			roots.append(b)
	# Iterative post-order walk (graphs can be very deep)
	for root in roots:
		var stack : Array = [ [ root, false ] ]
		while not stack.is_empty():
			var item : Array = stack.pop_back()
			var b : String = item[0]
			if item[1]:
				render_order.append(b)
				continue
			if visited.has(b):
				continue
			visited[b] = true
			stack.push_back([ b, true ])
			var inputs : Array = []
			for d in buffers[b].dependencies:
				if buffers.has(d) and not visited.has(d):
					inputs.append(d)
			# The last pushed input is visited first
			inputs.sort_custom(func(x, y): return buffers[x].dependencies.size() < buffers[y].dependencies.size())
			for d in inputs:
				stack.push_back([ d, false ])
	# Buffers in cycles (iterate buffers) that were not reached
	for b in buffers.keys():
		if not visited.has(b):
			render_order.append(b)
	render_order_dirty = false
	return render_order

func get_render_queue_size() -> int:
	var invalidated_buffers : int = 0
	for b in buffers.keys():
		var buffer : Buffer = buffers[b]
		if buffer.object != null and buffer.object is MMGenBase and buffer.status != Buffer.Updated and buffer.status != Buffer.Error:
			invalidated_buffers += 1
	return invalidated_buffers

## Names of the buffers of the generators of a graph (and of their children)
## that failed to render
func get_failed_buffers(graph : Node) -> PackedStringArray:
	var failed : PackedStringArray = PackedStringArray()
	for b in buffers.keys():
		var buffer : Buffer = buffers[b]
		if buffer.status == Buffer.Error and buffer.object is Node and is_instance_valid(buffer.object) and (buffer.object == graph or graph.is_ancestor_of(buffer.object)):
			failed.append(buffer.object.get_hier_name() if buffer.object.has_method("get_hier_name") else b)
	return failed

func material_update_params(material : MMShaderBase):
	for p in material.get_parameters().keys():
		if dependencies_values.has(p):
			material.set_parameter(p, dependencies_values[p])

func buffer_create_compute_material(buffer_name : String, material : MMShaderBase):
	buffer_clear_dependencies(buffer_name)
	for p in material.get_parameters().keys():
		var value = buffer_add_dependency(buffer_name, p)
		if value != null:
			await material.set_parameter(p, value)
	buffers[buffer_name].shader_generations += 1

func buffer_create_shader_material(buffer_name : String, material : MMShaderBase, shader : String):
	if await material.set_shader(shader):
		await buffer_create_compute_material(buffer_name, material)

func print_stats(object = null):
	var statuses : Dictionary = {}
	for s in Buffer.STATUS:
		statuses[s] = PackedStringArray()
	for b in buffers.keys():
		if object != null and object != buffers[b].object:
			continue
		print("Buffer "+b+":")
		print("  Dependencies: "+str(buffers[b].dependencies))
		print("  Status: "+Buffer.STATUS[buffers[b].status])
		var a = statuses[Buffer.STATUS[buffers[b].status]]
		a.append(b)
		statuses[Buffer.STATUS[buffers[b].status]] = a
		print(statuses[Buffer.STATUS[buffers[b].status]])
		var pending : PackedStringArray = PackedStringArray()
		if buffers[b].pending_dependencies > 0:
			for d in buffers[b].dependencies:
				if buffers.has(d) and buffers[d].status != Buffer.Updated:
					pending.append(d)
			print("  Pending: %d (%s)" % [ buffers[b].pending_dependencies, ", ".join(pending) ])
		else:
			print("  Pending: 0")
		print("  Renders: %d" % buffers[b].renders)
		print("  Shader generations: %d" % buffers[b].shader_generations)
		if buffers[b].object.has_method("on_dep_shader_generations"):
			var count = buffers[b].object.on_dep_shader_generations(b)
	for s in Buffer.STATUS:
		print("%s: %s" % [ s, ", ".join(statuses[s]) ])
