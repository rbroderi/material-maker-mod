@tool
extends MMGenAnalysis
class_name MMGenFillToIndex


# Gives each area of a fill input a consecutive index (in raster order of the
# areas' origins), output as a value between 0 and 1.
# A GPU pass sets one bit per area origin, the CPU numbers the bits, and the
# output looks up the index of each pixel's area in the resulting texture.


var cell_count : int = 0


func get_type() -> String:
	return "fill_to_index"

func get_type_name() -> String:
	return "Fill to Index"

func get_description() -> String:
	var desc_list : PackedStringArray = PackedStringArray()
	desc_list.push_back(TranslationServer.translate("Fill to Index"))
	desc_list.push_back(TranslationServer.translate("Gives each area a consecutive index"))
	return "\n".join(desc_list)

func get_parameter_defs() -> Array:
	return [ { name="size", label="Size", type="size", first=4, last=11, default=10, longdesc="The resolution at which the input is analyzed (should be at least the resolution of the fill node)" } ]

func get_input_type() -> String:
	return "fill"

func get_output_defs(_show_hidden : bool = false) -> Array:
	return [ { type="f", shortdesc="Index", longdesc="The index of each area, divided by the number of areas minus 1 (outlines are 0)" } ]

func get_result_size() -> int:
	var size : int = get_image_size()
	return max(1, size*size/32)

func get_analysis_code() -> String:
	return """if (dot(value.zw, vec2(1.0)) > 0.0000001) {
			ivec2 p = clamp(ivec2(floor(fract(value.xy)*image_size+vec2(0.001))), ivec2(0), ivec2(image_size)-1);
			int index = p.y*int(image_size.x)+p.x;
			atomicOr(mm_out.mm_results[index >> 5], 1 << (index & 31));
		}"""

func set_parameter(n : String, v) -> void:
	super.set_parameter(n, v)
	# The results array size depends on the size
	if n == "size" and is_inside_tree():
		update_shader()

func process_results(results : PackedInt32Array, size : int) -> Image:
	var image : Image = Image.create(size, size, false, Image.FORMAT_RF)
	var rank : int = 0
	for word_index in results.size():
		var word : int = results[word_index] & 0xFFFFFFFF
		if word == 0:
			continue
		for bit in 32:
			if word & (1 << bit):
				var index : int = word_index*32+bit
				image.set_pixel(index % size, index / size, Color(float(rank), 0, 0))
				rank += 1
	if rank != cell_count:
		cell_count = rank
		mm_deps.dependency_update(get_count_parameter_name(), float(cell_count))
	return image

func get_count_parameter_name() -> String:
	return "o%d_count" % get_instance_id()

func _get_shader_code(uv : String, _output_index : int, context : MMGenContext) -> ShaderCode:
	var rv : ShaderCode = ShaderCode.new()
	rv.output_type = "f"
	var source : OutputPort = get_source(0)
	if source == null:
		rv.output_values.f = "0.0"
		return rv
	var genname : String = "o%d" % get_instance_id()
	var variant_index : int = context.get_variant(self, uv)
	if variant_index == -1:
		variant_index = context.get_variant(self, uv)
		var source_code : ShaderCode = source.generator.get_shader_code(uv, source.output_index, context)
		rv.add_uniforms(source_code.uniforms)
		rv.defs += source_code.defs
		rv.add_globals(source_code.globals)
		rv.code += source_code.code
		rv.add_uniform(genname+"_tex", "sampler2D", texture)
		rv.add_uniform(get_count_parameter_name(), "float", float(cell_count))
		rv.add_uniform(get_size_parameter_name(), "float", float(get_image_size()))
		var bb : String = "%s_%d_bb" % [ genname, variant_index ]
		rv.code += "vec4 %s = %s;\n" % [ bb, source_code.output_values.fill ]
		rv.code += "float %s_%d_index = (dot(%s.zw, vec2(1.0)) > 0.0000001) ? textureLod(%s_tex, (floor(fract(%s.xy)*%s+vec2(0.001))+vec2(0.5))/%s, 0.0).r/max(%s-1.0, 1.0) : 0.0;\n" % [ genname, variant_index, bb, genname, bb, get_size_parameter_name(), get_size_parameter_name(), get_count_parameter_name() ]
	rv.output_values.f = "%s_%d_index" % [ genname, variant_index ]
	return rv
