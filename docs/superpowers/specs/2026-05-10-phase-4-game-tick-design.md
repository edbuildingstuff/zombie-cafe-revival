# Phase 4 — Game Tick Loop — Design

**Date:** 2026-05-10
**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))
**Phases touched:** Phase 4 (game tick) — picks up immediately after Phase 3 (save format bridge) closed on the same date. Folds Phase 2b's pending "cafe background" item into Phase 4 Session 1 as prerequisite work.

## Goal

Land the Godot client's game tick loop so that a player can boot the game, see their cafe rendered from a real save, watch customers spawn and walk to tables, take orders, cook food on stoves, serve, get paid, level up, and place new furniture. By end of Phase 4, the legacy APK's gameplay loop is reproduced in pure Godot — at first session granularity, with the simplest correct behavior at each step. No online features, no billing, no Facebook integration; those land in Phase 5.

The phase has more reverse engineering surface than Phase 3 by an order of magnitude — `tool/file_types/` was Phase 0b'd to feature-completeness before Phase 3 started, but `libZombieCafeAndroid.so` carries the entire game-logic codebase and `src/lib/cpp/ZombieCafeExtension.cpp` only labels crash-fix sites and IAP/URL patches. Customer spawn rates, order-cooldown timing, food-cook duration, payment formulas, XP curves — all of that must be lifted from the binary or inferred from the data files (`constants.bin.mid`, `cookbookData.bin.mid.json`, etc.) supplemented with empirical play-testing on the legacy device build.

## Context

This design closes nothing — it opens Phase 4. Phase 3 closed (`docs/devlog/2026-05-10-phase-3-save-format.md`) so the save Dict shape is now the canonical in-memory representation; the tick loop reads and writes that shape. Phase 2b shipped boxer-human posed in `main.tscn` but flagged "cafe background" as pending. That item is folded into Phase 4 Session 1 because Phase 4's customer-and-table behavior cannot be visually validated against an empty scene — we need a rendered cafe first.

**What's settled going into Phase 4:**

- Save format: JSON envelope at `user://save.json`, legacy `.caf`/`.dat` import as a one-time bridge (Phase 3).
- Asset pipeline: `tool/build_tool -target godot` produces `build_godot/` with character atlases, furniture atlases, animation JSON, etc. (Phase 1b).
- Render foundation: `SpriteAtlas` class with O(1) per-character lookup; `main_scene.gd` + `main.tscn` boot path; `validate_assets.gd` 15-check headless validator (Phase 2a/2b).
- Cross-platform target unchanged: Windows/Mac/Linux/Android/iOS/web from one Godot codebase.

**What's still open going into Phase 4:**

- `Cafe.Tiles[].U1` → atlas region mapping. 28 distinct values in [29, 113] across the real fixture; only 37 entries in `mapTilesOffsets`. Indirection layer unknown. Resolution path: Session 1's hybrid empirical-then-Ghidra strategy.
- Wall sprite source. `CafeWall.U1` values 41, 87-93 in fixture; their atlas is unidentified (none of the seven currently-packed atlases are obviously walls). Resolution: investigate as a Session 1 sub-task.
- Per-tile pixel size. Cafe Dict coordinate values like 553, 603, 653 with 50-pixel deltas suggest `TILE_H = 50`, but unconfirmed. Resolution: empirical fit during Session 1.
- Customer spawn rate, order-wait duration, cook duration, XP/coin payouts. All Phase 4 game-logic constants. Resolution: Ghidra + `constants.bin.mid` parsing as needed in later sessions.
- `mapTiles` atlas packer in `tool/build_tool/main.go` — currently commented out; Phase 1b stopped at 7 atlases. Resolution: one-line uncomment in Session 1.

## Success criteria

The work is done when all of the following are true:

