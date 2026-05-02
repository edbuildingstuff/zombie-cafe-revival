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


func parse_save_strings(r: BinaryReader) -> Dictionary:
	var d: Dictionary = {"RawCount": 0, "Strings": []}
	d["RawCount"] = r.read_int16()
	var num: int = int(d["RawCount"]) - 1
	if num >= 0:
		var i: int = num
		var arr: Array = d["Strings"] as Array
		while i >= 1:
			arr.append(r.read_string())
			i -= 1
	return d


func parse_character_instance(r: BinaryReader, version: int) -> Dictionary:
	var c: Dictionary = {
		"Type": 0, "Name": "",
		"U2": 0, "U3": 0, "U4": 0.0, "U5": 0,
		"U6": 0, "U7": 0, "U8": 0, "U9": 0,
		"U10": 0, "U11": 0, "U12": 0, "U13": 0,
		"U14": 0, "U15": 0, "U16": 0,
	}
	c["Type"] = r.read_byte()
	c["Name"] = r.read_string()
	c["U2"] = r.read_byte()
	c["U3"] = r.read_byte()
	c["U4"] = r.read_float()
	c["U5"] = r.read_byte()
	c["U6"] = r.read_int64()
	c["U7"] = r.read_byte()
	c["U8"] = r.read_int64()
	c["U9"] = r.read_int64()
	c["U10"] = r.read_int32()
	c["U11"] = r.read_int32()
	c["U12"] = r.read_int32()
	c["U13"] = r.read_int32()
	if version > 29:
		c["U14"] = r.read_byte()
		if version > 46:
			c["U15"] = r.read_int32()
			c["U16"] = r.read_int32()
	return c


func parse_cafe_state(r: BinaryReader, version: int) -> Dictionary:
	var s: Dictionary = {
		"U1": 0.0, "ExperiencePoints": 0.0,
		"Toxin": 0, "Money": 0, "Level": 0,
		"U6": 0, "U7": 0, "U8": 0.0, "U9": 0, "U10": false,
		"Character": {},
		"NumZombies": 0, "Zombies": [],
		"U11": 0, "U12": [], "U13": false,
	}
	s["U1"] = r.read_float64()
	s["ExperiencePoints"] = r.read_float()
	s["Toxin"] = r.read_int32()
	s["Money"] = r.read_int32()
	s["Level"] = r.read_int32()
	s["U6"] = r.read_int32()
	s["U7"] = r.read_int32()
	s["U8"] = r.read_float()
	s["U9"] = r.read_int32()
	s["U10"] = r.read_bool()
	s["Character"] = parse_character_instance(r, version)

	s["NumZombies"] = r.read_byte()
	var zombies: Array = []
	for i in range(int(s["NumZombies"])):
		zombies.append(parse_character_instance(r, version))
	s["Zombies"] = zombies

	if version > 62:
		s["U11"] = r.read_int32()
	else:
		s["U11"] = int(r.read_byte())

	var u12: Array = []
	for i in range(int(s["U11"])):
		u12.append(r.read_int8())
	s["U12"] = u12

	if version > 33:
		s["U13"] = r.read_bool()
	return s


func parse_save_game(r: BinaryReader) -> Dictionary:
	var s: Dictionary = {
		"Version": 0,
		"State": {},
		"PreStrings": {"RawCount": 0, "Strings": []},
		"U15": {"Year": 0, "Month": 0, "Day": 0, "Hour": 0, "Minute": 0, "Second": 0},
		"PostStrings": {"RawCount": 0, "Strings": []},
		"U17": {"Year": 0, "Month": 0, "Day": 0, "Hour": 0, "Minute": 0, "Second": 0},
		"NumOrders": 0,
		"U18": 0, "U19": 0, "U20": false,
		"Trailing_b64": "",
	}
	s["Version"] = r.read_byte()
	if int(s["Version"]) != 63:
		# Default-zero return matches Go's behavior for unknown versions.
		return s

	var version: int = int(s["Version"])
	s["State"] = parse_cafe_state(r, version)
	s["PreStrings"] = parse_save_strings(r)
	s["U15"] = r.read_date()
	s["PostStrings"] = parse_save_strings(r)
	s["U17"] = r.read_date()
	s["NumOrders"] = r.read_int16()
	if int(s["NumOrders"]) > 0:
		push_error("parse_save_game: NumOrders > 0 — orders deserialization not implemented")
		r.failed = true
		return s
	s["U18"] = r.read_byte()
	s["U19"] = r.read_byte()
	s["U20"] = r.read_bool()
	# Preserve any trailing bytes the struct doesn't know about — globalData.dat
	# carries ~1 KB of additional data past U20 (probably an extended character
	# / friend list). Storing as base64 keeps the JSON envelope round-trip in
	# Sessions 3+ readable.
	if r.remaining() > 0:
		var tail: PackedByteArray = r.bytes.slice(r.pos, r.bytes.size())
		s["Trailing_b64"] = Marshalls.raw_to_base64(tail)
		r.pos = r.bytes.size()
	return s


static func parse_save_game_bytes(data: PackedByteArray) -> Dictionary:
	var loader := LegacyLoader.new()
	var reader := BinaryReader.wrap(data)
	var result: Dictionary = loader.parse_save_game(reader)
	if reader.failed or reader.remaining() != 0:
		push_error("parse_save_game_bytes: reader failed=%s remaining=%d" % [reader.failed, reader.remaining()])
		return {}
	return result


func parse_friend_cafe(r: BinaryReader) -> Dictionary:
	var f: Dictionary = {"Version": 0, "State": {}, "Cafe": {}}
	f["Version"] = r.read_byte()
	if int(f["Version"]) != 63:
		push_error("parse_friend_cafe: unsupported version %d" % int(f["Version"]))
		r.failed = true
		return f
	f["State"] = parse_cafe_state(r, int(f["Version"]))
	f["Cafe"] = parse_cafe(r)
	return f


static func parse_friend_cafe_bytes(data: PackedByteArray) -> Dictionary:
	var loader := LegacyLoader.new()
	var reader := BinaryReader.wrap(data)
	var result: Dictionary = loader.parse_friend_cafe(reader)
	if reader.failed or reader.remaining() != 0:
		push_error("parse_friend_cafe_bytes: reader failed=%s remaining=%d" % [reader.failed, reader.remaining()])
		return {}
	return result
