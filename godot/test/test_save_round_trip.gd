extends SceneTree

## Phase 3 Layer-1 round-trip test runner. Builds up over Sessions 1-3:
##   Session 1: primitive round-trip + Cafe fixture round-trip
##   Session 2: SaveGame + FriendCafe fixture round-trip
##   Session 3: cross-validation (Layer 2) + envelope round-trip (Layer 3)

const FIXTURES_DIR := "res://test/fixtures/save"

var _passed: int = 0
var _failed: int = 0


func _init() -> void:
	_test_primitives_round_trip()
	_test_food_stack_round_trip()
	_test_food_round_trip()
	_test_cafe_object_leaf_round_trip()
	_test_cafe_wall_round_trip()
	_test_stove_round_trip()
	_test_serving_counter_round_trip()
	_test_cafe_furniture_plain_round_trip()
	_test_cafe_object_recursive_round_trip()
	_test_cafe_fixtures()
	_test_save_strings_round_trip()
	_test_character_instance_round_trip()
	_test_cafe_state_round_trip()
	_test_save_game_in_memory_round_trip()
	_test_save_game_fixtures()
	_test_friend_cafe_in_memory_round_trip()
	_test_friend_cafe_fixture()

	print("\n=== Save round-trip results: %d passed, %d failed ===" % [_passed, _failed])
	if _failed > 0:
		quit(1)
	else:
		quit(0)