1. **Cafe boots visually.** `godot/project.godot` opens, runs, and shows the player's actual cafe layout from `playerCafe.caf` — recognizable floor, walls, and furniture in the right places.
2. **Customers loop.** Customer entities spawn at the cafe entrance, walk to a free seat, raise an order bubble, wait for the kitchen to finish, eat, pay, and leave. Money and XP increment.
3. **Furniture is placeable.** The player can buy a furniture item from `foodData.bin.mid` / `furnitureData.bin.mid` and place it on an empty tile. Save persists the placement.
4. **Headless regression.** `godot --headless --script res://validate_assets.gd` passes 17+ checks (15 existing + at least 2 new for cafe render + tick loop). `godot --headless --script res://test/test_save_round_trip.gd` continues to pass 207/0.
5. **CI green.** Every push runs both validators on a fresh Linux runner via `.github/workflows/godot-validation.yml`.
6. **Documentation closed.** `docs/rewrite-plan.md` marks Phase 4 done; `docs/handoff.md` regenerated; per-session devlog entries cover the RE work and architectural decisions encountered.

Phase 4 is "feature-complete enough for offline play." Online features (server upload, friend raids, getrandomgamestate) are explicitly deferred to Phase 5.

## Out of scope

- Server-side anything. `tool/server/` stays unchanged in Phase 4. Save state writes locally to `user://save.json`. The legacy `.caf`/`.dat` path is import-only.
- Friend raids, friend cafes, Facebook integration. Phase 5.
- Sound. The legacy SFX path is patched-out on the Android build (`src/lib/cpp/ZombieCafeExtension.cpp` SoundManager NOP) and Godot's audio is not yet wired. Phase 4 ships silent.
- iOS / web export validation. Phase 6.
- Performance tuning. The legacy game ran fine on 2011 ARM hardware; Godot 4 on a modern desktop has tens of thousands of FPS budget for this scale. If a hot path emerges, it lands in Phase 7+ as a refactor.
- Bit-perfect economy fidelity. Cook times within ±10%, payout amounts within ±1 coin of the legacy game are acceptable. The non-goal "bit-perfect behavioral fidelity with the 2011 binary" from `docs/rewrite-plan.md` applies.
- Japanese version (`CharactersJP`). Phase 4 targets EN only; JP roster integration is a Phase 4.5 or Phase 6 decision.

---

## 1. Architecture and data flow (umbrella)

```
                ┌──────────────────────────────────────────────────────┐
                │   Godot client — Phase 4                             │
                │                                                      │
  user://       │   ┌────────────────────────┐                         │
  save.json ◀───┼───┤  SaveV1 (Phase 3)      │  Dict in/out            │
                │   └────────────────────────┘                         │
                │                  │                                   │
                │                  ▼                                   │
                │   ┌────────────────────────┐                         │
                │   │  GameState (autoload)  │  authoritative live     │
                │   │   - playerSave: Dict   │  game state             │
                │   │   - playerCafe: Dict   │                         │
                │   │   - friendCafes: []    │                         │
                │   │   - tickAccumulator    │                         │
                │   └────────────────────────┘                         │
                │                  │                                   │
                │     ┌────────────┼────────────┬───────────────┐      │
                │     ▼            ▼            ▼               ▼      │
                │  ┌─────────┐  ┌─────────┐  ┌──────────┐ ┌─────────┐  │
                │  │ Cafe    │  │ Customer│  │ Kitchen  │ │ Economy │  │
                │  │Renderer │  │ System  │  │ System   │ │ System  │  │
                │  │(S1)     │  │ (S2)    │  │ (S3)     │ │ (S4)    │  │
                │  └─────────┘  └─────────┘  └──────────┘ └─────────┘  │
                │                                                      │
                │  ┌──────────────────┐  ┌─────────────────┐           │
                │  │ FurniturePlacing │  │ Character Mgmt  │           │
                │  │ System (S5)      │  │ System (S6)     │           │
                │  └──────────────────┘  └─────────────────┘           │
                └──────────────────────────────────────────────────────┘
```

