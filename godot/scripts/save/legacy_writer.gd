class_name LegacyWriter
extends RefCounted

## Symmetric writers for legacy_loader.gd's parsers. Each write_*
## method consumes a Dictionary in the same shape parse_* produces and
## emits bytes that round-trip to the same Dictionary when fed back
## through the loader.


static func write_cafe_bytes(cafe: Dictionary) -> PackedByteArray:
	var writer := LegacyWriter.new()
	var w := BinaryWriter.make()
	writer.write_cafe(w, cafe)
	return w.to_bytes()


func write_cafe(w: BinaryWriter, c: Dictionary) -> void:
	w.write_byte(int(c["Version"]))
	w.write_float64(float(c["U0"]))
	w.write_byte(int(c["SizeX"]))
	w.write_byte(int(c["SizeY"]))
	w.write_int16(int(c["U3"]))
	w.write_int16(int(c["U4"]))
	if int(c["Version"]) > 48:
		w.write_int32(int(c["MapSizeX"]))
		w.write_int32(int(c["MapSizeY"]))
	w.write_bool(c["U7"])
	for tile in (c["Tiles"] as Array):
		write_cafe_tile(w, tile as Dictionary, int(c["Version"]))
	w.write_int32(int(c["U8"]))
	for v in (c["TrailingInts1"] as Array):
		w.write_int32(int(v))
	if int(c["Version"]) > 61:
		var t2: Array = c["TrailingInts2"] as Array
		w.write_int32(t2.size())
		for v in t2:
			w.write_int32(int(v))


# === Sub-record writers ===


func write_food_stack(w: BinaryWriter, f: Dictionary, version: int) -> void:
	if version > 24:
		w.write_byte(int(f["U0"]))
	w.write_byte(int(f["U1"]))
	if version > 48:
		w.write_int32(int(f["U3"]))
	if version <= 48:
		w.write_int16(int(f["U4"]))
	w.write_byte(int(f["U5"]))
	w.write_string(f["U6"])
	w.write_string(f["U6Alt"])
	if version > 51:
		w.write_date(f["U7"] as Dictionary)


func write_cafe_object(w: BinaryWriter, o: Dictionary, version: int) -> void:
	var t: int = int(o["Type"])
	w.write_byte(t)
	if t == 1:
		write_cafe_furniture(w, o["Furniture"] as Dictionary, version)
	elif t == 2:
		write_cafe_wall(w, o["Wall"] as Dictionary, version)
	if t == 1 or t == 2:
		w.write_int32(int(o["U1"]))
		w.write_int16(int(o["U2"]))
		w.write_int16(int(o["U3"]))
		w.write_bool(o["U4"])


func write_cafe_wall(w: BinaryWriter, c: Dictionary, version: int) -> void:
	if version > 58:
		w.write_int16(int(c["U1"]))
	else:
		w.write_byte(int(c["U1"]))
	w.write_bool(c["U2"])
	w.write_bool(c["U3"])
	w.write_bool(c["U4"])
	w.write_int32(int(c["U5"]))
	var has: bool = c["HasDecoration"]
	w.write_bool(has)
	if has:
		write_cafe_object(w, c["DecorationObject"] as Dictionary, version)


func write_food(w: BinaryWriter, f: Dictionary, version: int) -> void:
	if version > 48:
		w.write_int32(int(f["U1"]))
	else:
		w.write_byte(int(f["U1"]))
	w.write_byte(int(f["U2"]))
	var u3: bool = f["U3"]
	w.write_bool(u3)
	if u3:
		write_cafe_object(w, f["Object"] as Dictionary, version)
	w.write_byte(int(f["U4"]))
	if version > 23:
		w.write_int16(int(f["U5"]))
		if version > 47:
			w.write_date(f["U6"] as Dictionary)
	write_food_stack(w, f["U7"] as Dictionary, version)


func write_stove(w: BinaryWriter, s: Dictionary, version: int) -> void:
	if version <= 48:
		w.write_byte(int(s["U1"]))
	else:
		w.write_int32(int(s["U1"]))
	w.write_byte(int(s["U2"]))
	var has_obj: bool = s["HasObject"]
	w.write_bool(has_obj)
	if has_obj:
		write_cafe_object(w, s["Object"] as Dictionary, version)
	w.write_byte(int(s["U5"]))
	if version > 23:
		w.write_int16(int(s["U6"]))
	if version > 47:
		w.write_date(s["U7"] as Dictionary)
	var has_fs: bool = s["HasFoodStack"]
	w.write_bool(has_fs)
	if has_fs:
		write_food_stack(w, s["FoodStack"] as Dictionary, version)
	w.write_int64(int(s["U8"]))
	w.write_int64(int(s["U9"]))


func write_serving_counter(w: BinaryWriter, s: Dictionary, version: int) -> void:
	if version > 48:
		w.write_int32(int(s["U1"]))
	else:
		w.write_byte(int(s["U1"]))
	w.write_byte(int(s["U2"]))
	var has_obj: bool = s["HasObject"]
	w.write_bool(has_obj)
	if has_obj:
		write_cafe_object(w, s["Object"] as Dictionary, version)
	w.write_byte(int(s["U3"]))
	if version > 23:
		w.write_int16(int(s["U4"]))
	if version > 47:
		w.write_date(s["U5"] as Dictionary)
	if version > 25:
		w.write_int32(int(s["U6"]))
	else:
		w.write_int16(int(s["U6"]))
	w.write_int16(int(s["NumFoodStacks"]))
	var stacks: Array = s["FoodStacks"] as Array
	for fs in stacks:
		write_food_stack(w, fs as Dictionary, version)