func _check(name: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("PASS: %s" % name)
	else:
		_failed += 1
		var msg := "FAIL: %s" % name
		if detail != "":
			msg += " (%s)" % detail
		printerr(msg)


func _test_primitives_round_trip() -> void:
	# Round-trip every primitive at both extreme and benign values.
	var w := BinaryWriter.make()

	w.write_byte(0x00)
	w.write_byte(0xFF)
	w.write_bool(true)
	w.write_bool(false)
	w.write_uint16(0)
	w.write_uint16(65535)
	w.write_int16(-32768)
	w.write_int16(32767)
	w.write_uint32(0)
	w.write_uint32(0xFFFFFFFF)
	w.write_int32(-2147483648)
	w.write_int32(2147483647)
	w.write_int64(-9223372036854775808)
	w.write_int64(9223372036854775807)
	w.write_uint32_le(0xDEADBEEF)
	w.write_int32_le(-1)
	w.write_float(3.140625)  # exactly representable in float32
	w.write_float64(2.718281828459045)
	w.write_string("")
	w.write_string("hello, 世界")
	w.write_date({"Year": 2026, "Month": 4, "Day": 25, "Hour": 15, "Minute": 18, "Second": 0})
	w.write_int8(-128)
	w.write_int8(127)
	w.write_int8(-1)

	var r := BinaryReader.wrap(w.to_bytes())

	_check("read_byte 0x00", r.read_byte() == 0x00)
	_check("read_byte 0xFF", r.read_byte() == 0xFF)
	_check("read_bool true", r.read_bool() == true)
	_check("read_bool false", r.read_bool() == false)
	_check("read_uint16 0", r.read_uint16() == 0)
	_check("read_uint16 65535", r.read_uint16() == 65535)
	_check("read_int16 -32768", r.read_int16() == -32768)
	_check("read_int16 32767", r.read_int16() == 32767)
	_check("read_uint32 0", r.read_uint32() == 0)
	_check("read_uint32 max", r.read_uint32() == 0xFFFFFFFF)
	_check("read_int32 min", r.read_int32() == -2147483648)
	_check("read_int32 max", r.read_int32() == 2147483647)
	_check("read_int64 min", r.read_int64() == -9223372036854775808)
	_check("read_int64 max", r.read_int64() == 9223372036854775807)
	_check("read_uint32_le", r.read_uint32_le() == 0xDEADBEEF)
	_check("read_int32_le -1", r.read_int32_le() == -1)
	_check("read_float", abs(r.read_float() - 3.140625) < 1e-9)
	_check("read_float64", abs(r.read_float64() - 2.718281828459045) < 1e-15)
	_check("read_string empty", _str_eq(r.read_string(), ""))
	_check("read_string utf8", _str_eq(r.read_string(), "hello, 世界"))
	var d: Dictionary = r.read_date()
	_check("read_date round-trip",
		d["Year"] == 2026 and d["Month"] == 4 and d["Day"] == 25
		and d["Hour"] == 15 and d["Minute"] == 18 and d["Second"] == 0)
	_check("read_int8 -128", r.read_int8() == -128)
	_check("read_int8 127", r.read_int8() == 127)
	_check("read_int8 -1", r.read_int8() == -1)
	_check("reader fully consumed", r.remaining() == 0,
		"%d bytes remaining" % r.remaining())
	_check("reader did not fail", r.failed == false)


func _test_food_stack_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	var original: Dictionary = {
		"U0": 7,
		"U1": 12,
		"U3": -123456,
		"U5": 3,
		"U6": "Mystery Meat",
		"U6Alt": "after",
		"U7": {"Year": 2026, "Month": 4, "Day": 25, "Hour": 15, "Minute": 18, "Second": 0},
	}

	var w := BinaryWriter.make()
	writer.write_food_stack(w, original, version)

	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_food_stack(r, version)

	_check("food_stack reader fully consumed", r.remaining() == 0)
	_check("food_stack reader did not fail", r.failed == false)
	_check("food_stack U0", decoded["U0"] == original["U0"])
	_check("food_stack U1", decoded["U1"] == original["U1"])
	_check("food_stack U3", decoded["U3"] == original["U3"])
	_check("food_stack U5", decoded["U5"] == original["U5"])
	_check("food_stack U6", _str_eq(decoded["U6"], original["U6"]))
	_check("food_stack U6Alt", _str_eq(decoded["U6Alt"], original["U6Alt"]))
	_check("food_stack U7", _date_eq(decoded["U7"], original["U7"]))


func _date_eq(a: Dictionary, b: Dictionary) -> bool:
	return a["Year"] == b["Year"] and a["Month"] == b["Month"] \
		and a["Day"] == b["Day"] and a["Hour"] == b["Hour"] \
		and a["Minute"] == b["Minute"] and a["Second"] == b["Second"]


func _str_eq(a: Variant, b: Variant) -> bool:
	# Cross-type string equality: parsers store strings as PackedByteArray
	# for byte-faithful round-trip, but in-memory test fixtures pass plain
	# Strings. Compare via UTF-8 byte arrays so either side can be either.
	var ab: PackedByteArray = a if a is PackedByteArray else String(a).to_utf8_buffer()
	var bb: PackedByteArray = b if b is PackedByteArray else String(b).to_utf8_buffer()
	return ab == bb


func _test_food_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	# U3=false case so we don't hit the Object recursion (which still
	# only handles Type=0 at this point).
	var original: Dictionary = {
		"U1": 12345,
		"U2": 7,
		"U3": false,
		"Object": null,
		"U4": 9,
		"U5": -42,
		"U6": {"Year": 2025, "Month": 1, "Day": 1, "Hour": 0, "Minute": 0, "Second": 0},
		"U7": {
			"U0": 1, "U1": 2, "U3": 3, "U5": 4,
			"U6": "first", "U6Alt": "second",
			"U7": {"Year": 2024, "Month": 12, "Day": 31, "Hour": 23, "Minute": 59, "Second": 59},
		},
	}

	var w := BinaryWriter.make()
	writer.write_food(w, original, version)

	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_food(r, version)

	_check("food reader fully consumed", r.remaining() == 0)
	_check("food reader did not fail", r.failed == false)
	_check("food U1", decoded["U1"] == original["U1"])
	_check("food U2", decoded["U2"] == original["U2"])
	_check("food U3", decoded["U3"] == original["U3"])
	_check("food Object null", decoded["Object"] == null)
	_check("food U4", decoded["U4"] == original["U4"])
	_check("food U5", decoded["U5"] == original["U5"])
	_check("food U6 date", _date_eq(decoded["U6"], original["U6"]))
	_check("food U7 nested food_stack U6", _str_eq(decoded["U7"]["U6"], "first"))


func _test_cafe_object_leaf_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	var original: Dictionary = {"Type": 0}

	var w := BinaryWriter.make()
	writer.write_cafe_object(w, original, version)

	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_cafe_object(r, version)

	_check("cafe_object leaf fully consumed", r.remaining() == 0)
	_check("cafe_object leaf did not fail", r.failed == false)
	_check("cafe_object leaf Type=0", decoded["Type"] == 0)


func _test_cafe_wall_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	var original: Dictionary = {
		"U1": 12345,
		"U2": true,
		"U3": false,
		"U4": true,
		"U5": -987654,
		"HasDecoration": false,
		"DecorationObject": null,
	}

	var w := BinaryWriter.make()
	writer.write_cafe_wall(w, original, version)

	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_cafe_wall(r, version)

	_check("cafe_wall fully consumed", r.remaining() == 0)
	_check("cafe_wall did not fail", r.failed == false)
	_check("cafe_wall U1", decoded["U1"] == original["U1"])
	_check("cafe_wall U2", decoded["U2"] == original["U2"])
	_check("cafe_wall U3", decoded["U3"] == original["U3"])
	_check("cafe_wall U4", decoded["U4"] == original["U4"])
	_check("cafe_wall U5", decoded["U5"] == original["U5"])
	_check("cafe_wall HasDecoration false", decoded["HasDecoration"] == false)
	_check("cafe_wall DecorationObject null", decoded["DecorationObject"] == null)


func _test_stove_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	var original: Dictionary = {
		"U1": 1234567,
		"U2": 5,
		"HasObject": false,
		"Object": null,
		"U5": 9,
		"U6": -100,
		"U7": {"Year": 2026, "Month": 4, "Day": 25, "Hour": 0, "Minute": 0, "Second": 0},
		"HasFoodStack": false,
		"FoodStack": null,
		"U8": -987654321987,
		"U9": 12345678901234,
	}

	var w := BinaryWriter.make()
	writer.write_stove(w, original, version)
	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_stove(r, version)

	_check("stove fully consumed", r.remaining() == 0)
	_check("stove no fail", r.failed == false)
	_check("stove U1", decoded["U1"] == original["U1"])
	_check("stove HasObject", decoded["HasObject"] == false)
	_check("stove HasFoodStack", decoded["HasFoodStack"] == false)
	_check("stove U8 negative int64", decoded["U8"] == original["U8"])
	_check("stove U9 large positive int64", decoded["U9"] == original["U9"])


func _test_serving_counter_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	var fs: Dictionary = {
		"U0": 1, "U1": 2, "U3": 3, "U5": 4,
		"U6": "alpha", "U6Alt": "beta",
		"U7": {"Year": 2024, "Month": 1, "Day": 1, "Hour": 0, "Minute": 0, "Second": 0},
	}
	var original: Dictionary = {
		"U1": 42,
		"U2": 1,
		"HasObject": false,
		"Object": null,
		"U3": 2,
		"U4": 3,
		"U5": {"Year": 2026, "Month": 1, "Day": 1, "Hour": 0, "Minute": 0, "Second": 0},
		"U6": 99,
		"NumFoodStacks": 2,
		"FoodStacks": [fs, fs],
	}

	var w := BinaryWriter.make()
	writer.write_serving_counter(w, original, version)
	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_serving_counter(r, version)

	_check("sc fully consumed", r.remaining() == 0)
	_check("sc no fail", r.failed == false)
	_check("sc NumFoodStacks", decoded["NumFoodStacks"] == 2)
	_check("sc FoodStacks length", (decoded["FoodStacks"] as Array).size() == 2)
	_check("sc FoodStacks[0].U6", _str_eq((decoded["FoodStacks"] as Array)[0]["U6"], "alpha"))


func _test_cafe_furniture_plain_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	# Plain (non-food, non-stove, non-serving-counter) furniture branch.
	var original: Dictionary = {
		"Food": null,
		"Stove": null,
		"ServingCounter": null,
		"Object": null,
		"FurnitureType": 0,
		"U1": 0,
		"U2": 17,
		"Orientation": 1,
		"HasObject": false,
		"U3": 2,
		"U4": 3,
		"U5": {"Year": 2026, "Month": 1, "Day": 1, "Hour": 0, "Minute": 0, "Second": 0},
	}

	var w := BinaryWriter.make()
	writer.write_cafe_furniture(w, original, version)
	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_cafe_furniture(r, version)

	_check("cf-plain consumed", r.remaining() == 0)
	_check("cf-plain no fail", r.failed == false)
	_check("cf-plain FurnitureType", decoded["FurnitureType"] == 0)
	_check("cf-plain U2", decoded["U2"] == 17)
	_check("cf-plain Orientation", decoded["Orientation"] == 1)
	_check("cf-plain U3", decoded["U3"] == 2)


func _test_cafe_object_recursive_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	# Type=2 (wall) with no recursive decoration → exercises the Type=2
	# branch end-to-end without nesting.
	var wall: Dictionary = {
		"U1": 7, "U2": false, "U3": true, "U4": false, "U5": 99,
		"HasDecoration": false, "DecorationObject": null,
	}
	var original: Dictionary = {
		"Type": 2,
		"Furniture": null,
		"Wall": wall,
		"U1": 100, "U2": 200, "U3": 300, "U4": true,
	}

	var w := BinaryWriter.make()
	writer.write_cafe_object(w, original, version)
	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_cafe_object(r, version)

	_check("co-type2 consumed", r.remaining() == 0)
	_check("co-type2 no fail", r.failed == false)
	_check("co-type2 Type", decoded["Type"] == 2)
	_check("co-type2 Wall.U1", decoded["Wall"]["U1"] == 7)
	_check("co-type2 U1/U2/U3/U4 trailer",
		decoded["U1"] == 100 and decoded["U2"] == 200
		and decoded["U3"] == 300 and decoded["U4"] == true)


func _test_cafe_fixtures() -> void:
	for name in ["playerCafe.caf", "BACKUP1.caf"]:
		var path: String = FIXTURES_DIR + "/" + name
		var bytes_in: PackedByteArray = FileAccess.get_file_as_bytes(path)
		_check("fixture %s loaded" % name, bytes_in.size() > 0,
			"FileAccess.get_open_error=%d" % FileAccess.get_open_error())

		var dict: Dictionary = LegacyLoader.parse_cafe_bytes(bytes_in)
		_check("fixture %s parsed non-empty" % name, dict.size() > 0)
		_check("fixture %s Version=63" % name, int(dict.get("Version", 0)) == 63)

		var bytes_out: PackedByteArray = LegacyWriter.write_cafe_bytes(dict)
		_check("fixture %s round-trip size" % name,
			bytes_out.size() == bytes_in.size(),
			"in=%d out=%d" % [bytes_in.size(), bytes_out.size()])
		_check("fixture %s round-trip byte-identical" % name,
			bytes_in == bytes_out,
			"first diff at byte %d" % _first_diff(bytes_in, bytes_out))


func _first_diff(a: PackedByteArray, b: PackedByteArray) -> int:
	var n: int = min(a.size(), b.size())
	for i in range(n):
		if a[i] != b[i]:
			return i
	if a.size() != b.size():
		return n
	return -1


func _test_save_strings_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()

	var cases: Array = [
		{"name": "raw count 0, zero strings",            "RawCount": 0, "Strings": []},
		{"name": "raw count 1, zero strings (boundary)", "RawCount": 1, "Strings": []},
		{"name": "raw count 2, one string",              "RawCount": 2, "Strings": ["first"]},
		{"name": "raw count 5, four strings",            "RawCount": 5, "Strings": ["a", "b", "c", "d"]},
	]

	for c in cases:
		var name: String = c["name"]
		var original: Dictionary = {"RawCount": c["RawCount"], "Strings": c["Strings"]}

		var w := BinaryWriter.make()
		writer.write_save_strings(w, original)

		var r := BinaryReader.wrap(w.to_bytes())
		var decoded: Dictionary = loader.parse_save_strings(r)

		_check("save_strings %s consumed" % name, r.remaining() == 0)
		_check("save_strings %s no fail" % name, r.failed == false)
		_check("save_strings %s RawCount" % name, int(decoded["RawCount"]) == int(original["RawCount"]))
		_check("save_strings %s Strings deep-eq" % name, _string_array_eq(decoded["Strings"], original["Strings"]))


func _string_array_eq(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if not _str_eq(a[i], b[i]):
			return false
	return true


func _test_character_instance_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	# Mirrors Go's mainChar fixture in tool/file_types/roundtrip_test.go:463.
	# U4=3.5 is exactly representable in float32, so no epsilon tolerance is needed.
	var original: Dictionary = {
		"Type": 1, "Name": "MainZombie",
		"U2": 1, "U3": 2, "U4": 3.5, "U5": 4,
		"U6": 1000000000, "U7": 5, "U8": 2000000000, "U9": 3000000000,
		"U10": 10, "U11": 20, "U12": 30, "U13": 40,
		"U14": 50, "U15": 60, "U16": 70,
	}

	var w := BinaryWriter.make()
	writer.write_character_instance(w, original, version)
	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_character_instance(r, version)

	_check("char consumed", r.remaining() == 0)
	_check("char no fail", r.failed == false)
	_check("char Type", decoded["Type"] == 1)
	_check("char Name", _str_eq(decoded["Name"], "MainZombie"))
	_check("char U4 float32", decoded["U4"] == 3.5)
	_check("char U6 large int64", decoded["U6"] == 1000000000)
	_check("char U9 large int64", decoded["U9"] == 3000000000)
	_check("char U13", decoded["U13"] == 40)
	_check("char U14 (gated)", decoded["U14"] == 50)
	_check("char U15 (gated)", decoded["U15"] == 60)
	_check("char U16 (gated)", decoded["U16"] == 70)


func _make_cafe_state_fixture() -> Dictionary:
	# Mirrors Go's makeCafeStateFixture() — used here and in the SaveGame
	# / FriendCafe in-memory fixture tests below.
	var main_char: Dictionary = {
		"Type": 1, "Name": "MainZombie",
		"U2": 1, "U3": 2, "U4": 3.5, "U5": 4,
		"U6": 1000000000, "U7": 5, "U8": 2000000000, "U9": 3000000000,
		"U10": 10, "U11": 20, "U12": 30, "U13": 40,
		"U14": 50, "U15": 60, "U16": 70,
	}
	var zombie: Dictionary = {
		"Type": 2, "Name": "Z1",
		"U2": 3, "U3": 4, "U4": 5.5, "U5": 6,
		"U6": 1500000000, "U7": 7, "U8": 2500000000, "U9": 3500000000,
		"U10": 11, "U11": 21, "U12": 31, "U13": 41,
		"U14": 51, "U15": 61, "U16": 71,
	}
	return {
		"U1": 123.456,
		"ExperiencePoints": 999.5,
		"Toxin": 50,
		"Money": 500,
		"Level": 5,
		"U6": 1, "U7": 2,
		"U8": 3.0, "U9": 4,
		"U10": true,
		"Character": main_char,
		"NumZombies": 1,
		"Zombies": [zombie],
		"U11": 3,
		"U12": [1, 2, 3],
		"U13": true,
	}


func _test_cafe_state_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	var original: Dictionary = _make_cafe_state_fixture()

	var w := BinaryWriter.make()
	writer.write_cafe_state(w, original, version)
	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_cafe_state(r, version)

	_check("cafe_state consumed", r.remaining() == 0)
	_check("cafe_state no fail", r.failed == false)
	_check("cafe_state U1 float64", abs(float(decoded["U1"]) - 123.456) < 1e-12)
	_check("cafe_state ExperiencePoints float32", abs(float(decoded["ExperiencePoints"]) - 999.5) < 1e-3)
	_check("cafe_state Toxin", decoded["Toxin"] == 50)
	_check("cafe_state Money", decoded["Money"] == 500)
	_check("cafe_state Level", decoded["Level"] == 5)
	_check("cafe_state Character.Name", _str_eq(decoded["Character"]["Name"], "MainZombie"))
	_check("cafe_state NumZombies", decoded["NumZombies"] == 1)
	_check("cafe_state Zombies[0].Name", _str_eq((decoded["Zombies"] as Array)[0]["Name"], "Z1"))
	_check("cafe_state U11", decoded["U11"] == 3)
	_check("cafe_state U12 length", (decoded["U12"] as Array).size() == 3)
	_check("cafe_state U12[0]", (decoded["U12"] as Array)[0] == 1)
	_check("cafe_state U13", decoded["U13"] == true)


func _test_save_game_in_memory_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()

	var original: Dictionary = {
		"Version": 63,
		"State": _make_cafe_state_fixture(),
		"PreStrings": {"RawCount": 3, "Strings": ["pre_alpha", "pre_beta"]},
		"U15": {"Year": 2026, "Month": 4, "Day": 11, "Hour": 14, "Minute": 0, "Second": 0},
		"PostStrings": {"RawCount": 2, "Strings": ["post_solo"]},
		"U17": {"Year": 2026, "Month": 4, "Day": 11, "Hour": 14, "Minute": 30, "Second": 30},
		"NumOrders": 0,
		"U18": 7, "U19": 42, "U20": true,
		"Trailing_b64": "",
	}

	var bytes: PackedByteArray = LegacyWriter.write_save_game_bytes(original)
	var decoded: Dictionary = LegacyLoader.parse_save_game_bytes(bytes)

	_check("save_game in-memory parsed non-empty", decoded.size() > 0)
	_check("save_game in-memory Version", int(decoded["Version"]) == 63)
	_check("save_game in-memory State.Money", int((decoded["State"] as Dictionary)["Money"]) == 500)
	_check("save_game in-memory PreStrings.RawCount", int((decoded["PreStrings"] as Dictionary)["RawCount"]) == 3)
	_check("save_game in-memory PreStrings[0]", _str_eq(((decoded["PreStrings"] as Dictionary)["Strings"] as Array)[0], "pre_alpha"))
	_check("save_game in-memory U15 date", _date_eq(decoded["U15"], original["U15"]))
	_check("save_game in-memory PostStrings.RawCount", int((decoded["PostStrings"] as Dictionary)["RawCount"]) == 2)
	_check("save_game in-memory U17 date", _date_eq(decoded["U17"], original["U17"]))
	_check("save_game in-memory NumOrders", int(decoded["NumOrders"]) == 0)
	_check("save_game in-memory U18", int(decoded["U18"]) == 7)
	_check("save_game in-memory U20", decoded["U20"] == true)
	_check("save_game in-memory Trailing_b64 empty", String(decoded["Trailing_b64"]) == "")

	# Re-encode the decoded dict and confirm bytes match
	var bytes_again: PackedByteArray = LegacyWriter.write_save_game_bytes(decoded)
	_check("save_game in-memory re-encode size", bytes_again.size() == bytes.size())
	_check("save_game in-memory re-encode bytes match", bytes_again == bytes)


func _test_save_game_fixtures() -> void:
	for name in ["globalData.dat", "BACKUP1.dat"]:
		var path: String = FIXTURES_DIR + "/" + name
		var bytes_in: PackedByteArray = FileAccess.get_file_as_bytes(path)
		_check("fixture %s loaded" % name, bytes_in.size() > 0,
			"FileAccess.get_open_error=%d" % FileAccess.get_open_error())

		var dict: Dictionary = LegacyLoader.parse_save_game_bytes(bytes_in)
		_check("fixture %s parsed non-empty" % name, dict.size() > 0)
		_check("fixture %s Version=63" % name, int(dict.get("Version", 0)) == 63)
		_check("fixture %s Trailing_b64 non-empty" % name,
			String(dict.get("Trailing_b64", "")) != "",
			"trailing was empty — preservation field not populated?")

		var bytes_out: PackedByteArray = LegacyWriter.write_save_game_bytes(dict)
		_check("fixture %s round-trip size" % name,
			bytes_out.size() == bytes_in.size(),
			"in=%d out=%d" % [bytes_in.size(), bytes_out.size()])
		_check("fixture %s round-trip byte-identical" % name,
			bytes_in == bytes_out,
			"first diff at byte %d" % _first_diff(bytes_in, bytes_out))


func _test_friend_cafe_in_memory_round_trip() -> void:
	# We can't easily build a Cafe-by-hand fixture for in-memory testing
	# without re-implementing makeCafeFixture from the Go side. Instead,
	# round-trip the playerCafe.caf bytes through parse_cafe so we get
	# a known-good Cafe Dictionary, then wrap it in a FriendCafe envelope.
	var cafe_bytes: PackedByteArray = FileAccess.get_file_as_bytes(FIXTURES_DIR + "/playerCafe.caf")
	var cafe_dict: Dictionary = LegacyLoader.parse_cafe_bytes(cafe_bytes)
	_check("friend_cafe in-memory: cafe sub-fixture loaded", cafe_dict.size() > 0)

	var original: Dictionary = {
		"Version": 63,
		"State": _make_cafe_state_fixture(),
		"Cafe": cafe_dict,
	}

	var bytes: PackedByteArray = LegacyWriter.write_friend_cafe_bytes(original)
	var decoded: Dictionary = LegacyLoader.parse_friend_cafe_bytes(bytes)

	_check("friend_cafe in-memory parsed non-empty", decoded.size() > 0)
	_check("friend_cafe in-memory Version", int(decoded["Version"]) == 63)
	_check("friend_cafe in-memory State.Money", int((decoded["State"] as Dictionary)["Money"]) == 500)
	_check("friend_cafe in-memory Cafe.Version", int((decoded["Cafe"] as Dictionary)["Version"]) == 63)

	var bytes_again: PackedByteArray = LegacyWriter.write_friend_cafe_bytes(decoded)
	_check("friend_cafe in-memory re-encode size", bytes_again.size() == bytes.size())
	_check("friend_cafe in-memory re-encode bytes match", bytes_again == bytes)


func _test_friend_cafe_fixture() -> void:
	var name: String = "ServerData.dat"
	var path: String = FIXTURES_DIR + "/" + name
	var bytes_in: PackedByteArray = FileAccess.get_file_as_bytes(path)
	_check("fixture %s loaded" % name, bytes_in.size() > 0,
		"FileAccess.get_open_error=%d" % FileAccess.get_open_error())

	var dict: Dictionary = LegacyLoader.parse_friend_cafe_bytes(bytes_in)
	_check("fixture %s parsed non-empty" % name, dict.size() > 0)
	_check("fixture %s Version=63" % name, int(dict.get("Version", 0)) == 63)
	_check("fixture %s Cafe.Version=63" % name,
		int((dict.get("Cafe", {}) as Dictionary).get("Version", 0)) == 63)

	var bytes_out: PackedByteArray = LegacyWriter.write_friend_cafe_bytes(dict)
	_check("fixture %s round-trip size" % name,
		bytes_out.size() == bytes_in.size(),
		"in=%d out=%d" % [bytes_in.size(), bytes_out.size()])
	_check("fixture %s round-trip byte-identical" % name,
		bytes_in == bytes_out,
		"first diff at byte %d" % _first_diff(bytes_in, bytes_out))
