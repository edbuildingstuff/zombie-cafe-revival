@tool
extends SceneTree

# Headless validation script. Exercises every asset category the
# Phase 1 asset builder produces, then quits with an exit code:
#   0 = every asset loaded and parsed as expected
#   1 = at least one asset failed
#
# Run with:
#   godot --headless --script godot/validate_assets.gd --path godot/

# Accumulates failures from _init so _initialize can append the
# autoload-dependent checks and then emit the final result.
var _early_failures: Array = []

func _init() -> void:
	# Checks 1-16: no autoload dependencies — safe to run in _init.
	_early_failures += _validate_json("res://assets/data/foodData.json", "array", 1)
	_early_failures += _validate_json("res://assets/data/characterData.json", "array", 1)
	_early_failures += _validate_json("res://assets/data/animationData.json", "array", 1)

	_early_failures += _validate_json("res://assets/atlases/characterParts.offsets.json", "object", 0)
	_early_failures += _validate_json("res://assets/atlases/characterParts.characterArt.json", "object", 0)
	_early_failures += _validate_json("res://assets/atlases/furniture.offsets.json", "object", 0)

	_early_failures += _validate_texture("res://assets/atlases/characterParts.png")
	_early_failures += _validate_texture("res://assets/atlases/furniture.png")
	_early_failures += _validate_texture("res://assets/images/boxer-human/back_head1.png")

	_early_failures += _validate_font("res://assets/fonts/A Love of Thunder.ttf")

	_early_failures += _validate_audio("res://assets/audio/Zombie Theme V1.ogg")
	_early_failures += _validate_audio("res://assets/audio/sfx/blender.ogg")

	_early_failures += _validate_character_atlas()
	_early_failures += _validate_texture_atlas()
	_early_failures += _validate_main_scene()
	_early_failures += _validate_cafe_render()


func _initialize() -> void:
	# Check 17: requires GameState autoload (available in _initialize, not _init).
	var failures: Array = _early_failures
	failures += _validate_customer_spawn()

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

	# Second character check: pin down the invariant that different
	# characters get distinct piece arrays (not accidentally shared
	# state between characters). cowboy-human is known to exist in
	# the sample. This is the characterization test for the pending
	# refactor from linear-scan to precomputed dictionary index.
	var cowboy_pieces := atlas.get_character_pieces("cowboy-human")
	if cowboy_pieces.size() != atlas.pieces_per_character:
		return [
			"get_character_pieces('cowboy-human') returned "
			+ str(cowboy_pieces.size()) + " entries, expected "
			+ str(atlas.pieces_per_character)
		]

	# Distinctness: boxer's first piece and cowboy's first piece
	# must point at different AtlasTextures — if they don't, the
	# index is accidentally collapsing state across characters.
	if boxer_pieces[0] == cowboy_pieces[0]:
		return ["boxer-human and cowboy-human returned the same first AtlasTexture — piece arrays collapsed"]

	# Unknown-character check: a name not in character_names must
	# return an empty array, not nil. Pins the graceful-miss contract.
	var missing_pieces := atlas.get_character_pieces("not-a-real-character")
	if missing_pieces.size() != 0:
		return [
			"get_character_pieces('not-a-real-character') returned "
			+ str(missing_pieces.size()) + " entries, expected 0"
		]

	print("  OK SpriteAtlas(chars): ",
		atlas.regions.size(), " regions, ",
		atlas.character_names.size(), " characters, ",
		atlas.pieces_per_character, " pieces each")
	print("    first non-degenerate key '", first_key, "' at ", first_region.region)
	print("    boxer-human -> ", boxer_pieces.size(), " pieces, cowboy-human -> ",
		cowboy_pieces.size(), " pieces, unknown -> ", missing_pieces.size())
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

	var built: int = instance.call("assemble", "grid")
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

func _validate_cafe_render() -> Array:
	# Phase 4 Session 1: load playerCafe.caf via Phase 3 LegacyLoader,
	# render to a Node2D via CafeRenderer, assert sprite counts and
	# textures look right.
	var cafe_path := "res://test/fixtures/save/playerCafe.caf"
	if not FileAccess.file_exists(cafe_path):
		return [cafe_path + ": fixture missing"]

	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(cafe_path)
	if bytes.is_empty():
		return [cafe_path + ": fixture is empty"]

	var cafe_dict: Dictionary = LegacyLoader.parse_cafe_bytes(bytes)
	if cafe_dict.is_empty():
		return [cafe_path + ": LegacyLoader.parse_cafe_bytes returned empty Dict"]

	var furn_atlas: SpriteAtlas = SpriteAtlas.load_from(
		"res://assets/atlases/furniture.png",
		"res://assets/atlases/furniture.offsets.json")
	if furn_atlas == null:
		return ["furniture atlas load failed"]

	# Phase 4 Session 1 RE finding: cafe floor tiles, walls, AND furniture
	# all share the existing furniture atlas. The mapTiles atlas is for
	# Phase 5's world-map overview view, not cafe interior. So all three
	# atlas keys point at furn_atlas.
	var tiles_atlas: SpriteAtlas = furn_atlas
	var walls_atlas: SpriteAtlas = furn_atlas

	var node := Node2D.new()
	var atlases := {
		"tiles": tiles_atlas,
		"walls": walls_atlas,
		"furn": furn_atlas,
	}
	var count: int = CafeRenderer.render(node, cafe_dict, atlases)

	# Hard floor: 1925 floor tiles (35x55 grid, one per Tiles[] entry).
	var floor_count: int = 0
	var object_count: int = 0
	for child in node.get_children():
		if not (child is Sprite2D):
			node.queue_free()
			return ["non-Sprite2D child found in CafeRenderer output: " + str(child)]
		var sprite := child as Sprite2D
		if sprite.z_index == CafeRenderer.Z_FLOOR:
			floor_count += 1
		else:
			object_count += 1

	node.queue_free()

	if floor_count != 1925:
		return ["expected 1925 floor sprites (35x55 grid), got " + str(floor_count)]

	# The fixture has 23 non-trivial tiles. Each can carry up to 3 cafe
	# objects (U5/U7/U9), so up to 69. Use >= 23 as a hard floor.
	if object_count < 23:
		return ["expected ≥23 cafe-object sprites, got " + str(object_count)]

	if count != floor_count + object_count:
		return ["CafeRenderer.render returned " + str(count) + " but children counted " + str(floor_count + object_count)]

	print("  OK cafe render: ", floor_count, " floor + ", object_count, " objects = ", count, " total")
	return []

