extends RefCounted
class_name MMNpy


# Reads and writes NumPy .npy files (format version 1.0) of little endian
# float32 values in C order, the arrays exchanged with Python by the
# point evaluation (see voxel_eval.gd).


const MAGIC : PackedByteArray = [ 0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59 ]


## Reads a .npy file. Returns { shape : Array[int], data : PackedFloat32Array },
## or { error : String } if the file cannot be read or is not a version 1.0
## little endian float32 C order array.
static func load(path : String) -> Dictionary:
	var file : FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return { error="cannot open '%s' (%s)" % [ path, error_string(FileAccess.get_open_error()) ] }
	var bytes : PackedByteArray = file.get_buffer(file.get_length())
	file.close()
	return parse(bytes, path)

## Parses the bytes of a .npy file (path is only used in error messages)
static func parse(bytes : PackedByteArray, path : String = "") -> Dictionary:
	var name : String = "'%s': " % path if path != "" else ""
	if bytes.size() < 10 or bytes.slice(0, 6) != MAGIC:
		return { error=name+"not a .npy file" }
	if bytes[6] != 1 or bytes[7] != 0:
		return { error=name+"unsupported .npy version %d.%d (only 1.0 is supported)" % [ bytes[6], bytes[7] ] }
	var header_length : int = bytes.decode_u16(8)
	if bytes.size() < 10+header_length:
		return { error=name+"truncated .npy header" }
	var header : String = bytes.slice(10, 10+header_length).get_string_from_ascii()
	var descr : RegEx = RegEx.create_from_string("'descr'\\s*:\\s*'([^']*)'")
	var fortran : RegEx = RegEx.create_from_string("'fortran_order'\\s*:\\s*(True|False)")
	var shape_regex : RegEx = RegEx.create_from_string("'shape'\\s*:\\s*\\(([^)]*)\\)")
	var m_descr : RegExMatch = descr.search(header)
	var m_fortran : RegExMatch = fortran.search(header)
	var m_shape : RegExMatch = shape_regex.search(header)
	if m_descr == null or m_fortran == null or m_shape == null:
		return { error=name+"malformed .npy header" }
	if m_descr.get_string(1) != "<f4":
		return { error=name+"unsupported .npy type '%s' (only '<f4', little endian float32, is supported)" % m_descr.get_string(1) }
	if m_fortran.get_string(1) != "False":
		return { error=name+"unsupported .npy order (only C order is supported)" }
	var shape : Array[int] = []
	var count : int = 1
	for s in m_shape.get_string(1).split(",", false):
		var t : String = s.strip_edges()
		if not t.is_valid_int() or t.to_int() < 0:
			return { error=name+"malformed .npy shape" }
		shape.append(t.to_int())
		count *= t.to_int()
	var data_bytes : PackedByteArray = bytes.slice(10+header_length)
	if data_bytes.size() != count*4:
		return { error=name+"the .npy data has %d bytes, its shape needs %d" % [ data_bytes.size(), count*4 ] }
	return { shape=shape, data=data_bytes.to_float32_array() }

## Writes a .npy file. Returns OK, or an error.
static func save(path : String, shape : Array, data : PackedFloat32Array) -> Error:
	var count : int = 1
	for s in shape:
		count *= int(s)
	if count != data.size():
		# (the shape does not match the data)
		return ERR_INVALID_PARAMETER
	var file : FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(make_header(shape))
	file.store_buffer(data.to_byte_array())
	file.close()
	return OK

## The bytes of a version 1.0 header (padded to a multiple of 64 bytes, as
## NumPy does)
static func make_header(shape : Array) -> PackedByteArray:
	var shape_text : String
	if shape.size() == 1:
		shape_text = "(%d,)" % shape[0]
	else:
		shape_text = "(%s)" % ", ".join(shape.map(func(s): return str(int(s))))
	var text : String = "{'descr': '<f4', 'fortran_order': False, 'shape': %s, }" % shape_text
	var total : int = 10+text.length()+1
	text += " ".repeat((64-total%64)%64)+"\n"
	var rv : PackedByteArray = MAGIC.duplicate()
	rv.append(1)
	rv.append(0)
	rv.resize(10)
	rv.encode_u16(8, text.length())
	rv.append_array(text.to_ascii_buffer())
	return rv