**`GameState` autoload** (introduced Session 1, expanded each subsequent session) is the single canonical mutable copy of the loaded save Dict. Sub-systems read from and write to it; nobody else holds save fields. On tick, sub-systems read `GameState`, decide actions, mutate `GameState`. On save, `GameState` is handed to `SaveV1.save_save`. Same hub-and-spoke pattern the legacy game uses (`ZombieCafe::tick` operates on a single `Cafe*`).

**Sub-system signal bus.** Each sub-system exposes signals on `GameState` that other systems subscribe to. Customer arrives at table → `customer_seated` → Kitchen subscribes and starts cooking timer → `food_ready` → Customer subscribes and walks to fetch. No direct cross-system function calls; signal bus only. This keeps each sub-system testable in isolation (Session N can be exercised against a fake `GameState` without standing up the full chain).

**Tick model.** Every sub-system has a `tick(delta_seconds: float)` method. The autoload calls all sub-systems' `tick` from `_process(delta)`. Real-time clock updates land naturally; pause is `set_process(false)` on the autoload. Save format stores absolute timestamps for cooldowns (legacy convention, see `Date` fields in `CafeFurniture` and `Stove` from Phase 3 work).

## 2. Session breakdown

Phase 4 splits into **7 sessions**, each with a concrete acceptance criterion. Order is forced — earlier work is load-bearing for later work.

### Session 1 — Cafe rendering from save Dict *(this spec details, plan to follow)*

Goal: when the project boots, the rendered scene shows the player's actual cafe layout — floor, walls, furniture in their stored positions. No tick logic, no customers. Closes Phase 2b's pending cafe-background item as prerequisite work for Sessions 2+.

Deliverables:
- `tool/build_tool/main.go` — uncomment `serialization.PackTextures(... mapTiles ...)` line.
- `godot/scripts/cafe_renderer.gd` — new `class_name CafeRenderer` (extends `RefCounted`). Single public method `render(parent: Node2D, cafe_dict: Dictionary, atlases: Dictionary) -> int` returning sprite count. Three internal passes (tiles → walls → furniture); each takes the relevant atlas and emits `Sprite2D` children to `parent`.
- `godot/scripts/main_scene.gd` — `assemble(mode: String)` accepts `"grid"` (existing boxer-human grid) or `"cafe"` (new). `_ready()` defaults to `"cafe"`. The headless validator continues calling `assemble("grid")` for the existing 27-piece check and adds a new `assemble("cafe")` check.
- `godot/assets/atlases/mapTiles.png` + `mapTiles.json` — sample copy of the build-tool output for the validator.
- `validate_assets.gd` — 16th check: `assemble("cafe")` produces ≥1925 floor-tile Sprite2Ds + ≥23 cafe-object Sprite2Ds, every Sprite2D has a non-null texture.

Acceptance: `godot/project.godot` shows the player's cafe; `validate_assets.gd` passes 16/16; `test_save_round_trip.gd` still 207/0.

**RE budget for Session 1:** 45 minutes empirical iteration on the `Tiles[].U1` → atlas-region mapping before escalating to Ghidra. Wall atlas investigation runs in parallel (different unknown, different resolution path).

### Session 2 — Customer spawn + walk to seat

Goal: a customer entity spawns at the cafe entrance every N seconds, walks to a randomly-chosen free seat using a path-tween, and idles there. No orders yet; the customer just sits.

Deliverables:
- `godot/scripts/game_state.gd` — autoload singleton holding the loaded save Dicts. Initial form: just storage + reload-from-disk + flush-to-disk. Future sessions extend.
- `godot/scripts/systems/customer_system.gd` — first sub-system. Spawn timer + `Customer` actor class + path-tween-to-seat behavior. Reads `Cafe.Tiles[]` to find seats (CafeFurniture with `FurnitureType=2` per legacy convention; verified via Ghidra spot-check).
- `godot/scripts/systems/customer_actor.gd` — per-customer node. Visual: assemble character pieces from the available character roster (read from `SaveGame.PreStrings` / character roster — TBD how characters are referenced). Motion: tween position from spawn to seat over ~3 seconds.
- `validate_assets.gd` — 17th check: spawn one customer, run a fake tick for ~3 seconds, assert it reaches its seat (final position matches a free seat tile).

