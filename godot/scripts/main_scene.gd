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
