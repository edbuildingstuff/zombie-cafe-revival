@tool
extends SceneTree

# Headless validation script. Exercises every asset category the
# Phase 1 asset builder produces, then quits with an exit code:
#   0 = every asset loaded and parsed as expected
#   1 = at least one asset failed
#
# Run with:
#   godot --headless --script godot/validate_assets.gd --path godot/

func _init() -> void:
	var failures: Array = []

	failures += _validate_json("res://assets/data/foodData.json", "array", 1)
	failures += _validate_json("res://assets/data/characterData.json", "array", 1)
	failures += _validate_json("res://assets/data/animationData.json", "array", 1)

	failures += _validate_json("res://assets/atlases/characterParts.offsets.json", "object", 0)
	failures += _validate_json("res://assets/atlases/characterParts.characterArt.json", "object", 0)
	failures += _validate_json("res://assets/atlases/furniture.offsets.json", "object", 0)

	failures += _validate_texture("res://assets/atlases/characterParts.png")
	failures += _validate_texture("res://assets/atlases/furniture.png")
	failures += _validate_texture("res://assets/images/boxer-human/back_head1.png")

	failures += _validate_font("res://assets/fonts/A Love of Thunder.ttf")

	failures += _validate_audio("res://assets/audio/Zombie Theme V1.ogg")
	failures += _validate_audio("res://assets/audio/sfx/blender.ogg")

	failures += _validate_character_atlas()
	failures += _validate_texture_atlas()

	if failures.is_empty():
		print("\n========== VALIDATION PASSED ==========")
		print("All asset categories load and parse as expected.")
		quit(0)
	else:
		print("\n========== VALIDATION FAILED ==========")
		for f in failures:
			print("  FAIL: ", f)
		quit(1)

func _validate_json(path: String, expected_shape: String, min_elements: int) -> Array:
	if not FileAccess.file_exists(path):
		return ["missing file: " + path]

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ["cannot open: " + path]

	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if parsed == null:
		return ["JSON parse failed: " + path]

	match expected_shape:
		"array":
			if typeof(parsed) != TYPE_ARRAY:
				return [path + ": expected array, got type " + str(typeof(parsed))]
			if (parsed as Array).size() < min_elements:
				return [path + ": expected >= " + str(min_elements) + " elements, got " + str((parsed as Array).size())]
			print("  OK json(array, ", (parsed as Array).size(), " items): ", path)
		"object":
			if typeof(parsed) != TYPE_DICTIONARY:
				return [path + ": expected object, got type " + str(typeof(parsed))]
			print("  OK json(object, ", (parsed as Dictionary).size(), " keys): ", path)
		_:
			return [path + ": unknown expected shape " + expected_shape]

	return []

func _validate_texture(path: String) -> Array:
	if not ResourceLoader.exists(path):
		return ["texture resource not found: " + path]

	var tex: Texture2D = load(path)
	if tex == null:
		return ["texture load returned null: " + path]

	var size := tex.get_size()
	if size.x <= 0 or size.y <= 0:
		return [path + ": zero-size texture " + str(size)]

	print("  OK texture(", size.x, "x", size.y, "): ", path)
	return []

func _validate_font(path: String) -> Array:
	if not ResourceLoader.exists(path):
		return ["font resource not found: " + path]

	var font: FontFile = load(path)
	if font == null:
		return ["font load returned null: " + path]

	print("  OK font: ", path)
	return []

func _validate_audio(path: String) -> Array:
	if not ResourceLoader.exists(path):
		return ["audio resource not found: " + path]

	var stream: AudioStream = load(path)
	if stream == null:
		return ["audio load returned null: " + path]

	var duration := stream.get_length()
	print("  OK audio(", "%.2f" % duration, "s): ", path)
	return []