Acceptance: open project, see cafe + spawned customer walking to seat over time. Validator passes 17/17.

**RE work expected:** seat detection in `CafeFurniture.FurnitureType` (which numeric value = seat?), path-tween parameters (legacy uses `PathTween` per `ZombieCafeExtension.cpp`'s crash sites — see what fields the constructor takes).

### Session 3 — Order + kitchen state

Goal: seated customer raises an order bubble. Kitchen subsystem assigns the order to a stove; stove cooks for some duration; food appears on serving counter. Customer walks to fetch food, returns to table, "eats" (timer), then leaves. Money/XP do not yet update — that's Session 4.

Deliverables:
- `godot/scripts/systems/kitchen_system.gd` — stove state machine (idle → assigned → cooking → done). Serving counter slot tracking. Read `Cafe.Tiles[].U5/U7/U9.Furniture.Stove` and `.ServingCounter` for the in-game state machine's persistent fields.
- Order bubble visual on customer actor.
- Cook-duration values from `cookbookData.bin.mid.json` or Ghidra (probably the latter — cookbookData is only metadata).
- `validate_assets.gd` — 18th check: full customer cycle in fake ticks (spawn → seat → order → cook → eat → leave) finishes within N simulated seconds without errors.

Acceptance: customer cycles end-to-end. Cook duration plausibly matches legacy.

### Session 4 — Payment + XP loop close

Goal: customer leaving pays N coins; player XP increments; level-up triggers when XP threshold crossed. Save Dict's money/XP fields update. Reload from `user://save.json` proves persistence.

Deliverables:
- `godot/scripts/systems/economy_system.gd` — coin/XP arithmetic, level-up table from data file or Ghidra.
- `GameState.save_now()` flushes to disk. Auto-save every N seconds.
- HUD overlay showing money + XP + level (basic, no animations).
- `validate_assets.gd` — 19th check: run customer cycle, assert money increased and matches expected formula.

Acceptance: closed customer loop with persistent state changes. Reloading the project picks up the new money total.

### Session 5 — Furniture placement (interactive)

Goal: player can spend money to buy a furniture item from a menu and click an empty tile to place it. Tile becomes occupied; subsequent customers may sit there. Save persists.

Deliverables:
- `godot/scripts/systems/placement_system.gd` — UI flow + tile-click detection + collision check (no two pieces of furniture on the same tile slot).
- Furniture catalog UI (read `furnitureData.bin.mid.json`; price comes from data file or Ghidra).
- `validate_assets.gd` — 20th check: programmatic place-a-table, assert tile slot updated and money decreased.

Acceptance: full place-a-table interaction works. Saved cafe matches.

### Session 6 — Character roster

Goal: player can buy a new character from the unlocked roster, level them up by feeding XP, and deploy them as workers (cooks, servers — exact roles TBD by the legacy game's mechanics). Character pieces render via the existing `SpriteAtlas` get_character_pieces.

Deliverables:
- `godot/scripts/systems/character_system.gd` — roster CRUD + level-up + role assignment.
- Character buy UI.
- `SaveGame` Dict's character section — figure out where in the Phase 3 Dict the character roster lives and how to add/level/assign.

Acceptance: buy a new character, see them appear in the cafe doing a job. Save persists.

### Session 7 — Phase 4 close-out

Goal: devlog + handoff + rewrite-plan update; Phase 4 marked done.

Deliverables:
- `docs/devlog/2026-XX-XX-phase-4-game-tick.md` — narrative covering the per-session journey, the RE work, the architectural decisions encountered.
- `docs/handoff.md` — regenerate, recommend Phase 5 next.
- `docs/rewrite-plan.md` — Phase 4 status flip from `*(in progress)*` to `*(done, 2026-XX-XX)*`. Open-questions list updated.

Acceptance: documentation in sync with code; Phase 5 (online features) is the next active phase.

---

## 3. Session 1 detailed design

(The rest of this document is Session 1 specifics. Sessions 2-7 will get their own implementation plans when their predecessors land.)

### 3.1 Components

**`tool/resource_manager/serialization/godot.go`** — one-line addition to `packGodotAtlases`. The function currently calls `PackGodotTextures` for the 7 packed atlases (recipeImages, recipeImages2, furniture, furniture2, furniture3, plus the 2 characterParts atlases via `PackGodotCharacters`). Add:

```go
PackGodotTextures(filepath.Join(imagesIn, "mapTiles"), out_directory, 1.0)
```

`PackGodotTextures` already handles atlases with heterogeneous-size source PNGs (the `furniture` atlas mixes various sprite sizes; mapTiles' 28×49 to 810×1024 range is wider but the same code path). It emits `<name>.png` + `<name>.offsets.json` — Phase 1b Godot format with Type=2 offsets that carry a `Name` field set to the source filename including extension (verified against the existing `furniture.offsets.json`: keys look like `"42.png"`). For mapTiles the region keys will be `"0.png"`, `"1.png"`, ..., `"36.png"`. The existing `SpriteAtlas.get_region(key)` API consumes these keys directly. Note: the commented-out line in `tool/build_tool/main.go:63` is for the legacy CCTX-based Android build, not the Godot path; ignore it. Phase 1b deliberately moved Godot asset packing into `serialization.BuildGodotAssets` and that's where the new line goes.

**`godot/scripts/cafe_renderer.gd`** — new `class_name CafeRenderer` (extends `RefCounted`).

```gdscript
class_name CafeRenderer
extends RefCounted

const TILE_W: int = 50
const TILE_H: int = 50

# render(parent, cafe_dict, atlases) -> total sprite count
#   parent: Node2D to receive Sprite2D children
#   cafe_dict: parsed Cafe Dict (Phase 3 LegacyLoader output)
#   atlases: { "tiles": SpriteAtlas, "walls": SpriteAtlas, "furn": SpriteAtlas }
static func render(parent: Node2D, cafe_dict: Dictionary, atlases: Dictionary) -> int:
    var count: int = 0
    count += _render_tiles(parent, cafe_dict, atlases["tiles"])
    count += _render_objects(parent, cafe_dict, atlases["walls"], atlases["furn"])
    return count

# Three internal helpers:
#   _render_tiles — for each Tiles[i], place a floor sprite at (tx*TILE_W, ty*TILE_H)
#   _render_objects — for each non-null U5/U7/U9, dispatch on Type (1=furn, 2=wall)
#   _atlas_region_for_tile_u1 — the U1→region lookup; the RE-risk function
```

`_atlas_region_for_tile_u1` starts as a hypothesis the implementation iterates on. Initial form:

```gdscript
static func _atlas_region_for_tile_u1(u1: int) -> String:
    # Returns the atlas region key (e.g., "5.png") to look up via
    # SpriteAtlas.get_region(). Phase 4 Session 1 hypothesis under test —
    # if no hypothesis pans out within the time budget, fall back to
    # `u1 % 37` and accept visual incoherence until Ghidra escalation.
    # See docs/superpowers/specs/2026-05-10-phase-4-game-tick-design.md §3.4
    return "%d.png" % (u1 % 37)  # placeholder — will be replaced
```

**`godot/scripts/main_scene.gd`** — `assemble(mode: String = "cafe")` dispatch. The existing 27-piece grid lives at `assemble("grid")`; cafe rendering at `assemble("cafe")`. `_ready()` calls `assemble("cafe")` so booting the project shows the cafe by default. The pose-from-animation work stays under `"grid"` mode.

### 3.2 Data flow (Session 1)

1. `main_scene._ready()` calls `assemble("cafe")`.
2. `assemble("cafe")` reads `res://test/fixtures/save/playerCafe.caf` bytes (the existing Phase 3 fixture).
3. `LegacyLoader.parse_cafe_bytes(bytes)` → Dict. (Signature is `(data: PackedByteArray) -> Dictionary` — the version byte is read out of the data itself; no separate version arg.)
4. Three `SpriteAtlas` instances loaded:
   - `mapTiles` from `res://assets/atlases/mapTiles.png` + `mapTiles.offsets.json`
   - `furniture` from `res://assets/atlases/furniture.png` + `furniture.offsets.json` (existing, used by Phase 2b)
   - Walls — TBD; pending Session 1's wall-atlas investigation (§3.5)
5. `CafeRenderer.render(self, cafe_dict, atlases)` returns sprite count.
6. Validator's 16th check asserts the count is in expected ranges.

### 3.3 Coordinate system

`Cafe.MapSizeX = 35`, `Cafe.MapSizeY = 55`. `Cafe.Tiles[]` length 1925 = 35 × 55 confirms row-major order. Tile at index `i`:

```
tx = i % MapSizeX   # 0..34
ty = i / MapSizeX   # 0..54
screen_x = tx * TILE_W
screen_y = ty * TILE_H
```

`TILE_W = TILE_H = 50` is a hypothesis from CafeObject `U2` values (553, 603, 653 — 50-pixel deltas). Confirmation during implementation: render with this assumption, eyeball whether walls and floor tiles align. Adjust the constant if visibly wrong.

CafeObject `U2` and `U3` fields hold the absolute screen Y and parent tile index; the Y matches `ty * TILE_H + offset` where `offset` is the in-cell vertical position. CafeObjects can be 0 (back wall), `TILE_H/2` (mid), or `TILE_H` (front). Session 1 starts by ignoring the offset and placing every CafeObject at `(tx * TILE_W, ty * TILE_H)`; refine if the visual is broken.

### 3.4 RE strategy: `Tiles[].U1` → atlas-region mapping

**Hypothesis space, ordered by test cost:**

1. `region = U1 - 29`. Smallest U1 in the fixture is 29. If U1 is a sequential type code starting from 29, this maps cleanly to atlas regions [0, 36] for U1 ∈ [29, 65]. Out of range for U1 = 113. **Test:** render with this; check if U1=51 (most common) lands on a sensible floor texture and U1=113 produces an obvious-mismatch error.

2. `region = U1 mod 37`. **Test:** likely produces visual chaos (51 % 37 = 14, 113 % 37 = 2) but cheap to confirm.

3. `region = U1 & 0x3F` (low 6 bits) with `U1 & 0x40` as flip-x flag. 7-bit range (0-127) covers all observed U1s. **Test:** 51 & 0x3F = 51 (out of range — only 37 regions exist), so this needs further intersection — maybe `region = (U1 & 0x3F) - 29`. Convoluted but possible.

4. **Frequency-rank correspondence.** Map most-common U1 → most-likely floor texture (region whose width + height suggests "tileable floor"). Fixture: U1=51 (368 occurrences), 68 (362), 70 (225), 69 (76), 73 (67) are the top 5; 23 distinct U1s appear ≤3 times. Atlas regions 0 (810×1024 — backdrop, not a tile) and 4-5 (28×49, 30×49 — small) are size candidates. **Test:** rank both lists, line them up, render.

5. **Hardcoded LUT.** Construct from inspection — manually map each of 28 distinct U1 values to a plausible region by looking at what each PNG depicts. Tedious but bounded.

6. **Ghidra escalation.** Open `libZombieCafeAndroid.so`. Find `Cafe::draw` or the tile-rendering function. Look for an array indexed by `Tile.U1` or a switch table. Trace to the offsets table. Extract the LUT, transcribe it to GDScript.

**Time budget:** 45 minutes on hypotheses 1-5. If no recognizable cafe emerges, escalate to Ghidra. The escalation isn't a failure — it's the planned fallback path. Same risk-management pattern as Phase 1b's animation parser ("decode the structurally-confirmed skeleton, preserve the opaque tail, name what the spot-check confirms"); we ship what we can verify, defer what we can't.

### 3.5 Wall atlas investigation

`CafeWall.U1` values 41, 87-93 in the fixture. The seven currently-packed atlases (`characterParts`, `characterParts2`, `recipeImages`, `recipeImages2`, `furniture`, `furniture2`, `furniture3`) don't obviously source walls.

**Investigation steps in Session 1:**

1. Parse each existing offsets manifest's region IDs and check against the observed wall U1 values [41, 87-93]. Quick grep across the JSONs.
2. If no match, search `src/assets/images/` for directories whose name suggests walls: `cafeWalls`, `walls`, etc. List `.cct.mid` files like the `mapTiles.cct.mid` we already found.
3. If a wall-source directory exists with a corresponding `*Offsets.bin.mid`, the resolution is the same one-line uncomment pattern as `mapTiles`.
4. Worst case: walls live inside an already-packed atlas under a non-obvious key range. Trace via Ghidra (same fallback as the U1 mapping work).

**Out of scope for Session 1:** wall decoration positioning. `CafeWall.HasDecoration = true` with a nested `DecorationObject` (recursive `CafeObject`) is rare in the fixture; Session 1 renders the wall body and leaves decorations as a Session 1.5 follow-up.

### 3.6 Test / validation

**Headless validation (`validate_assets.gd` 16th check):**

```gdscript
func _validate_cafe_render() -> void:
    var bytes := FileAccess.get_file_as_bytes("res://test/fixtures/save/playerCafe.caf")
    var cafe_dict := LegacyLoader.parse_cafe_bytes(bytes)
    var node := Node2D.new()
    var atlases := { ... }  # load tiles, walls, furn
    var count := CafeRenderer.render(node, cafe_dict, atlases)
    assert(count >= 1925, "expected ≥1925 sprites (1925 floor tiles + at least 23 objects)")
    var floor_count := 0
    var object_count := 0
    for child in node.get_children():
        assert(child is Sprite2D)
        assert(child.texture != null)
        if child.has_meta("floor"):
            floor_count += 1
        else:
            object_count += 1
    assert(floor_count == 1925)
    assert(object_count >= 23)  # the 23 non-trivial tiles in the fixture
    node.queue_free()
```

**Visual confirmation:** run the GUI Godot binary on `project.godot`. Scene boots into `assemble("cafe")` mode. Eye-test that the rendered cafe resembles what `playerCafe.caf` describes (35 columns × 55 rows of tile textures + visible walls + visible furniture pieces).

**Layer 1 regression:** all existing 15 validator checks + 207 save round-trip tests still pass. Critical because Session 1's `assemble(mode)` refactor touches the existing scene-construction code path.

### 3.7 Session 1 task list (preview)

Implementation plan (separate doc per Phase 3 convention) will include:

1. Add the `PackGodotTextures(... mapTiles ..., 1.0)` line in `packGodotAtlases`. Run `build_tool -target godot`, verify a 38th + 39th file (`mapTiles.png` + `mapTiles.offsets.json`) appear in `build_godot/assets/atlases/`. Copy a sample of each into `godot/assets/atlases/` for the headless validator.
2. Refactor `main_scene.gd` to `assemble(mode)` dispatch; preserve grid mode under regression tests (the existing `_validate_main_scene` 15th check exercises grid mode and must keep passing).
3. Implement `CafeRenderer.render` floor-pass with placeholder LUT (`u1 mod 37`).
4. Implement `_atlas_region_for_tile_u1` empirical iteration loop (45-minute budget — see §3.4).
5. Implement `CafeRenderer.render` walls-pass, including the wall atlas investigation sub-task (§3.5).
6. Implement `CafeRenderer.render` furniture-pass against the existing `furniture` atlas.
7. Add the 16th validator check.
8. Re-run all existing validators + save round-trip tests; confirm no regressions.
9. Visual confirmation in the GUI Godot.
10. Commit (one grouped commit per project memory).

The plan doc will break each into Task entries with checkboxes per `subagent-driven-development` convention.

---

## 4. GDScript-specific gotchas to expect (Phase 4 broad)

Anticipated friction across the phase:

- **`Sprite2D` z-ordering.** Cafe rendering needs floor < walls < furniture. Either use `z_index` per sprite (cheap) or organize children into separate `Node2D` parents per layer (cleaner). Default to `z_index` in Session 1.
- **Tween pooling.** Customer pathfinding spawns lots of tweens. Godot 4 has `create_tween()` which auto-cleans, but spawning thousands per second can leak — pool if customer count gets high. Not a Session 1 concern.
- **`@onready` vs constructor injection.** Sub-systems prefer dependency injection (passed `GameState` ref) over `@onready get_node("/root/GameState")` for testability. Same pattern as Phase 3's GDScript (LegacyLoader's static methods plus passed-in BinaryReader).
- **Per-frame work in `_process`.** Avoid Dictionary allocation in hot ticks. Mutate-in-place where possible. Probably moot at the scale Zombie Cafe runs at.
- **Save-during-tick races.** If auto-save fires while a sub-system is mid-mutation, the persisted state could be inconsistent. Phase 4 ships single-threaded — `_process` runs to completion before save fires from the same thread — so this is moot today, but worth flagging for any future thread-pool work.

These will be discovered and documented in per-session devlogs as Sessions 1-7 progress.

## Verification plan

Per session (rolled up at Phase 4 close):

1. **After Session 1:** `assemble("cafe")` produces a recognizable cafe in GUI Godot. Headless validator passes 16/16. Save round-trip 207/0. RE work for U1 mapping documented in the Session 1 devlog (whether resolved empirically or via Ghidra escalation).
2. **After Session 2:** customer spawns and walks to a seat in real time. 17/17 validator. Customer behavior matches a brief eye-test against the legacy device build.
3. **After Session 3:** full customer cycle (spawn → seat → order → cook → eat → leave) in fake ticks. 18/18 validator.
4. **After Session 4:** money/XP increment per cycle and persist across reload. 19/19 validator.
5. **After Session 5:** interactive furniture place. 20/20 validator.
6. **After Session 6:** character roster CRUD + deployment. 21/21 validator.
7. **After Session 7:** all docs updated.

Each session ships as 1-2 commits. `git revert` is the per-session rollback path. Per-phase rollback is a `git revert` of each session's commits in reverse order; the legacy Android APK build path stays untouched throughout (Phase 7 retires it, not Phase 4).

## Rollback

Phase 4 only touches the Godot client and the build-tool's `main.go` (one-line uncomment in Session 1). Reverting any session leaves the legacy APK and the Phase 3 save format intact. The `mapTiles` packer re-enable is the only build-tool change with non-trivial side effects (adds a new atlas to `build_godot/`); reverting it just removes the atlas from the output tree.

The Phase 3 save format contract is preserved end-to-end: every Phase 4 sub-system reads from and writes to the Phase 3 Dict shape. Save files written by a Phase 4 client load cleanly in the Phase 3 client (no game-state fields are added — they live in the existing Phase 3 fields, possibly with new sub-keys). If a future format extension forces an envelope `version` bump, that's a Phase 3 migration concern (the dispatcher in `save_v1.gd` exists for exactly this), not a Phase 4 design decision.