func write_cafe_furniture(w: BinaryWriter, c: Dictionary, version: int) -> void:
	var is_food: bool = c["Food"] != null
	w.write_bool(is_food)
	if is_food:
		w.write_byte(int(c["U1"]))
		write_food(w, c["Food"] as Dictionary, version)
		return

	w.write_byte(int(c["FurnitureType"]))
	if int(c["FurnitureType"]) == 1:
		write_stove(w, c["Stove"] as Dictionary, version)
		return
	if int(c["FurnitureType"]) == 2:
		write_serving_counter(w, c["ServingCounter"] as Dictionary, version)
		return

	# Plain furniture branch.
	if version > 48:
		w.write_int32(int(c["U2"]))
	else:
		w.write_byte(int(c["U2"]))
	w.write_byte(int(c["Orientation"]))
	var has_obj: bool = c["HasObject"]
	w.write_bool(has_obj)
	if has_obj:
		write_cafe_object(w, c["Object"] as Dictionary, version)
	w.write_byte(int(c["U3"]))
	if version > 23:
		w.write_int16(int(c["U4"]))
	if version > 47:
		w.write_date(c["U5"] as Dictionary)


func write_cafe_tile(w: BinaryWriter, t: Dictionary, version: int) -> void:
	if version <= 58:
		w.write_byte(int(t["U1"]))
	else:
		w.write_int16(int(t["U1"]))
	w.write_int32(int(t["U2"]))
	w.write_bool(t["U3"])
	var u4: bool = t["U4"]
	w.write_bool(u4)
	if u4:
		write_cafe_object(w, t["U5"] as Dictionary, version)
	var u6: bool = t["U6"]
	w.write_bool(u6)
	if u6:
		write_cafe_object(w, t["U7"] as Dictionary, version)
	var u8: bool = t["U8"]
	w.write_bool(u8)
	if u8:
		write_cafe_object(w, t["U9"] as Dictionary, version)


func write_save_strings(w: BinaryWriter, s: Dictionary) -> void:
	w.write_int16(int(s["RawCount"]))
	for str in (s["Strings"] as Array):
		w.write_string(str)


func write_character_instance(w: BinaryWriter, c: Dictionary, version: int) -> void:
	w.write_byte(int(c["Type"]))
	w.write_string(c["Name"])
	w.write_byte(int(c["U2"]))
	w.write_byte(int(c["U3"]))
	w.write_float(float(c["U4"]))
	w.write_byte(int(c["U5"]))
	w.write_int64(int(c["U6"]))
	w.write_byte(int(c["U7"]))
	w.write_int64(int(c["U8"]))
	w.write_int64(int(c["U9"]))
	w.write_int32(int(c["U10"]))
	w.write_int32(int(c["U11"]))
	w.write_int32(int(c["U12"]))
	w.write_int32(int(c["U13"]))
	if version > 29:
		w.write_byte(int(c["U14"]))
		if version > 46:
			w.write_int32(int(c["U15"]))
			w.write_int32(int(c["U16"]))


func write_cafe_state(w: BinaryWriter, s: Dictionary, version: int) -> void:
	w.write_float64(float(s["U1"]))
	w.write_float(float(s["ExperiencePoints"]))
	w.write_int32(int(s["Toxin"]))
	w.write_int32(int(s["Money"]))
	w.write_int32(int(s["Level"]))
	w.write_int32(int(s["U6"]))
	w.write_int32(int(s["U7"]))
	w.write_float(float(s["U8"]))
	w.write_int32(int(s["U9"]))
	w.write_bool(s["U10"])
	write_character_instance(w, s["Character"] as Dictionary, version)

	w.write_byte(int(s["NumZombies"]))
	for z in (s["Zombies"] as Array):
		write_character_instance(w, z as Dictionary, version)

	if version > 62:
		w.write_int32(int(s["U11"]))
	else:
		w.write_byte(int(s["U11"]))

	for v in (s["U12"] as Array):
		w.write_int8(int(v))

	if version > 33:
		w.write_bool(s["U13"])


func write_save_game(w: BinaryWriter, s: Dictionary) -> void:
	w.write_byte(int(s["Version"]))
	if int(s["Version"]) != 63:
		return

	var version: int = int(s["Version"])
	write_cafe_state(w, s["State"] as Dictionary, version)
	write_save_strings(w, s["PreStrings"] as Dictionary)
	w.write_date(s["U15"] as Dictionary)
	write_save_strings(w, s["PostStrings"] as Dictionary)
	w.write_date(s["U17"] as Dictionary)
	w.write_int16(int(s["NumOrders"]))
	if int(s["NumOrders"]) > 0:
		push_error("write_save_game: NumOrders > 0 — orders serialization not implemented")
		return
	w.write_byte(int(s["U18"]))
	w.write_byte(int(s["U19"]))
	w.write_bool(s["U20"])

	var b64: String = String(s.get("Trailing_b64", ""))
	if b64 != "":
		var tail: PackedByteArray = Marshalls.base64_to_raw(b64)
		w.append_bytes(tail)


static func write_save_game_bytes(save: Dictionary) -> PackedByteArray:
	var writer := LegacyWriter.new()
	var w := BinaryWriter.make()
	writer.write_save_game(w, save)
	return w.to_bytes()


func write_friend_cafe(w: BinaryWriter, f: Dictionary) -> void:
	w.write_byte(int(f["Version"]))
	write_cafe_state(w, f["State"] as Dictionary, int(f["Version"]))
	write_cafe(w, f["Cafe"] as Dictionary)


static func write_friend_cafe_bytes(fc: Dictionary) -> PackedByteArray:
	var writer := LegacyWriter.new()
	var w := BinaryWriter.make()
	writer.write_friend_cafe(w, fc)
	return w.to_bytes()
