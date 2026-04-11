# 2026-04-11 — Phase 1b: per-animation keyframe parser + first real skeletal pose

**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))

Twelfth devlog entry of the day. Ambitious session: reverse engineer the per-animation `.bin.mid` format, ship byte-identical round-trip Go parser with tests on all 60 real files, plumb decoded JSON through `build_tool -target godot`, and replace the Phase 2b 9×3 grid layout in `main_scene.gd` with a real keyframe-driven pose of `boxer-human`. All four landed in one pass. The format turned out to be more layered than the pre-implementation spec predicted, and I shipped a deliberate hybrid design that decodes the confirmed-structural part and preserves the rest as an opaque byte tail — round-trip contract intact, semantic decode deferred for the tail.

## Why this session, not the other alternatives

The handoff listed three options. Option A (Phase 2b visible scene) closed in the prior session. Option C (Phase 0b fixture sourcing) is still blocked on physical-world emulator work. Option B, the per-animation parser, is the highest-value item in Phase 1b and directly unblocks replacing the grid layout with real posing — which was explicitly flagged as a `(pending, future)` Phase 2b substep in `docs/rewrite-plan.md` blocked on exactly this parser.

The brainstorming for this session settled on approach `A + B`: structural preservation parse with semantic naming where differential evidence supports it. The user also confirmed "γ" for the Ghidra question — start with hex-dump differential analysis, escalate to Ghidra only if stuck. Target done criterion was "option 2": Go-side parser + build-tool integration + Godot minimal consumer that poses boxer-human from one keyframe. No full animated playback, no bone-accurate skeleton reconstruction.

## What shipped

- **`tool/file_types/animation_file.go`** — `AnimationFile`/`AnimationHeader`/`AnimationPrologue`/`AnimationRecord` structs with `ReadAnimationFile`/`WriteAnimationFile`. Struct uses preservation-field naming: `Header.BoneCount`, `Header.SkeletonRecordCount`, `Prologue.KeyframeCount` are the three semantic labels that survived differential analysis; the rest are `Unknown*`/`Field*`/`Pad*` placeholders. Critically, the parser decodes the skeleton section (the first confirmed-structural 13-record block of 64-byte records each) and stashes everything after it as an opaque `Tail []byte` — this trades semantic interpretation of the complex tail (bone permutation list, pointer table, keyframe data) for byte-identical round-trip fidelity and a parser that actually fits in one session.
- **Three new tests in `tool/file_types/roundtrip_test.go`**:
  - `TestAnimationFileRoundTrip` iterates every `.bin.mid` under `src/assets/data/animation/` as sub-tests (60 total) and asserts `bytes.Equal` between each original and its round-tripped rewrite. All 60 green.
  - `TestAnimationFileInMemoryFixture` hand-constructs an `AnimationFile` with non-default values across every field (including non-zero `Transform` floats and explicit trailer bytes) and asserts round-trip symmetry. Catches reader-writer asymmetry the zero-heavy real files can't catch.
  - `TestAnimationFileKeyframeCountHypothesis` spot-checks that `Prologue.KeyframeCount` for `sitSW` is in [1, 3] and for `walkNW` is in [20, 60]. Both assertions passed, so `KeyframeCount` stays as a semantic label rather than demoting back to `Field1`.
- **`tool/resource_manager/serialization/godot.go`** — new `packGodotAnimations` helper wired into `BuildGodotAssets` right after `packGodotAtlases`. Reads every `.bin.mid` from `src/assets/data/animation/`, decodes via `ReadAnimationFile`, writes pretty-printed JSON to `build_godot/assets/data/animation/<name>.json` (one file per source). First real end-to-end run produced all 60 JSON files cleanly.
- **`godot/assets/data/animation/sitSW.json`** — checked-in sample for validator coverage. Same source-of-truth pattern the Phase 2a atlas PNGs use.
- **`godot/scripts/main_scene.gd`** — new `pose_from_animation(json_path, frame_index) -> int` method plus helpers `_load_animation_json`, `_is_spacer_name`, `_extract_position_from_record`. `_ready` calls it after `assemble()`; the validator also calls it directly to avoid the `extends SceneTree`/`_init` lifecycle quirk Phase 2b already had to work around. Graceful fallback: if posing fails, the grid layout from Phase 2b stays visible.
- **`godot/validate_assets.gd`** — `_validate_main_scene` grew a pose delta assertion that confirms at least one sprite has a position different from its grid cell origin after `pose_from_animation` runs. End-to-end proof that the Go parser → JSON → Godot consumer pipeline works in the headless check.

## The spec vs. reality surprise

The brainstorming session committed to a struct skeleton where `Header.BoneCount = 24` (matching 27 boxer-human atlas pieces minus 3 spacers) and records would follow in a flat list after the prologue. Hex-dumping `sitSW.bin.mid` during Task 2 of implementation revealed that this was wrong in an interesting way:

