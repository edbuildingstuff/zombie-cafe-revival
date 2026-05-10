# Phase 4 Session 2: Customer Spawn + Walk to Seat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A customer entity spawns at a fixed cafe-entrance coord every 5 seconds, walks to a free chair via tween-equivalent motion, sits there for 2 seconds, then despawns to make room for the next customer. Establishes the Phase 4 tick architecture: `GameState` autoload + per-system `tick(delta)` driven from `main_scene._process`.

**Architecture:** Three new GDScript files. `GameState` is an autoload `Node` holding the loaded `Cafe` Dict + a set of occupied seat tile indices. `CustomerSystem` (`Node`) has a spawn timer; on each `tick(delta)`, it advances the timer and (if no active customer) spawns a `CustomerActor`. `CustomerActor` (`Node2D`) has a single Sprite2D placeholder visual and its own `tick(delta)` that advances position toward a target by `speed * delta`. No Godot Tween — manual interpolation makes the system fully headless-testable. Customer lifecycle: spawn → walking → seated (2s timer) → despawn.

**Tech Stack:** GDScript 4.x (Godot 4.6.2), no new external dependencies. Reuses the existing `SpriteAtlas` (Phase 2a) and `LegacyLoader.parse_cafe_bytes` (Phase 3).

**Spec:** `docs/superpowers/specs/2026-05-10-phase-4-game-tick-design.md` (umbrella). Session 2 sketch is in §2; this plan fills in TBDs.

**Predecessor:** Phase 4 Session 1, commit `705a760b`. Cafe rendering from save Dict works; 16/16 validator green.

**Environment paths:**
- Godot 4.6.2 console binary: `/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe`
- Repo root: `/c/Users/edwar/edbuildingstuff/zombie-cafe-revival`

**Resolved Session 2 design choices** (per the controller-user discussion):

| Decision | Choice | Rationale |
|---|---|---|
| Customer visual | Single `Sprite2D` with `boxer-human/0_bodyA.png` from `characterParts.png` atlas | Single sprite is enough to prove motion; full 27-piece skeletal customer is Session 6 |
| Spawn point | Fixed world coord `(50, 50)` | Cafe upper-left; visible in the camera-centered scene |
| Seat detection | `Cafe.Tiles[i].U5/U7/U9.Furniture.FurnitureType == 3` | Confirmed: `cafe.go:36` says 1=Stove, 2=ServingCounter; `furniture/19.png` is a chair (FurnitureType=3 has U2 in `[3, 19, 20, 21]` in fixture) |
| Spawn rate | 5 sec | Hardcoded; real rates are Phase 4 RE work |
| Walk duration | 3 sec | Linear interpolation in `tick(delta)` — no Godot Tween |
| Concurrency | Max 1 active customer | Tighter scope; multi-customer is Session 2.5 |
| Sit duration | 2 sec | After sitting, customer despawns; next customer spawns 5s after the previous despawn |
| Camera | New `Camera2D` in `main.tscn`, anchored at `(875, 1375)` (cafe center) with `zoom=(0.4, 0.4)` | The 35×55 grid at 50px = 1750×2750 world; default viewport showed only the upper-left corner |
| 17th validator check | Headless: instantiate scene, manually call `customer_system.tick()` for 3.5s sim time, assert active customer reached the chair tile's screen position | Tickable architecture means no `await`/`Tween.finished` dance |

**Commit policy:** Per `feedback_commit_style`, **one grouped commit** for the whole session. Per `feedback_no_coauthor_trailer`, **omit** the `Co-Authored-By:` trailer. Task 8 below creates the single commit. Implementer subagents may make WIP intermediate commits; the controller squashes at the end.

**Out of scope** (deferred to later sessions):
- A* / obstacle-avoiding pathfinding (linear lerp passes through walls/furniture; Session 2.5)
- Multiple concurrent customers (Session 2.5)
- Order/cook/eat/pay loop (Session 3-4)
- Animated walking sprites; just Sprite2D placeholder (Session 6)
- Spawn rate variation, character roster selection (later)
- Save persistence of in-flight customers (Session 4)

---

## File structure

```
godot/
├── main.tscn                                MODIFY — add Camera2D
├── project.godot                            MODIFY — register GameState autoload
├── scripts/
│   ├── game_state.gd                        NEW — autoload (Node)
│   ├── game_state.gd.uid                    NEW
│   ├── main_scene.gd                        MODIFY — _assemble_cafe inits
│   │                                                  systems; _process drives them
│   └── systems/                             NEW directory
│       ├── customer_actor.gd                NEW — CustomerActor (Node2D)
│       ├── customer_actor.gd.uid            NEW
│       ├── customer_system.gd               NEW — CustomerSystem (Node)
│       └── customer_system.gd.uid           NEW
└── validate_assets.gd                       MODIFY — 17th check

docs/rewrite-plan.md                         MODIFY — Session 2 of 7 landed
```

