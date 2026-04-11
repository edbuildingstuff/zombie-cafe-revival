# Per-Animation Keyframe Parser — Design

**Date:** 2026-04-11
**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))
**Phases touched:** Phase 1b item 2 (per-animation keyframe parser), Phase 2b "real skeletal posing for `boxer-human`" substep

## Goal

Reverse engineer the `src/assets/data/animation/*.bin.mid` format (60 files, 1.5 – 18 KB each), ship `ReadAnimationFile` and `WriteAnimationFile` in `tool/file_types` with byte-identical round-trip tests on every real file, plumb the decoded JSON through `build_tool -target godot`, and replace the 9×3 grid layout in `godot/scripts/main_scene.gd` with a single-keyframe pose of `boxer-human` driven by the first frame of `sitSW.bin.mid` (or `idleSW.bin.mid` as a fallback). By the end of the session, opening `godot/project.godot` in the Godot 4 editor and pressing Run should show `boxer-human` posed from real keyframe data, not tiled on an arbitrary grid.

## Context

This is the eleventh-plus session on the Zombie Cafe Revival rewrite. Phase 2b closed in the previous session with a visible scene that lays `boxer-human`'s 27 atlas pieces out in a 9×3 grid, applying per-piece `draw_offsets` as a small positional nudge. That grid layout was deliberately provisional — it proved the atlas → `AtlasTexture` → `Sprite2D` rendering path works, but not that the character can be posed into a real skeleton shape. Real posing was called out in `docs/rewrite-plan.md` as a `(pending, future)` Phase 2b substep, blocked on the per-animation keyframe parser that lives in Phase 1b.

The manifest file `src/assets/data/animationData.bin.mid.json` (already decoded in Phase 0a) is a list of `(Form, Type, Direction, AnimationFile)` entries that point at the per-animation files. An entry like `{"Form": 255, "Type": 2, "Direction": 1, "AnimationFile": "sitSW.bin"}` tells us which of the 60 `*.bin.mid` files a given `(form, type, direction)` combination should load — so the manifest is the index, and the files this design targets are the actual payload. Without a parser for the payload, the index can only be inspected, not acted on.

This session is simultaneously closing **Phase 1b item 2** on the Go side (the parser + round-trip tests + build_tool integration) and the **"Real skeletal posing for `boxer-human`"** substep of **Phase 2b** on the Godot side (the consumer that turns decoded keyframes into sprite positions).

## Success criteria

The session is done when all of the following are true:

1. `go test ./tool/file_types/...` runs a new `TestAnimationFileRoundTrip` test that iterates over every `src/assets/data/animation/*.bin.mid` file and asserts `bytes.Equal` between each original file and its round-tripped rewrite. All 60 sub-tests pass.
2. A smaller `TestAnimationFileInMemoryFixture` builds an `AnimationFile` struct by hand, round-trips it, and asserts byte equality. Catches reader-writer asymmetry that the real files don't exercise because of their heavy zero-padding.
3. `go run ./tool/build_tool -i src/ -o build_godot/ -target godot` produces `build_godot/assets/data/animation/*.json` — one JSON file per input `.bin.mid`, pretty-printed.
4. `godot --headless --path godot/ --script res://validate_assets.gd` passes every check it passed at the end of Phase 2b, plus an additional assertion inside `_validate_main_scene` that confirms the sprites are no longer laid out on the grid (at least one sprite has a position different from its grid cell origin, indicating the pose function applied real data).
5. Opening `godot/project.godot` in the Godot 4 editor and pressing Run shows `boxer-human` posed in a visually meaningful configuration — not the grid and not a single point.
6. All 5 Go workspace modules (`file_types`, `build_tool`, `resource_manager`, `cctpacker` native; `server` under `GOOS=js GOARCH=wasm`) still build clean.
7. A devlog entry at `docs/devlog/2026-04-11-phase-1b-animation-parser.md` documents the session; `docs/rewrite-plan.md` marks the two affected substeps as `(done)`.

---

## 1. Architecture and data flow

Four new pieces of code, one lightweight asset copy:

```
src/assets/data/animation/*.bin.mid       (60 files, 1.5 – 18 KB each)
        │
        ▼   [new — tool/file_types/animation_file.go]
  ReadAnimationFile  ─────────────►  AnimationFile struct
        │                                    │
        │                                    ▼   [new — same file]
        │                            WriteAnimationFile
        │                                    │
        │   ▲                                │
        │   └──── round-trip ────────────────┘
        │         (60 sub-tests + in-memory fixture)
        │
        ▼   [new — packGodotAnimations in godot.go]
  BuildGodotAssets
        │
        ▼
  build_godot/assets/data/animation/*.json  (pretty-printed)
        │
        ▼   [checked in for validator coverage]
  godot/assets/data/animation/sitSW.json   (and maybe idleSW.json)
        │
        ▼   [new — pose_from_animation() method]
  main_scene.gd           grid layout from Phase 2b gets replaced
                          with a single-keyframe pose of boxer-human
```

**Four new pieces of code:**

1. **`tool/file_types/animation_file.go`** — the parser and writer. Follows existing `file_types` conventions: top-level `ReadAnimationFile(io.Reader) AnimationFile` and `WriteAnimationFile(io.Writer, AnimationFile)`, uses the panic-on-short-read primitive helpers (`ReadByte`, `ReadInt32`, `ReadFloat32`) for every field, no nested error returns.
2. **`tool/file_types/roundtrip_test.go`** — one new test function for the 60-file real round-trip, plus one function for the in-memory fixture. Matches the sub-test-per-file pattern I plan to introduce so a single-file failure names the file precisely.
3. **`tool/resource_manager/serialization/godot.go`** — a new `packGodotAnimations` helper, wired into `BuildGodotAssets` next to `packGodotAtlases`. Reads every `.bin.mid` in `src/assets/data/animation/`, decodes via `ReadAnimationFile`, writes pretty-printed JSON to `<out>/assets/data/animation/<name>.json`. Mirrors the existing `deserializeAnimationDataForGodot` pattern the same file already uses for the `animationData.bin.mid` manifest.
4. **`godot/scripts/main_scene.gd`** — one new public method `pose_from_animation(json_path, frame_index) -> int`. Called from `_ready` after `assemble()`, and called directly by the validator for headless coverage (same pattern `assemble()` already uses to sidestep the `extends SceneTree` `_ready` lifecycle quirk from Phase 2b).

**One asset copy:** `godot/assets/data/animation/sitSW.json` (and optionally `idleSW.json`) checked in alongside the existing sample assets so the validator has known input.

The Go side is the load-bearing work. Everything else hangs off it.

---

## 2. The Go struct shape and preservation policy

Differential analysis on the two hex-dumped samples (`sitSW.bin.mid` at 1516 bytes and `walkNW.bin.mid` at 13616 bytes) produced enough structural evidence to commit to a skeleton without yet understanding every field's semantic meaning. The key observations:

- **Bytes 0x00 – 0x0B is a 3-int32 header with constant values across both samples: `(3, 24, 13)`.** The `24` is extremely suspicious: `boxer-human` has 27 atlas pieces, of which `0-spacer.png`, `1x1.png`, and `1x1_front.png` are non-bone utility pieces, leaving exactly 24 bone-backed parts. That's strong circumstantial evidence the middle int is bone count.
- **Bytes 0x0C – 0x2B is a 32-byte "prologue" containing four `"_PTR"` ASCII markers at fixed offsets** (`0x0C`, `0x18`, `0x20`, `0x28`), interleaved with eight bytes of int32 data that differ between files:
  - `sitSW`: `(2, 0, 1, 0)` for the four int slots
  - `walkNW`: `(1, 0, 39, 0)` for the four int slots

  The `sitSW` → `1` at slot 2 and `walkNW` → `39` at slot 2 is very suggestive of keyframe count — `sitSW` is a static pose (one frame), `walkNW` is a cyclic animation (39 frames at ~24 fps is a ~1.6-second walk cycle, which is dead-on for typical cartoon walks). This is the one place I'm confident enough to commit to a semantic label early.