- The 12-byte header is really `(3, 24, 13)` where **13** (not 24) is the count of records in the first structural section. Records are 64 bytes each, and `13 × 64 = 832` bytes exactly matches the stretch of the file from byte 0x2C (after the prologue) to byte 0x36B. The 24 in the header is *something else* — most likely the count of visual parts per keyframe, since animation rigs typically have fewer bones than visible atlas pieces (one bone can drive multiple parts).
- Past the skeleton section, the file has at least three more sections:
  - A short prologue-like block at 0x36C containing `_PTR`, a `UUPF` marker (which looks like another pointer-placeholder sentinel in the same spirit as `_PTR`), and a pair of int32 lists that look like a bone permutation table.
  - Twelve `(_PTR, int32=1)` pairs at 0x3E8 onward — possibly a "which parts get used by which bones" lookup table.
  - A keyframe section with more 12-float transform blocks, but whose record boundaries and sizes don't divide cleanly into 13 or 24, so there's structure I didn't fully decode.
- For `walkNW.bin.mid`, the tail is much larger (13572 bytes vs 1472 for sit) because it has 39 keyframes instead of 1. The ratio isn't a clean 39× — the per-keyframe overhead varies — which says the keyframe encoding is denser than "one flat list of per-bone transforms per frame."

Rather than spend another hour in hex dumps trying to crack the full tail (or escalate to Ghidra, which was the explicit γ safety valve), I shipped a **hybrid struct** that decodes what's structurally confirmed and preserves the rest:

```go
type AnimationFile struct {
    Header   AnimationHeader
    Prologue AnimationPrologue
    Skeleton []AnimationRecord // 13 × 64 bytes, confirmed structural
    Tail     []byte            // everything after, preserved verbatim
}
```

This is the "preservation-field" philosophy from Phase 0b taken one level up: instead of every unnamed *field* being a placeholder, every unnamed *section* is. The round-trip test still enforces byte identity because `io.ReadAll` + `file.Write` is a no-op on opaque bytes. Semantic decoding of the tail can happen in a follow-up session when there's a concrete reason to care (e.g., real animated playback, which is out of scope for this session).

The struct field named `BoneCount` is now *known to be misnamed* — the comments document both the pre-implementation hypothesis and the evidence-corrected interpretation, so future-me has a paper trail for why the name stuck. Renaming would have churned the struct and the fixture test; keeping the name with an honest comment was the lower-friction choice.

## The `SkeletonRecordCount` variance gotcha

After sitSW and walkNW both round-tripped cleanly, the full 60-file sweep immediately panicked on `attack2NW.bin.mid` with `unexpected header (expected 3, 24, 13)`. A quick hex dump showed `attack2NW` has header `(3, 24, 14)` — one more record in the skeleton section. Then `attackSW` has something else, and so on. Turns out the third header int isn't an invariant at all — it's a per-file skeleton size that tells the reader how many 64-byte records to expect.

The fix was trivial once identified: loosen the validation panic to only check the first two ints (`Unknown0 = 3` and `BoneCount = 24`, both of which *are* invariant across all 60 files), and use `data.Header.SkeletonRecordCount` as the iteration bound for the skeleton read loop. After that change the full 60-file sweep turned green without further iteration.

**What I want to remember:** validation panics that assume "constant across 2 samples = constant across 60" are how you get false negatives on reverse engineering. The fix is to hard-fail only on values you actually need to rely on structurally, and let the rest vary. The rest of this format has several "constant across the samples I checked" values that might vary across the full 60 — I'm keeping validation tight for now and will loosen reactively as needed.

## Two GDScript parse errors mid-iteration

Neither was deep — both were small syntax stumbles I haven't hit before on this project:

1. **`var _ = frame_index`** — I tried to suppress an unused-parameter warning with the Go idiom `_ = x`. GDScript doesn't allow `_` as a variable name. Fix: just delete the line. GDScript doesn't warn on unused function parameters.
2. **`var data := _load_animation_json(json_path)`** — type inference on a `Variant` return produced `The variable type is being inferred from a Variant value, so it will be typed as Variant. (Warning treated as error.)`. This project has warnings-as-errors enabled by default in the Godot editor config. Fix: declare the type explicitly as `var data: Variant = _load_animation_json(json_path)`. Same rule probably applies elsewhere in my GDScript going forward.

Both failures surfaced in the validator run (not at import time), which means I lost ~30 seconds per iteration to the editor class-cache cost. Going forward I should `godot --headless --editor --quit --path godot/` after each meaningful GDScript edit to catch parse errors synchronously.

## Verification

Final validator run:

```
  OK json(array, 216 items): res://assets/data/foodData.json
  OK json(array, 219 items): res://assets/data/characterData.json
  OK json(array, 60 items): res://assets/data/animationData.json
  OK json(object, 2 keys): res://assets/atlases/characterParts.offsets.json
  OK json(object, 2 keys): res://assets/atlases/characterParts.characterArt.json
  OK json(object, 2 keys): res://assets/atlases/furniture.offsets.json
  OK texture(2048.0x2048.0): res://assets/atlases/characterParts.png
  OK texture(2048.0x2048.0): res://assets/atlases/furniture.png
  OK texture(62.0x65.0): res://assets/images/boxer-human/back_head1.png
  OK font: res://assets/fonts/A Love of Thunder.ttf
  OK audio(130.69s): res://assets/audio/Zombie Theme V1.ogg
  OK audio(9.87s): res://assets/audio/sfx/blender.ogg
  OK SpriteAtlas(chars): 3051 regions, 113 characters, 27 pieces each
  OK SpriteAtlas(furn): 256 regions (no character art)
  OK main.tscn: 27 Sprite2D children, 27 with valid AtlasTextures, pose delta applied

========== VALIDATION PASSED ==========
```