# SpriteAtlas end-to-end test: load the character atlas via
# SpriteAtlas.load_from, assert the region count is proportional to
# characters × pieces (not collapsed by name collisions), retrieve a
# specific region by its composite key, and pull all pieces for a
# known character via get_character_pieces. Proves the offsets JSON
# shape the Go build tool emits maps correctly to AtlasTexture
# sub-region cropping at Godot runtime AND that the character-to-
# piece grouping math is right.
func _validate_character_atlas() -> Array:
	var atlas := SpriteAtlas.load_from(
		"res://assets/atlases/characterParts.png",
		"res://assets/atlases/characterParts.offsets.json",
		"res://assets/atlases/characterParts.characterArt.json"
	)

	if atlas == null:
		return ["SpriteAtlas.load_from returned null for characterParts"]

	if atlas.regions.is_empty():
		return ["characterParts SpriteAtlas has zero regions"]

	if atlas.character_names.is_empty():
		return ["characterParts SpriteAtlas has zero character names"]

	if atlas.pieces_per_character <= 0:
		return ["characterParts SpriteAtlas pieces_per_character is " + str(atlas.pieces_per_character)]

	# Sanity check: the region dict should have approximately
	# character_count × pieces_per_character entries, not just
	# pieces_per_character (which would indicate name collisions).
	var expected := atlas.character_names.size() * atlas.pieces_per_character
	if atlas.regions.size() < expected / 2:
		return [
			"characterParts SpriteAtlas looks collapsed: expected ~"
			+ str(expected) + " regions, got " + str(atlas.regions.size())
		]

	# Grab the first non-degenerate region via composite key lookup.
	var first_key := ""
	var first_region: AtlasTexture = null
	for key in atlas.region_keys():
		var candidate: AtlasTexture = atlas.get_region(key)
		if candidate != null and candidate.region.size.x > 0 and candidate.region.size.y > 0:
			first_key = key
			first_region = candidate
			break

	if first_region == null:
		return ["characterParts SpriteAtlas has no non-degenerate regions"]

	if first_region.atlas != atlas.source:
		return ["characterParts region atlas reference mismatch"]

	# Pull the entire piece list for boxer-human (known to exist in the
	# sample) and confirm it returns exactly pieces_per_character entries.
	var boxer_pieces := atlas.get_character_pieces("boxer-human")
	if boxer_pieces.size() != atlas.pieces_per_character:
		return [
			"get_character_pieces('boxer-human') returned "
			+ str(boxer_pieces.size()) + " entries, expected "
			+ str(atlas.pieces_per_character)
		]

	print("  OK SpriteAtlas(chars): ",
		atlas.regions.size(), " regions, ",
		atlas.character_names.size(), " characters, ",
		atlas.pieces_per_character, " pieces each")
	print("    first non-degenerate key '", first_key, "' at ", first_region.region)
	print("    get_character_pieces('boxer-human') -> ", boxer_pieces.size(), " AtlasTextures")
	return []

func _validate_texture_atlas() -> Array:
	var atlas := SpriteAtlas.load_from(
		"res://assets/atlases/furniture.png",
		"res://assets/atlases/furniture.offsets.json"
	)

	if atlas == null:
		return ["SpriteAtlas.load_from returned null for furniture"]

	if atlas.regions.is_empty():
		return ["furniture SpriteAtlas has zero regions"]

	# Character art should be empty for a non-character atlas.
	if not atlas.character_names.is_empty():
		return ["furniture SpriteAtlas unexpectedly has character names"]

	var first_key := ""
	var first_region: AtlasTexture = null
	for key in atlas.region_keys():
		var candidate: AtlasTexture = atlas.get_region(key)
		if candidate != null and candidate.region.size.x > 0 and candidate.region.size.y > 0:
			first_key = key
			first_region = candidate
			break

	if first_region == null:
		return ["furniture SpriteAtlas has no non-degenerate regions"]

	if first_region.atlas != atlas.source:
		return ["furniture region atlas reference mismatch"]

	print("  OK SpriteAtlas(furn): ",
		atlas.regions.size(), " regions (no character art)")
	print("    first non-degenerate key '", first_key, "' at ", first_region.region)
	return []
