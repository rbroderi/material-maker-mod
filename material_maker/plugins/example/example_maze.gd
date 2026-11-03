extends MMGenTexture


# A node type added by the example plugin (see plugin.gd): a tileable maze,
# generated on the CPU (something a shader cannot do). Each cell of the maze
# is 2x2 pixels of the texture, which is sampled without filtering.


const DIRECTIONS : Array[Vector2i] = [ Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1) ]


func _ready() -> void:
	super._ready()
	generate()

func get_type() -> String:
	return "example_maze"

func get_type_name() -> String:
	return "Example Maze"

func get_description() -> String:
	return "A tileable maze (a node type added by the example plugin)"

func has_randomness() -> bool:
	return true

func get_parameter_defs() -> Array:
	return [
		{ name="size", label="Size", type="float", min=2, max=128, step=1, default=16 },
		{ name="path", label="Path", type="color", default={ r=1.0, g=1.0, b=1.0, a=1.0 } },
		{ name="wall", label="Wall", type="color", default={ r=0.0, g=0.0, b=0.0, a=1.0 } }
	]

func set_parameter(n : String, v) -> void:
	super.set_parameter(n, v)
	if is_inside_tree():
		generate()

func set_seed(s : float) -> bool:
	if not super.set_seed(s):
		return false
	generate()
	return true

func get_adjusted_uv(uv : String) -> String:
	var size : int = texture.get_width()
	if size == 0:
		return uv
	return "((floor(fract(%s)*%d.0)+vec2(0.5))/%d.0)" % [ uv, size, size ]

func get_color(n : String) -> Color:
	var value = get_parameter(n)
	return value if value is Color else MMType.deserialize_value(value)

## Draws a maze made with a randomized depth-first search on a torus (so
## that it tiles)
func generate() -> void:
	var size : int = clampi(int(get_parameter("size")), 2, 128)
	var path_color : Color = get_color("path")
	var rng : RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = hash(get_seed())
	var image : Image = Image.create(2*size, 2*size, false, Image.FORMAT_RGBA8)
	image.fill(get_color("wall"))
	var visited : PackedByteArray = PackedByteArray()
	visited.resize(size*size)
	var stack : Array[Vector2i] = [ Vector2i(rng.randi_range(0, size-1), rng.randi_range(0, size-1)) ]
	visited[stack[0].y*size+stack[0].x] = 1
	image.set_pixelv(2*stack[0], path_color)
	while not stack.is_empty():
		var cell : Vector2i = stack.back()
		var next : Array[Vector2i] = []
		for d in DIRECTIONS:
			var n : Vector2i = Vector2i(posmod(cell.x+d.x, size), posmod(cell.y+d.y, size))
			if visited[n.y*size+n.x] == 0:
				next.append(d)
		if next.is_empty():
			stack.pop_back()
			continue
		var d : Vector2i = next[rng.randi_range(0, next.size()-1)]
		var n : Vector2i = Vector2i(posmod(cell.x+d.x, size), posmod(cell.y+d.y, size))
		visited[n.y*size+n.x] = 1
		# The pixel between the two cells (to the right of or below the first one)
		var wall : Vector2i = 2*cell+d if d.x+d.y > 0 else 2*n-d
		image.set_pixelv(Vector2i(posmod(wall.x, 2*size), posmod(wall.y, 2*size)), path_color)
		image.set_pixelv(2*n, path_color)
		stack.append(n)
	texture.set_texture(ImageTexture.create_from_image(image))
	mm_deps.dependency_update("o%d_tex" % get_instance_id(), texture)

func _serialize(data : Dictionary) -> Dictionary:
	return data
