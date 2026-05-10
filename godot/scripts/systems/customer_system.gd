class_name CustomerSystem
extends Node

## Phase 4 Session 2: customer spawn loop.
##
## Single concurrent customer (Session 2 scope). Despawn-on-leave makes room
## for the next spawn 5 sec later (timer counts from despawn, not from spawn).
##
## Reads Cafe.Tiles[] from GameState.cafe_dict to find FurnitureType=3 (chair)
## seats. Spawns a CustomerActor at the cafe entrance, walks them to a free
## chair via the actor's own tick(delta), then despawns them after their
## SIT_DURATION elapses.
##
## init() is called once by main_scene._assemble_cafe with the scene parent
## (where actors are added as children) and the character atlas (passed
## through to CustomerActor.init).

const SPAWN_INTERVAL_SEC: float = 5.0
const WALK_DURATION_SEC: float = 3.0
const SPAWN_POS: Vector2 = Vector2(50, 50)
const TILE_W: int = 50
const TILE_H: int = 50

const FURNITURE_TYPE_CHAIR: int = 3

var _scene_parent: Node2D = null
var _char_atlas: SpriteAtlas = null
var _time_until_next_spawn: float = 1.0  # First spawn at t=1s
var _active_customer: CustomerActor = null


func init(scene_parent: Node2D, char_atlas: SpriteAtlas) -> void:
	_scene_parent = scene_parent
	_char_atlas = char_atlas


func tick(delta: float) -> void:
	if _scene_parent == null or _char_atlas == null:
		return  # Not initialized; controller hasn't called init yet.

	if _active_customer != null:
		_active_customer.tick(delta)
		if _active_customer.state == CustomerActor.State.LEAVING:
			_despawn_active_customer()
		return

	_time_until_next_spawn -= delta
	if _time_until_next_spawn <= 0.0:
		_spawn_one_customer()
		_time_until_next_spawn = SPAWN_INTERVAL_SEC


func _spawn_one_customer() -> void:
	var seat_tile_idx: int = _find_free_seat()
	if seat_tile_idx < 0:
		push_warning("CustomerSystem: no free seat available; deferring spawn")
		_time_until_next_spawn = 1.0  # retry in 1s
		return

	var actor := CustomerActor.new()
	actor.init(_char_atlas)
	actor.position = SPAWN_POS
	_scene_parent.add_child(actor)
	_active_customer = actor

	GameState.mark_seat_occupied(seat_tile_idx)
	GameState.customer_spawned.emit(actor)

	var seat_world: Vector2 = _seat_world_position(seat_tile_idx)
	actor.walk_to(seat_world, WALK_DURATION_SEC, seat_tile_idx)


func _despawn_active_customer() -> void:
	if _active_customer == null:
		return
	GameState.mark_seat_free(_active_customer.seat_tile_idx)
	_active_customer.queue_free()
	_active_customer = null


func _find_free_seat() -> int:
	var tiles: Array = GameState.cafe_dict.get("Tiles", [])
	if tiles.is_empty():
		return -1
	for i in range(tiles.size()):
		var tile: Dictionary = tiles[i]
		for slot in ["U5", "U7", "U9"]:
			var obj = tile.get(slot)
			if obj == null or not (obj is Dictionary):
				continue
			if int(obj.get("Type", 0)) != 1:
				continue  # Not Furniture (Type=1)
			var furn = obj.get("Furniture")
			if furn == null or not (furn is Dictionary):
				continue
			if int(furn.get("FurnitureType", 0)) != FURNITURE_TYPE_CHAIR:
				continue
			if not GameState.is_seat_free(i):
				continue
			return i
	return -1


func _seat_world_position(tile_idx: int) -> Vector2:
	var map_size_x: int = int(GameState.cafe_dict.get("MapSizeX", 0))
	if map_size_x <= 0:
		return Vector2.ZERO
	var tx: int = tile_idx % map_size_x
	var ty: int = tile_idx / map_size_x
	return Vector2(tx * TILE_W, ty * TILE_H)


# Test helper (controller / validator can read these for assertions).
func get_active_customer() -> CustomerActor:
	return _active_customer