- **The `"_PTR"` literal** (4 bytes: `5f 50 54 52`) is almost certainly a serialization-time sentinel where a raw C++ pointer field got replaced with an ASCII magic value so the pointer itself doesn't get written to disk. Common pattern in game engines that `memcpy` their object graphs for fast save/load.
- **Bytes 0x2C onward is a sequence of records, each containing a 12-float block** that reads naturally as a 3×4 affine transform: 3×3 identity rotation (`1 0 0 / 0 1 0 / 0 0 1`) followed by a 3-float translation (`0 0 0`). Most records in both samples hold an identity transform with zero translation — consistent with a "resting pose" skeleton where most bones haven't been moved from their base position yet.
- **Each 12-float block is followed by a trailer** that includes `0xCDCDCDCD` (the MSVC CRT debug-heap uninitialized-memory marker — another strong indicator this file is a raw C++ struct dump from a debug build of the legacy tooling), zero-valued int32s, and `0xFFFFFFFF` (`-1` as int32 or a sentinel value). The exact trailer size isn't nailed down from two samples alone — I'll lock it in during implementation by watching records line up byte-for-byte.

### Struct skeleton

```go
type AnimationFile struct {
    Header   AnimationHeader
    Prologue AnimationPrologue
    Records  []AnimationRecord
    // If differential analysis reveals a trailing block (e.g., a
    // keyframe table separate from the records), it gets added here.
}

type AnimationHeader struct {
    Unknown0  int32 // = 3  in all observed files, maybe format version
    BoneCount int32 // = 24 in all observed files, matches 27 − 3 spacers
    Unknown2  int32 // = 13 in all observed files, meaning TBD
}

type AnimationPrologue struct {
    PtrMarker0    [4]byte // literal "_PTR"
    Field0        int32   // sit=2, walk=1 — probably anim type/subtype flag
    Pad0          int32   // = 0 in all samples
    PtrMarker1    [4]byte // literal "_PTR"
    KeyframeCount int32   // sit=1, walk=39 — strong semantic hypothesis
    PtrMarker2    [4]byte // literal "_PTR"
    Pad1          int32   // = 0 in all samples
    PtrMarker3    [4]byte // literal "_PTR"
}

type AnimationRecord struct {
    Transform [12]float32 // 3×4 affine, row-major (hypothesis)
    Trailer   [N]byte     // fixed-size trailer, size nailed down during impl
}
```

The only semantic name committed at design time is `BoneCount` (heavy circumstantial evidence: matches atlas piece count minus spacers) and `KeyframeCount` (dynamic differential evidence: matches sit-vs-walk expectation). Everything else uses `Unknown*`/`Field*`/`Pad*` placeholders that get upgraded during implementation as differential analysis across all 60 files produces more evidence.

### Preservation policy

**Every byte in the file must be covered by a named field or an explicit byte slice.** Same rule as Phase 0b's cafe/savegame preservation work — we can have `Unknown*` or `Reserved` fields, but we cannot have dropped bytes. The round-trip test (Section 3) is the forcing function: if the writer emits even one byte differently from the reader's consumption, the `bytes.Equal` check on one of the 60 real files fails and names the exact culprit.

If differential analysis reveals a genuinely uninterpreted region (e.g., the `0xCDCDCDCD` markers that are just heap garbage from the original serialization), it lives in a `Reserved []byte` slice and the writer echoes it verbatim. **The reader never discards; the writer never synthesizes.** A field with no confirmed meaning still gets round-tripped.

### What this policy deliberately does NOT do

- **No multi-character skeleton support.** The 60 files all observably target the same `(3, 24, 13)` header, so the parser hard-fails on any file with a different header. Multi-skeleton support is a future phase.
- **No format version migration.** Same reason — every file is version-homogeneous. If a version mismatch ever shows up, the parser will panic with a clear message pointing at the responsible file, and we can add migration then.
- **No "best-effort" parsing that tolerates malformed files.** If a file doesn't round-trip, the test fails and the session stops to investigate. No silent degradation.

---

## 3. Testing strategy

Four layers, each with a distinct purpose:

### Layer 1 — Structural round-trip on all 60 real files

