# Session Handoff — Zombie Cafe Revival

**Last updated:** 2026-05-10 (after Phase 4 Sessions 1 + 1.5 + 2 land; previous: same-day Phase 3 close-out, 2026-04-25 Phase 3 Session 1, 2026-04-19 Scudo crash hunt, 2026-04-12 IAP bypass)
**Purpose:** quick orientation for a fresh session. Self-contained; read this plus `docs/devlog/2026-05-10-phase-3-save-format.md` and `docs/rewrite-plan.md` and you should be able to continue without re-reading the full devlog history.

---

## The project in one paragraph

**Zombie Cafe Revival** is a reverse engineering + rewrite project for Capcom's 2011 mobile game *Zombie Cafe*. Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff)) is continuing from Airyz's original Android APK patching work (see `README.md`) by rewriting the client as a **Godot 4 game** that reuses the existing Go asset pipeline and the Cloudflare Workers backend. The Go tooling decodes/encodes every binary format the game uses; the Godot client renders and simulates on top of that. Goal is cross-platform (Windows/Mac/Linux/Android/iOS/web) via Godot's export targets. The original ARMv7 `libZombieCafeAndroid.so` is used only as reference documentation, not as runtime code.

---

## Where we are

**Phase 4 Sessions 1, 1.5, and 2 are landed.** Opening `godot/project.godot` and pressing Run shows the player's actual cafe rendered isometrically from `playerCafe.caf` (1925 floor tiles + 29 cafe-objects from the saved layout) plus a customer entity that spawns at the cafe's "north" tip every 5 seconds, walks down-and-right to a free chair via manual lerp motion, sits 2 seconds, and despawns. Validator at 17/17, save round-trip 207/0. Three of seven Phase 4 sessions remain: order + kitchen state, payment + XP, interactive furniture placement, character roster, close-out.

**Phase 3 is closed.** Five real device fixtures round-trip byte-identically through pure GDScript; the JSON envelope at `user://save.json` is the going-forward format; CI runs the test runner on every push. The Go ↔ Godot integration question settled in favor of option 3 (GDScript port). See `docs/devlog/2026-05-10-phase-3-save-format.md`.

**Phase status by phase:**

- **Phase 0a (done):** file_types validation harness. Round-trip tests for every format passing.
- **Phase 0b (done, including real fixtures):** lossless parsers and symmetric writers for every binary format. Real device fixtures live under `tool/file_types/testdata/` — `playerCafe.caf` + `BACKUP1.caf` (Cafe), `globalData.dat` + `BACKUP1.dat` (SaveGame, with `Trailing []byte` preservation field), `ServerData.dat` (FriendCafe). All round-trip byte-identically.
- **Phase 1a (done):** `-target godot` flag on `build_tool`.
- **Phase 1b (almost fully done):** atlas packing, animation parser, six opaque binary parsers, debug print sweep, atlas-only output (66% size reduction). `mapTiles` atlas added in Phase 4 Session 1 (8th atlas in the Godot tree — turned out to be the world-map overview, useful for Phase 5). Pending: `constants.bin.mid` (mixed endian), `font3.bin.mid` (custom bitmap format). Bitmap font conversion (item 4) and social icon copy (item 7) also pending but low-priority cosmetic.
- **Phase 1 validation (done):** 17/17 validation checks passing via `godot/validate_assets.gd` + GitHub Actions CI.
- **Phase 2a (done):** `SpriteAtlas` with O(1) per-character piece lookup.
- **Phase 2b (done):** `godot/main.tscn` + `main_scene.gd` + the pose function reading `sitSW.json`. Cafe background closed in Phase 4 Session 1 (was previously deferred).
- **Phase 3 (done, 2026-04-25 → 2026-05-10):** Pure GDScript port of the Go save-family parsers and writers. 4 sessions, 207/0 in CI.
- **Phase 4 (in progress, 2 of 7 sessions + Session 1.5 polish):**
  - **Session 1 (done, `705a760b`):** Cafe rendering from save Dict via `CafeRenderer` (floor + walls + furniture). All elements share the existing `furniture` atlas — Session 1's RE finding was that the umbrella spec's "mapTiles holds floor tiles" hypothesis was wrong (mapTiles is the world-map overview view used by Phase 5). Direct lookup `region = "%d.png" % U1`.
  - **Session 1.5 (done, `576af897`):** Iso projection. Session 1 used Cartesian `(tx*50, ty*50)` which produced visible zigzag along long pavement edges; Session 1.5 corrected to `((tx-ty)*50, (tx+ty)*25)` so diamond edges chain into continuous lines. Camera2D moved to `(-418, 1153)` zoom `0.25` to fit new bounds. Plus `cb556725` uncrops the customer sprite by moving spawn from `(0, -100)` to `(0, 0)`.
  - **Session 2 (done, `2276edf2` + fix commits `a38c8065` + `cf48c821`):** `GameState` autoload + `CustomerSystem` + `CustomerActor`. Single concurrent customer; `tick(delta)` driven from `main_scene._process`. Reads `Cafe.Tiles[].U5/U7/U9.Furniture.FurnitureType == 3` for chairs (umbrella spec said `=2` but `cafe.go:36` confirms `2=ServingCounter`). Two follow-up fix commits resolved blank-scene issues — see Gotchas.
  - **Sessions 3-7 remain:** order + kitchen state, payment/XP, interactive furniture placement, character roster, close-out.
