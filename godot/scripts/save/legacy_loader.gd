class_name LegacyLoader
extends RefCounted

## Pure parsers from legacy .caf / .dat byte streams to PascalCase
## Dictionary representations. Mirrors tool/file_types/{cafe,save_game,
## friend_cafe}.go field-for-field. Session 1 covers the Cafe family;
## SaveGame and FriendCafe land in Session 2.


static func parse_cafe_bytes(data: PackedByteArray) -> Dictionary:
	var loader := LegacyLoader.new()
	var reader := BinaryReader.wrap(data)
	var result: Dictionary = loader.parse_cafe(reader)
	if reader.failed or reader.remaining() != 0:
		push_error("parse_cafe_bytes: reader failed=%s remaining=%d" % [reader.failed, reader.remaining()])
		return {}
	return result


func parse_cafe(r: BinaryReader) -> Dictionary:
	var c: Dictionary = {
		"Version": 0,
		"U0": 0.0,
		"SizeX": 0,
		"SizeY": 0,
		"U3": 0,
		"U4": 0,
		"MapSizeX": 0,
		"MapSizeY": 0,
		"U7": false,
		"Tiles": [],
		"U8": 0,
		"TrailingInts1": [],
		"TrailingInts2": [],
	}
	c["Version"] = r.read_byte()
	c["U0"] = r.read_float64()
	c["SizeX"] = r.read_byte()
	c["SizeY"] = r.read_byte()
	c["U3"] = r.read_int16()
	c["U4"] = r.read_int16()
	if int(c["Version"]) > 48:
		c["MapSizeX"] = r.read_int32()
		c["MapSizeY"] = r.read_int32()
	c["U7"] = r.read_bool()
	var num_tiles: int = int(c["MapSizeX"]) * int(c["MapSizeY"])
	var tiles: Array = []
	for i in range(num_tiles):
		tiles.append(parse_cafe_tile(r, int(c["Version"])))
	c["Tiles"] = tiles
	c["U8"] = r.read_int32()
	var t1: Array = []
	for i in range(int(c["U8"])):
		t1.append(r.read_int32())
	c["TrailingInts1"] = t1
	if int(c["Version"]) > 61:
		var num_t2: int = r.read_int32()
		var t2: Array = []
		for i in range(num_t2):
			t2.append(r.read_int32())
		c["TrailingInts2"] = t2
	return c


# === Sub-record parsers ===
# All take a BinaryReader and a version: int. They return Dictionary.
# Recursive references stay within this class so GDScript resolves them
# at call-time without forward-declaration concerns.


func parse_food_stack(r: BinaryReader, version: int) -> Dictionary:
	var d: Dictionary = {}
	if version > 24:
		d["U0"] = r.read_byte()
	d["U1"] = r.read_byte()
	if version > 48:
		d["U3"] = r.read_int32()
	if version <= 48:
		d["U4"] = r.read_int16()
	d["U5"] = r.read_byte()
	d["U6"] = r.read_string()
	d["U6Alt"] = r.read_string()
	if version > 51:
		d["U7"] = r.read_date()
	return d


func parse_cafe_object(r: BinaryReader, version: int) -> Dictionary:
	var d: Dictionary = {
		"Type": 0,
		"Furniture": null,
		"Wall": null,
		"U1": 0,
		"U2": 0,
		"U3": 0,
		"U4": false,
	}
	d["Type"] = r.read_byte()
	if d["Type"] == 1:
		d["Furniture"] = parse_cafe_furniture(r, version)
	elif d["Type"] == 2:
		d["Wall"] = parse_cafe_wall(r, version)
	if d["Type"] == 1 or d["Type"] == 2:
		d["U1"] = r.read_int32()
		d["U2"] = r.read_int16()
		d["U3"] = r.read_int16()
		d["U4"] = r.read_bool()
	return d


func parse_cafe_wall(r: BinaryReader, version: int) -> Dictionary:
	var d: Dictionary = {}
	if version > 58:
		d["U1"] = r.read_int16()
	else:
		d["U1"] = int(r.read_byte())
	d["U2"] = r.read_bool()
	d["U3"] = r.read_bool()
	d["U4"] = r.read_bool()
	d["U5"] = r.read_int32()
	d["HasDecoration"] = r.read_bool()
	if d["HasDecoration"]:
		d["DecorationObject"] = parse_cafe_object(r, version)
	else:
		d["DecorationObject"] = null
	return d