func _validate_customer_spawn() -> Array:
	# Phase 4 Session 2: spawn a customer in a fresh GameState + CustomerSystem,
	# tick the system through full spawn -> walk -> seated, assert the customer
	# reached its seat tile.
	#
	# This function runs in _initialize (not _init) so GameState autoload IS
	# available. Types are accessed without explicit annotation to avoid a
	# compile-time dependency chain from validate_assets.gd → CustomerSystem →
	# GameState that would break in _init context. The classes compile correctly
	# at project startup when autoloads are ready; untyped new() calls work fine.
	var cafe_path := "res://test/fixtures/save/playerCafe.caf"
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(cafe_path)
	if bytes.is_empty():
		return [cafe_path + ": fixture missing or empty"]

	var cafe_dict: Dictionary = LegacyLoader.parse_cafe_bytes(bytes)
	if cafe_dict.is_empty():
		return ["LegacyLoader.parse_cafe_bytes returned empty"]

	# Access GameState via node path. Even though _validate_customer_spawn is
	# called from _initialize (where GameState IS available), the bare name
	# "GameState" in any function triggers a compile-time identifier lookup that
	# fails when validate_assets.gd is parsed. get_root().get_node() is a
	# runtime call and resolves correctly.
	var gs: Node = get_root().get_node_or_null("GameState")
	if gs == null:
		return ["GameState autoload not found at /root/GameState"]
	gs.set("cafe_dict", {})
	gs.set("occupied_seats", {})
	gs.call("load_cafe_dict", cafe_dict)

	var char_atlas: SpriteAtlas = SpriteAtlas.load_from(
		"res://assets/atlases/characterParts.png",
		"res://assets/atlases/characterParts.offsets.json",
		"res://assets/atlases/characterParts.characterArt.json")
	if char_atlas == null:
		return ["characterParts atlas load failed"]

	var parent := Node2D.new()
	# Load and instantiate CustomerSystem without static type annotation to avoid
	# triggering a re-compile of customer_system.gd at validate_assets.gd
	# parse time (when GameState is not yet in scope).
	var SystemScript = ResourceLoader.load(
		"res://scripts/systems/customer_system.gd", "",
		ResourceLoader.CACHE_MODE_IGNORE)
	if SystemScript == null:
		return ["customer_system.gd failed to load"]
	var system = SystemScript.new()
	system.init(parent, char_atlas)
	parent.add_child(system)

	# Tick the system. First spawn fires at t=1.0s. Walk takes 3.0s. Sit takes
	# 2.0s. So at t = 1.0 + 3.0 = 4.0s, customer should be seated. Tick in 0.1
	# steps for granularity. Assert seated state at simulated t=4.5s.
	var sim_dt: float = 0.1
	var sim_steps: int = 45  # 4.5 seconds
	for i in range(sim_steps):
		system.tick(sim_dt)

	var actor = system.get_active_customer()
	if actor == null:
		parent.queue_free()
		return ["CustomerSystem: no active customer after 4.5s sim"]

	# CustomerActor.State enum: WALKING=0, SEATED=1, LEAVING=2
	var SEATED_STATE: int = 1
	if int(actor.state) != SEATED_STATE:
		parent.queue_free()
		return ["CustomerActor: expected SEATED state (1) at t=4.5s, got " + str(actor.state)]

	# The customer's position should equal the seat's world position.
	var distance_from_target: float = actor.position.distance_to(actor.target_pos)
	if distance_from_target > 0.5:
		parent.queue_free()
		return [
			"CustomerActor: position " + str(actor.position) +
			" should match target " + str(actor.target_pos) +
			" (distance=" + str(distance_from_target) + ")"
		]

	# The seat the customer chose should be in occupied_seats.
	var occupied: Dictionary = gs.get("occupied_seats")
	if not occupied.has(actor.seat_tile_idx):
		parent.queue_free()
		return ["GameState.occupied_seats missing tile_idx " + str(actor.seat_tile_idx)]

	print("  OK customer spawn: actor SEATED at tile ",
		actor.seat_tile_idx,
		" world=", actor.position, " after sim t=4.5s")

	parent.queue_free()
	return []