- **Phase 5 (unblocked):** online features. Server upload of binary saves now plumbable against the GDScript writer (`write_save_game(dict) -> PackedByteArray`).

**Legacy APK on hardware is stable.** The 2026-04-19 session tracked down the `Scudo: corrupted chunk header` crashes that had been firing every few minutes. Root cause: two sibling off-by-one bugs in the game's JNI MD5 wrappers (`javaMD5String+102` and `javaMD5Data+126`), both writing `\0` one byte past their `new char[32]` allocation. Fix is a 1-byte patch at each site flipping `movs r3, #0x20` → `movs r3, #0x1F` so the terminator lands at `buf[31]` in-bounds. A separate Bug 1 (`SoundManager.playSound → MediaPlayer.release → RefBase::decStrong → scudo_free` on every character SFX) was initially worked around by NOPing `javaStartEffect+50`, but with the source corruption from javaMD5 fixed the SFX path was provably clean — the NOP was reverted in `2ebcfc35` to restore character SFX. See `docs/devlog/2026-04-19-scudo-crash-hunt.md` for the diagnostic trail. Validated stable on a Samsung Note 20 Ultra (Android 13) for multi-minute raid sessions.

**Legacy APK toxin IAP is bypassed for unlimited late-game access.** `src/smali/com/capcom/billing/SmurfsBilling.smali` patched so that triggered-by-low-toxin slot picks fake successful purchases by reading `ItemName0` from the Intent and calling `ZombieCafeAndroid.boughtToxin(productID)`. The Activity-swap cycle stays intact so the native shopping state machine clears cleanly. The HUD toxin icon ("store page" entry) still does nothing — confirmed via smali probe instrumentation that the native handler has zero JNI calls; future work there requires Ghidra on `libZombieCafeAndroid.so`. See `docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md` Findings section.

**Facebook invite-friends rebrand (`f23cef1a`)** points the dialog at `https://github.com/edbuildingstuff` and adds a back-button-dismissable WebView fix (was unkillable due to a threading bug in the original FB SDK).

**Nothing is broken.** Full workspace builds clean (`file_types`, `resource_manager`, `build_tool`, `cctpacker`, `dump_legacy_fixtures` native; `server` under `GOOS=js GOARCH=wasm`). All Go tests green. Headless Godot validation passes 17/17. Phase 3 save round-trip runner passes 207/0. Pavement edges in the rendered cafe chain as continuous diagonal lines (iso); customer sprite is fully visible on spawn.

---

## What to do next

### Option A — Phase 4 Session 3: order + kitchen state *(recommended)*

The next vertical slice in Phase 4. Sessions 1-2 established the architectural pattern (`GameState` autoload + per-system `tick(delta)` + signal bus + `CustomerActor` lifecycle); Session 3 extends it to the customer-order interaction:

