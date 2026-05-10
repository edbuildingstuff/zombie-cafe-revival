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
	# Placeholder: pick any boxer-human piece. The body is recognizable.
	# Real 27-piece skeletal customer is Session 6.
	var pieces: Array = atlas.get_character_pieces("boxer-human")
	if pieces.is_empty():
		push_warning("CustomerActor: no boxer-human pieces in atlas; sprite will be invisible")
	else:
		# Pick a piece that's visually distinct — index 12 is typically the body
		# in this atlas; clamp defensively.
		var idx: int = mini(12, pieces.size() - 1)
		_sprite.texture = pieces[idx]
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