---

## Task 1: GameState autoload

**Files:**
- Create: `godot/scripts/game_state.gd`
- Create: `godot/scripts/game_state.gd.uid` (auto-generated)
- Modify: `godot/project.godot` (autoload registration)

`GameState` is a thin holder for the live mutable Dict + cross-system signals + occupied-seat tracking. Autoload makes it reachable as `GameState.cafe_dict` from any sub-system without dependency injection plumbing — appropriate for a singleton state hub.

- [ ] **Step 1.1: Create `godot/scripts/game_state.gd`**

```gdscript
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
```

- [ ] **Step 1.2: Register GameState as an autoload in `project.godot`**

Open `godot/project.godot` and add an `[autoload]` section if it doesn't exist, with the GameState entry:

```ini
[autoload]

GameState="*res://scripts/game_state.gd"
```

The `*` prefix means "always loaded" (singleton autoload). The name `GameState` is what scripts use to reference it.

If an `[autoload]` section already exists, just add the line.

- [ ] **Step 1.3: Rebuild Godot's class cache**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --editor --quit --path godot/
```

Expected: silent or low-volume. Generates `godot/scripts/game_state.gd.uid`.

- [ ] **Step 1.4: Smoke-test that the existing 16/16 validator still passes**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --path godot/ --script res://validate_assets.gd 2>&1 | tail -3
```

Expected: `========== VALIDATION PASSED ==========` (still 16/16). The autoload is registered but nothing uses it yet.

---

## Task 2: CustomerActor

**Files:**
- Create: `godot/scripts/systems/customer_actor.gd`
- Create: `godot/scripts/systems/customer_actor.gd.uid` (auto-generated)

`CustomerActor` extends `Node2D`. Holds a placeholder `Sprite2D` visual. Has its own `tick(delta)` for motion — manual lerp toward target, no Godot Tween. State machine: walking → seated → leaving.

- [ ] **Step 2.1: Create the directory**

```bash
mkdir -p godot/scripts/systems
```

- [ ] **Step 2.2: Create `godot/scripts/systems/customer_actor.gd`**

```gdscript
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
	var pieces: Array[AtlasTexture] = atlas.get_character_pieces("boxer-human")
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
```

- [ ] **Step 2.3: Smoke-test class cache rebuild**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --editor --quit --path godot/
```

Expected: silent. Generates `customer_actor.gd.uid`.

---

## Task 3: CustomerSystem

**Files:**
- Create: `godot/scripts/systems/customer_system.gd`
- Create: `godot/scripts/systems/customer_system.gd.uid` (auto-generated)

`CustomerSystem` extends `Node` (no visual). Holds the spawn timer + active-customer reference. `tick(delta)` advances the timer and either spawns a new customer or progresses the active one's tick.

- [ ] **Step 3.1: Create `godot/scripts/systems/customer_system.gd`**

```gdscript
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
```

- [ ] **Step 3.2: Class cache rebuild**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --editor --quit --path godot/
```

Expected: silent. Generates `customer_system.gd.uid`.

---

## Task 4: Wire CustomerSystem into main_scene + add Camera2D

**Files:**
- Modify: `godot/scripts/main_scene.gd`
- Modify: `godot/main.tscn`

- [ ] **Step 4.1: Edit `main_scene.gd` to add CustomerSystem field + initialize in cafe mode + drive tick**

Find the existing constants near the top. Add:

```gdscript
const CHAR_ATLAS_PNG := ATLAS_PNG  # alias for clarity
const CHAR_ATLAS_OFFSETS := OFFSETS_JSON
const CHAR_ATLAS_CHARACTER_ART := CHARACTER_ART_JSON
```

(These reuse the existing characterParts atlas constants under clearer names — characterParts is also the source for customer placeholder visuals. Optional but cleaner.)

Add a new field below the constants:

```gdscript
var _customer_system: CustomerSystem = null
```

Find `_assemble_cafe()`. After the `return CafeRenderer.render(self, cafe_dict, atlases)` line, insert (replacing the return):

