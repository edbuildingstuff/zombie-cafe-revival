class_name BinaryReader
extends RefCounted

var bytes: PackedByteArray
var pos: int = 0
var failed: bool = false


static func wrap(b: PackedByteArray) -> BinaryReader:
	var r := BinaryReader.new()
	r.bytes = b
	return r


func remaining() -> int:
	return bytes.size() - pos


func _need(n: int) -> bool:
	if failed:
		return false
	if remaining() < n:
		push_error("BinaryReader: short read at pos=%d (have %d, need %d)" % [pos, remaining(), n])
		failed = true
		return false
	return true


func read_byte() -> int:
	if not _need(1):
		return 0
	var v: int = bytes[pos]
	pos += 1
	return v


func read_bool() -> bool:
	if not _need(1):
		return false
	var b: int = bytes[pos]
	pos += 1
	if b > 1:
		push_error("BinaryReader.read_bool: byte was %d, not 0 or 1" % b)
		failed = true
		return false
	return b == 1


func read_uint16() -> int:
	if not _need(2):
		return 0
	var v: int = (bytes[pos] << 8) | bytes[pos + 1]
	pos += 2
	return v


func read_int16() -> int:
	var v: int = read_uint16()
	if v >= 0x8000:
		v -= 0x10000
	return v


func read_uint32() -> int:
	if not _need(4):
		return 0
	var v: int = (bytes[pos] << 24) | (bytes[pos + 1] << 16) | (bytes[pos + 2] << 8) | bytes[pos + 3]
	pos += 4
	return v


func read_int32() -> int:
	var v: int = read_uint32()
	if v >= 0x80000000:
		v -= 0x100000000
	return v


func read_int64() -> int:
	if not _need(8):
		return 0
	var v: int = 0
	for i in range(8):
		v = (v << 8) | bytes[pos + i]
	pos += 8
	# GDScript int is 64-bit signed; the byte-shift above already
	# produces the correct two's-complement value for negative inputs
	# because GDScript's << on a 64-bit int sign-extends.
	return v


func read_uint32_le() -> int:
	if not _need(4):
		return 0
	var v: int = bytes[pos] | (bytes[pos + 1] << 8) | (bytes[pos + 2] << 16) | (bytes[pos + 3] << 24)
	pos += 4
	return v


func read_int32_le() -> int:
	var v: int = read_uint32_le()
	if v >= 0x80000000:
		v -= 0x100000000
	return v


func read_float() -> float:
	if not _need(4):
		return 0.0
	# IEEE 754 binary32, little-endian
	var sub: PackedByteArray = bytes.slice(pos, pos + 4)
	pos += 4
	return sub.decode_float(0)


func read_float64() -> float:
	if not _need(8):
		return 0.0
	# IEEE 754 binary64, little-endian
	var sub: PackedByteArray = bytes.slice(pos, pos + 8)
	pos += 8
	return sub.decode_double(0)


func read_string() -> PackedByteArray:
	# Returns the raw bytes of the length-prefixed string. The legacy save
	# format permits embedded NUL bytes (real `globalData.dat` strings end
	# with a `\r\0` suffix), so byte-faithful round-trip requires we keep
	# bytes rather than decoding through Godot's String type which strips
	# embedded NULs. Use PackedByteArray.get_string_from_utf8() at consumer
	# boundaries when a printable form is needed.
	# Do NOT change this to return String — Godot's String cannot hold
	# NUL codepoints (verified empirically against globalData.dat).
	var length: int = read_int16()
	if failed:
		return PackedByteArray()
	if length == 0:
		return PackedByteArray()
	if length < 0:
		push_error("BinaryReader.read_string: negative length %d at pos=%d" % [length, pos - 2])
		failed = true
		return PackedByteArray()
	if not _need(length):
		return PackedByteArray()
	var sub: PackedByteArray = bytes.slice(pos, pos + length)
	pos += length
	return sub


func read_date() -> Dictionary:
	var d := {}
	d["Year"] = read_int16()
	d["Month"] = read_byte()
	d["Day"] = read_byte()
	d["Hour"] = read_byte()
	d["Minute"] = read_byte()
	d["Second"] = read_byte()
	return d


func read_int8() -> int:
	var v: int = read_byte()
	if v >= 0x80:
		v -= 0x100
	return v
