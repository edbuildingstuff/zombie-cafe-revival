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
	failures += _validate_main_scene()

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

# main.tscn end-to-end test: load the packed scene, instantiate it,
# and add it to the scene tree so its _ready() fires. The startup
# script is expected to assemble the boxer-human character by
# pulling 27 AtlasTexture pieces out of SpriteAtlas and assigning
# them to Sprite2D children. Proves the atlas -> AtlasTexture ->
# Sprite2D rendering path works end-to-end in a real node tree,
# not just in the SpriteAtlas unit check above. Does not capture
# pixels — scene-tree instantiation is enough to shake out
# script errors, node-type mismatches, and texture-binding bugs.
func _validate_main_scene() -> Array:
	var path := "res://main.tscn"
	if not ResourceLoader.exists(path):
		return ["main scene not found: " + path]

	var packed: PackedScene = load(path)
	if packed == null:
		return ["main scene load returned null: " + path]

	var instance := packed.instantiate()
	if instance == null:
		return ["main scene instantiate returned null: " + path]

	if not (instance is Node2D):
		return [path + ": root is not a Node2D (got " + instance.get_class() + ")"]

	# Call assemble() directly rather than routing through _ready.
	# In an `extends SceneTree` script running from _init, nodes
	# added to get_root() don't get their _ready callback until
	# the first frame — too late for the synchronous child-count
	# check below. assemble() is idempotent via the _ready guard.
	if not instance.has_method("assemble"):
		instance.queue_free()
		return [path + ": root node has no assemble() method"]

	var built: int = instance.call("assemble")
	if built <= 0:
		instance.queue_free()
		return [path + ": assemble() built " + str(built) + " sprites"]

	# Phase 1b: drive pose_from_animation so the grid layout gets
	# replaced by real keyframe-driven positions. Tests the full
	# Go parser -> JSON -> Godot consumer pipeline end-to-end.
	if not instance.has_method("pose_from_animation"):
		instance.queue_free()
		return [path + ": root node has no pose_from_animation() method"]

	var posed: int = instance.call(
		"pose_from_animation",
		"res://assets/data/animation/sitSW.json",
		0,
	)
	if posed <= 0:
		instance.queue_free()
		return [path + ": pose_from_animation returned " + str(posed)]

	var sprites: Array = []
	for child in instance.get_children():
		if child is Sprite2D:
			sprites.append(child)

	if sprites.size() != 27:
		instance.queue_free()
		return [path + ": expected 27 Sprite2D children, got " + str(sprites.size())]

	var valid_textures := 0
	for s in sprites:
		var sprite := s as Sprite2D
		if sprite.texture != null and sprite.texture is AtlasTexture:
			var atlas_tex := sprite.texture as AtlasTexture
			if atlas_tex.atlas != null and atlas_tex.region.size.x > 0 and atlas_tex.region.size.y > 0:
				valid_textures += 1

	if valid_textures != 27:
		instance.queue_free()
		return [
			path + ": expected 27 sprites with valid AtlasTexture, got "
			+ str(valid_textures)
		]

	# Pose delta check: at least one sprite must have a position
	# different from its Phase 2b grid cell origin. Confirms that
	# pose_from_animation actually mutated positions rather than
	# leaving the grid in place. Uses constants from main_scene.gd.
	const CELL_W_CHECK := 140.0
	const CELL_H_CHECK := 140.0
	const GRID_ORIGIN_CHECK := Vector2(80.0, 80.0)
	const GRID_COLS_CHECK := 9

	var pose_applied := false
	var idx := 0
	for s in sprites:
		var sprite := s as Sprite2D
		var col := idx % GRID_COLS_CHECK
		var row := idx / GRID_COLS_CHECK
		var cell_origin := GRID_ORIGIN_CHECK + Vector2(col * CELL_W_CHECK, row * CELL_H_CHECK)
		if sprite.position.distance_to(cell_origin) > 1.0:
			pose_applied = true
			break
		idx += 1

	if not pose_applied:
		instance.queue_free()
		return [path + ": every sprite still at its grid cell origin — pose_from_animation did not move anything"]

	print("  OK main.tscn: ",
		sprites.size(), " Sprite2D children, ",
		valid_textures, " with valid AtlasTextures, pose delta applied")

	instance.queue_free()
	return []