```gdscript
func _assemble_cafe() -> int:
	# ... [keep all existing code that loads cafe_dict, atlases, calls CafeRenderer.render] ...

	var sprite_count: int = CafeRenderer.render(self, cafe_dict, atlases)

	# Phase 4 Session 2: hand the loaded Dict to GameState and wire up
	# the customer system. The character atlas is reused as the customer
	# sprite source (boxer-human placeholder pieces).
	GameState.load_cafe_dict(cafe_dict)

	var char_atlas := SpriteAtlas.load_from(CHAR_ATLAS_PNG, CHAR_ATLAS_OFFSETS, CHAR_ATLAS_CHARACTER_ART)
	if char_atlas == null:
		push_error("main_scene: char_atlas load failed")
		return sprite_count  # Still return — cafe is rendered, just no customers.

	_customer_system = CustomerSystem.new()
	_customer_system.init(self, char_atlas)
	add_child(_customer_system)

	return sprite_count
```

Add or modify `_process(delta)`:

```gdscript
func _process(delta: float) -> void:
	if _customer_system != null:
		_customer_system.tick(delta)
```

If `_process` already exists, just add the body line.

- [ ] **Step 4.2: Edit `main.tscn` to add a Camera2D node**

Read the current `main.tscn`:

```bash
cat godot/main.tscn
```

The structure should be a Node2D root with a script attached. Add a Camera2D child.

Edit `main.tscn` to add a Camera2D under the root. The simpler way is via the Godot editor GUI, but for headless: edit the `.tscn` directly. Append a Camera2D node section:

```
[node name="MainCamera" type="Camera2D" parent="."]
position = Vector2(875, 1375)
zoom = Vector2(0.4, 0.4)
```

The exact format may need tweaking to match the existing tscn structure. If the existing tscn has `[gd_scene load_steps=N format=3 ...]`, add the new node block at the end. Verify the file parses by running:

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --editor --quit --path godot/
```

Expected: silent. If the tscn is malformed, Godot will print a parse error.

- [ ] **Step 4.3: Smoke-test 16/16 validator still passes**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --path godot/ --script res://validate_assets.gd 2>&1 | tail -5
```

