extends Node2D

## Phase 2b visible-scene entry point. Loads the character atlas
## via SpriteAtlas.load_from, pulls all 27 pieces for boxer-human,
## and lays them out as Sprite2D children so opening project.godot
## in Godot 4 shows the first rendered artifact of the rewrite.
##
## Layout note: without per-animation keyframe data (Phase 1b
## pending), we cannot pose the 27 parts into a real character
## skeleton. This scene instead tiles the pieces in a grid so
## every cropped sub-region is visible on screen, and applies
## the per-piece draw_offsets as a small positional nudge on top
## of each cell origin. The nudge is typically only 0-5 pixels,
## so its visual effect is subtle — the purpose at this phase is
## to prove the plumbing (atlas -> AtlasTexture -> Sprite2D),
## not to render a posed character. Real skeletal assembly is a
## Phase 1b/Phase 4 task once the animation parser lands.

const ATLAS_PNG := "res://assets/atlases/characterParts.png"
const OFFSETS_JSON := "res://assets/atlases/characterParts.offsets.json"
const CHARACTER_ART_JSON := "res://assets/atlases/characterParts.characterArt.json"
const CHARACTER_NAME := "boxer-human"

const GRID_COLS := 9
const CELL_W := 140.0
const CELL_H := 140.0
const GRID_ORIGIN := Vector2(80.0, 80.0)


func _ready() -> void:
	# Guard against double-assembly when the validation test has
	# already called assemble() before the node entered the tree.
	if get_child_count() == 0:
		assemble()
	# Phase 1b: replace the grid with a single-keyframe pose.
	# Grid layout stays as a graceful fallback when the JSON is
	# missing or malformed — the push_warning is a signal to
	# investigate but never crashes the scene.
	var applied := pose_from_animation("res://assets/data/animation/sitSW.json", 0)
	if applied == 0:
		push_warning("main_scene: pose_from_animation returned 0, grid stays")


## Builds the 27 Sprite2D children. Pulled out of _ready so the
## headless validation can invoke it synchronously — nodes added
## to the root window inside a `extends SceneTree` script's _init
## only get their _ready callback on a later frame, which is too
## late for the validation's same-frame child-count assertion.
func assemble() -> int:
	var atlas := SpriteAtlas.load_from(ATLAS_PNG, OFFSETS_JSON, CHARACTER_ART_JSON)
	if atlas == null:
		push_error("main_scene: SpriteAtlas.load_from returned null")
		return 0

	var prefix := CHARACTER_NAME + "/"
	var piece_index := 0
	for key in atlas.region_keys():
		var key_str := key as String
		if not key_str.begins_with(prefix):
			continue

		var region: AtlasTexture = atlas.get_region(key_str)
		if region == null:
			continue

		var sprite := Sprite2D.new()
		sprite.name = key_str.substr(prefix.length())
		sprite.texture = region
		sprite.centered = false

		var col := piece_index % GRID_COLS
		var row := piece_index / GRID_COLS
		var cell_origin := GRID_ORIGIN + Vector2(col * CELL_W, row * CELL_H)

		var offset_vec := atlas.get_draw_offset(key_str)
		sprite.position = cell_origin + Vector2(offset_vec.x, offset_vec.y)

		add_child(sprite)
		piece_index += 1

	return piece_index


## Replaces the grid layout with a single-keyframe pose pulled from an
## animation JSON file produced by tool/build_tool -target godot. Called
## from _ready after assemble() for the normal runtime path; called
## directly by the validator for headless coverage, matching the same
## lifecycle workaround assemble() uses. Returns the number of sprites
## whose position was rewritten; zero means posing failed and the grid
## layout stays as a graceful fallback.
func pose_from_animation(json_path: String, frame_index: int) -> int:
	var data: Variant = _load_animation_json(json_path)
	if data == null:
		return 0

	var skeleton_variant: Variant = data.get("Skeleton", null)
	if skeleton_variant == null or typeof(skeleton_variant) != TYPE_ARRAY:
		push_error("main_scene: " + json_path + " has no Skeleton array")
		return 0
	var skeleton := skeleton_variant as Array
	if skeleton.is_empty():
		push_error("main_scene: " + json_path + " Skeleton is empty")
		return 0

	# frame_index is unused for now — single keyframe only. Kept in
	# the signature so the validator call site doesn't need to change
	# when real keyframe playback lands in a follow-up session.

	var applied := 0
	var bone_idx := 0

	for child in get_children():
		if not (child is Sprite2D):
			continue
		var sprite := child as Sprite2D

		if _is_spacer_name(sprite.name):
			sprite.visible = false
			continue

		if bone_idx >= skeleton.size():
			# More bone-backed sprites than skeleton records — remaining
			# sprites stay at their grid positions. In practice this
			# happens because the 24 part-backed sprites outnumber the
			# ~13 actual skeleton bones in the animation file; see the
			# mismatch note in AnimationHeader.BoneCount.
			break

		var record := skeleton[bone_idx] as Dictionary
		sprite.position = _extract_position_from_record(record)
		applied += 1
		bone_idx += 1

	return applied


func _load_animation_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("main_scene: animation JSON not found: " + path)
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("main_scene: cannot open: " + path)
		return null
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		push_error("main_scene: JSON parse failed: " + path)
		return null
	return parsed


func _is_spacer_name(sprite_name: String) -> bool:
	return sprite_name.begins_with("0-spacer") \
		or sprite_name == "1x1.png" \
		or sprite_name == "1x1_front.png"


## Pulls a Vector2 translation from a skeleton record's Transform. The
## 12-float block is a 3x4 affine matrix in row-major order; the last
## column holds the translation (indices 9, 10, 11 = Tx, Ty, Tz). Since
## the game is 2D isometric we use (9, 10) and discard Z. Grounds the
## pose near (640, 360) so real translations render inside the visible
## area regardless of their base magnitude.
func _extract_position_from_record(record: Dictionary) -> Vector2:
	var transform_variant: Variant = record.get("Transform", null)
	if transform_variant == null or typeof(transform_variant) != TYPE_ARRAY:
		return Vector2(640.0, 360.0)
	var transform := transform_variant as Array
	if transform.size() < 12:
		return Vector2(640.0, 360.0)
	var tx := float(transform[9])
	var ty := float(transform[10])
	return Vector2(640.0, 360.0) + Vector2(tx, ty)