One new test function in `tool/file_types/roundtrip_test.go`:

```go
func TestAnimationFileRoundTrip(t *testing.T) {
    files, err := filepath.Glob("../../src/assets/data/animation/*.bin.mid")
    if err != nil || len(files) == 0 {
        t.Skip("no animation files found")
    }
    for _, path := range files {
        path := path
        name := filepath.Base(path)
        t.Run(name, func(t *testing.T) {
            original, err := os.ReadFile(path)
            if err != nil { t.Fatal(err) }

            parsed := file_types.ReadAnimationFile(bytes.NewReader(original))

            var roundtrip bytes.Buffer
            file_types.WriteAnimationFile(&roundtrip, parsed)

            if !bytes.Equal(original, roundtrip.Bytes()) {
                t.Fatalf("%s: bytes differ (orig %d, got %d)",
                    name, len(original), roundtrip.Len())
            }
        })
    }
}
```

Each of the 60 files becomes a distinct sub-test so a failure produces a precise signal: "`walkSW.bin.mid`: bytes differ at offset 0x180" rather than "animation round-trip failed." Sub-test structure also makes it safe to commit a half-complete parser — I can see exactly which files still flunk as I iterate.

**Why not a single test that aggregates failures.** The iteration speed matters. Running `go test -run TestAnimationFileRoundTrip/sitSW` to focus on one failing file is worth the boilerplate.

### Layer 2 — In-memory fixture

One `TestAnimationFileInMemoryFixture` that constructs an `AnimationFile` with non-default values across every field:
- Non-zero `Field0` / `KeyframeCount`
- 2 records with non-identity `Transform` floats (e.g., rotation of 0.5 radians around Z, translation of `(10.5, 20.5, 0)`)
- Non-zero trailer bytes

The real files have a lot of zeros and identity transforms, which means the round-trip test won't catch reader-writer asymmetry that only shows up on non-zero data. The in-memory fixture fills that gap — it's the "did you correctly serialize a non-default float" assertion the real files can't make.

### Layer 3 — Semantic hypothesis spot-check

After layers 1 and 2 are green, one additional test:

```go
func TestAnimationFileKeyframeCountHypothesis(t *testing.T) {
    sit := readAnimation(t, "sitSW.bin.mid")
    if sit.Prologue.KeyframeCount < 1 || sit.Prologue.KeyframeCount > 3 {
        t.Errorf("sitSW.KeyframeCount = %d, expected 1-3 (static pose)",
            sit.Prologue.KeyframeCount)
    }

    walk := readAnimation(t, "walkSW.bin.mid")
    if walk.Prologue.KeyframeCount < 20 || walk.Prologue.KeyframeCount > 60 {
        t.Errorf("walkSW.KeyframeCount = %d, expected 20-60 (walk cycle)",
            walk.Prologue.KeyframeCount)
    }
}
```

