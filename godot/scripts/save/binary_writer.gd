class_name BinaryWriter
extends RefCounted

var _buf: PackedByteArray = PackedByteArray()


static func make() -> BinaryWriter:
	return BinaryWriter.new()


func to_bytes() -> PackedByteArray:
	return _buf


func size() -> int:
	return _buf.size()


func write_byte(v: int) -> void:
	_buf.append(v & 0xFF)


func write_bool(v: bool) -> void:
	_buf.append(1 if v else 0)


func write_uint16(v: int) -> void:
	_buf.append((v >> 8) & 0xFF)
	_buf.append(v & 0xFF)


func write_int16(v: int) -> void:
	# Mask to 16 bits first to handle negatives correctly
	var u: int = v & 0xFFFF
	write_uint16(u)


func write_uint32(v: int) -> void:
	_buf.append((v >> 24) & 0xFF)
	_buf.append((v >> 16) & 0xFF)
	_buf.append((v >> 8) & 0xFF)
	_buf.append(v & 0xFF)


func write_int32(v: int) -> void:
	var u: int = v & 0xFFFFFFFF
	write_uint32(u)


func write_int64(v: int) -> void:
	for i in range(7, -1, -1):
		_buf.append((v >> (i * 8)) & 0xFF)


func write_uint32_le(v: int) -> void:
	_buf.append(v & 0xFF)
	_buf.append((v >> 8) & 0xFF)
	_buf.append((v >> 16) & 0xFF)
	_buf.append((v >> 24) & 0xFF)


func write_int32_le(v: int) -> void:
	var u: int = v & 0xFFFFFFFF
	write_uint32_le(u)


func write_float(v: float) -> void:
	var sub := PackedByteArray()
	sub.resize(4)
	sub.encode_float(0, v)
	_buf.append_array(sub)


func write_float64(v: float) -> void:
	var sub := PackedByteArray()
	sub.resize(8)
	sub.encode_double(0, v)
	_buf.append_array(sub)


func write_string(v: Variant) -> void:
	# Accepts either PackedByteArray (byte-faithful, preserves embedded
	# NULs from the legacy save format) or String (encoded via UTF-8).
	# Parsers store the byte form in their Dictionary representation;
	# in-memory test fixtures may pass plain Strings for convenience.
	var b: PackedByteArray
	if v is PackedByteArray:
		b = v
	else:
		b = String(v).to_utf8_buffer()
	write_int16(b.size())
	_buf.append_array(b)


func write_date(d: Dictionary) -> void:
	write_int16(int(d["Year"]))
	write_byte(int(d["Month"]))
	write_byte(int(d["Day"]))
	write_byte(int(d["Hour"]))
	write_byte(int(d["Minute"]))
	write_byte(int(d["Second"]))


func write_int8(v: int) -> void:
	write_byte(v & 0xFF)


func append_bytes(bytes: PackedByteArray) -> void:
	_buf.append_array(bytes)