func parse_food(r: BinaryReader, version: int) -> Dictionary:
	var d: Dictionary = {}
	if version > 48:
		d["U1"] = r.read_int32()
	else:
		d["U1"] = int(r.read_byte())
	d["U2"] = r.read_byte()
	d["U3"] = r.read_bool()
	if d["U3"]:
		d["Object"] = parse_cafe_object(r, version)
	else:
		d["Object"] = null
	d["U4"] = r.read_byte()
	if version > 23:
		d["U5"] = r.read_int16()
		if version > 47:
			d["U6"] = r.read_date()
	d["U7"] = parse_food_stack(r, version)
	return d


func parse_stove(r: BinaryReader, version: int) -> Dictionary:
	var s: Dictionary = {}
	if version <= 48:
		s["U1"] = int(r.read_byte())
	else:
		s["U1"] = r.read_int32()
	s["U2"] = r.read_byte()
	s["HasObject"] = r.read_bool()
	if s["HasObject"]:
		s["Object"] = parse_cafe_object(r, version)
	else:
		s["Object"] = null
	s["U5"] = r.read_byte()
	if version > 23:
		s["U6"] = r.read_int16()
	if version > 47:
		s["U7"] = r.read_date()
	s["HasFoodStack"] = r.read_bool()
	if s["HasFoodStack"]:
		s["FoodStack"] = parse_food_stack(r, version)
	else:
		s["FoodStack"] = null
	s["U8"] = r.read_int64()
	s["U9"] = r.read_int64()
	return s


func parse_serving_counter(r: BinaryReader, version: int) -> Dictionary:
	var s: Dictionary = {}
	if version > 48:
		s["U1"] = r.read_int32()
	else:
		s["U1"] = int(r.read_byte())
	s["U2"] = r.read_byte()
	s["HasObject"] = r.read_bool()
	if s["HasObject"]:
		s["Object"] = parse_cafe_object(r, version)
	else:
		s["Object"] = null
	s["U3"] = r.read_byte()
	if version > 23:
		s["U4"] = r.read_int16()
	if version > 47:
		s["U5"] = r.read_date()
	if version > 25:
		s["U6"] = r.read_int32()
	else:
		s["U6"] = int(r.read_int16())
	s["NumFoodStacks"] = r.read_int16()
	var stacks: Array = []
	for i in range(s["NumFoodStacks"]):
		stacks.append(parse_food_stack(r, version))
	s["FoodStacks"] = stacks
	return s


func parse_cafe_furniture(r: BinaryReader, version: int) -> Dictionary:
	var c: Dictionary = {
		"Food": null,
		"Stove": null,
		"ServingCounter": null,
		"Object": null,
		"FurnitureType": 0,
		"U1": 0,
		"U2": 0,
		"Orientation": 0,
		"HasObject": false,
		"U3": 0,
		"U4": 0,
		"U5": {"Year": 0, "Month": 0, "Day": 0, "Hour": 0, "Minute": 0, "Second": 0},
	}

	var is_food: bool = r.read_bool()
	if is_food:
		c["U1"] = r.read_byte()
		c["Food"] = parse_food(r, version)
		return c

	c["FurnitureType"] = r.read_byte()
	if c["FurnitureType"] == 1:
		c["Stove"] = parse_stove(r, version)
		return c
	if c["FurnitureType"] == 2:
		c["ServingCounter"] = parse_serving_counter(r, version)
		return c

	# Plain furniture branch.
	if version > 48:
		c["U2"] = r.read_int32()
	else:
		c["U2"] = int(r.read_byte())
	c["Orientation"] = r.read_byte()
	c["HasObject"] = r.read_bool()
	if c["HasObject"]:
		c["Object"] = parse_cafe_object(r, version)
	c["U3"] = r.read_byte()
	if version > 23:
		c["U4"] = r.read_int16()
	if version > 47:
		c["U5"] = r.read_date()
	return c


func parse_cafe_tile(r: BinaryReader, version: int) -> Dictionary:
	var t: Dictionary = {}
	if version <= 58:
		t["U1"] = int(r.read_byte())
	else:
		t["U1"] = r.read_int16()
	t["U2"] = r.read_int32()
	t["U3"] = r.read_bool()
	t["U4"] = r.read_bool()
	if t["U4"]:
		t["U5"] = parse_cafe_object(r, version)
	else:
		t["U5"] = null
	t["U6"] = r.read_bool()
	if t["U6"]:
		t["U7"] = parse_cafe_object(r, version)
	else:
		t["U7"] = null
	t["U8"] = r.read_bool()
	if t["U8"]:
		t["U9"] = parse_cafe_object(r, version)
	else:
		t["U9"] = null
	return t
