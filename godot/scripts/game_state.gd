extends Node

## Phase 4 GameState autoload. Single canonical mutable copy of the loaded
## save Dict + cross-system signals + occupied-seat tracking. Sub-systems
## read from and write to this; nobody else holds save fields.
##
## Set up as autoload via project.godot; reachable as `GameState.cafe_dict`
## anywhere. Class name not declared — autoloads use the registered name
## ("GameState") directly. See https://docs.godotengine.org/en/stable/tutorials/scripting/singletons_autoload.html
##
## Phase 4 fields land per session:
##   Session 2 (this): cafe_dict, occupied_seats, signals
##   Session 3: kitchen state (stove timers etc.)
##   Session 4: player_save (money, XP)
##   Session 5: pending furniture purchases
##   Session 6: character roster

## The loaded Cafe Dict from playerCafe.caf via Phase 3 LegacyLoader.
## Empty until load_cafe_dict() is called.
var cafe_dict: Dictionary = {}

## Set of tile indices currently occupied by a seated customer.
## Used by CustomerSystem._find_free_seat to avoid double-booking.
var occupied_seats: Dictionary = {}  # tile_idx -> true

## Emitted when CustomerSystem spawns a new customer.
signal customer_spawned(actor)

## Emitted when a customer reaches their assigned seat.
signal customer_seated(actor, seat_tile_idx)

## Emitted when a customer leaves their seat (despawn).
signal customer_left(actor, seat_tile_idx)


func load_cafe_dict(d: Dictionary) -> void:
	cafe_dict = d


func mark_seat_occupied(tile_idx: int) -> void:
	occupied_seats[tile_idx] = true


func mark_seat_free(tile_idx: int) -> void:
	occupied_seats.erase(tile_idx)


func is_seat_free(tile_idx: int) -> bool:
	return not occupied_seats.has(tile_idx)
