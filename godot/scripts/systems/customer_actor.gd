class_name CustomerActor
extends Node2D

## Phase 4 Session 2: per-customer node. State machine driven by tick(delta)
## from CustomerSystem. Three states:
##   walking: lerping position toward target_pos
##   seated:  arrived at seat; sit_timer counting down
##   leaving: sit_timer expired; CustomerSystem will despawn next tick
##
## Visual: single Sprite2D placeholder (boxer-human body part). Real 27-piece
## skeletal assembly is Session 6. The placeholder is enough to prove motion.

enum State { WALKING, SEATED, LEAVING }

const SIT_DURATION_SEC: float = 2.0

var state: State = State.WALKING
var target_pos: Vector2 = Vector2.ZERO
var speed_pixels_per_sec: float = 0.0
var sit_timer: float = 0.0
var seat_tile_idx: int = -1
var _sprite: Sprite2D


## Build the placeholder visual. Called by CustomerSystem when spawning.
## atlas: SpriteAtlas already loaded with characterParts (or any character atlas).
func init(atlas: SpriteAtlas) -> void:
	_sprite = Sprite2D.new()
	_sprite.centered = true
	# Placeholder: pick boxer-human's head1.png — the largest single piece
	# (93x90) so the customer is recognizable at the camera's 0.4x zoom.
	# Boxer-human piece order in the characterParts atlas (verified via
	# offsets manifest):
	#   [0]=0-spacer, [1]=1x1, [2]=1x1_front, [3..7]=back_head/arms/legs,
	#   [8]=back_pelvis(3x3 spacer), [9..13]=back_arms/legs/torso,
	#   [14..15]=chairback(3x3 spacers), [16]=head1, [17..20]=front limbs,
	#   [21]=pelvis(spacer), [22..25]=front limbs, [26]=torso1.
	# Index 16 (head1) is the most visually distinctive single piece.
	# A previous attempt used index 12 (back_rightleg2.png, 22x31) which
	# was too small to see at camera zoom 0.4.
	# Real 27-piece skeletal assembly is Session 6.
	var pieces: Array = atlas.get_character_pieces("boxer-human")
	if pieces.is_empty():
		push_warning("CustomerActor: no boxer-human pieces in atlas; sprite will be invisible")
	else:
		var idx: int = mini(16, pieces.size() - 1)
		_sprite.texture = pieces[idx]
	# Scale up 2x for visibility at the camera's 0.4x zoom — net on-screen
	# size is ~74x72 px, comparable to a tile sprite. Drop this when the
	# real skeletal customer lands in Session 6.
	_sprite.scale = Vector2(2.0, 2.0)
	add_child(_sprite)


## Begin walking to target_world_pos. duration is the target time to arrive.
## Speed is computed from current distance / duration; if the actor is
## displaced after walking starts, arrival timing degrades but doesn't crash.
func walk_to(target_world_pos: Vector2, duration_sec: float, target_seat_idx: int) -> void:
	target_pos = target_world_pos
	seat_tile_idx = target_seat_idx
	state = State.WALKING
	var distance: float = position.distance_to(target_pos)
	if duration_sec <= 0.0:
		# Defensive: avoid divide-by-zero. Snap to target.
		position = target_pos
		_arrive()
		return
	speed_pixels_per_sec = distance / duration_sec


## Per-frame tick. Called by CustomerSystem each delta.
func tick(delta: float) -> void:
	match state:
		State.WALKING:
			_advance_walk(delta)
		State.SEATED:
			_advance_sit(delta)
		State.LEAVING:
			pass  # No-op — CustomerSystem despawns this actor next tick


func _advance_walk(delta: float) -> void:
	var to_target: Vector2 = target_pos - position
	var step: float = speed_pixels_per_sec * delta
	if to_target.length() <= step or step <= 0.0:
		position = target_pos
		_arrive()
		return
	position += to_target.normalized() * step


func _arrive() -> void:
	state = State.SEATED
	sit_timer = SIT_DURATION_SEC
	GameState.customer_seated.emit(self, seat_tile_idx)


func _advance_sit(delta: float) -> void:
	sit_timer -= delta
	if sit_timer <= 0.0:
		state = State.LEAVING
		GameState.customer_left.emit(self, seat_tile_idx)
