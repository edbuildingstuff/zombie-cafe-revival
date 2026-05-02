# Godot 4 Rewrite Plan

**Status:** Active — adopted 2026-04-11
**Owner:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))
**Inherits from:** Airyz's reverse engineering work (see [README.md](../README.md))

## TL;DR

We are rewriting the *Zombie Cafe* client as a **Godot 4** project that consumes the existing Go asset pipeline and Cloudflare Workers backend. The original `libZombieCafeAndroid.so` becomes *reference material*, not a runtime dependency. The smali shell and `LibZombieCafeExtension` runtime patcher are retired the moment a Godot boot path can load a save file and render a cafe.

## Goals

1. **Cross-platform.** One codebase, exports to Windows, macOS, Linux, Android, iOS, and the web. No per-platform forks.
2. **Preserve the data.** Save games, cafe layouts, characters, food, furniture, and textures round-trip through the existing Go tooling without loss. Old saves from the patched Android build remain loadable.
3. **Own the game loop.** Gameplay logic lives in GDScript (or C# where it matters), not in a reverse-engineered binary. Any future balance change, new character, or new mode is a normal code edit.
4. **Keep the server.** `tool/server/` stays as-is. The Godot client talks to the same `/v1/zca/*` endpoints the legacy APK talks to today.
5. **Document as we go.** Every non-trivial decision and every reversed piece of behavior gets a devlog entry so it can become a blog post later.

## Non-goals

- **Bit-perfect behavioral fidelity with the 2011 binary.** We'll match the original where it matters (economy, pacing, character stats), but we will not chase every undocumented edge case in the original `libZombieCafeAndroid.so`.
- **Shipping on the Play Store / App Store under the original name.** This is preservation, not commercial distribution.
- **Supporting the legacy patched-APK build in parallel forever.** It stays buildable during the transition and gets archived once the Godot client reaches feature parity.
- **Rewriting the Go tooling.** `tool/file_types/`, `tool/cctpacker/`, `tool/resource_manager/`, and `tool/build_tool/` are already well-factored for this use case. They may get a new entry point for exporting Godot-native assets, but the binary format code is untouched.

## What we keep vs. what we replace

| Component                                             | Status       | Notes                                                                                       |
| ----------------------------------------------------- | ------------ | ------------------------------------------------------------------------------------------- |
| `tool/file_types/` (Go binary format definitions)     | **Keep**     | Canonical source of truth for `SaveGame`, `Cafe`, `Character`, `Food`, `Furniture`, etc.    |
| `tool/cctpacker/` (CCTX codec)                        | **Keep**     | Used to decode the original texture atlases into PNGs the Godot importer can consume.       |
| `tool/resource_manager/` (JSON ↔ binary)              | **Keep**     | Human-readable editing workflow for game data.                                              |
| `tool/build_tool/` (APK build orchestrator)           | **Keep (legacy)** | Kept runnable during transition; retired once Godot client is at parity.              |
| `tool/server/` (Cloudflare Workers backend)           | **Keep & extend** | Fill in the currently-stubbed endpoints (`getgamestate`, proper friend metadata).      |
| `src/assets/` (extracted game assets)                 | **Keep as source** | Feed into the Godot import pipeline via the Go tooling.                                |
| `src/smali/` (decompiled Dalvik bytecode)             | **Reference, then delete** | Kept until the Godot client boots; then archived on a branch and removed from main. |
| `src/lib/armeabi/libZombieCafeAndroid.so`             | **Reference** | Not shipped with the Godot client. Used as an oracle for behavior we're unsure about.     |
| `src/lib/cpp/` (LibZombieCafeExtension)               | **Retire**   | Every patch it applies becomes unnecessary once the game is running in Godot.               |
| `src/AndroidManifest.xml`, `apktool.yml`, `debug.keystore` | **Retire** | Godot handles Android export directly.                                                |

## Phased plan

Each phase has a concrete "done" criterion. We do not start phase N+1 until phase N's criterion is met.

### Phase 0a — Validation harness for symmetric formats *(in progress)*

**Done when:** `go test ./tool/file_types/...` passes on the round-trip tests in `tool/file_types/roundtrip_test.go` for every format that currently has both a `Read*` and `Write*` function.

Why first: the Go binary format code had zero tests. Before we trust any part of it as the bridge between old saves and the Godot client, we need to lock in Read/Write symmetry where it already exists — so any future refactor of `file_types` can be validated against a regression baseline.

Scope: six formats. `Food`, `Furniture`, `Character`, `CharacterArt`, `ImageOffsets` (both `Type=1` and `Type=2`), and `AnimationData` (after adding the missing `WriteAnimationData` in this phase). All tested with in-memory fixtures. One real-file smoke test against `src/assets/data/animationData.bin.mid`.

Deliverables:
- `tool/file_types/roundtrip_test.go` with in-memory round-trip tests.
- `WriteAnimationData` added to `animation_data.go`.
- `WriteFoods` signature widened from `*os.File` to `io.Writer` for consistency with every other writer in the package.
- A `go test` invocation documented in the README once the tests have been verified green.

### Phase 0b — Lossless parsers and missing writers *(in progress, blocks Phase 3)*

**Done when:** `SaveGame`, `Cafe`, and `FriendCafe` all round-trip byte-identically through Read → Write on in-memory fixtures covering every version-conditional code path, and on at least one real binary fixture per format.

Why this is its own phase: the existing readers for `SaveGame`, `Cafe`, and `FriendCafe` are *lossy*. `readSaveStrings` in `save_game.go` reads length-prefixed string arrays and throws every string away. `ReadCafe` was reading a `float64` header, a trailing `int32` block, and a second version-conditional `int32` block entirely into nowhere. `readFoodStack` in `cafe.go` read a byte into `f.U1`, then on `version > 24` overwrote it with a second byte — losing the first — and also read a second string after `f.U6` that went straight into the void. `readCafeFurniture` read a `furnitureType` byte, branched on it, and never stored it. None of this is a bug in the sense of "the build pipeline is broken" — the build pipeline never round-trips these formats, so there's been no pressure to be lossless. It *is* a bug in the sense of "we cannot use this as the source of truth for the Godot client's save/load path."

**Approach: preservation fields, not Ghidra.** An earlier version of this plan assumed we'd need to reverse-engineer `libZombieCafeAndroid.so` in Ghidra to understand what the currently-discarded bytes *mean* before we could preserve them. That's wrong — byte preservation doesn't require byte understanding. We can add `U0`/`TrailingInts1`/`U6Alt`/`FurnitureType` placeholder fields to the structs, populate them from the readers, write them back from the writers, and leave the semantic naming for whenever Phase 4 needs to act on a specific field. The existing `U1`/`U2`/`U3` convention in Airyz's code is exactly this pattern, one step further. Ghidra remains valuable for Phase 4 (game tick implementation in the Godot client), not Phase 0b.

Work broken into small steps, with completed ones marked:

1. *(done)* `ReadNextBytes` hardened with `io.ReadFull` + `panic` instead of single `file.Read` + `log.Fatal`, so tests can catch parser failures cleanly. `ReadBool` given the same panic treatment.
2. *(done)* `WriteCharactersJP` added as the mechanical rehearsal. `CharacterJP` had no lossy reads and no version conditionals, which made it a clean dry-run before the harder cafe work. `TestCharacterJPRoundTrip` passing.
3. *(done)* Primitive writers `WriteInt64`, `WriteFloat64`, `WriteDate` added to `binary_writer.go`. These are consumed by the cafe and save-game writer families.
4. *(done)* Cafe family parsers extended to preserve previously-discarded bytes: `Cafe.U0` (header `float64`), `Cafe.TrailingInts1` and `Cafe.TrailingInts2`, `FoodStack.U0` and `FoodStack.U6Alt`, `CafeFurniture.FurnitureType`. All readers updated; `ReadCafe` now loses zero bytes on the path to its return value. Debug prints stripped from `cafe.go`.
5. *(done)* Cafe family writers: `writeFoodStack`, `writeFood`, `writeStove`, `writeServingCounter`, `writeCafeWall`, `writeCafeObject`, `writeCafeFurniture`, `writeCafeTile`, `WriteCafe`. Plus `writeCharacter` (for `CharacterInstance` in `save_game.go`), `writeCafeState`, and `WriteFriendData`. All mechanical mirrors of their readers with matching version conditionals. `TestCafeRoundTrip` and `TestFriendCafeRoundTrip` passing against in-memory fixtures that exercise every reader branch at version 63. `FriendCafe.Version byte` added to capture the leading version byte the reader was previously dropping.
6. *(done)* `SaveGame`. The `readSaveStrings` subtract-one count encoding is preserved via a new `SaveStrings` struct with explicit `RawCount int16` and `Strings []string` fields — stored separately because `RawCount=0` and `RawCount=1` both decode to zero strings and cannot be distinguished from `len(Strings)` alone. `SaveGame.Version`, `SaveGame.PreStrings`, and `SaveGame.PostStrings` added to the struct (the old `SaveGame.U14` and `SaveGame.U16` fields were vestigial — declared but never read — and have been removed). `WriteSaveGame`, `writeSaveGameVersion63`, `writeSaveStrings` all landed. `TestSaveGameRoundTrip` plus `TestSaveStringsEncoding` (with boundary sub-tests at `RawCount` values 0, 1, 2, and 5) passing.
7. *(done)* Debug print sweep across `furniture.go`, `character.go`, `file_types.go` — three stray `fmt.Println` / `fmt.Printf` calls removed and unused `fmt` imports dropped. Test output on success is now silent across every existing test.
8. *(done)* Check in real binary fixtures under `tool/file_types/testdata/`. All three canonical save-family formats now have real device fixtures pulled from the legacy patched APK running on a physical ARM Samsung device:
   - **`Cafe`:** `playerCafe.caf` (20,129 B), `BACKUP1.caf` (20,017 B). Round-trip byte-identically via `TestRealCafeFixturesRoundTrip`.
   - **`SaveGame`:** `globalData.dat` (1,626 B), `BACKUP1.dat` (1,556 B). Round-trip via `TestRealSaveGameFixturesRoundTrip`. The existing `SaveGame` parser was extended with a `Trailing []byte` preservation field because the real files carry ~1 KB of additional data past the known struct fields (probably an extended character/friend list near offset 0x265 in globalData.dat — visible in hex as `Lionel`, `Odie`, `Krystal`, etc.). Decoding that trailing section structurally is deferred; byte-preservation is sufficient for the round-trip contract.
   - **`FriendCafe`:** `ServerData.dat` (20,747 B), the last friend cafe cached from a server raid lookup. Round-trips via `TestRealFriendCafeFixturesRoundTrip`. The filename is misleading — it's not generic "server data", it's the binary blob the raid flow downloads for a friend's cafe. The struct layout (`byte Version + CafeState State + Cafe Cafe`) matches the file's 20.7 KB size exactly: ~1 byte header + ~500 bytes of state + ~20 KB of cafe data. No parser changes needed.
   
   The empty `raidCafe*.dat` / `raidEnemies*.dat` slot files (2 bytes each = 0 as int16) are NOT fixtures — they're just count markers populated by in-map NPC raid UI that the game never flushes to real data on disk. Real player-to-player raids would populate them, but the game's random-player view is read-only on this device so those paths couldn't be exercised.
   
   Getting the game to boot on the modern device required building `libZombieCafeExtension.so` from source via the NDK's bundled CMake+Ninja and adding a runtime patch that NOPs out `Java_com_capcom_zombiecafeandroid_SoundManager_setEnabled` to dodge a null-pointer race triggered by modern Android's broadcast-receiver lifecycle. See the `lib/cpp: patch SoundManager.setEnabled` commit and `src/lib/cpp/ZombieCafeExtension.cpp`.

### Phase 1a — Asset export pipeline MVP *(done)*

**Done when:** `go run ./tool/build_tool -target godot -i src/ -o build_godot/` produces a directory tree that Godot 4 can import without manual intervention for the asset categories Godot understands natively: JSON data files, individual PNG textures, OGG audio, TTF fonts.

Landed:
- *(done)* `-target` flag on `build_tool` selecting `android` (default, legacy APK path) or `godot`. The legacy orchestration is preserved verbatim inside a new `buildAndroid` helper; the Godot path calls `serialization.BuildGodotAssets`.
- *(done)* `tool/resource_manager/serialization/godot.go` — new file containing `BuildGodotAssets` plus four subroutines that produce `<out>/assets/data/`, `<out>/assets/images/`, `<out>/assets/audio/`, `<out>/assets/fonts/`. Data files are either copied (`*.bin.mid.json` → `*.json`) or decoded on the fly (`animationData.bin.mid` via the existing `ReadAnimationData` parser). Images, audio, and fonts are copied verbatim from their respective source locations.
- *(done)* `build_godot/` added to `.gitignore`.
- *(done)* First run against the real `src/` tree produced a 41 MB output in 5 seconds: 4 JSON data files, 7,054 PNG files (subdirectory structure preserved), 205 OGG files (1 music + 204 sfx), 1 TTF. Every file is in a format Godot 4's built-in importers consume natively.

### Phase 1b — Asset export pipeline polish *(in progress)*

**Done when:** the Godot asset tree includes everything the runtime needs to boot — atlas-packed textures with JSON offset metadata, decoded per-animation keyframe data, decoded constants/strings/enemy data — not just the categories Phase 1a covered.

Pending work:
1. *(done)* Atlas packing. `PackGodotCharacters` and `PackGodotTextures` in `godot.go` reuse `cct_file.WritePackedTexture` with the same parameters the legacy pipeline uses, save the packed image as PNG via `imaging.Save`, and write `ImageOffsets` + `CharacterArt` as pretty-printed JSON. Wired into `BuildGodotAssets` via a new `packGodotAtlases` helper that runs the seven known atlases (characterParts, characterParts2, recipeImages, recipeImages2, furniture, furniture2, furniture3) into `<out>/assets/atlases/`. Total atlas footprint is 11 MB (7 PNGs averaging 1.2 MB plus their JSON metadata), additive to the individual-PNG tree for now — a future pass can remove the individual copies once Phase 2 confirms the Godot client reads atlases exclusively.
2. *(done)* Per-animation keyframe parser. Shipped `tool/file_types/animation_file.go` with `ReadAnimationFile` / `WriteAnimationFile`, byte-identical round-trip tests on all 60 real files under `src/assets/data/animation/*.bin.mid`, an in-memory fixture test with non-default values across every field, and a semantic-hypothesis spot-check that survived (`Prologue.KeyframeCount`: sit=1, walk=39). Wired through `BuildGodotAssets` via a new `packGodotAnimations` helper that writes `build_godot/assets/data/animation/*.json`. The struct decodes the confirmed-structural skeleton section (13×64-byte records after the header+prologue; the `13` is in header position [2] and is *per-file variable*) and preserves everything after it as an opaque `Tail []byte` — rigorous round-trip, tail decode deferred. The pre-implementation hypothesis that `Header.BoneCount = 24` was the skeleton bone count turned out wrong (24 is the per-keyframe part count; the actual skeleton record count is ~13); both interpretations are documented inline. See `docs/devlog/2026-04-11-phase-1b-animation-parser.md` for the reverse engineering narrative and the spec-vs-reality surprise.
3. *(in progress)* Opaque binary game data. Still pending: `constants.bin.mid`, `font3.bin.mid`. Done this phase:
   - **`enemyLayouts.bin.mid`:** `tool/file_types/enemy_layouts.go` with a byte-preservation `ReadEnemyLayouts` / `WriteEnemyLayouts` pair. The file contains repeating records with 1-byte ASCII type codes (`H T W L A S C D G B E P` — likely initials of cafe element types: Hole, Table, Wall, Lamp, etc.) and int16 prefixes, but a hex-dump analysis couldn't lock down the exact record boundaries in a single session — gaps between consecutive `H` occurrences are 29 and 30 bytes (inconsistent), so records are either variable-size or the encoding has per-record alignment that isn't obvious from the byte patterns alone. Rather than commit to a wrong struct interpretation, the parser preserves the whole file as an opaque `Data []byte` slice. This still satisfies the Phase 0b-style round-trip contract (byte-identical) and lets `BuildGodotAssets` emit the file as JSON (base64-encoded via Go's default `[]byte` marshaling) while the schema work is deferred. A future session with more investigation budget or a Ghidra pass against `libZombieCafeAndroid.so` can upgrade the struct without touching the wire format. Wired through `BuildGodotAssets` via `deserializeEnemyLayoutsForGodot`.
   - **`enemyCafeData.bin.mid`:** `tool/file_types/enemy_cafe_data.go` with `ReadEnemyCafeData` / `WriteEnemyCafeData`. The file holds 14 enemy cafe definitions for the raid/friend system. Mixed-endian header: LE int32 count + BE int16 header flag. Each entry has `Name`, `SubType`, `SequenceID`, `CafeID`, length-prefixed `Data` (underscore-delimited item-id list), four flag int16s, and a `LocationName` franchise/chain string ("Frankenstein's", "Leprechaun's", etc.). **The last entry ("Villain") is truncated** — the real file has exactly 26 bytes of space left for it after entry 12, which only fits up through Flag3 (no Flag4 and no LocationName). Every other entry has a full tail. The struct exposes a `HasTail bool` flag that distinguishes the two shapes so the writer faithfully reproduces the original byte layout. First draft attempted `int32 SequenceID` which happened to work for entries 0-11 (SubType=0 made the int32 read correctly) and then blew up on entry 12 where SubType=1. Split into two int16 fields to catch both cases. Wired through `BuildGodotAssets` via `deserializeEnemyCafeDataForGodot` producing a structured `enemyCafeData.json` with every field named.
   - **`enemyItems.bin.mid`:** `tool/file_types/enemy_items.go` with `ReadEnemyItems` / `WriteEnemyItems`. The file is a 2-byte BE int16 count header (= 14) followed by a flat list of length-prefixed strings that runs to EOF. Count is the number of cafe categories ("Cafe", "Diner", "Italian", "Asian", ...) and the strings include category names interleaved with underscore-delimited item-id lists like `"34_35_36_37_38_39"` that encode which items each category's enemy drops when raided. Real file round-trips byte-identically; in-memory fixture with UTF-8 content and an embedded empty string catches reader-writer asymmetry. Wired through `BuildGodotAssets` via `deserializeEnemyItemsForGodot`. Note: an attempt at `enemyCafeData.bin.mid` in the same session uncovered a more complex structure with mixed endianness (LE int32 count + BE int16 fields), nested `SubType` flags, and length-prefixed trailer strings — multiple iteration rounds still hit format surprises, so the file was dropped from this session without a parser landing. `enemyLayouts.bin.mid` is binary-heavy and wasn't attempted.
   - **`cookbookData.bin.mid`:** `tool/file_types/cookbook_data.go` with `ReadCookbookData` / `WriteCookbookData` decoding 10 cookbook entries, each with `Name`, 4 × `int16` `Fields` (observed non-zero values like `(5000, 20, 3, 3)` on the Mafia Cookbook row look like cost/level/stats but are not semantically interpreted yet), `Description`, `AfterDescription`, `Status`, and `Trailer`. Big-endian int16 length-prefixed strings throughout, matching the existing `ReadString` convention. Real file round-trips byte-identically; in-memory fixture with extreme int16 values (-32768, 32767, -1) and UTF-8 name catches reader-writer asymmetry. Wired through `BuildGodotAssets` via `deserializeCookbookDataForGodot`, producing a clean structured JSON with human-readable strings and int arrays.
   - **`enemyItemData.bin.mid`:** `tool/file_types/enemy_item_data.go` with `ReadEnemyItemData` / `WriteEnemyItemData`, byte-identical round-trip test against the real file (321 bytes = 1-byte count header `0x14=20` + `20 × 16` per-item attribute records), and an in-memory fixture test with non-default values. Wired through `BuildGodotAssets` via `deserializeEnemyItemDataForGodot`. Per-item column meanings not interpreted — same preservation philosophy as Phase 0b.
   - **`strings_google.bin.mid` / `strings_amazon.bin.mid`:** despite the `.bin.mid` suffix these are plain UTF-8 text files with `\r\n` separators carrying the game's localized English strings. `tool/file_types/strings_file.go` with `ReadStringsFile` / `WriteStringsFile` is a 20-line `strings.Split` / `strings.Join` wrapper. Both real files round-trip byte-identically; the two files differ by exactly one URL (iphone vs android in a `beeline-i.com` link). Wired through `BuildGodotAssets` via `deserializeStringsFilesForGodot` which emits `strings_google.json` and `strings_amazon.json` with human-readable UTF-8 string arrays.
   
   Note: `constants.bin.mid` was attempted first but has a more complex mixed-endian structure (9789 bytes, not divisible by 4, ints appear big-endian at the start but the layout past the first block isn't obvious from hex dumps alone); deferred to a longer-scope session.
4. *(pending, lower priority)* Bitmap font conversion. `thunder_*.fnt.mid` + `thunder_*_0.png` pairs become Godot-native BMFont or sprite font format. Godot's native TTF renderer can rasterize `A Love of Thunder.ttf` at any size, so this only matters if the original bitmap rendering has a specific look that needs preserving.
5. *(done)* `cct_file` debug print sweep. Removed eight `fmt.Print*` calls from `tool/cctpacker/cct_file/packed_texture.go` (`Print(images)`, per-file `Println(file)`, `"Could not find json file: ..."`, `"Initial rect:"`, `Print(entryData)`, per-rect `"Could not pack: %d"`, summary `"Num rects not packed: %d"`) and one from `tool/cctpacker/cct_file/cctexture.go` (`"Decompressed: %d bytes!"`). The pack-failure case was consolidated into a single `log.Fatalf` that names the failing rect indices, so the error-path signal is strictly better than before. `build_tool -target godot` now produces two lines of output (`BuildGodotAssets: <start>` and `BuildGodotAssets: done`) instead of dozens of lines of per-image spam. No behavior change — all 5 workspace modules still build clean, `file_types` tests still green, Godot headless validator still 15/15.
6. *(done, subsumed by item 8)* Skip leftover `*.cct.mid.png` artifacts left in `src/assets/images/` by previous legacy build runs. The whole individual-PNG copy path was removed in item 8, so these artifacts are no longer copied anywhere — problem dissolves rather than being solved.
7. *(pending, cosmetic)* Copy social icons and EULA/help HTML from `src/assets/data/` if the Godot client needs them.
8. *(done)* Replace individual PNG copies with atlas-only output. Removed the `copyGodotImages` call from `BuildGodotAssets` and deleted the function entirely (along with its now-unused `io/fs` import). Confirmed the Godot client reads sprites exclusively through `SpriteAtlas` — `main_scene.gd` uses `SpriteAtlas.load_from`, `sprite_atlas.gd` loads only the packed atlas PNG, and `validate_assets.gd` is the only consumer that references individual PNGs and it reads them from the `godot/assets/` sample tree (not `build_godot/`), so nothing in the Godot code path is affected. Build output shrunk from **53 MB → 18 MB** (-35 MB, -66%); the `build_godot/assets/images/` directory no longer exists. All 15 validator checks still green, `file_types` tests still green, all 5 workspace modules still build clean.

### Phase 2a — Godot project scaffold and first client code *(done)*

**Done when:** a tracked Godot 4 project exists, the Phase 1 asset tree imports cleanly under Godot's built-in importers, and the first reusable piece of game code can load a packed atlas + offsets JSON and surface named `AtlasTexture` regions at runtime.

Landed:
- *(done)* `godot/project.godot` — minimal Godot 4.6-targeted project file. No scenes or startup scripts; exists so the directory is recognized as a project.
- *(done)* `godot/assets/` — 5.5 MB of representative sample files copied from `build_godot/` (3 data JSON, 3 individual character PNGs, 2 atlas PNGs + 3 JSON manifests, 1 TTF, 2 OGGs). Tracked for reproducibility of the validation script.
- *(done)* `godot/validate_assets.gd` — headless `SceneTree`-based validation script. Exercises every asset category the Phase 1 builder emits: JSON parse (data files + atlas manifests), `Texture2D` load (individual PNGs + atlas PNGs), `FontFile` load, `AudioStream` load. Exits 0 on success, 1 on any failure. Reusable as a regression test.
- *(done)* `godot/scripts/sprite_atlas.gd` — first reusable piece of real Godot client code. A `SpriteAtlas` `class_name` exposing `load_from(atlas_png, offsets_json, character_art_json="")`, `get_region(key)`, `get_character_pieces(character_name)`, and draw-offset lookups. Handles both character atlases (keyed by composite `"<character>/<part>"`) and plain texture atlases (keyed by bare `"<part>"`). The composite-key model was forced by the discovery that naive bare-name keying silently collapses 3,051 character-part entries down to 27 when every character shares the same part filenames.
- *(done)* Extended `validate_assets.gd` with end-to-end `SpriteAtlas` tests for both `characterParts.png` and `furniture.png`. Exercises the character atlas's 3,051-region count, retrieves all 27 `AtlasTexture` objects for `boxer-human` via `get_character_pieces`, confirms the grouping math is right.
- *(done, first run)* Godot 4.6.2 installed via winget (`GodotEngine.GodotEngine`). Binary at `%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\`. Full 14-check validation pass confirmed against the real installed Godot runtime.

### Phase 2b — Visible rendered scene *(in progress)*

**Done when:** opening `godot/project.godot` in Godot 4 shows a rendered character sprite assembled from its `SpriteAtlas` pieces. A visible artifact proves the rendering path, not just the import path.

Landed:
- *(done)* `godot/main.tscn` + `godot/scripts/main_scene.gd` — minimal scene whose startup script calls `SpriteAtlas.load_from` and lays the 27 pieces of `boxer-human` out as `Sprite2D` children. Assembly lives in a public `assemble()` method that `_ready()` delegates to, so the headless validator can call it synchronously instead of routing through the `SceneTree._init` → `_ready` lifecycle (which defers `_ready` to the first processed frame and breaks same-call child-count assertions). `run/main_scene="res://main.tscn"` set in `project.godot` so opening the project boots straight into the rendered scene. Layout is a 9×3 grid of 140-pixel cells with the per-piece `draw_offsets` applied as a positional nudge; this is a provisional interpretation because real skeletal posing requires the per-animation keyframe parser (Phase 1b pending) — see `docs/devlog/2026-04-11-phase-2b-visible-scene.md` for the reasoning.
- *(done)* `godot/validate_assets.gd` extended with `_validate_main_scene`, a 15th check that loads `main.tscn` as a `PackedScene`, asserts the root is `Node2D`, calls `assemble()`, and confirms exactly 27 `Sprite2D` children each holding a valid `AtlasTexture` with non-null source and non-zero region rect.
- *(done)* `.github/workflows/godot-validation.yml` — triggers on every `push` and `pull_request`, downloads the official Godot 4.6.2 Linux x86_64 binary on `ubuntu-latest`, runs the `--editor --quit` pre-pass to build the `.godot/` class cache (required because `.godot/` is gitignored so CI always starts cold), then runs the full validator via `--headless --script`. First real green run will appear on the first push; CI URL/path assumptions are best-effort based on the standard Godot releases mirror and will be fixed in a follow-up if they fail on the runner.

Pending:
- *(done)* Per-character index in `SpriteAtlas.get_character_pieces`. Precomputes `_character_pieces_index: Dictionary[String, Array[AtlasTexture]]` during `_load_offsets` in the same pass that builds the `regions` dict; synthetic `_unassigned/...` overflow entries are deliberately excluded. `get_character_pieces` is now a single dict lookup — O(1) instead of O(n) scanning 3,051 regions — which makes it safe to call in hot loops (e.g., per-frame pose rebuilds once real animated playback lands). `_validate_character_atlas` gained characterization assertions before the refactor: it now confirms `get_character_pieces` returns distinct piece arrays for `boxer-human` vs `cowboy-human` (rejecting accidental shared state) and returns an empty array for unknown character names. All 15 validator checks green; refactor preserved behavior byte-identically.
- *(pending, future)* Cafe background. Blocked on the `mapTiles` texture packer being enabled (currently commented out in the legacy `build_tool/main.go`).
- *(done)* Real skeletal posing for `boxer-human`. `main_scene.gd` gained a `pose_from_animation(json_path, frame_index)` method that loads `godot/assets/data/animation/sitSW.json`, pulls the 13-record skeleton section, and writes bone-derived `Sprite2D` positions on top of the Phase 2b grid. The grid layout stays as a graceful fallback when the JSON is missing or malformed (no scene crash). The pose uses the translation component of each 3×4 transform (indices 9, 10 of the 12-float block) anchored at screen-center (640, 360). `validate_assets.gd`'s `_validate_main_scene` check gained a pose delta assertion that confirms at least one sprite position differs from its grid cell origin after posing runs — end-to-end headless verification that the Go parser → JSON → Godot consumer pipeline works. Does NOT yet render a biologically faithful sit pose because the skeleton-section translations are all zero in the bind pose; real per-keyframe data lives in the opaque Tail section that's deferred. See `docs/devlog/2026-04-11-phase-1b-animation-parser.md` for details.

### Phase 3 — Save-load round-trip *(in progress)*

**Done when:** the Godot client can load a real save file produced by the legacy Android build, render the cafe layout described by it, and write it back out byte-identically. No tick simulation yet — this is purely a data path.

Why this before gameplay: if the Godot client can't agree with the Go tooling on what a save file means, there's no point implementing a tick loop. This is the fidelity contract.

Landed (Session 1 of 4 per `docs/superpowers/specs/2026-04-25-godot-save-format-bridge-design.md`):

- *(done)* `godot/scripts/save/binary_reader.gd`, `binary_writer.gd` — primitive read/write helpers mirroring the Go `binary_reader.go` / `binary_writer.go` (BE ints, LE ints + floats, bool, BE int16 length-prefixed UTF-8 strings, Date struct).
- *(done)* `godot/scripts/save/legacy_loader.gd`, `legacy_writer.gd` — `parse_cafe` and `write_cafe` plus all 8 sub-record parsers/writers (`FoodStack`, `Food`, `CafeObject`, `CafeWall`, `CafeFurniture`, `Stove`, `ServingCounter`, `CafeTile`). PascalCase Dictionary keys mirror Go's default `json.Marshal` output.
- *(done)* `godot/test/test_save_round_trip.gd` — Layer-1 round-trip runner. Real fixtures `playerCafe.caf` (20,129 B) and `BACKUP1.caf` (20,017 B) round-trip byte-identically through GDScript. 87 PASS / 0 FAIL.

Landed (Session 2 of 4 per `docs/superpowers/specs/2026-04-25-godot-save-format-bridge-design.md`):

- *(done)* `legacy_loader.gd` / `legacy_writer.gd` extended with `parse_save_strings`, `parse_character_instance`, `parse_cafe_state`, `parse_save_game`, `parse_friend_cafe`, plus matching writers and `parse_*_bytes` / `write_*_bytes` static dispatch wrappers. The `SaveStrings` count-1 quirk (`RawCount=0` and `RawCount=1` both decode to zero strings) is preserved by storing `RawCount` separately from the string list. The ~1 KB `SaveGame.Trailing` preservation field is stored as `Trailing_b64` (standard base64) per the spec's `_b64` suffix convention.
- *(done)* New primitives `read_int8` / `write_int8` and `BinaryWriter.append_bytes` added to support `CafeState.U12 []int8` and the `Trailing_b64` re-emit path.
- *(done)* **Architectural deviation from spec:** `read_string` now returns `PackedByteArray` (not `String`) because the legacy fixtures contain `\r\0` byte suffixes inside `CharacterInstance.Name` strings that Godot's `String` cannot represent (the engine refuses to hold a NUL codepoint). `write_string` accepts both `PackedByteArray` and `String` via `Variant`. Test helpers (`_str_eq`, `_string_array_eq`) bridge the two representations. **Implication for Session 3:** the JSON envelope cannot serialize string fields as plain JSON strings — needs a hybrid scheme (UTF-8 decode when valid + no NULs, else `_b64` sibling field). See `binary_reader.gd:125-132` for the rationale.
- *(done)* Three more fixtures copied into `godot/test/fixtures/save/`: `globalData.dat` (1,626 B), `BACKUP1.dat` (1,556 B), `ServerData.dat` (20,747 B).
- *(done)* `godot/test/test_save_round_trip.gd` extended with 8 new `_test_*` functions covering all five real fixtures plus boundary in-memory cases. Runner banner renamed to "Save round-trip results". Final count: **170 PASS / 0 FAIL**.

Deliverables:
- A GDScript/C# wrapper that calls into the Go `file_types` package (via a compiled shared library, or by round-tripping through JSON).
- A test save file checked in under `godot/test/fixtures/`.
- A unit test in Godot that loads it, re-saves it, and diffs against the original bytes.

### Phase 4 — Game tick loop

**Done when:** customers spawn, walk to tables, order food, wait for the stove, eat, pay, and leave. XP and money update. The player can place furniture and buy characters. No online features, no billing, no Facebook.

This is where the bulk of the reverse engineering effort goes. For each behavior, the order of operations is:

1. Check the original `libZombieCafeAndroid.so` in Ghidra, using the offsets already labelled in `src/lib/cpp/ZombieCafeExtension.cpp` as anchors.
2. Write a devlog entry describing the behavior in plain English.
3. Implement it in Godot.
4. If the behavior is exposed in a save file field (e.g., a timer, a cooldown), verify by loading a legacy save and confirming the values match expectations.

### Phase 5 — Online features

**Done when:** the Godot client authenticates (or stubs auth), uploads its save state to `tool/server/`, fetches a random friend cafe via `getrandomgamestate`, and lets the player raid it. Friend metadata is no longer hardcoded.

This phase also drives the remaining server work: implementing `getgamestate` properly, replacing the placeholder timestamp, and removing the 90% save-drop throttle (which was a cost-control hack and should not survive the rewrite).

### Phase 6 — Platform exports

**Done when:** clean builds for Windows, Linux, macOS, Android, and web are attached to a GitHub release, each one smoke-tested to boot into the menu and load a save.

iOS is listed separately: it requires a macOS build host and an Apple developer account, so it's a stretch goal for this phase rather than a blocker.

### Phase 7 — Retire the legacy build

**Done when:** `src/smali/`, `src/lib/cpp/`, `src/AndroidManifest.xml`, `apktool.yml`, and `debug.keystore` are removed from `main` and preserved on a `legacy-android-apk` branch. The README's "Building the legacy Android APK" section is replaced with a "Building in Godot" section.

## Validation strategy

Three layers of test coverage, in order of how much they're worth:

1. **Phase 0 Go round-trip tests.** Canary for any binary format regression. Fast, deterministic, runs on every push.
2. **Godot ↔ Go contract tests.** Load a real save in Godot, serialize it back, diff against the Go tooling's output. Catches divergence between the two consumers of the format.
3. **Behavioral smoke tests.** A small Godot test scene that runs a headless tick loop for N simulated minutes and asserts that a starting save reaches an expected end state. Catches gameplay regressions.

Performance tests are explicitly skipped. Zombie Cafe's peak entity count is low enough that Godot 4 can run it at several thousand FPS on any modern machine. If we ever hit a hot loop, GDExtension exists.

## Why Godot over the alternatives

We considered three paths before committing:

### Path A — Emulate `libZombieCafeAndroid.so` on non-Android hosts

Wrap the existing ARM binary in a user-mode emulator (unidbg, QEMU user-mode) plus a JNI stub layer and a GL ES 1.0 translator. Would run on desktop in weeks.

**Rejected because:** every existing limitation (memory leak, ARMv7 lock-in, 2-character-sheet ceiling, NOPed destructors) carries forward. We'd never own the code. iOS and web remain hard.

### Path B — Static decompilation of the `.so` into portable C++

Use Ghidra to lift the entire 1.9 MB binary into readable C++, then port it to SDL2 + modern GL. The existing offset labels in `ZombieCafeExtension.cpp` would seed the symbol table.

**Rejected because:** even in the best case, this is months of work on deeply hostile decompiler output, and the end state is a codebase that only ARM reverse engineers can maintain. Every future feature — new characters, new modes, modding, real-time friends — fights the port instead of building on it. Bit-perfect fidelity is the only advantage, and this project has already diverged from the original in deliberate ways (toxin buy swap, disabled cafe-size upgrade, server throttling), so fidelity is not a meaningful goal.

### Path C — Godot remake using the existing assets and server *(chosen)*

Rewrite the client in Godot 4. Keep the Go tooling, the server, and the assets. Use the original `.so` as reference documentation, not as runtime code.

**Chosen because:**

- **Maintainability:** idiomatic Godot code any 2D game developer can contribute to, versus decompiled C++ that has a talent pool measured in dozens of people worldwide.
- **Flexibility:** every improvement the project wants — JP character roster, new modes, modding, real-time multiplayer, modern graphics — is a normal Godot feature instead of a patch to reverse-engineered logic.
- **Platform reach:** Godot exports to all six target platforms from a single button.
- **Performance is a non-issue at this scale**, so the theoretical advantage of native C++ doesn't matter.
- **The existing Go tooling is already perfectly suited to this path.** It was written to pack/unpack game data — exactly what a Godot asset pipeline needs.

The trade-off we're accepting: we give up bit-perfect behavioral fidelity with the 2011 binary in exchange for a codebase that's still alive in 2030.

## Open questions and known risks

- **Save format v63 is not the only version.** There may be older save formats in the wild. Phase 3 needs to decide whether to support them or require a one-way upgrade.
- **The animation format is decoded but not re-packed.** We'll need to finish that work in Phase 1 or Phase 4, depending on whether Godot consumes the original atlases or a re-exported form.
- **Go ↔ Godot integration path is undecided.** Three candidates: (a) compile `file_types` to a shared library via `c-shared` buildmode and call it from GDExtension; (b) run the Go tooling as a subprocess during asset import only, and never at runtime; (c) port `file_types` to GDScript/C# and accept the maintenance duplication. Option (b) is the leading candidate because it keeps runtime and tooling concerns cleanly separated.
- **Legal posture.** The project has always operated in the reverse engineering preservation grey zone. A Godot rewrite doesn't change that, but it's worth re-reading the position stated in the README before any public release.
- **Japanese version support.** Phase 4 should decide early whether to target EN-only, JP-only, or both. Both is cheap if the rewrite is designed for it from the start, expensive if bolted on later.

## Decision log pointer

This document *is* the decision log for the Godot rewrite. Future major decisions (e.g., GDScript vs. C#, the Go ↔ Godot integration path, save format migration strategy) will be captured here as amendments with dates, not in separate files. Small decisions and exploration notes go in `docs/devlog/` instead.
