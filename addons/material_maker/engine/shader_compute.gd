extends MMShaderBase
class_name MMShaderCompute


var compute_shader : MMComputeShader = MMComputeShader.new()


func set_shader_from_shadercode(shader_code : MMGenBase.ShaderCode, is_32_bits : bool = false, is_8_bits : bool = false) -> bool:
	return await compute_shader.set_shader_from_shadercode(shader_code, is_32_bits, [], is_8_bits)

func get_parameters() -> Dictionary:
	return compute_shader.get_parameters()

func set_parameter(name : String, value):
	compute_shader.set_parameter(name, value)

func is_greyscale(index : int = 0) -> bool:
	return MMPipeline.TEXTURE_TYPE[get_texture_type(index)].channels == 1

func get_texture_type(index : int = 0) -> int:
	return compute_shader.output_textures[index].type

## Renders a size x size texture (or size x height when height is not 0)
func render(texture : MMTexture, size : int, height : int = 0) -> bool:
	return await compute_shader.render(texture, Vector2i(size, height if height > 0 else size))

func get_render_time() -> int:
	return compute_shader.render_time
