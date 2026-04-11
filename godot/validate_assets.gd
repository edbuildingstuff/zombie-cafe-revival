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
