class_name MMLayer

var name : String
var index : int
var hidden : bool
var layers : Array[MMLayer] = []

const LAYER_NONE  : int = -1
const LAYER_PAINT : int = 0
const LAYER_PROC  : int = 1
const LAYER_MASK  : int = 2

func get_layer_type() -> int:
	return LAYER_NONE


func duplicate():
	var layer = get_script().new()
	print(layer.get_script().resource_path)
	layer.name = name+" (copy)"
	layer.hidden = false
	for c in get_channels():
		var texture = ImageTexture.new()
		texture.set_image(get(c).get_image())
		layer.set(c, texture)
	return layer


func get_channel_texture(channel_name : String) -> Texture2D:
	return get(channel_name)

func get_channels() -> Array:
	return []

func _load_layer(_data : Dictionary) -> void:
	pass

func load_layer(data : Dictionary, first_index : int, path : String) -> void:
	name = data.name
	if data.has("index"):
		index = data.index
	else:
		index = first_index
	hidden = data.hidden
	for c in get_channels():
		if data.has(c):
			var texture = ImageTexture.create_from_image(Image.load_from_file(path+"/"+data[c]))
			set(c, texture)
	_load_layer(data)

func _save_layer(_data : Dictionary):
	pass

static var rounding_shader : MMComputeShader = null
static var rounding_shader_busy : bool = false

## Returns an 8 bits copy of a channel texture, with values rounded to the
## nearest level. Image.convert() truncates them, and the 16 bits float
## textures of the painter often hold 8 bits values slightly below k/255,
## so each save and reload would make layers one level darker.
static func get_8_bits_image(texture : Texture2D) -> Image:
	if texture is ImageTexture and texture.get_format() != Image.FORMAT_RGBA8:
		while rounding_shader_busy:
			await Engine.get_main_loop().process_frame
		rounding_shader_busy = true
		if rounding_shader == null:
			var shader : MMComputeShader = MMComputeShader.new()
			shader.add_parameter_or_texture("input_image", "sampler2D", null)
			var texture_defs : Array[Dictionary] = [ { name="output_image", type=MMPipeline.TEXTURE_TYPE_RGBA16F } ]
			var shader_template : String = load("res://material_maker/tools/painter/shaders/round_to_8_bits_shader.tres").text
			if await shader.set_shader_ext(shader_template, texture_defs):
				rounding_shader = shader
		var rounded : Image = null
		if rounding_shader != null:
			var input : MMTexture = MMTexture.new()
			input.set_texture(texture)
			rounding_shader.set_parameter("input_image", input)
			var output : MMTexture = MMTexture.new()
			if await rounding_shader.render_ext([ output ], Vector2i(texture.get_size())):
				rounded = (await output.get_texture()).get_image()
			rounding_shader.set_parameter("input_image", null)
		rounding_shader_busy = false
		if rounded != null:
			rounded.convert(Image.FORMAT_RGBA8)
			return rounded
	var image : Image = texture.get_image()
	image.convert(Image.FORMAT_RGBA8)
	return image

func save_layer(path : String) -> Dictionary:
	var layer_data = { name=name, type=get_layer_type(), index=index, hidden=hidden }
	for c in get_channels():
		if get(c) != null:
			var file_name : String = "%s_%d.png" % [ c, index ]
			var file_path : String = path.path_join(file_name)
			var image : Image = await get_8_bits_image(get(c))
			image.save_png(file_path)
			layer_data[c] = file_name
	_save_layer(layer_data)
	if !layers.is_empty():
		layer_data.layers = await save_layers(layers, path)
	return layer_data

static func save_layers(layers_array : Array, path : String) -> Array:
	var layers_data = []
	for l in layers_array:
		var layer_data = await l.save_layer(path)

		layers_data.push_back(layer_data)
	return layers_data

func set_state(s):
	for c in s.keys():
		if c in get_channels():
			get(c).set_image(s[c])
		else:
			print("Useless channel %s in layer state" % c)