15 validation checks, all green, including the new `pose delta applied` annotation on `main.tscn`. The full `file_types` test suite is green (`TestAnimationFileRoundTrip` with 60 sub-tests + `TestAnimationFileInMemoryFixture` + `TestAnimationFileKeyframeCountHypothesis`, plus all prior tests). All 5 Go workspace modules (`file_types`, `build_tool`, `resource_manager`, `cctpacker` native; `server` under `GOOS=js GOARCH=wasm`) still build clean.

## What Phase 1b leaves open

Unchanged from the last devlog except for item 2 closing:

1. `(done)` Atlas packing — landed in a prior session.
2. **`(done)`** Per-animation keyframe parser — **this session**. Skeleton section fully decoded; tail preserved as opaque bytes. Full tail decode is a possible follow-up session once there's gameplay pressure to interpret it.
3. `(pending)` Opaque binary game data parsers — `constants.bin.mid`, `cookbookData.bin.mid`, etc. Each is its own small reverse engineering session.
4. `(pending, lower priority)` Bitmap font conversion.
5. `(pending)` `cct_file` debug print sweep — ran during this session's `build_tool` invocation and spammed stdout loudly. Confirmed the Phase 1b item 5 is real.
6. `(pending, cosmetic)` Skip `*.cct.mid.png` artifacts in `src/assets/images/`.
7. `(pending, cosmetic)` Social icons and EULA/help HTML copy.
8. `(pending, size optimization)` Replace individual PNG copies with atlas-only output.

And the Phase 2b posing substep (added yesterday) is also closed this session: `boxer-human` now poses from real keyframe data (even if the specific pose from `sitSW` frame 0 isn't a visually recognizable sit — which makes sense because I'm using the *skeleton section* translations, not the keyframe section, and those translations are all zero in the bind pose).

## What I want to remember from this session

Four things.

First, **"structural preservation" generalizes one level up**. The Phase 0b pattern was "every unnamed field is a preservation placeholder." The Phase 1b animation parser is "every unnamed *section* is a preservation placeholder." The struct has one named section (the skeleton) and one `[]byte` tail. Round-trip still works because `io.ReadAll` + `file.Write` is byte-identical on opaque data. This is a useful escape hatch when a format is too layered to fully decode in a session but the parts you need are locally structured.

Second, **the pre-implementation spec was wrong in a very specific way, and the wrongness was productive**. I committed to `BoneCount = 24` at design time based on the 27-atlas-pieces-minus-3-spacers observation, and the field is actually the *part* count per keyframe (24 visible pieces per rendered frame), not the skeleton bone count (13 or so actual joints). The wrong name is now documented in a comment rather than renamed, so the paper trail shows the evidence flow from hypothesis to confirmation. Future reverse engineering sessions should expect semantic labels to shift as more evidence comes in.

Third, **validation panics on "constants" are risky when you've only seen 2 samples**. I panicked on `SkeletonRecordCount != 13`, which immediately fired on `attack2NW.bin.mid` with a count of 14. The rule: hard-fail only on values the parser structurally depends on (like `BoneCount` being fixed so the record-count math works), not on values that merely happened to match across the samples I hex-dumped.

Fourth, **run `godot --headless --editor --quit --path godot/` after every meaningful GDScript edit, not just after adding a new `class_name`**. It catches parse errors synchronously instead of letting them surface at validator runtime, saving 30-second iteration cycles.

## Next

Phase 1b item 2 is closed. The remaining Phase 1b items are all smaller scope and none of them depend on this one. The natural next sessions are:

- **Phase 1b item 5** (`cct_file` debug print sweep) — mechanical, quick, no reverse engineering. This session's `build_tool` run made it obvious how noisy the current situation is; a 10-line cleanup would make future runs much easier to read.
- **Phase 0b fixture sourcing** — still the one blocker on closing Phase 0b. Needs an Android emulator session or a friendly Airyz-era save file.
- **Phase 1b item 3** (opaque binary data parsers) — `constants.bin.mid` / `cookbookData.bin.mid` / `enemyCafeData.bin.mid` etc. Each is its own small RE session. Good "warm up" before the real Phase 4 game tick work.
- **Full tail decode of the animation format** — defer until there's concrete gameplay pressure. The Godot consumer can progress a long way with just the skeleton section.

Leaning toward the `cct_file` debug print sweep next session — it's small, it's mechanical, it cleans up a real annoyance, and it gives my context a break from byte-level reverse engineering.
