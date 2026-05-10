# 2026-05-10 — Phase 3 close-out: save format bridge from binary to GDScript-native JSON

**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))
**Phase:** 3 closed (Sessions 1-4 spanning 2026-04-25 → 2026-05-10)
**Predecessor:** `docs/superpowers/specs/2026-04-25-godot-save-format-bridge-design.md`

This entry is the close-out for Phase 3 of the Godot rewrite. It captures the architectural decision Phase 3 settled, the per-session arc, the per-format surprises encountered during the GDScript port, and the load-bearing design choices that future sessions inherit.

## TL;DR

- **Phase 3 is closed.** Five real device fixtures (two `Cafe`, two `SaveGame`, one `FriendCafe`) round-trip byte-identically through pure GDScript. CI runs the test runner on every push.
- **Architecture decision: option 3 from the rewrite plan** — port the Go `file_types` parsers to GDScript — over GDExtension's per-platform native shared-library matrix or a subprocess at asset-import time only. Cross-platform reach (web, iOS) made options 1 and 2 untenable.
- **Going-forward save format is a single Godot-native JSON file** at `user://save.json` carrying every byte of the legacy formats inside a versioned envelope. Migration dispatcher is scaffold-only at v1; real migrations land when a real format change requires one (Phase 4+).
- **Three orthogonal test layers running in CI** — byte-identical Layer 1, Go-Dict ↔ GDScript-Dict cross-validation Layer 2, JSON envelope round-trip Layer 3. **207 PASS / 0 FAIL** on the headless test runner.

## Why this phase mattered

Phase 3 closed `docs/rewrite-plan.md`'s longest-standing open question — "Go ↔ Godot integration path is undecided" — which had been on the open-questions list since the 2026-04-11 kickoff. The rewrite plan listed three candidates:

1. **`c-shared` GDExtension** wrapping `tool/file_types` as a per-platform native shared library
2. **Subprocess at asset-import time only**, no runtime Go dependency, Godot reads JSON
3. **Port `tool/file_types` save parsers to GDScript**, accepting duplicate-maintenance cost

Option 1 fails on the cross-platform goal: GDExtension on web is wobbly in Godot 4, and even where it works the per-platform `.so` / `.dll` / `.dylib` / `.wasm` matrix is fragile relative to the payload size (saves are 1.6 – 20 KB, no native-performance pressure). Option 2 is impossible on web (no subprocesses in the browser sandbox) and effectively impossible on iOS (no `fork+exec` in the standard sandbox). Option 3's duplicate-maintenance cost is bounded — the formats have been stable since 2011 and `file_types` reached feature-completeness in Phase 0b.

The deeper architectural decision Phase 3 settled was *the legacy binary is a bridge, not a forever format*. Phase 3's done criterion in the rewrite plan ("the Godot client can ... write it back out byte-identically") carried an ambiguity: is the binary the forever format, or is byte-identical round-trip a one-time fidelity proof? The spec resolved it in favor of the latter:

- Text JSON survives Godot version upgrades (Godot 4 → 5) where `Resource` (`.tres`) historically breaks; coupling saves to `class_name` choices is an avoidable footgun.
- The Go tooling already emits PascalCase JSON for every `*.bin.mid.json` under `build_godot/assets/data/`; matching that convention in the Godot client reuses the existing test oracle for free.
- Adding a new field for a Phase 4 feature is a JSON key add, not a binary format extension that the legacy parser also has to tolerate.
- The legacy binary contract still matters at exactly two well-defined boundaries — legacy save import on first run, and server upload in Phase 5 — neither of which needs the in-memory representation to also be binary.

## The four-session arc

The work was split into four sessions per the spec, each with a concrete acceptance criterion that gated the next.

### Session 1 (2026-04-25, commit `d02a00de`) — primitives + Cafe round-trip

Foundation. `BinaryReader` / `BinaryWriter` mirroring `tool/file_types/binary_reader.go` field-for-field: BE ints, LE floats, BE int16 length-prefixed UTF-8 strings, Date struct. Cafe family parsers and writers — `parse_cafe` plus all 8 sub-record parsers/writers (`FoodStack`, `Stove`, `ServingCounter`, `CafeWall`, `CafeObject`, `CafeFurniture`, `CafeTile`, `Food`). Two real fixtures (`playerCafe.caf`, `BACKUP1.caf`) round-trip byte-identically.

