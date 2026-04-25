# Godot Save Format Bridge — Design

**Date:** 2026-04-25
**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))
**Phases touched:** Phase 3 (save-load round-trip) — picks the Go ↔ Godot integration path that has been the rewrite plan's leading open question since 2026-04-11

## Goal

Land the Godot client's save-load path so that:

1. A real legacy `.caf` / `.dat` save produced by the patched Android APK can be read in pure GDScript, edited in memory, and written back byte-identically to disk. Five real device fixtures across three formats already live under `tool/file_types/testdata/` and pass Go round-trip tests; the GDScript port must produce the same bytes.
2. Going forward, the Godot client persists state to a single Godot-native JSON file (`user://save.json`) carrying every byte of the legacy formats inside a versioned envelope. New game features (Phase 4 onwards) extend the envelope schema; the legacy binary becomes a one-time import + a translation layer for server interop.
3. Validation runs in CI on every push: byte-identical round-trip + cross-language Dictionary equivalence against Go-decoded JSON oracle + envelope round-trip.

By end of Phase 3, the Godot client owns the save format end-to-end with no runtime Go dependency and no per-platform native build matrix. Web export works. iOS export works. Phase 4 (game tick) and Phase 5 (server upload) inherit a clean foundation.

## Context

This design closes the rewrite plan's longest-standing open question: "Go ↔ Godot integration path is undecided." The three candidates the plan listed —

1. **`c-shared` GDExtension** wrapping `tool/file_types` as a per-platform native shared library
2. **Subprocess at asset-import time only**, no runtime Go dependency, Godot reads JSON
3. **Port `tool/file_types` save parsers to GDScript**, accepting duplicate-maintenance cost

— map cleanly onto the cross-platform goal in `docs/rewrite-plan.md` ("exports to Windows, macOS, Linux, Android, iOS, and the web. No per-platform forks.") only if option 3 is chosen. Option 1's per-platform `.so` / `.dll` / `.dylib` / `.wasm` matrix is fragile on web (GDExtension on web is wobbly in Godot 4) and adds complexity for a payload (saves are 1.6 – 20 KB) that doesn't need native performance. Option 2 is impossible on web (no subprocesses in the browser sandbox) and effectively impossible on iOS (no `fork+exec` in the standard sandbox). Option 3's duplicate-maintenance cost is bounded because the formats have been stable since 2011 and `file_types` reached feature-completeness in Phase 0b.

Phase 3's done criterion in `docs/rewrite-plan.md` is "the Godot client can load a real save file produced by the legacy Android build, render the cafe layout described by it, and write it back out byte-identically." That phrasing carries an architectural ambiguity: is the binary the forever format, or is byte-identical round-trip a one-time fidelity proof? This spec resolves the ambiguity in favor of the latter — the legacy binary is a *bridge*, JSON is the going-forward format. Concrete reasoning:

- Text JSON survives Godot version upgrades (Godot 4 → 5) where `Resource` (`.tres`) historically breaks; coupling saves to `class_name` choices is an avoidable footgun.
- The Go tooling already emits PascalCase JSON for every `*.bin.mid.json` under `build_godot/assets/data/`; matching that convention in the Godot client reuses the existing test oracle.
- Adding a new field for a Phase 4 feature is a JSON key add, not a binary format extension that the legacy parser also has to tolerate.
- The legacy binary contract still matters at exactly two well-defined boundaries (legacy save import on first run, server upload in Phase 5); neither needs the in-memory representation to also be binary.

Phase 3 is the smallest unit of work that makes Phase 4 tractable. Phase 4's game tick reads and writes saves continuously, so until the Godot client owns the save format the tick loop has nowhere to write. This spec is the unblocker.

## Success criteria

The work is done when all of the following are true:

1. `godot --headless --path godot/ --script res://test/test_save_round_trip.gd` exits 0 with three layers of test output green:
   - **Layer 1:** all 5 real device fixtures (`playerCafe.caf`, `BACKUP1.caf`, `globalData.dat`, `BACKUP1.dat`, `ServerData.dat`) round-trip byte-identically through `legacy_loader.gd` → Dictionary → `legacy_writer.gd`.
   - **Layer 2:** for each fixture, `legacy_loader.gd`'s Dictionary deep-equals the corresponding Go-decoded JSON loaded via `JSON.parse_string`. The PascalCase-keyed Dictionary shape produced by GDScript matches the shape Go produces, modulo type-coercion details documented in the Go-side dump tool.
   - **Layer 3:** envelopes built from the fixture Dictionaries, written to `user://test_save.json`, read back, and split into their constituent Dictionaries still produce byte-identical legacy binaries when each is fed to `legacy_writer.gd`. (Two envelopes — primary with `globalData.dat` + `playerCafe.caf` + `ServerData.dat`, backup with `BACKUP1.dat` + `BACKUP1.caf` + empty `friendCafes` — cover all 5 fixtures.)
2. `.github/workflows/godot-validation.yml` runs `test_save_round_trip.gd` on every push and pull request. First green CI run on `main` is the integration signal.
3. `tool/dump_legacy_fixtures/main.go` (new standalone CLI) generates `godot/test/fixtures/save/<name>.json` for each fixture; output is committed and regenerated whenever Go parsers change.
4. `go test ./tool/file_types/...` continues to pass — no regressions to the Go round-trip suite, which remains the canonical oracle.
5. `docs/rewrite-plan.md` marks Phase 3 as done; `docs/handoff.md` is regenerated; a devlog entry under `docs/devlog/` captures the architecture decision and any per-format surprises encountered during the GDScript port.

## Out of scope

Explicitly deferred to later phases:

- **Server upload of binary saves.** The legacy backend at `tool/server/` still expects binary; the GDScript writer produces it, but actually wiring the network call is Phase 5. (The rewrite plan also wants the 90% server-drop throttle removed in Phase 5; that's a separate decision.)
- **Game tick logic operating on the loaded Dictionary.** Phase 4. This spec produces the in-memory shape; the tick loop will mutate it.
- **Save backup rotation.** The legacy format ships `BACKUP1.dat` / `BACKUP1.caf` mirroring the primary save; Phase 4 will likely add a `user://save.backup.json` mirror. This spec only ensures the Dictionary shape supports it (by having `playerSave` and `playerCafe` as separable keys).
- **Cloud save / cross-device sync.** Explicit non-goal.
- **Real migration logic (v1 → v2).** This spec ships the dispatcher only. No migration files yet — at v1 with `CURRENT_VERSION=1` the loop is a no-op. Real migrations land when a real format change requires one.
- **Fuzz testing of the GDScript parser against malformed input.** The Go round-trip tests in Phase 0b already exercise format edge cases via in-memory fixtures with extreme values; we trust them. The GDScript port's correctness is gated on the cross-validation oracle, not on independent fuzzing.

---

## 1. Architecture and data flow

```
                 ┌─────────────────────────────────────────────┐
                 │      Godot client (pure GDScript)           │
                 │                                             │
  legacy import  │  ┌────────────────────────────────────┐    │
  (one-time on   │  │  godot/scripts/save/               │    │
  first run, on  │  │   ├── primitives.gd  ─────────┐    │    │
  user device)   │  │   │   BinaryReader/Writer     │    │    │
  ┌──────────┐   │  │   ├── legacy_loader.gd  ──┐   │    │    │
  │ user's   │   │  │   │   parse_save_game     │   │    │    │
  │ .caf /   │───┼─▶│   │   parse_cafe          │◀──┘    │    │
  │ .dat     │   │  │   │   parse_friend_cafe   │        │    │
  └──────────┘   │  │   ├── legacy_writer.gd  ──┘        │    │
                 │  │   │   write_save_game              │    │
                 │  │   │   write_cafe                   │    │
                 │  │   │   write_friend_cafe            │    │
                 │  │   ├── save_v1.gd                   │    │
                 │  │   │   load_save / save_save        │    │
                 │  │   │   envelope schema              │    │
                 │  │   └── migrations/                  │    │
                 │  │       (stub v1→v1, future v1→v2)   │    │
                 │  └────────────────────────────────────┘    │
                 │                  │                          │
                 │                  ▼                          │
                 │             ┌────────────┐                  │
                 │             │ Dictionary │  in-memory       │
                 │             │ (canonical │  representation  │
                 │             │  PascalCase│                  │
                 │             │  shape)    │                  │
                 │             └────────────┘                  │
                 │                  │                          │
                 │                  ▼                          │
                 │   ┌──────────────────────────┐              │
                 │   │ user://save.json         │ ◀──── Phase 4│
                 │   │  { version: 1,           │       reads/ │
                 │   │    savedAt: "...",       │       writes │
                 │   │    playerSave: { ... },  │              │
                 │   │    playerCafe: { ... },  │              │
                 │   │    friendCafes: [ ... ] }│              │
                 │   └──────────────────────────┘              │
                 └─────────────────────────────────────────────┘

                 ┌─────────────────────────────────────────────┐
                 │  Go tooling (dev-time only)                 │
                 │                                             │
                 │  tool/file_types/        — unchanged        │
                 │      (canonical decoders, Phase 0b done)    │
                 │                                             │
                 │  tool/dump_legacy_fixtures/  — NEW          │
                 │      Reads testdata/*, writes               │
                 │      godot/test/fixtures/save/*.json        │
                 │      Commits as test oracle.                │
                 └─────────────────────────────────────────────┘
```

**Five new GDScript modules** under `godot/scripts/save/`:

1. **`primitives.gd`** — `BinaryReader` and `BinaryWriter` classes. Mirror `tool/file_types/binary_reader.go` and `binary_writer.go` field-for-field: BE/LE int8/16/32/64, float32/64, length-prefixed strings (BE int16 length + UTF-8 bytes), bool, date. Panic semantics match Go's `panic` on short read via `push_error` + early return. Cursor/position bookkeeping is internal state on the class.
2. **`legacy_loader.gd`** — top-level `parse_save_game(bytes) -> Dictionary`, `parse_cafe(bytes) -> Dictionary`, `parse_friend_cafe(bytes) -> Dictionary`, plus internal helpers for sub-records (`parse_food_stack`, `parse_stove`, `parse_serving_counter`, `parse_cafe_wall`, `parse_cafe_object`, `parse_cafe_furniture`, `parse_cafe_tile`, `parse_food`, `parse_character_instance`, `parse_cafe_state`, `parse_save_strings`). Pure decoders; no game logic. Output Dictionary shape mirrors Go struct field-for-field with PascalCase keys.
3. **`legacy_writer.gd`** — symmetric `write_save_game(dict) -> PackedByteArray` etc. Each `write_*` matches the corresponding Go writer's branching and version conditionals exactly. Preservation fields (`U0`, `TrailingInts1`, `TrailingInts2`, `Trailing_b64`, `RawCount`, etc.) are written from the Dictionary unchanged.
4. **`save_v1.gd`** — envelope load/save. `load_save(path: String) -> Dictionary` reads JSON, dispatches through migration loop, returns the envelope Dictionary. `save_save(envelope: Dictionary, path: String) -> Error` stamps `savedAt` and writes pretty-printed JSON. Constants: `CURRENT_VERSION = 1`, default path `user://save.json`.
5. **`migrations/`** — directory reserved for future migration step functions. Phase 3 ships the dispatcher (`while save.version < CURRENT_VERSION: save = apply_one_migration(save)`) but no migration files — at v1 with `CURRENT_VERSION=1` the loop is a no-op. The dispatcher's testable behavior at this stage is *negative*: it accepts v1 saves unchanged, rejects v2+ saves with a clear `push_error`, and rejects envelopes missing the `version` field with a clear error. Real migration files land when a real format change requires one (Phase 4+).

**One new Go module** at `tool/dump_legacy_fixtures/`:

A small standalone CLI (separate from `build_tool` because it's a test-fixture concern, not an asset-pipeline concern). Reads `tool/file_types/testdata/<name>.{caf,dat}`, decodes via the existing Phase 0b parsers, emits PascalCase JSON via `json.MarshalIndent` to `godot/test/fixtures/save/<name>.json`. Run manually as `go run ./tool/dump_legacy_fixtures` whenever Go parsers change. Output committed to git as the cross-validation oracle.

---

## 2. JSON envelope schema

The going-forward save file at `user://save.json`:

```json
{
  "version": 1,
  "savedAt": "2026-04-25T15:18:00Z",
  "playerSave": {
    "Version": 63,
    "PreStrings": { "RawCount": 4, "Strings": ["...", "...", "...", "..."] },
    "PostStrings": { "RawCount": 1, "Strings": [] },
    "Trailing_b64": "AAECAwQF...",
    "_comment": "all other SaveGame Go-struct fields, PascalCase keys"
  },
  "playerCafe": {
    "U0": 1.0,
    "TrailingInts1": [0, 0, 1],
    "TrailingInts2": [],
    "_comment": "all Cafe Go-struct fields, PascalCase keys"
  },
  "friendCafes": [
    {
      "Version": 1,
      "State": { "...": "..." },
      "Cafe": { "...": "..." }
    }
  ]
}
```

Top-level fields:

- **`version`** — Godot-side schema version, independent of the legacy `SaveGame.Version=63` byte (which lives nested inside `playerSave`). Starts at 1 in this spec. Bumped only when the *envelope* schema changes — adding fields to `playerSave` is not a version bump as long as old saves still parse.
- **`savedAt`** — ISO 8601 UTC timestamp stamped at write time. Useful for save-slot UI; not load-bearing.
- **`playerSave`** — Dictionary mirroring the Go `SaveGame` struct field-for-field. Preserves every byte of the legacy `globalData.dat` (including the `Trailing []byte` ~1 KB tail).
- **`playerCafe`** — Dictionary mirroring the Go `Cafe` struct. Preserves every byte of `playerCafe.caf`.
- **`friendCafes`** — Array of Dictionaries mirroring the Go `FriendCafe` struct. Optional; absent or empty means no friend cafe is currently cached. Maps to the legacy `ServerData.dat` (and any future per-friend caches Phase 5 introduces).

**Key naming convention: PascalCase, mirroring Go's default `json.Marshal` output.** This is the existing convention used by every `*.bin.mid.json` file `build_tool` already produces under `build_godot/assets/data/`. Adopting it here means the cross-validation test oracle (Layer 2) compares Dictionaries directly with no key-shape translation.

**Opaque byte slices use base64 strings with `_b64` suffix.** Fields like `SaveGame.Trailing []byte` (~1 KB of unparsed tail data preserved for round-trip fidelity) become:

```json
"Trailing_b64": "AAECAwQF..."
```

The `_b64` suffix is a marker for the writer: any Dictionary key ending in `_b64` is base64-decoded back to `PackedByteArray` before being written to the binary stream. Avoids the JSON bloat of integer arrays (`[0, 1, 2, 3, ...]`) and keeps the on-disk JSON file readable.

GDScript handles base64 via `Marshalls.base64_to_raw(s) -> PackedByteArray` and `Marshalls.raw_to_base64(bytes) -> String`. Go uses `encoding/base64.StdEncoding` (default Go `json.Marshal` of `[]byte` already produces standard base64; the `_b64` suffix is a renaming concern handled in the Go side via per-field aliases or a thin translation in `dump_legacy_fixtures`).

**Versioning semantics:**

- The envelope `version` field is the single source of truth for migration dispatch.
- v1 = this spec.
- Future migrations live as discrete functions in `godot/scripts/save/migrations/v1_to_v2.gd` etc. Each takes a Dictionary at version N and returns a Dictionary at version N+1.
- Forward-only: a v1 reader refuses v2+ saves with a clear `push_error` and aborts. Players never downgrade their save by running an older client.
- We do NOT pre-design v2. YAGNI. The framework exists; real migrations land when a real format change requires one.

---

## 3. Test and validation strategy

Three orthogonal test layers, each catching a different failure class. All run in `godot/test/test_save_round_trip.gd`, which is separate from the existing `validate_assets.gd` because save-format correctness is a different concern from asset-import correctness — different signal in CI logs, different change cadence.

### Layer 1 — GDScript byte-identical round-trip

The headline test. For each of the 5 real device fixtures:

```gdscript
var bytes_in: PackedByteArray = FileAccess.get_file_as_bytes("res://test/fixtures/save/playerCafe.caf")
var dict: Dictionary = LegacyLoader.parse_cafe(bytes_in)
var bytes_out: PackedByteArray = LegacyWriter.write_cafe(dict)
assert(bytes_in == bytes_out, "Round-trip mismatch for playerCafe.caf")
```

Mirrors `TestRealCafeFixturesRoundTrip` / `TestRealSaveGameFixturesRoundTrip` / `TestRealFriendCafeFixturesRoundTrip` from the Go side. Catches **reader/writer asymmetry** in the GDScript port — the most common bug class when porting a parser.

Fixtures in `godot/test/fixtures/save/` (~63 KB total, copied from `tool/file_types/testdata/`):

| Fixture | Format | Size |
|---|---|---|
| `playerCafe.caf` | `Cafe` | 20,129 B |
| `BACKUP1.caf` | `Cafe` | 20,017 B |
| `globalData.dat` | `SaveGame` | 1,626 B |
| `BACKUP1.dat` | `SaveGame` | 1,556 B |
| `ServerData.dat` | `FriendCafe` | 20,747 B |

### Layer 2 — Go ↔ GDScript Dictionary cross-validation

For each fixture, the GDScript-decoded Dictionary must deep-equal the Go-decoded JSON loaded via `JSON.parse_string`:

```gdscript
var dict_gd: Dictionary = LegacyLoader.parse_cafe(bytes_in)
var json_text: String = FileAccess.get_file_as_string("res://test/fixtures/save/playerCafe.caf.json")
var dict_go: Dictionary = JSON.parse_string(json_text)
assert(deep_equal(dict_gd, dict_go), "Cross-language shape mismatch for playerCafe.caf")
```

Catches **silent semantic divergence** — bytes round-trip in GDScript but the Dictionary shape disagrees with Go. This would break Phase 5 server interop, where the server expects to round-trip Go-shaped Dictionaries through binary.

`deep_equal(a, b)` is a small helper that recurses through Dictionary, Array, and base64-string field values. JSON-parsed integers come back as floats in Godot; the helper coerces both sides to canonical types before comparing primitives.

### Layer 3 — Envelope round-trip

```gdscript
var envelope: Dictionary = build_envelope_from_fixtures()
var path: String = "user://test_save.json"
SaveV1.save_save(envelope, path)
var loaded: Dictionary = SaveV1.load_save(path)

# Original fixtures must still round-trip after envelope serialization
for fixture in [["playerCafe.caf", "playerCafe", "Cafe"], ...]:
    var dict: Dictionary = loaded[fixture[1]]
    var bytes: PackedByteArray = LegacyWriter["write_" + fixture[2].to_snake_case()].call(dict)
    var original: PackedByteArray = FileAccess.get_file_as_bytes("res://test/fixtures/save/" + fixture[0])
    assert(bytes == original)
```

Catches **base64 encode/decode bugs**, **envelope schema bugs**, and any **silent type-coercion in `JSON.stringify`/`parse`**. Godot's JSON treats all numbers as `float`; int fields need explicit handling on the way out, and this layer is what catches a missed cast.

### CI integration

Append to `.github/workflows/godot-validation.yml`:

```yaml
- name: Run save round-trip tests
  run: |
    "${GODOT}" --headless --path godot/ --script res://test/test_save_round_trip.gd
```

Runs on every push and pull request. First green run on `main` is the Phase 3 done signal.

---

## 4. Implementation sequencing

Phase 3 splits cleanly into **4 sessions**, each with a concrete acceptance criterion. Order matters — earlier work is load-bearing for later work.

### Session 1 — Foundation: primitives + `Cafe` round-trip

Goal: prove the GDScript port architecture works on the meatiest format. `Cafe` is chosen first because `FriendCafe` embeds `CafeState + Cafe` and `SaveGame` shares sub-records (`CharacterInstance`).

Deliverables:
- `godot/scripts/save/primitives.gd` — `BinaryReader` / `BinaryWriter` classes
- `godot/scripts/save/legacy_loader.gd` — `parse_cafe` + sub-records (`FoodStack`, `Stove`, `ServingCounter`, `CafeWall`, `CafeObject`, `CafeFurniture`, `CafeTile`, `Food`)
- `godot/scripts/save/legacy_writer.gd` — symmetric `write_cafe` + sub-record writers
- `godot/test/fixtures/save/{playerCafe.caf, BACKUP1.caf}` copied from `tool/file_types/testdata/`
- `godot/test/test_save_round_trip.gd` — Layer 1 only, for the two `Cafe` fixtures

Acceptance: `OK 2/2` from `godot --headless --script res://test/test_save_round_trip.gd`, both `Cafe` fixtures byte-identical.

### Session 2 — Remaining formats: `SaveGame` + `FriendCafe`

Goal: complete legacy-binary support across all three families.

Deliverables:
- `legacy_loader.gd` extended with `parse_save_game`, `parse_friend_cafe`, `parse_character_instance`, `parse_cafe_state`, `parse_save_strings`
- `legacy_writer.gd` extended with corresponding writers
- 3 more fixtures copied: `globalData.dat`, `BACKUP1.dat`, `ServerData.dat`
- `test_save_round_trip.gd` extended to all 5 fixtures

`SaveGame` is the trickier of the two new formats because of:
- The `SaveStrings` count-1 quirk (`RawCount=0` and `RawCount=1` both decode to zero strings; the `RawCount` field must be preserved separately from `len(Strings)`)
- The ~1 KB `Trailing []byte` preservation field past the known struct fields, which becomes `Trailing_b64` in the Dictionary

`FriendCafe` is mostly orchestration on top of Session 1's `Cafe` work — `byte Version + CafeState + Cafe`.

Acceptance: `OK 5/5` — all five real device fixtures round-trip byte-identically in pure GDScript.

### Session 3 — Cross-validation oracle + JSON envelope

Goal: prove the GDScript Dictionary shape matches Go's, then bolt on the going-forward JSON save format.

Deliverables:
- `tool/dump_legacy_fixtures/main.go` — small standalone CLI. Reads each fixture in `tool/file_types/testdata/`, encodes via existing Go parsers, emits PascalCase JSON to `godot/test/fixtures/save/<name>.json`
- 5 golden JSON files committed
- `test_save_round_trip.gd` Layer 2 — deep-dict-equal each GDScript-parsed fixture against its Go-produced JSON twin, with `deep_equal()` helper
- `godot/scripts/save/save_v1.gd` — envelope load/save, version dispatch (no migration files yet; the dispatcher's negative-path tests cover v2+ rejection and missing-version rejection)
- `test_save_round_trip.gd` Layer 3 — envelope round-trip, plus dispatcher rejection cases for v2 and missing-version envelopes
- `.github/workflows/godot-validation.yml` extended to run the new test script

Acceptance: Layers 1, 2, 3 all green locally and in CI on first push.

### Session 4 — Polish and close-out

Deliverables:
- `docs/rewrite-plan.md` — mark Phase 3 as done, update Phase 5 prerequisites
- `docs/handoff.md` — regenerate (the doc is 6 days stale as of this spec; this is the natural time to refresh)
- `docs/devlog/2026-04-XX-phase-3-save-format.md` — devlog entry covering the architecture decision, the GDScript-specific surprises encountered (e.g. `JSON.parse_string` returning floats, `PackedByteArray` indexing, type coercion), and the legacy ↔ JSON bridge model for future reference

Acceptance: README / rewrite-plan / handoff all reflect that Phase 3 is closed; Phase 4 (game tick) is the next active phase.

---

## 5. GDScript-specific gotchas to expect

Anticipated friction during the port:

- **`JSON.parse_string` returns floats for everything.** Integer fields in the Go struct (e.g. `int16`, `int32`) come back from JSON parsing as 64-bit floats. The cross-validation `deep_equal` helper coerces both sides to a canonical type before comparing; the migration framework will need similar care if it operates on numeric fields.
- **`PackedByteArray` is 0-indexed, slicing uses `slice(start, end)`.** No surprises versus Python-ish semantics, but test the boundaries — a `bytes_in.slice(0, 4)` for a BE int32 read is the right shape.
- **GDScript has no `panic`.** Use `push_error` + early return. The `BinaryReader` should track an internal `failed: bool` flag set by any short read; downstream callers check it before treating output as valid.
- **`String` is UTF-8 by default**, but the legacy format uses BE int16 length-prefixed UTF-8 strings. Length is in bytes, not code points. Convert via `bytes.slice(pos, pos + length).get_string_from_utf8()`.
- **Dictionaries in GDScript are ordered (insertion order)** as of Godot 4. JSON round-trip preserves order, but the cross-validation `deep_equal` should not depend on order — Go's `json.Marshal` for structs uses field-declaration order, but a `deep_equal` should compare by key set, not by iteration order.
- **No `int32` vs `int64` distinction in GDScript** — all ints are 64-bit. The serializer must explicitly mask / range-check when writing int8/16/32 to ensure the bytes match Go's output.

These will be discovered and documented in the devlog as Sessions 1-3 progress.

## Verification plan

No automated tests beyond the three layers above — Phase 0b's Go round-trip suite remains the canonical oracle, and the GDScript port is gated against it. Manual verification per session:

1. **After Session 1:** run `godot --headless --path godot/ --script res://test/test_save_round_trip.gd` locally, expect `OK 2/2`. If not, narrow the failure to a specific sub-record by adding focused asserts.
2. **After Session 2:** same command, expect `OK 5/5`. The `SaveStrings` quirk is the most likely failure point; the `_b64` suffix handling for `Trailing` is the second.
3. **After Session 3:** run `go run ./tool/dump_legacy_fixtures` to regenerate the JSON oracle, then run the GDScript test, expect all three layers green. Push to GitHub and confirm CI is green on first run.
4. **After Session 4:** all three docs updated; `git log --oneline` shows a clean Phase 3 commit history.

If any session's acceptance fails, do not proceed to the next session — diagnose and fix in place. Phase 3 has no partial-credit checkpoint; it ships when all 5 fixtures round-trip in CI.

## Rollback

Each session's work lands as 1-2 commits. `git revert` on the relevant commits is the rollback path. No generated artifacts under `build_godot/`, `godot/.godot/`, or `tool/dump_legacy_fixtures/` build output are committed; all are regeneratable. The 5 fixture JSON files at `godot/test/fixtures/save/*.json` are committed and would also need reverting if the dump tool changes.

The legacy APK build path is untouched by this spec. Rolling back Phase 3 has no impact on the patched Android APK or its smali / `ZombieCafeExtension.cpp` patches.