- Customer reaches a chair (Session 2 done) → raises an order bubble (new visual on `CustomerActor`).
- `KitchenSystem` (new sub-system) tracks stove state (idle / assigned / cooking / done). Reads `Cafe.Tiles[].U5/U7/U9.Furniture` for `FurnitureType == 1` (Stove) and `== 2` (ServingCounter) — both confirmed via `cafe.go:36`.
- A stove "cooks" for some duration (Phase 4 RE — likely needs Ghidra on `libZombieCafeAndroid.so` to find the cook-duration table; alternatively `cookbookData.bin.mid.json` may carry it).
- When cooking finishes, food appears on a serving counter; customer walks to the counter, fetches food, returns to seat, "eats" (timer), then leaves (existing despawn logic).

**Per the Phase 4 spec template (sessions get their own implementation plans),** start by writing `docs/superpowers/plans/2026-05-XX-phase-4-session-3-order-kitchen.md` mirroring the Session 2 plan structure. Open questions to resolve early in the plan-writing:

- What's the cook duration? (`cookbookData.bin.mid.json` first, then Ghidra)
- How does the customer know what to order? (random from menu, or driven by a save field?)
- Where does the served food appear visually? (sprite from furniture atlas, indexed by what?)

The Session 1 + 2 file structure is the template (`scripts/systems/<system>.gd` + autoload integration + 18th validator check).

### Option B — Phase 1b stragglers: `constants.bin.mid` or `font3.bin.mid`

Both deferred during the Phase 1b megasession because their formats resist quick analysis. `constants.bin.mid` may actually contain Phase 4 game-balance constants (cook durations, customer spawn rates, XP curves, payment formulas) — which would make it directly relevant to Sessions 3-4. Investigating its structure could unblock or accelerate Session 3.

- **`constants.bin.mid`** (9789 bytes): mixed-endian, first 12 bytes look like BE int32s (`1000, 10000, 3000`), subsequent floats only decode under LE. Differential analysis across similar files OR a Ghidra pass would help.
- **`font3.bin.mid`** (2533 bytes): custom bitmap font format — NOT standard BMFont. Would need its own RE investigation.

### Option C — Multi-customer + A* pathfinding (Session 2.5)

Session 2 is intentionally minimum-viable: max 1 concurrent customer; linear lerp passes through walls. A Session 2.5 could lift these:
- Track multiple `CustomerActor`s in `CustomerSystem` (currently a single `_active_customer`).
- Replace `_advance_walk`'s linear lerp with A* over the tile grid, blocking on `FurnitureType != 0` tiles.
- Spawn rate variation per save state (early-game vs late-game cafe).

Lower priority than Option A. Customer behavior IS visible — but it's also OK that Session 1 ships with one customer at a time; the architectural pattern is what Sessions 3+ extend.

**Recommendation:** **Option A (Session 3)**. Session 2 just closed and the architecture is fresh; the order/kitchen flow is what makes the cafe come alive (customers actually do something when seated). Option B's `constants.bin.mid` could be folded into Session 3 if the cook-duration RE wants those fields; Option C is polish and can land any time.

---

## Environment

Neither Go, Godot, nor `adb` is on `PATH` in Git Bash. Always invoke via full path.

| Tool | Full path |
|---|---|
| Go 1.26.2 | `/c/Program Files/Go/bin/go.exe` |
| Godot 4.6.2 (console) | `/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe` |
| Godot 4.6.2 (GUI) | same dir, `Godot_v4.6.2-stable_win64.exe` |
| `adb` (Android Platform Tools) | `/c/Users/edwar/AppData/Local/Android/Sdk/platform-tools/adb.exe` |

`apktool` and `jarsigner` **are** on `PATH` in Git Bash and can be invoked directly.

**Multi-device note:** Edward works on this project across at least two computers. The paths above are canonical — if a tool is missing on a machine, install it at the matching path (e.g. `winget install -e --id GodotEngine.GodotEngine` brings Godot to the WinGet location above) rather than localizing to a divergent path. See `memory/project_multi_device.md`.