The non-obvious part was getting GDScript's failure semantics right. GDScript has no exceptions, so the `BinaryReader` uses a `failed: bool` flag pattern: short reads call `push_error` and set `failed = true`; subsequent reads short-circuit. Top-level callers check `reader.failed` after parsing. This matches the Go `panic`-on-short-read shape closely enough that consumer code reads almost identically across the two languages — just with a single check at the top of each `parse_*` instead of an implicit panic propagation.

**87 PASS / 0 FAIL.**

### Session 2 (2026-05-02, commit `0b059166`) — SaveGame + FriendCafe

Completes legacy-binary support across all three save-family formats. `parse_save_game` was the trickier of the two new formats because of:

- The **`SaveStrings` count-1 quirk** — `RawCount=0` and `RawCount=1` both decode to zero strings, so `RawCount` must be preserved separately from `len(Strings)`. The GDScript port stores both fields in the Dictionary, mirroring the Go struct.
- The **~1 KB `Trailing []byte`** preservation field past the known struct fields, which becomes `Trailing_b64` (standard base64) in the Dictionary per the spec's `_b64` suffix convention.

`parse_friend_cafe` is mostly orchestration — three lines of plumbing on top of Session 1's `parse_cafe`: leading byte version + `CafeState` + `Cafe`.

But the load-bearing surprise of Session 2 was a **forced architectural deviation from the spec**:

> `read_string` returns `PackedByteArray`, not `String`.

The legacy `globalData.dat` contains `\r\0` byte suffixes inside `CharacterInstance.Name` strings. Godot's `String` cannot hold a NUL codepoint — the engine substitutes embedded NULs at the Variant boundary, so byte-faithful round-trip is impossible if you decode through `String`. The fix was to keep `read_string` returning the raw `PackedByteArray` and let `write_string` accept either `PackedByteArray` or `String` via `Variant`. Test helpers (`_str_eq`, `_string_array_eq`) bridge the two representations.

This deviation makes Layer 1 fully byte-faithful but pushes complexity into Layer 3's JSON serialization — discussed below. **`binary_reader.gd:125-132` carries the explanatory comment for future readers.**

**170 PASS / 0 FAIL.**

### Session 3 (2026-05-02, commit `c3f90174`) — oracle + envelope + CI

The three-layer test plan from the spec, plus the going-forward JSON envelope.

`tool/dump_legacy_fixtures/main.go` is a small standalone Go CLI that reads each fixture in `tool/file_types/testdata/`, parses via the existing `Read*` functions, and emits PascalCase JSON to `godot/test/fixtures/save/<name>.json`. Run on demand whenever the Go parsers change. Two trivial Go-side adjustments to make the JSON shape match GDScript:

- `SaveGame.Trailing []byte` gained `json:"Trailing_b64"` so the JSON key matches the GDScript Dictionary's `Trailing_b64`.
- `FoodStack.U2` (vestigial — declared but never read or written) gained `json:"-"` so it's excluded from the JSON oracle, matching the GDScript Dictionary which also omits it.

`save_v1.gd` is the going-forward JSON envelope. `save_save(envelope, path)` and `load_save(path)` plus a recursive `_to_json_safe` / `_from_json_safe` walker that decides per-value how to serialize a `PackedByteArray`:

```gdscript
# clean UTF-8, no embedded NULs              -> plain JSON string
# anything else                               -> {"_b64": "<base64>"}
```

This is the resolution to Session 2's architectural deviation. Layer 1 is byte-faithful through the loader/writer; Layer 3 needs a way to serialize bytes through JSON without losing them. The hybrid scheme keeps the on-disk JSON file readable for the 99% of strings that ARE clean UTF-8 (most `Name` and `Strings` fields) while still supporting the edge cases (legacy `\r\0`-suffixed names, opaque `Trailing` bytes, anything else that comes up as Phase 4 evolves the schema).

The migration dispatcher loops `while envelope.version < CURRENT_VERSION`, but `CURRENT_VERSION = 1` and v1 is the only version, so the loop is a no-op today. The negative-path tests cover the cases that matter: v2 envelope rejected (forward-only — players never downgrade their save by running an older client), missing-version rejected, missing-file rejected, non-object root rejected. Real migration files (`migrations/v1_to_v2.gd`) land when a real format change requires one — Phase 4 onwards.