Expected: still 16/16 (the wiring is in place but no test exercises customer spawning yet — that's Task 5).

---

## Task 5: 17th validator check — customer spawn + walk

**Files:**
- Modify: `godot/validate_assets.gd`

Add a 17th check that programmatically spawns a customer, fast-forwards via direct `tick(delta)` calls, and asserts the customer reached the seat.

- [ ] **Step 5.1: Add `_validate_customer_spawn` function**

In `godot/validate_assets.gd`, after `_validate_cafe_render()`, add:

```gdscript
func _validate_customer_spawn() -> Array:
	# Phase 4 Session 2: spawn a customer in a fresh GameState + CustomerSystem,
	# tick the system through full spawn -> walk -> seated, assert the customer
	# reached its seat tile.
	var cafe_path := "res://test/fixtures/save/playerCafe.caf"
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(cafe_path)
	if bytes.is_empty():
		return [cafe_path + ": fixture missing or empty"]

	var cafe_dict: Dictionary = LegacyLoader.parse_cafe_bytes(bytes)
	if cafe_dict.is_empty():
		return ["LegacyLoader.parse_cafe_bytes returned empty"]

	# Reset GameState (autoload persists across checks).
	GameState.cafe_dict = {}
	GameState.occupied_seats = {}
	GameState.load_cafe_dict(cafe_dict)

	var char_atlas: SpriteAtlas = SpriteAtlas.load_from(
		"res://assets/atlases/characterParts.png",
		"res://assets/atlases/characterParts.offsets.json",
		"res://assets/atlases/characterParts.characterArt.json")
	if char_atlas == null:
		return ["characterParts atlas load failed"]

	var parent := Node2D.new()
	var system := CustomerSystem.new()
	system.init(parent, char_atlas)
	parent.add_child(system)

	# Tick the system. First spawn fires at t=1.0s. Walk takes 3.0s. Sit takes
	# 2.0s. So at t = 1.0 + 3.0 = 4.0s, customer should be seated. Tick in 0.1
	# steps for granularity. Assert seated state at simulated t=4.5s.
	var sim_dt: float = 0.1
	var sim_steps: int = 45  # 4.5 seconds
	for i in range(sim_steps):
		system.tick(sim_dt)

	var actor: CustomerActor = system.get_active_customer()
	if actor == null:
		parent.queue_free()
		return ["CustomerSystem: no active customer after 4.5s sim"]

	if actor.state != CustomerActor.State.SEATED:
		parent.queue_free()
		return ["CustomerActor: expected SEATED state at t=4.5s, got " + str(actor.state)]

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
	if not GameState.occupied_seats.has(actor.seat_tile_idx):
		parent.queue_free()
		return ["GameState.occupied_seats missing tile_idx " + str(actor.seat_tile_idx)]

	print("  OK customer spawn: actor SEATED at tile ",
		actor.seat_tile_idx,
		" world=", actor.position, " after sim t=4.5s")

	parent.queue_free()
	return []
```

- [ ] **Step 5.2: Wire into `_init`**

Find where `_validate_cafe_render` is called (added in Session 1):

```gdscript
	failures += _validate_cafe_render()
```

Add below:

```gdscript
	failures += _validate_customer_spawn()
```

- [ ] **Step 5.3: Run the validator**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --path godot/ --script res://validate_assets.gd 2>&1 | tail -10
```

Expected: `========== VALIDATION PASSED ==========` with `OK customer spawn: actor SEATED at tile <N> world=<pos> after sim t=4.5s`.

If the customer doesn't reach SEATED state by t=4.5s:
- Check `_find_free_seat` finds a seat (it should — fixture has 4 chairs).
- Check `walk_to` is being called with non-zero duration.
- Check `_advance_walk` is updating position (`speed_pixels_per_sec * delta` per step).

If the customer's final position doesn't match target:
- Floating-point round-off; the 0.5 px tolerance should cover it. If failing, increase tolerance to 1.0.

---

## Task 6: Final regression sweep

**Files:** none modified.

- [ ] **Step 6.1: Re-run all validators**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --path godot/ --script res://validate_assets.gd 2>&1 | tail -5
```

Expected: 17/17 PASSED.

- [ ] **Step 6.2: Re-run save round-trip tests**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --path godot/ --script res://test/test_save_round_trip.gd 2>&1 | tail -3
```

Expected: 207/0.

- [ ] **Step 6.3: Re-run Go file_types tests + workspace builds**

```bash
"/c/Program Files/Go/bin/go.exe" test -count=1 ./tool/file_types/...
for m in file_types build_tool resource_manager cctpacker dump_legacy_fixtures; do
  (cd tool/$m && "/c/Program Files/Go/bin/go.exe" build ./...) || echo "$m FAILED"
done
(cd tool/server && GOOS=js GOARCH=wasm "/c/Program Files/Go/bin/go.exe" build ./...)
```

Expected: ok, no FAILED, exit 0.

- [ ] **Step 6.4: Visual confirmation in GUI Godot**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64.exe" godot/project.godot
```

In the Godot editor, press F5. Observe: the cafe is rendered (Camera2D centered on it), and after ~1s a customer sprite spawns in the upper-left and walks to a chair over 3 seconds. Customer sits for 2 seconds and despawns. Five seconds after despawn, the next customer spawns.

If the customer is invisible: the boxer-human piece may have rendered as a 1×1 sprite (the atlas has spacer entries). Pick a different piece index (e.g., index 1 instead of 12). Document the choice in `customer_actor.gd`.

If the customer goes to an off-screen seat: the camera position may need adjustment. Tweak `position` in `main.tscn` until both spawn and seat are in view.

- [ ] **Step 6.5: Update `docs/rewrite-plan.md`**

Add a Session 2 of 7 entry under Phase 4, after the existing Session 1 of 7 block. Mirror the Session 1 entry's style. Include:
- Files added (game_state.gd, customer_actor.gd, customer_system.gd; main.tscn Camera2D)
- 17th validator check pass
- Resolved seat-detection finding (FurnitureType=3, not =2 as the umbrella spec said — note the spec correction)
- Architectural pattern established (autoload + tick(delta) + signal bus) for Sessions 3-6 to extend

---

## Task 7: Commit

**Files:** all changed files.

- [ ] **Step 7.1: Confirm git status**

```bash
git status
```

Expected files modified or new:
- `godot/scripts/game_state.gd` (new)
- `godot/scripts/game_state.gd.uid` (new)
- `godot/scripts/systems/customer_actor.gd` (new)
- `godot/scripts/systems/customer_actor.gd.uid` (new)
- `godot/scripts/systems/customer_system.gd` (new)
- `godot/scripts/systems/customer_system.gd.uid` (new)
- `godot/scripts/main_scene.gd` (modified)
- `godot/main.tscn` (modified)
- `godot/project.godot` (modified)
- `godot/validate_assets.gd` (modified)
- `docs/rewrite-plan.md` (modified)

- [ ] **Step 7.2: Stage and commit (NO Co-Authored-By trailer)**

```bash
git add \
  godot/scripts/game_state.gd \
  godot/scripts/game_state.gd.uid \
  godot/scripts/systems/customer_actor.gd \
  godot/scripts/systems/customer_actor.gd.uid \
  godot/scripts/systems/customer_system.gd \
  godot/scripts/systems/customer_system.gd.uid \
  godot/scripts/main_scene.gd \
  godot/main.tscn \
  godot/project.godot \
  godot/validate_assets.gd \
  docs/rewrite-plan.md

git commit -m "$(cat <<'EOF'
godot: phase 4 session 2 — customer spawn + walk to seat

A customer entity spawns at the cafe entrance every 5 seconds, walks to a
free chair via manual lerp motion, sits for 2 seconds, then despawns to
make room for the next customer. Establishes the Phase 4 tick architecture:
GameState autoload + per-system tick(delta) driven from main_scene._process.

New components:
  godot/scripts/game_state.gd — autoload (Node). Single canonical mutable
    copy of the loaded Cafe Dict + occupied-seat tracking + cross-system
    signals (customer_spawned, customer_seated, customer_left). Reachable
    as `GameState.cafe_dict` from any sub-system.
  godot/scripts/systems/customer_actor.gd — Node2D. Per-customer state
    machine (WALKING / SEATED / LEAVING). Manual lerp motion via tick(delta);
    no Godot Tween (makes the system fully headless-testable). Placeholder
    visual is a single Sprite2D pulling from the boxer-human pieces in
    characterParts; full 27-piece skeletal customer is Session 6.
  godot/scripts/systems/customer_system.gd — Node. Spawn timer + seat
    finder + active-customer tracker. Single concurrent customer; multi-
    customer is Session 2.5. Reads Cafe.Tiles[] for FurnitureType=3 chairs
    (umbrella spec said =2 but cafe.go:36 confirms 2=ServingCounter, not
    seat — corrected here).

Plumbing:
  godot/main.tscn — Camera2D centered on cafe interior so spawn (50,50) +
    seat positions are both in view.
  godot/project.godot — GameState registered as autoload.
  godot/scripts/main_scene.gd — _assemble_cafe instantiates the
    CustomerSystem and hands it the scene parent + character atlas.
    _process(delta) drives system.tick(delta).
  godot/validate_assets.gd — 17th check _validate_customer_spawn:
    programmatically spawns a customer, fast-forwards via direct tick()
    calls (sim t=4.5s in 0.1s steps), asserts SEATED state, position
    matches target_pos, occupied_seats[seat_tile_idx] == true.

Verification:
  - validate_assets.gd: 17/17 PASSED
  - test_save_round_trip.gd: 207/0
  - go test -count=1 ./tool/file_types/...: ok
  - all 5 native workspace modules build clean
  - server module builds clean under GOOS=js GOARCH=wasm

Out of scope (later sessions):
  - A* / obstacle-avoiding pathfinding (linear lerp passes through walls)
  - Multiple concurrent customers (Session 2.5)
  - Order/cook/eat/pay loop (Session 3-4)
  - Animated walking sprites (Session 6)
  - Spawn rate variation, character roster selection
EOF
)"
```

- [ ] **Step 7.3: Verify the commit**

```bash
git log --oneline -3 && git log -1 --format=full | grep -i "Co-Authored\|Edward Yang" | head -5
```

Expected: top commit is `godot: phase 4 session 2 — customer spawn + walk to seat`, Author/Commit are Edward Yang only (no `Co-Authored-By:` trailer).

---

## Acceptance summary

Session 2 is complete when:

1. `validate_assets.gd` passes 17/17.
2. `test_save_round_trip.gd` passes 207/0.
3. Opening `godot/project.godot` in GUI Godot and pressing Run produces a visible cafe with a customer sprite spawning, walking to a chair, sitting briefly, despawning, and respawning.
4. Single grouped commit, no `Co-Authored-By:` trailer.
5. `docs/rewrite-plan.md` reflects Session 2 of 7 landed.

Known acceptable imperfections (deferred to later sessions):
- Customer walks in a straight line — passes through walls/furniture.
- Single customer at a time; the cafe doesn't fill up.
- Customer is a single Sprite2D (one body part), not a full assembled character.
- Spawn point is hardcoded (50, 50); not derived from a save-file "entrance" tile.

Future sessions:
- **Session 2.5** (optional): A* pathfinding around walls, multi-concurrent customers.
- **Session 3:** Order + kitchen state — customer raises an order bubble; stove cooks.
- **Sessions 4-7:** payment/XP, furniture placement, character roster, close-out.