Git user: **Edward Yang**. Main branch: **main**. Repo root: `/c/Users/edwar/edbuildingstuff/zombie-cafe-revival` on the current authoring device (path may vary by device — different from the 2026-04-19 doc's `/c/Users/edwar/Documents/edbuildingstuff/...`; both are valid on their respective machines).

---

## Key commands

### Build the Godot asset tree
```bash
"/c/Program Files/Go/bin/go.exe" run ./tool/build_tool -i src/ -o build_godot/ -target godot
```

### Run file_types tests
```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/...
```

### Run Phase 3 GDScript save round-trip tests
```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --path godot/ --script res://test/test_save_round_trip.gd
```

Expected: `=== Save round-trip results: 207 passed, 0 failed ===`, exit 0.

### Regenerate Layer 2 JSON oracles after Go parser changes
```bash
"/c/Program Files/Go/bin/go.exe" run ./tool/dump_legacy_fixtures
```

Reads `tool/file_types/testdata/*.{caf,dat}`, writes PascalCase JSON to `godot/test/fixtures/save/<name>.json` for the 5 real fixtures. Re-run the GDScript test runner afterwards to confirm Layer 2 still passes.

### Run Godot headless asset validation
```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --path godot/ --script res://validate_assets.gd
```

Expected: 17/17 checks pass. Includes 16th `_validate_cafe_render` (cafe rendered from `playerCafe.caf`: 1925 floor + ≥23 cafe-objects) and 17th `_validate_customer_spawn` (customer spawn → walk → seated, all in headless via direct `tick()` calls).

### Run the cafe + customer scene visually (GUI)
```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64.exe" godot/project.godot
```

Then F5 (or click Run). The full cafe should render iso-projected, centered in the viewport (`Camera2D` at `(-418, 1153)` zoom `0.25`). After ~1s a boxer-human head sprite spawns at the cafe's "north" tip and walks down-and-right to a chair over 3s; sits 2s; despawns; next customer 5s later.

### If adding new `class_name` scripts, rebuild Godot class cache first
```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --editor --quit --path godot/
```

### Build every workspace module
```bash
for m in file_types build_tool resource_manager cctpacker dump_legacy_fixtures; do
  (cd tool/$m && "/c/Program Files/Go/bin/go.exe" build ./...) || echo "$m FAILED"
done
(cd tool/server && GOOS=js GOARCH=wasm "/c/Program Files/Go/bin/go.exe" build ./...) || echo "server FAILED"
```

---

## Key files

| Path | What it is |
|---|---|
| `README.md` | Project overview, heritage, legacy APK build instructions |
| `docs/rewrite-plan.md` | Phased implementation plan, source of truth for done/pending substeps |
| `docs/devlog/` | Narrative entries spanning Phase 0a through Phase 3 close-out (2026-05-10) |
| `docs/superpowers/specs/` | Design specs — `2026-04-12-iap-debug-bypass-design.md`, `2026-04-11-animation-keyframe-parser-design.md`, `2026-04-25-godot-save-format-bridge-design.md` |
| `docs/superpowers/plans/` | Implementation plans — IAP bypass, animation keyframe parser, Phase 3 Sessions 1/2/3 |
| `tool/file_types/` | Go binary format parsers and writers. Every format has round-trip tests. |
| `tool/file_types/testdata/` | Real device fixtures pulled from the legacy APK |
| `tool/file_types/roundtrip_test.go` | Go round-trip tests, ~1306 lines |
| `tool/dump_legacy_fixtures/` | Standalone Go CLI emitting Layer 2 JSON oracles for the GDScript test runner |
| `tool/resource_manager/serialization/godot.go` | Godot asset build functions |
| `tool/build_tool/main.go` | Entry point with `-target` flag dispatch (android/godot) |
| `godot/project.godot` | Godot 4 project config. Has `[autoload] GameState=...` (Phase 4 Session 2). |
| `godot/main.tscn` | Main scene — Node2D root + Camera2D at iso center `(-418, 1153)` zoom `0.25`. `current=true` is critical (see Gotchas). |
| `godot/scripts/sprite_atlas.gd` | `SpriteAtlas` class — atlas + offsets JSON loader. `get_character_pieces(name)` returns 27 pieces in a fixed order (see Gotchas for index→part-name map). |
| `godot/scripts/main_scene.gd` | Main scene with `assemble(mode)` dispatch (`grid` legacy / `cafe` default). `_assemble_cafe` loads playerCafe.caf, instantiates `CafeRenderer`, wires `CustomerSystem`. `_process(delta)` drives `customer_system.tick(delta)`. |
| `godot/scripts/cafe_renderer.gd` | **NEW (Phase 4 S1+1.5):** `CafeRenderer.render(parent, cafe_dict, atlases)`. Three passes (floor / walls / furniture); iso projection via `_iso_position(tx, ty)` returning `((tx-ty)*50, (tx+ty)*25)`. All passes use the existing `furniture` atlas. `mapTiles` exists in build but is unused for cafe interior — Phase 5 world map will use it. |
| `godot/scripts/game_state.gd` | **NEW (Phase 4 S2):** `GameState` autoload. Holds `cafe_dict`, `occupied_seats`, signals `customer_spawned/seated/left`. Reachable as `GameState.foo` (runtime) or `/root/GameState` (path). |
| `godot/scripts/systems/customer_actor.gd` | **NEW (Phase 4 S2):** `CustomerActor` Node2D. State machine WALKING/SEATED/LEAVING. Manual lerp via `tick(delta)`; no Godot Tween. Placeholder visual: boxer-human pieces[16] = `head1.png` at 2× scale. |
| `godot/scripts/systems/customer_system.gd` | **NEW (Phase 4 S2):** `CustomerSystem` Node. Spawn timer + seat finder (`FurnitureType==3`) + active-customer tracker. SPAWN_POS is iso `(0, 0)` (north tip of cafe). Single concurrent customer; multi-customer is Session 2.5. |
| `godot/scripts/save/binary_reader.gd`, `binary_writer.gd` | GDScript primitives mirroring Go's `binary_reader.go` / `binary_writer.go`. Note: `read_string` returns `PackedByteArray`, not `String` (see Gotchas) |
| `godot/scripts/save/legacy_loader.gd`, `legacy_writer.gd` | GDScript port of the Go Cafe / SaveGame / FriendCafe parsers and writers |
| `godot/scripts/save/save_v1.gd` | Going-forward JSON envelope. `save_save` / `load_save` + `_to_json_safe` / `_from_json_safe` walker |
| `godot/test/test_save_round_trip.gd` | Phase 3 three-layer test runner. **207 PASS / 0 FAIL.** |
| `godot/test/fixtures/save/` | Real device fixtures (`.caf`/`.dat`) plus committed JSON oracles for Layer 2 |
| `godot/validate_assets.gd` | Headless asset validator, **17 checks**: 15 from Phase 1-2, +16th cafe-render (Phase 4 S1), +17th customer-spawn (Phase 4 S2). |
| `godot/assets/` | 5.5 MB sample assets for the validation script |
| `godot/assets/atlases/mapTiles.{png,offsets.json}` | NEW in Phase 4 S1 — the world-map overview atlas (37 regions: city streets, cafe buildings). Currently unused at runtime; reserved for Phase 5. |
| `build_godot/` | Gitignored. Full 18 MB Godot tree produced by `-target godot`. Regenerate with the build command above. |
| `godot/.godot/` | Gitignored Godot class cache. Regenerate with `--editor --quit` if a `class_name` import fails. |
| `.github/workflows/godot-validation.yml` | CI: Godot 4.6.2 download + class cache build + asset validator + save round-trip tests, all on every push |

---

## Gotchas

### Phase 4 specific

- **`Camera2D` must have `current = true` to activate.** A bare Camera2D in a tscn does NOT auto-activate in Godot 4 — the viewport stays at default `(0, 0)` and renders the upper-left of the world. Symptom: scene appears at upper-left corner instead of centered. Fix: add `current = true` to the tscn declaration. Verify via `Viewport.get_camera_2d()` returning non-null after the scene loads + processes one frame.
- **Don't use `;` comments inside tscn `[node ...]` blocks.** They appear to parse but properties declared after the comment may be silently dropped. Keep comments in `.gd` source instead.
- **`main_scene._ready` uses an `_assembled` bool, NOT child count.** Original Phase 2b `_ready` had `if get_child_count() == 0: assemble()` to prevent double-assembly when the validator pre-calls assemble before _ready fires. Phase 4 added a static Camera2D to main.tscn — child count is now 1, so the count-based guard skipped assemble entirely (blank scene). The fix: explicit `_assembled: bool` flag set by `assemble()`. If you add more static children to main.tscn, this still works.
- **Iso projection: `screen_x = (tx-ty)*50`, `screen_y = (tx+ty)*25`** for Cafe.Tiles[i] at `(tx, ty) = (i % MapSizeX, i / MapSizeX)`. `TILE_W = 100`, `TILE_H = 50`. Cafe pixel bounds: `x ∈ [-2700, 1864]`, `y ∈ [0, 2305]` for the 35×55 fixture grid. Camera at `(-418, 1153)` zoom `0.25` fits the whole cafe in the default 1152×648 viewport. `CafeRenderer._iso_position` is the helper; `CustomerSystem._seat_world_position` mirrors the same math.
- **`FurnitureType == 3` is a chair, NOT `== 2`.** The umbrella spec said `=2` but `tool/file_types/cafe.go:36` confirms `1=Stove, 2=ServingCounter`. Chairs are FurnitureType 3 (verified visually via `furniture/19.png` + 4 instances in playerCafe.caf fixture).
- **Headless `--script` mode does NOT initialize project autoloads during `_init`.** Validator checks that touch autoloads (e.g. `_validate_customer_spawn`) must run inside `_initialize()` — see `validate_assets.gd` `_early_failures` accumulation pattern. Also: scripts that import `GameState` at parse time fail to compile in `--script` mode; access via `get_root().get_node_or_null("GameState")` or `load("res://scripts/...").new()` instead. The runtime path (GUI Godot) is unaffected; autoloads ARE at `/root/<Name>` when running normally.
- **`mapTiles` atlas is the world-map overview, NOT cafe floor tiles.** Phase 4 Session 1's RE finding: the spec assumed `Cafe.Tiles[].U1` mapped via `mapTiles`. Visual inspection of `mapTiles/0.png` (810×1024 city street scene), `/1.png` (BACK button), `/2.png` (Enemy Cafe building) revealed it's the city overview atlas. Cafe interior tiles + walls + furniture all live in `furniture` atlas. Direct lookup `region = "%d.png" % U1`.
- **`CafeFurniture.U2` is the atlas key, not `U1`.** `CafeWall.U1` IS the atlas key (e.g., 41, 87-93). But for furniture, U1 is something else (a unique id?) and U2 is the atlas region (e.g., 19 for a chair). See `cafe_renderer.gd._emit_furniture_object`.
- **Boxer-human atlas piece order (for placeholder customer sprites):** `[0]=0-spacer, [1]=1x1, [2]=1x1_front, [3..7]=back_*, [8]=back_pelvis(spacer), [9..13]=back_arms/legs/torso, [14..15]=chairback(spacers), [16]=head1, [17..20]=front limbs, [21]=pelvis(spacer), [22..25]=front limbs, [26]=torso1`. Index 16 (head1.png, 93×90) is the largest visible piece. Indexes 0/8/14/15/21 are 3×3 spacers — invisible.
- **GDScript lint warnings in console are not bugs.** Phase 4 Session 2 has 11 console warnings (unused signals, integer division, unused parameter `frame_index`). All are intentional false positives or signature-stability artifacts. Cleanup is a 5-minute pass with `@warning_ignore` annotations; deferred indefinitely as cosmetic.

### Phase 3 specific

- **`read_string` returns `PackedByteArray`, not `String`.** The legacy `globalData.dat` carries `\r\0` byte suffixes inside `CharacterInstance.Name` strings. Godot's `String` cannot hold a NUL codepoint, so byte-faithful round-trip requires keeping bytes rather than decoding through `String`. `write_string` accepts both `PackedByteArray` and `String` via `Variant`. The JSON envelope (`save_v1.gd`) walks Dictionary trees and serializes each `PackedByteArray` as either a plain JSON string (clean UTF-8, no NULs) or `{"_b64": "<base64>"}` (anything else). When adding new string-bearing parsers, follow this convention. See `binary_reader.gd:125-132`.
- **Layer 2 cross-validation is lossy on string fields by design.** `_deep_equal` UTF-8-decodes the `PackedByteArray` side and compares to the JSON-parsed `String`. Layer 1 already proves byte-faithfulness; Layer 2's job is structural agreement. The diagnostic stderr "Unicode parsing error, some characters were replaced with � (U+FFFD)" during Layer 2 is expected — Godot's JSON parser substitutes embedded NULs with U+FFFD, and `_bytes_eq_string` compensates.
- **`JSON.parse_string` returns `float` for every number.** The `_deep_equal` helper coerces both sides to float-with-tolerance. Tolerance is both absolute and relative (`max(1e-6, max(abs(a), abs(b)) * 1e-6)`) because Go's `json.Marshal` of float32 emits the shortest decimal representation; reconstructed float64 differs from the original float32 by up to half a ULP at float32 precision (~1e-7 relative).
- **Migration dispatcher is scaffold-only at v1.** `CURRENT_VERSION = 1`. The negative-path tests cover v2 rejection (forward-only), missing-version rejection, missing-file rejection, non-object root rejection. Real migration files (`migrations/v1_to_v2.gd`) land when a real format change requires one — Phase 4+.
- **Godot CLI `--path` is sticky.** After `--path godot/`, any `--script` argument is resolved via `res://` from that project root. Always use `res://<path>`, never a system path.
- **`class_name` registry is lazy.** New scripts with `class_name` directives are invisible to other scripts until a project filesystem scan has run. After adding a new `class_name`, run `godot --headless --editor --quit --path godot/` once. Symptom: `Identifier "FooClass" not declared`.
- **Use the `_console` Godot variant for headless runs.** The plain `.exe` spawns a separate Windows console window that's hard to capture; the `_console` variant writes to stdout in-process.
- **GDScript has no exceptions** — no try/catch. The `BinaryReader` in `godot/scripts/save/binary_reader.gd` uses a `failed: bool` flag pattern: short reads call `push_error` and set `failed = true`; subsequent reads short-circuit. Top-level callers check `reader.failed` after parsing.
- **GDScript only allows one `class_name` per file.** `binary_reader.gd` and `binary_writer.gd` were intentionally split for this reason. New parser/writer modules should follow.
- **`PackedByteArray.encode_float` / `decode_float` are little-endian** in Godot 4 — matches the Go save format's float encoding. No translation needed.
- **`.uid` files for `class_name` scripts are tracked.** Convention from existing `main_scene.gd.uid`, `sprite_atlas.gd.uid`, `validate_assets.gd.uid`, the save scripts. When adding a new `class_name`, commit the auto-generated `.uid` sidecar alongside.
- **Windows autocrlf produces benign `.import` modifications.** `git status` may show every `*.import` file as modified after running Godot, with `git diff` only printing line-ending warnings. `git diff --ignore-all-space` confirms no real content change. Don't restage them; they'll resolve on the next genuine update.
- **Working directory drift.** Multi-step bash commands with `cd` can leave the shell in `tool/<module>/` from a previous build step. Always prefer absolute paths or `cd` back to repo root.
- **Go 1.26 `go vet` is stricter than 1.20.** The `go.mod` files declare Go 1.20 but the installed toolchain is 1.26. Format-string bugs that 1.20 let slide (like `%d` on a `bool`) fail `go test` under 1.26 because `go test` runs `go vet` first.
- **`server` module only builds for wasm.** It targets Cloudflare Workers and imports `syscall/js`. Native build fails with "build constraints exclude all Go files in syscall/js" — expected. Use `GOOS=js GOARCH=wasm`.
- **The pre-existing `cct_file.WritePackedTexture` had ~15 debug prints** — removed in Phase 1b polish. `build_tool -target godot` now produces two lines of output instead of dozens.
- **`adb install -r` does not restart a running game instance.** Always `adb shell am force-stop com.capcom.zombiecafeandroid` before `am start` when testing a smali patch. Confirm the process is dead with `adb shell pidof com.capcom.zombiecafeandroid` (exit code 1 = dead).
- **The `SmurfsBilling` IAP bypass depends on `BuyToxin` staying unchanged.** Don't patch `BuyToxin` directly — see `docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md` Findings section.
- **Samsung dropbox rotates tombstone content within hours.** `dumpsys dropbox --print` will show entries as `(contents lost)` almost immediately. Always capture via `adb bugreport`.
- **Samsung user builds silently refuse GWP-ASan unless `android:debuggable="true"`.** Verify via `adb shell run-as PKG cat /proc/$PID/maps | grep GWP-ASan`.
- **Verify runtime patches landed via `/proc/$PID/mem`, not by trusting `memcpyProtected`.** From a debuggable build: `adb shell run-as PKG dd if=/proc/$PID/mem bs=1 skip=$VA count=N | od -An -tx1`.

---

## Preferences and durable findings recorded

Memory files under `~/.claude/projects/<project-slug>/memory/` (auto memory location, separate from the repo):

- **`feedback_commit_style.md`** — always produce one grouped commit message per session, not split options. Don't offer "three commits or one" footers.
- **`feedback_no_coauthor_trailer.md`** — omit the `Co-Authored-By: Claude` trailer from commit messages on this repo.
- **`project_iap_bypass_findings.md`** — full story of what works and what doesn't for legacy APK IAP bypassing. Read before any future IAP-related smali patching.
- **`project_crash_sites_from_tombstones.md`** — root-cause story of the 2026-04-19 Scudo crash hunt. Read before any future crash investigation in the legacy APK.
- **`project_multi_device.md`** — handoff doc tool paths reflect what was installed on the authoring device. Missing tool on a new device → install at the same path, don't localize. Added 2026-04-25 after the Godot 4.6.2 install dance.

---

## Pointers for deeper reading

**Phase 4 (in progress):**
- `docs/superpowers/specs/2026-05-10-phase-4-game-tick-design.md` — Phase 4 umbrella design: 7-session breakdown, GameState autoload + signal bus pattern, sub-system map, RE strategy. Detailed Session 1 design.
- `docs/superpowers/plans/2026-05-10-phase-4-session-1-cafe-rendering.md` — Session 1 implementation plan (executed). 14 tasks, hybrid empirical/Ghidra RE protocol for the U1 mapping (resolved via empirical inspection — mapTiles isn't the floor source).
- `docs/superpowers/plans/2026-05-10-phase-4-session-2-customer-spawn.md` — Session 2 plan: `GameState` + `CustomerSystem` + `CustomerActor`. Reference template for Session 3.

**Phase 3 (closed):**
- `docs/devlog/2026-05-10-phase-3-save-format.md` — Phase 3 close-out: architecture decision, four-session arc, GDScript-specific surprises (`PackedByteArray` strings, `_b64` hybrid, `JSON.parse_string` floats), CI-as-done-signal.
- `docs/superpowers/specs/2026-04-25-godot-save-format-bridge-design.md` — Phase 3 design: GDScript port choice + JSON envelope schema + 4-session sequencing.
- `docs/superpowers/plans/2026-04-25-phase-3-session-1-cafe-round-trip.md` — Session 1 implementation plan (executed; useful as reference pattern for future session-scoped plans).
- `docs/superpowers/plans/2026-04-25-phase-3-session-2-savegame-friendcafe.md` — Session 2 plan + the architectural deviation discovery for `read_string`.
- `docs/superpowers/plans/2026-04-25-phase-3-session-3-oracle-envelope-ci.md` — Session 3 plan: oracle CLI, envelope walker, three-layer test integration, CI wiring.

**Phase 0-2:**
- `docs/devlog/2026-04-19-scudo-crash-hunt.md` — root cause of the Scudo crashes, GWP-ASan setup, runtime memory verification.
- `docs/devlog/2026-04-12-megasession-wrap.md` — IAP bypass session + 14 commits across three phase boundaries.
- `docs/devlog/2026-04-11-kickoff.md` — why Godot over the other rewrite paths.
- `docs/devlog/2026-04-11-phase-2a-sprite-atlas.md` — most relevant for continuing Phase 2b (now closed via Phase 4 S1's cafe render).
- `docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md` + `docs/superpowers/plans/2026-04-12-iap-debug-bypass.md` — IAP bypass design, Findings, and implementation plan. Only relevant if touching the legacy APK's billing path.

Fifteen devlog entries total under `docs/devlog/` — read them chronologically for the full story, or jump to the latest two or three for context on the immediate next step. Note: Phase 4 Sessions 1 + 1.5 + 2 don't yet have a devlog entry; that's deferred to Phase 4's close-out (Session 7), per the Phase 3 pattern.