`.github/workflows/godot-validation.yml` got a "Run save round-trip tests" step, runs on every push and pull request. **207 PASS / 0 FAIL.**

### Session 4 (2026-05-10, this entry) — close-out

This devlog, the rewrite-plan update, the handoff regeneration. No code, no test changes.

## What I want to remember

- **Byte preservation, not byte understanding**, is the right primitive for legacy formats. The Go side of `file_types` already used this pattern in Phase 0b (the `Trailing []byte` field on `SaveGame`, the `U0` / `TrailingInts1` / `U6Alt` / `FurnitureType` placeholder fields). Carrying it forward to the GDScript port and to the JSON envelope (`Trailing_b64`) lets us round-trip bytes we don't yet understand without committing to a wrong interpretation. Same lesson the animation parser internalized in Phase 1b (the opaque `Tail []byte`).

- **The legacy binary's edge cases drive the cross-language data model.** The `\r\0`-suffixed `CharacterInstance.Name` is one byte sequence in one fixture, but it forced `read_string` to return `PackedByteArray` everywhere, and through that the JSON envelope to need a hybrid `{"_b64": ...}` scheme. Don't decide the in-memory representation until you've round-tripped the actual bytes — what looks like "a string field" may not be a Godot `String` at all.

- **Layer 2 cross-validation is lossy on string fields by design.** Once `read_string` returns `PackedByteArray`, comparing GDScript Dicts to Go-via-JSON Dicts can't be byte-exact on string fields — Go's `json.Marshal` produces JSON Strings, and Godot's `JSON.parse_string` substitutes embedded NULs with U+FFFD (with diagnostic stderr). Layer 1's byte-identical round-trip already proves byte-faithfulness; Layer 2's job is **structural agreement** — same fields, same nesting, same types modulo coercion. Putting that boundary in the right place was a 30-minute architectural call that saved hours of trying to make `_deep_equal` byte-faithful.

- **`JSON.parse_string` returns `float` for every number.** The `_deep_equal` helper coerces both sides to float-with-tolerance before comparing primitives. Tolerance is both absolute and relative (`max(1e-6, max(abs(a), abs(b)) * 1e-6)`) because Go's `json.Marshal` of float32 emits the shortest decimal representation and Godot's reconstructed float64 differs from the original float32 by up to half a ULP at float32 precision (~1e-7 relative). Future numeric-field migration code will need similar care.

- **Dictionary insertion order is observable.** As of Godot 4, `Dictionary` preserves insertion order; JSON round-trip preserves that order. Don't write `_deep_equal` to depend on iteration order — Go's `json.Marshal` for structs uses field-declaration order, but a comparison helper should be set-based.

- **"First green CI run on `main`" is a clean done signal.** It separates "the test runner passes locally" from "the test runner passes in a fresh Linux runner with a downloaded Godot binary, on every push, going forward." The latter is what Phase 4 inherits as a regression baseline.

- **One canonical oracle, two consumers.** The Go round-trip suite under `tool/file_types/...` remains the canonical oracle for what each binary format means. The GDScript port is gated against it — Layer 1 against the same fixtures, Layer 2 against `tool/dump_legacy_fixtures`'s output. There is no independent fuzzing of the GDScript parser; the spec deliberately rejected that as out of scope. If the Go parsers change, regenerate the JSON oracle and re-run the GDScript tests; that's the contract.

## What's next

Phase 3 is closed. The two unblocked phases:

- **Phase 4 (game tick loop)** is the immediate next phase. Customers spawn, walk to tables, order food, wait for the stove, eat, pay, and leave. XP and money update. The tick loop reads and writes saves continuously, so Phase 3's save-load path is the immediate predecessor.

- **Phase 5 (online features)** is also unblocked. Server upload of binary saves can now be plumbed against the GDScript writer — `write_save_game(dict) -> PackedByteArray` is already callable from the network layer. The 90% server-drop throttle removal listed in the rewrite plan is a separate decision for Phase 5.

The two open Phase 1b items (`constants.bin.mid` mixed-endian, `font3.bin.mid` custom bitmap font) and the cosmetic items (bitmap font conversion, social icon copy) remain as low-priority polish, runnable any time, none blocking gameplay.