This is the lever for semantic labels: if the hypothesis is wrong, the test fails, I demote `KeyframeCount` back to `Field1` in the struct, and the parser ships with preservation-only naming. The round-trip contract is unaffected (struct field names don't control byte layout), so the session still closes with Layer 1 and 2 green.

### Layer 4 — Godot scene validator extension

One additional assertion in `_validate_main_scene` inside `godot/validate_assets.gd`. After `assemble()` + `pose_from_animation()` run, the validator checks that at least one sprite has a position **different** from the Phase 2b grid cell origin. The grid has deterministic cell positions (`80, 80, 220, 80, 360, 80, ...`); the pose function writes real keyframe data. If any sprite's position doesn't match its grid cell's origin, the scene is demonstrably in "pose mode" rather than "grid mode." Not a correctness check of the pose itself — just a smoke test that the pose function executed and moved at least one sprite.

If `sitSW` happens to decode to an all-identity pose that coincidentally matches the grid, this check false-negatives. Mitigation: the check gets tightened to "matches expected position for frame 0 of sitSW" with hardcoded reference values.

### Out of scope for testing

- Go benchmarks — 60 small files parse in microseconds, perf is irrelevant.
- Fuzz testing — byte preservation on real files + in-memory fixture is sufficient coverage.
- Property-based testing — overkill for a fixed-schema binary format.
- Pixel-diff tests on the rendered scene — postponed until we want visual regression coverage in general; explicit non-goal this session.

---

## 4. The Godot consumer

This is where the visible payoff lands.

### Which animation file

**`sitSW.bin.mid`** is the first-choice source for the single-keyframe pose:
- Smallest file (1516 bytes) — minimum surface area for the first real decode.
- Static semantics from the `animationData.bin.mid.json` manifest (`Type: 2` → "sit"), consistent with the hex-dump observation that `sitSW`'s prologue has `KeyframeCount = 1`.
- SW direction matches the grid layout the previous session used; the isometric facing math only has to handle one view.

**`idleSW.bin.mid`** is the fallback if `sitSW` decodes to an all-identity-transform pose (zero displacement from the grid, which would render as "no visible change"). `idleSW` is multi-frame and almost certainly has meaningful bone movement on frame 0 because idle animations typically breathe.

### The `pose_from_animation` method

Lives on `main_scene.gd` next to the existing `assemble()`:

```gdscript
## Replaces the grid layout with a single-keyframe pose pulled from
## an animation JSON file. Called by _ready after assemble() for the
## normal runtime path; called directly by the validator for headless
## coverage (same lifecycle workaround as assemble()).
func pose_from_animation(json_path: String, frame_index: int) -> int:
    var data := _load_animation_json(json_path)
    if data == null:
        push_error("main_scene: could not load " + json_path)
        return 0
    if not data.has("Records") or (data["Records"] as Array).is_empty():
        push_error("main_scene: " + json_path + " has no records")
        return 0

    var applied := 0
    for sprite in get_children():
        var bone_idx := _sprite_name_to_bone_index(sprite.name)
        if bone_idx < 0:
            sprite.visible = false  # spacer — hide rather than position
            continue
        if bone_idx >= (data["Records"] as Array).size():
            continue  # bone index out of range for this animation
        sprite.position = _extract_position(data, bone_idx, frame_index)
        applied += 1
    return applied
```

### Bone-to-sprite mapping: alphabetical heuristic

The cleanest first-pass mapping is **alphabetical order of non-spacer piece names**. Rationale:
- The Go packer walks character subdirectories alphabetically and packs parts in alphabetical file order.
- If the original game's keyframe data was authored against the same packer (very likely — it's the same toolchain), the bone indices in the keyframe data should line up with alphabetical pack order out of the box.
- Building a proper lookup table requires either a `characterArt`-style mapping file (which we don't have for bones) or a Ghidra pass against the original `.so` — both out of scope for the first pass.

If alphabetical produces visibly wrong results (head where a leg should be, etc.), the fallback is to respect the `back_` prefix split: all 12 `back_*` pieces map to bones 0-11, all 12 front pieces map to bones 12-23. If that also fails, I escalate to Ghidra (option γ from the approach questions).

### Extracting the translation from a transform

`_extract_position(data, bone_idx, frame_index)` pulls `Vector2(matrix[9], matrix[10])` as the first guess — conventional row-major 3×4 stores translation in the last column, which in flat indexing is indices 9, 10, 11. If that produces nonsense (all zero, out-of-range values), the alternatives to try in order:
1. `Vector2(matrix[3], matrix[7])` — column-major 3×4 translation.
2. `Vector2(matrix[10], matrix[11])` — same as first guess but with the Z axis swapped to Y (the game is 2D isometric, Z might not be semantic).

Differential analysis during implementation will pick the right one.

### Control flow

```gdscript
func _ready() -> void:
    if get_child_count() == 0:
        assemble()
    var applied := pose_from_animation(
        "res://assets/data/animation/sitSW.json", 0)
    if applied == 0:
        push_warning("main_scene: pose_from_animation failed, grid stays")
```

The key property: **posing failure degrades to the grid layout, it does NOT crash**. Same defensive pattern the Phase 2b code already uses. The worst visible outcome is "we're still showing the grid from Phase 2b," which is strictly better than a black screen or a crash.

### Asset copy

`sitSW.json` (and optionally `idleSW.json`) needs to be in `godot/assets/data/animation/` so the validator can find it in the sample asset tree. I'll check these in alongside the existing sample assets copied from `build_godot/` in Phase 2a.

---

## 5. Error handling and risk mitigations

### Go side error handling

Matches existing `file_types` conventions: fail loudly, not gracefully. `ReadAnimationFile` uses the hardened `ReadNextBytes` helper that panics on short read. The header validation panics with a clear message if it encounters anything other than `(3, 24, 13)`. `WriteAnimationFile` has no failure mode beyond `io.Writer` errors — every field is a fixed-size primitive, no variable-length encoding.

### Godot side error handling

Softer, consistent with `SpriteAtlas.load_from`: `pose_from_animation` uses `push_error`/`push_warning` and returns `0` on failure, letting `_ready` fall back to the grid layout. The scene never crashes. The worst visible outcome is "we're still showing the grid instead of a posed character," and that's acceptable because the grid is itself a valid visible artifact.

### Identified risks

1. **Differential analysis produces insufficient evidence to label `KeyframeCount` semantically.**
   - *Mitigation:* Layer 3 of the test strategy is the forcing function. If it fails, `KeyframeCount` demotes to `Field1` and the parser ships with preservation-only naming. The round-trip contract is unaffected.

2. **The `AnimationRecord` trailer is not a fixed size.**
   - *Mitigation:* If the struct shape from Section 2 turns out wrong, the round-trip test fails immediately on the first `.bin.mid` file whose trailer doesn't match. I iterate on the struct — possibly introducing a `Reserved []byte` slice whose length comes from an earlier field. The preservation policy still holds.

3. **The 12-float block is not a 3×4 affine transform.**
   - *Mitigation:* Only affects semantic labels and the Godot consumer's `_extract_position` function. The round-trip test is agnostic to what the 12 floats mean — the parser just reads and writes them as opaque `[12]float32`. If the Godot pose reads nonsense positions, the worst case is "grid fallback kicks in, Go work still ships, Phase 1b item 2 is still closed."

4. **Ghidra escalation mid-session.**
   - *Mitigation:* This is the explicit γ safety valve from the approach questions. I'll only trigger it if hex-dump analysis hits a structural ambiguity I can't resolve from byte patterns alone. Ghidra startup + first-time symbol navigation is a session's worth of work on its own, so the trigger is "user confirmation first, then a checkpointed pivot" — not unilateral.

5. **The `_validate_main_scene` delta assertion false-positives on an all-identity pose.**
   - *Mitigation:* If `sitSW` decodes to zero-displacement bones (no visible difference from grid), the check gets tightened to hardcoded reference positions for frame 0 of `sitSW`. Still asserts real behavior, just more specifically.

6. **The bone-to-sprite mapping is wrong and boxer-human renders as a Picasso.**
   - *Mitigation:* This is strictly a visible-quality problem, not a correctness problem. The Go work is still complete, the validator still passes its structural checks, and the grid fallback isn't even needed. I'll document the mismapping in the devlog and defer the correct mapping to a future session (probably alongside the Ghidra pass for semantic field labels).

---

## 6. What gets documented

- **Spec** at `docs/superpowers/specs/2026-04-11-animation-keyframe-parser-design.md` — this document, committed before implementation starts. First file to land in `docs/superpowers/specs/`; the directory gets created fresh for this spec. Previous sessions have used devlogs-only for planning.
- **Implementation plan** at `docs/superpowers/plans/2026-04-11-animation-keyframe-parser.md` — produced after spec approval via the `writing-plans` skill.
- **Devlog** at `docs/devlog/2026-04-11-phase-1b-animation-parser.md` — session narrative written at the end of the session. Will cover: what differential analysis revealed, which semantic labels survived vs got demoted, any Ghidra escalation if it happened, the bone-mapping choice and how it rendered.
- **Inline comments** in `tool/file_types/animation_file.go` documenting the preservation-field naming, the 60-file round-trip contract, and the hypotheses committed at design time (with one-line citations of the differential evidence).
- **`docs/rewrite-plan.md`** — mark Phase 1b item 2 as `(done)` and the "Real skeletal posing for `boxer-human`" Phase 2b substep as `(done)`. If either one ends up only partially closed (e.g., the Go side shipped but the Godot side is stuck on bone mapping), the marking is `(done)` on the Go side and a more precise status on the Godot side.

## 7. Out of scope

Explicitly not part of this session:

- **Multi-character skeleton support.** Every animation file in `src/assets/data/animation/` targets the same `(3, 24, 13)` header, so the parser hard-fails on anything else. Supporting multiple skeletons is a future session once the one-skeleton case is solid.
- **Animated playback.** The Godot consumer applies one keyframe from one animation. A `_process` loop that advances frames over time is explicitly out of scope — see the Section 4 pattern: single-keyframe static pose, not moving animation.
- **Correct bone-to-sprite mapping that produces a visually faithful `boxer-human`.** The alphabetical heuristic is good enough for "visibly different from the grid." Visual faithfulness is a follow-up.
- **Ghidra pass.** Stays a safety valve; the plan is to close the session without opening Ghidra at all.
- **Parsing `constants.bin.mid` / `cookbookData.bin.mid` / `enemyCafeData.bin.mid` / etc.** These are separate Phase 1b items, each its own session.
- **Replacing individual PNG copies with atlas-only output.** Phase 1b item 8 (pending), separate session.
- **`cct_file` debug print sweep.** Phase 1b item 5 (pending), mechanical cleanup that deserves a focused session.
- **Fixing the Phase 2b `get_character_pieces` linear-scan optimization.** Phase 2b `(pending, optimization)` substep, small enough to piggyback on a future session but not this one.

---

## Appendix — hex-dump evidence

Captured during the Section 2 differential analysis.

**`sitSW.bin.mid`, bytes 0x00 – 0xBF:**

```
00000000: 0300 0000 1800 0000 0d00 0000 5f50 5452  ............_PTR
00000010: 0200 0000 0000 0000 5f50 5452 0100 0000  ........_PTR....
00000020: 5f50 5452 0000 0000 5f50 5452 0000 803f  _PTR...._PTR...?
00000030: 0000 0000 0000 0000 0000 803f 0000 0000  ...........?....
00000040: 0000 0000 0000 803f 0000 0000 0000 0000  .......?........
00000050: 0000 803f 0000 0000 0000 0000 cdcd cdcd  ...?............
00000060: cdcd cdcd 0000 0000 ffff ffff 0000 803f  ...............?
00000070: 0000 0000 0000 0000 0000 803f 0000 0000  ...........?....
00000080: 0000 0000 0000 803f 0000 0000 0000 0000  .......?........
00000090: 0000 803f 0000 0000 0000 0000 0000 0000  ...?............
000000a0: 0200 0000 0000 0000 1a00 0000 0000 803f  ...............?
000000b0: 0000 0000 0000 0000 0000 803f 0000 0000  ...........?....
```

**`walkNW.bin.mid`, bytes 0x00 – 0x2F:**

```
00000000: 0300 0000 1800 0000 0d00 0000 5f50 5452  ............_PTR
00000010: 0100 0000 0000 0000 5f50 5452 2700 0000  ........_PTR'...
00000020: 5f50 5452 0000 0000 5f50 5452 0000 803f  _PTR...._PTR...?
```

**Key observations across both samples:**
- Header `(3, 24, 13)` is byte-identical between the two files — 12 bytes of structural constants.
- Prologue has 4 `_PTR` markers at fixed offsets `0x0C`, `0x18`, `0x20`, `0x28`.
- Interleaved int32 values differ: `(2, 0, 1, 0)` for sit, `(1, 0, 39, 0)` for walk. The slot-2 value (sit=1, walk=39) is the `KeyframeCount` hypothesis.
- First record begins at `0x2C` in both files with `00 00 80 3f = 1.0f`, consistent with a 3×4 identity transform.
- `0xCDCDCDCD` appears in `sitSW` at offsets `0x5C-0x63` — MSVC CRT uninitialized-heap marker, preserved verbatim.
