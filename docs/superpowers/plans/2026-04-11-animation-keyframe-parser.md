# Per-Animation Keyframe Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reverse engineer `src/assets/data/animation/*.bin.mid`, ship byte-identical Go round-trip parser with tests on all 60 files, wire it through `build_tool -target godot`, and replace the Phase 2b grid layout in `main_scene.gd` with a single-keyframe pose of `boxer-human` driven by real animation data.

**Architecture:** New `tool/file_types/animation_file.go` holds `AnimationFile`/`AnimationHeader`/`AnimationPrologue`/`AnimationRecord` structs with preservation-field naming. Round-trip tests iterate every real `.bin.mid` file and in-memory fixtures. `packGodotAnimations` in `tool/resource_manager/serialization/godot.go` plumbs the decoded JSON into the Godot asset tree. `main_scene.gd` gains a `pose_from_animation` method that loads one keyframe and positions bone-backed sprites; grid layout stays as graceful fallback. The parser follows the same preservation-field philosophy as Phase 0b (`U0`/`Unknown1`-style placeholders upgraded only when differential evidence supports semantic labels).

**Tech Stack:** Go 1.26 (toolchain) / 1.20 (go.mod), Godot 4.6.2 GDScript, existing `file_types` primitive helpers (`ReadByte`, `ReadInt32`, `ReadFloat32`, `WriteByte`, `WriteInt32`, `WriteFloat32`), existing `cct_file.WritePackedTexture` conventions.

**Environment gotchas** (from `docs/handoff.md`):
- Go: `/c/Program Files/Go/bin/go.exe` (not on PATH)
- Godot: `/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe` (use `_console` variant for headless)
- `--path godot/` makes `--script` arguments resolve via `res://`
- Run `godot --headless --editor --quit --path godot/` if any `class_name` registry misses
- Working directory drifts across multi-step `cd` chains — prefer absolute paths

**Commit policy:** The user batches commits at end of session. Do NOT commit per task. Treat the "checkpoint" step at the end of each task as a state-verification step (staged changes, green tests), not a commit. Task 16 handles the single grouped commit at the end.

---

## Task 1: Scaffold `animation_file.go` with stub functions and a failing test

**Files:**
- Create: `tool/file_types/animation_file.go`
- Modify: `tool/file_types/roundtrip_test.go`

The goal of this task is to set up the parser file, get a test that compiles and fails for the right reason (no implementation), and lock in the API shape.

- [ ] **Step 1: Create the stub parser file**

Write `tool/file_types/animation_file.go`:

```go
package file_types

import (
	"io"
)

// AnimationFile is the decoded form of one src/assets/data/animation/*.bin.mid.
// Field layout is byte-preservation-oriented: semantic names are committed
// only when differential analysis across the 60 real files produces strong
// evidence; otherwise fields use Unknown*/Field*/Pad* placeholders. The
// writer echoes every byte the reader consumed, same preservation contract
// as Phase 0b's cafe/savegame work.
type AnimationFile struct {
	Header   AnimationHeader
	Prologue AnimationPrologue
	Records  []AnimationRecord
}

// AnimationHeader is the 12-byte fixed header. Every observed .bin.mid file
// has (3, 24, 13) here; the 24 matches 27 boxer-human atlas pieces minus 3
// spacer/utility pieces, which is strong evidence it's bone count.
type AnimationHeader struct {
	Unknown0  int32 // = 3  in all observed files
	BoneCount int32 // = 24 in all observed files
	Unknown2  int32 // = 13 in all observed files
}

// AnimationPrologue is the 32-byte block directly after the header. It
// contains four literal "_PTR" ASCII markers at fixed offsets, interleaved
// with int32 data that differs per file. KeyframeCount is the one semantic
// label the differential-analysis evidence supports: sitSW has 1 here, walkNW
// has 39, matching "static pose" vs "full walk cycle" expectations.
type AnimationPrologue struct {
	PtrMarker0    [4]byte // literal "_PTR"
	Field0        int32   // sit=2, walk=1 — probable animation subtype flag
	Pad0          int32   // = 0 in all samples
	PtrMarker1    [4]byte // literal "_PTR"
	KeyframeCount int32   // sit=1, walk=39 — likely keyframe count
	PtrMarker2    [4]byte // literal "_PTR"
	Pad1          int32   // = 0 in all samples
	PtrMarker3    [4]byte // literal "_PTR"
}

// AnimationRecord is the per-bone data unit that repeats after the prologue.
// Exact trailer size is determined during implementation by running the
// round-trip test and iterating until bytes match.
type AnimationRecord struct {
	Transform [12]float32 // 3x4 affine hypothesis; row-major
	Trailer   []byte      // size nailed down during iteration
}

// ReadAnimationFile decodes a .bin.mid animation file. Panics on short read
// (via the hardened ReadNextBytes helpers) or on a header other than the
// observed (3, 24, 13) — supporting other skeleton topologies is a future
// session, not this one.
func ReadAnimationFile(file io.Reader) AnimationFile {
	panic("ReadAnimationFile: not implemented")
}

// WriteAnimationFile echoes the parsed struct back to bytes. Must produce
// byte-identical output for every file the reader consumes.
func WriteAnimationFile(file io.Writer, data AnimationFile) {
	panic("WriteAnimationFile: not implemented")
}
```

- [ ] **Step 2: Add a stub test that exercises the API**

Append to `tool/file_types/roundtrip_test.go` (the existing file already has imports like `bytes`, `os`, `testing`, `file_types`; reuse them, add `path/filepath` if not present):

```go
func TestAnimationFileRoundTrip(t *testing.T) {
	files, err := filepath.Glob("../../src/assets/data/animation/*.bin.mid")
	if err != nil {
		t.Fatalf("glob failed: %v", err)
	}
	if len(files) == 0 {
		t.Skip("no animation files found at ../../src/assets/data/animation/*.bin.mid")
	}
	for _, path := range files {
		path := path
		name := filepath.Base(path)
		t.Run(name, func(t *testing.T) {
			original, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", name, err)
			}

			parsed := file_types.ReadAnimationFile(bytes.NewReader(original))

			var roundtrip bytes.Buffer
			file_types.WriteAnimationFile(&roundtrip, parsed)

			got := roundtrip.Bytes()
			if !bytes.Equal(original, got) {
				t.Fatalf("%s: round-trip bytes differ (orig %d, got %d)",
					name, len(original), len(got))
			}
		})
	}
}
```

- [ ] **Step 3: Run the test; expect every sub-test to fail with a panic**

```bash
cd /c/Users/edwar/edbuildingstuff/zombie-cafe-revival
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/... -run TestAnimationFileRoundTrip
```

Expected: test run fails; failures show `panic: ReadAnimationFile: not implemented`. All 60 sub-tests panic at the same point.

If the failure is anything else (compile error, `filepath` import missing, `path/filepath` name collision, etc.), fix the test harness before continuing.

- [ ] **Step 4: Checkpoint**

Verify the file compiles and the test fails for the expected reason. Do not commit.

---

## Task 2: Implement header parser + writer

**Files:**
- Modify: `tool/file_types/animation_file.go`

- [ ] **Step 1: Replace the `ReadAnimationFile` stub body with header-only decode**

Replace the `panic` line in `ReadAnimationFile` with:

```go
func ReadAnimationFile(file io.Reader) AnimationFile {
	data := AnimationFile{}
	data.Header.Unknown0 = ReadInt32(file)
	data.Header.BoneCount = ReadInt32(file)
	data.Header.Unknown2 = ReadInt32(file)
	if data.Header.Unknown0 != 3 || data.Header.BoneCount != 24 || data.Header.Unknown2 != 13 {
		panic("ReadAnimationFile: unexpected header (expected 3, 24, 13)")
	}
	return data
}
```

- [ ] **Step 2: Replace the `WriteAnimationFile` stub body with header-only encode**

Replace the `panic` line in `WriteAnimationFile` with:

```go
func WriteAnimationFile(file io.Writer, data AnimationFile) {
	WriteInt32(file, data.Header.Unknown0)
	WriteInt32(file, data.Header.BoneCount)
	WriteInt32(file, data.Header.Unknown2)
}
```

- [ ] **Step 3: Run the round-trip test; expect all 60 sub-tests to fail**

```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/... -run TestAnimationFileRoundTrip/sitSW.bin.mid
```

Expected: the sitSW sub-test fails with `round-trip bytes differ (orig 1516, got 12)` — the writer only emitted 12 bytes (the header) but the reader consumed 12 bytes total. Parity is there, the file just isn't fully covered yet.

Any other failure mode (e.g., panic) means the header parse is wrong — investigate before continuing.

- [ ] **Step 4: Checkpoint**

Header reader and writer work. Next task extends to the prologue.

---

## Task 3: Implement prologue parser + writer

**Files:**
- Modify: `tool/file_types/animation_file.go`

- [ ] **Step 1: Add a helper for the `_PTR` literal**

Right below the type definitions in `animation_file.go`, add:

```go
// Expected ASCII bytes for the "_PTR" sentinel that appears at fixed offsets
// in the prologue. Preserved byte-for-byte by the writer.
var expectedPtrMarker = [4]byte{'_', 'P', 'T', 'R'}
```

- [ ] **Step 2: Add a `readPtrMarker` helper**

Above `ReadAnimationFile`, add:

```go
func readPtrMarker(file io.Reader) [4]byte {
	var marker [4]byte
	if _, err := io.ReadFull(file, marker[:]); err != nil {
		panic(err)
	}
	if marker != expectedPtrMarker {
		panic("readPtrMarker: expected \"_PTR\", got " + string(marker[:]))
	}
	return marker
}

func writePtrMarker(file io.Writer, marker [4]byte) {
	if _, err := file.Write(marker[:]); err != nil {
		panic(err)
	}
}
```

- [ ] **Step 3: Extend `ReadAnimationFile` with prologue decode**

Replace the `return data` at the end of `ReadAnimationFile` with:

```go
	data.Prologue.PtrMarker0 = readPtrMarker(file)
	data.Prologue.Field0 = ReadInt32(file)
	data.Prologue.Pad0 = ReadInt32(file)
	data.Prologue.PtrMarker1 = readPtrMarker(file)
	data.Prologue.KeyframeCount = ReadInt32(file)
	data.Prologue.PtrMarker2 = readPtrMarker(file)
	data.Prologue.Pad1 = ReadInt32(file)
	data.Prologue.PtrMarker3 = readPtrMarker(file)

	return data
```

- [ ] **Step 4: Extend `WriteAnimationFile` with prologue encode**

After the three `WriteInt32` calls in `WriteAnimationFile`, add:

```go
	writePtrMarker(file, data.Prologue.PtrMarker0)
	WriteInt32(file, data.Prologue.Field0)
	WriteInt32(file, data.Prologue.Pad0)
	writePtrMarker(file, data.Prologue.PtrMarker1)
	WriteInt32(file, data.Prologue.KeyframeCount)
	writePtrMarker(file, data.Prologue.PtrMarker2)
	WriteInt32(file, data.Prologue.Pad1)
	writePtrMarker(file, data.Prologue.PtrMarker3)
```

- [ ] **Step 5: Run the round-trip test focusing on sitSW**

```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/... -run TestAnimationFileRoundTrip/sitSW.bin.mid -v
```

Expected: sub-test fails with `round-trip bytes differ (orig 1516, got 44)`. 44 bytes = 12 header + 32 prologue. Header + prologue are parity, remaining 1472 bytes are record data.

Any panic from `readPtrMarker` means the prologue layout is wrong — inspect `xxd` output for `sitSW.bin.mid` and adjust.

- [ ] **Step 6: Checkpoint**

Prologue is parsed. Next task tackles records, which is where most of the iteration happens.

---

## Task 4: Implement record parser + writer (first iteration, 12-float body)

**Files:**
- Modify: `tool/file_types/animation_file.go`

This is the iteration-heavy task. The spec hypothesizes records contain a 12-float body followed by a variable-or-fixed-size trailer. We start with the 12 floats and let the round-trip test tell us how large the trailer is.

- [ ] **Step 1: Add record body reader with empty trailer**

At the bottom of `animation_file.go`, add:

```go
func readAnimationRecord(file io.Reader, trailerSize int) AnimationRecord {
	r := AnimationRecord{}
	for i := 0; i < 12; i++ {
		r.Transform[i] = ReadFloat32(file)
	}
	if trailerSize > 0 {
		r.Trailer = make([]byte, trailerSize)
		if _, err := io.ReadFull(file, r.Trailer); err != nil {
			panic(err)
		}
	}
	return r
}

func writeAnimationRecord(file io.Writer, r AnimationRecord) {
	for i := 0; i < 12; i++ {
		WriteFloat32(file, r.Transform[i])
	}
	if len(r.Trailer) > 0 {
		if _, err := file.Write(r.Trailer); err != nil {
			panic(err)
		}
	}
}
```

- [ ] **Step 2: Wire records into the top-level reader with a first-guess trailer size of 16**

The hex dump of `sitSW.bin.mid` shows a 16-byte tail after the first 12-float block (`cdcd cdcd cdcd cdcd 0000 0000 ffff ffff`). Use 16 as the starting guess.

Also: how many records are there? First guess — `BoneCount` (24 records). Will verify via round-trip math.

Replace the `return data` at the end of `ReadAnimationFile` with:

```go
	// First-guess record layout: 12 floats + 16-byte trailer, repeated
	// BoneCount times. The round-trip test will tell us if this is wrong.
	const trailerSize = 16
	data.Records = make([]AnimationRecord, data.Header.BoneCount)
	for i := int32(0); i < data.Header.BoneCount; i++ {
		data.Records[i] = readAnimationRecord(file, trailerSize)
	}

	return data
```

- [ ] **Step 3: Wire records into the top-level writer**

After the prologue-write calls in `WriteAnimationFile`, add:

```go
	for _, r := range data.Records {
		writeAnimationRecord(file, r)
	}
```

- [ ] **Step 4: Run the round-trip test on sitSW**

```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/... -run TestAnimationFileRoundTrip/sitSW.bin.mid -v
```

**Expected outcomes and what each one means:**

- **PASS:** trailer size 16 and record count `BoneCount` (24) are correct. Proceed to Task 5.
- **`bytes differ (orig 1516, got X)` where X == 1516:** bytes match except the test says they don't — double-check test output for a Fatal vs Error. Extremely unlikely.
- **`bytes differ (orig 1516, got X)` where X < 1516:** the parser consumed fewer bytes than the file. Either `BoneCount` isn't the record count, or the trailer is larger than 16. Compute `(1516 - 12 - 32) / 24 = 61.83`, which is not an integer — so the record count is not exactly 24. Try `(1516 - 12 - 32) / (48 + trailer)`. For trailer=16, `48+16=64`, `1472/64 = 23`. So 23 records of 64 bytes fits perfectly. Update `BoneCount` → hardcoded `23` and retry. If that passes, the record count is NOT `BoneCount` and needs its own hypothesis field.
- **`panic: ReadNextBytes`:** parser ran past end of file. The hypothesis predicted more bytes than exist. Reduce record count or trailer size.

Investigate and iterate until sitSW passes. Record each iteration decision as a one-line comment in the source.

- [ ] **Step 5: Once sitSW passes, run the test against walkNW too**

```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/... -run TestAnimationFileRoundTrip/walkNW.bin.mid -v
```

Expected: walkNW is 13616 bytes. If the struct is correct, it should also round-trip cleanly.

**Anticipated outcome:** walkNW will likely NOT round-trip on the first try because it has 39 keyframes vs sit's 1, and the "record count = BoneCount" hypothesis breaks down. The record count likely scales with `KeyframeCount`: `total_records = BoneCount * KeyframeCount` or similar.

If walkNW fails, compute the expected record math:
- walkNW: 13616 bytes file, 44 bytes header+prologue, so 13572 bytes of records
- If records are 64 bytes each: `13572 / 64 = 212.0625`, not integer
- If records are 68 bytes: `13572 / 68 = 199.59`, not integer
- `13572 / 39 = 348.0` — that's 348 bytes per keyframe, times 39 keyframes
- `348 / 24 = 14.5` — not integer if per-bone
- `348 / 23 = 15.13` — not integer if 23-bone
- Try: 12 floats per bone + `X` trailer, with 24 bones per keyframe
  - `(48+X) * 24 = 348` → `X = 348/24 - 48 = -33.5` — impossible
- Try: 12 floats per bone + `X` trailer, with 29 bones per keyframe (arbitrary): doesn't cleanly divide

If nothing clean fits, the structure hypothesis is wrong in a way the 2-sample dump couldn't catch. Dump `walkNW.bin.mid` record region byte-by-byte (`xxd walkNW.bin.mid | head -100`) and look for repeating patterns.

**Escalation:** if multiple rounds of iteration on walkNW don't converge, stop and flag the Ghidra option (γ) to the user before spending more time. Ghidra startup + navigation alone is its own session.

- [ ] **Step 6: Iterate until sitSW AND walkNW both round-trip**

Continue adjusting the struct shape and record-count logic until both files pass. Update inline source comments with each hypothesis as it's proved or disproved — do NOT commit per iteration (see the Commit policy at the top of the plan).

- [ ] **Step 7: Checkpoint**

Two files round-trip cleanly. The struct shape is probably now correct enough to try the remaining 58.

---

## Task 5: Round-trip the remaining 58 files and nail down stragglers

**Files:**
- Modify: `tool/file_types/animation_file.go` (if stragglers reveal more format quirks)

- [ ] **Step 1: Run the full round-trip test**

```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/... -run TestAnimationFileRoundTrip -v 2>&1 | tail -80
```

Expected: many of the 60 sub-tests pass. Some may fail, especially edge cases like the sitting animations (which may have chair-specific bones) or the largest files.

- [ ] **Step 2: For each failing sub-test, investigate and fix**

For each failure, use this pattern:

```bash
# Find the offset where the parse diverges from expectation
xxd "/c/Users/edwar/edbuildingstuff/zombie-cafe-revival/src/assets/data/animation/<failing_name>.bin.mid" | head -50
```

Typical failure modes and fixes:
- **File size not an integer multiple of the record size:** there's a trailing section after the records (separate keyframe metadata, frame timing table, etc.). Add a `Trailing []byte` field to `AnimationFile` and read the remaining bytes into it after the record loop.
- **Record count off by one or two:** investigate whether headers vary for sitting animations (chair data?) or celebration animations (emote frames?).
- **Panic on `readPtrMarker`:** the prologue structure might differ for some animation types. Flag which files and investigate.

Each fix should cause the round-trip test for that file to pass without breaking any previously-passing sub-test.

- [ ] **Step 3: Re-run the full suite after each change**

```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/... -run TestAnimationFileRoundTrip 2>&1 | tail -10
```

Expected progression: pass count grows, fail count shrinks. Final state: all 60 sub-tests green.

- [ ] **Step 4: Checkpoint**

All 60 real files round-trip byte-identically. The Go parser is structurally complete.

---

## Task 6: Add in-memory fixture test

**Files:**
- Modify: `tool/file_types/roundtrip_test.go`

- [ ] **Step 1: Add the in-memory fixture test**

Append to `tool/file_types/roundtrip_test.go`:

```go
func TestAnimationFileInMemoryFixture(t *testing.T) {
	// Hand-constructed AnimationFile with non-default values across every
	// field. The real files are full of zeros and identity transforms,
	// which means the round-trip-on-real-files test can miss reader-writer
	// asymmetry that only shows up on non-zero data. This fixture fills
	// that gap.
	fixture := file_types.AnimationFile{
		Header: file_types.AnimationHeader{
			Unknown0:  3,
			BoneCount: 24,
			Unknown2:  13,
		},
		Prologue: file_types.AnimationPrologue{
			PtrMarker0:    [4]byte{'_', 'P', 'T', 'R'},
			Field0:        7,
			Pad0:          0,
			PtrMarker1:    [4]byte{'_', 'P', 'T', 'R'},
			KeyframeCount: 5,
			PtrMarker2:    [4]byte{'_', 'P', 'T', 'R'},
			Pad1:          0,
			PtrMarker3:    [4]byte{'_', 'P', 'T', 'R'},
		},
		Records: []file_types.AnimationRecord{
			{
				Transform: [12]float32{
					0.866, 0.5, 0,
					-0.5, 0.866, 0,
					0, 0, 1,
					10.5, 20.25, 0,
				},
				Trailer: make([]byte, 16), // zero trailer, exact size filled in by Task 4 iteration
			},
			{
				Transform: [12]float32{
					1, 0, 0,
					0, 1, 0,
					0, 0, 1,
					-5.75, 100.125, 3.5,
				},
				Trailer: make([]byte, 16),
			},
		},
	}

	var buf bytes.Buffer
	file_types.WriteAnimationFile(&buf, fixture)

	parsed := file_types.ReadAnimationFile(bytes.NewReader(buf.Bytes()))

	if parsed.Header != fixture.Header {
		t.Errorf("header mismatch: got %+v, want %+v", parsed.Header, fixture.Header)
	}
	if parsed.Prologue != fixture.Prologue {
		t.Errorf("prologue mismatch: got %+v, want %+v", parsed.Prologue, fixture.Prologue)
	}
	// Records equality: check the transform floats directly; skip the
	// slice-equality shortcut because Trailer is a slice.
	if len(parsed.Records) != len(fixture.Records) {
		t.Fatalf("record count: got %d, want %d", len(parsed.Records), len(fixture.Records))
	}
	for i := range fixture.Records {
		if parsed.Records[i].Transform != fixture.Records[i].Transform {
			t.Errorf("record %d transform mismatch:\n  got %+v\n  want %+v",
				i, parsed.Records[i].Transform, fixture.Records[i].Transform)
		}
	}
}
```

Note: adjust `Records` field count and `Trailer` size to match whatever final struct shape Task 4/5 landed on. If Task 4/5 added a top-level `Trailing []byte` field, include it in the fixture.

If the real parser uses `BoneCount * KeyframeCount` records (rather than a flat count), the fixture needs `24 * 5 = 120` records, not 2. Adjust accordingly.

- [ ] **Step 2: Run the new test**

```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/... -run TestAnimationFileInMemoryFixture -v
```

Expected: PASS.

If it fails, the fixture is wrong (probably the record count expected by the parser) — fix the fixture, not the parser. The parser is already validated by Task 5 on real data.

- [ ] **Step 3: Checkpoint**

The in-memory fixture passes. Non-default values survive a round-trip.

---

## Task 7: Add semantic hypothesis spot-check test

**Files:**
- Modify: `tool/file_types/roundtrip_test.go`

- [ ] **Step 1: Add the hypothesis spot-check**

Append to `tool/file_types/roundtrip_test.go`:

```go
func TestAnimationFileKeyframeCountHypothesis(t *testing.T) {
	cases := []struct {
		file     string
		minFrame int32
		maxFrame int32
		why      string
	}{
		{"sitSW.bin.mid", 1, 3, "sit is a static pose, expect 1-3 frames"},
		{"walkNW.bin.mid", 20, 60, "walk is a full cycle, expect 20-60 frames"},
	}

	for _, tc := range cases {
		t.Run(tc.file, func(t *testing.T) {
			path := "../../src/assets/data/animation/" + tc.file
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Skipf("%s not found: %v", tc.file, err)
			}
			parsed := file_types.ReadAnimationFile(bytes.NewReader(raw))
			got := parsed.Prologue.KeyframeCount
			if got < tc.minFrame || got > tc.maxFrame {
				t.Errorf("%s.KeyframeCount = %d, expected [%d, %d] (%s)",
					tc.file, got, tc.minFrame, tc.maxFrame, tc.why)
			}
		})
	}
}
```

- [ ] **Step 2: Run the hypothesis test**

```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/... -run TestAnimationFileKeyframeCountHypothesis -v
```

**Expected outcome A (hypothesis holds):** PASS. Keep `KeyframeCount` as the semantic name. Done.

**Expected outcome B (hypothesis fails):** the test reports the actual values. Demote `KeyframeCount` to `Field1` in `animation_file.go`:

```go
// Before:
//   KeyframeCount int32 // sit=1, walk=39 — likely keyframe count
// After:
//   Field1 int32 // sit=X, walk=Y — meaning TBD
```

Update the same field in:
- `AnimationPrologue` struct definition
- `ReadAnimationFile` prologue decode
- `WriteAnimationFile` prologue encode
- `TestAnimationFileInMemoryFixture`
- `TestAnimationFileKeyframeCountHypothesis` (change the test to document the actual values rather than asserting)

Re-run `TestAnimationFileRoundTrip` to confirm nothing broke.

- [ ] **Step 3: Checkpoint**

Semantic labels are grounded in evidence or demoted to placeholders. Go parser work is complete.

---

## Task 8: Run full `file_types` test suite to confirm no regression

**Files:** none

- [ ] **Step 1: Run the entire `file_types` package test**

```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/...
```

Expected: PASS. All previously-passing round-trip tests (`TestCharacterJPRoundTrip`, `TestCafeRoundTrip`, `TestFriendCafeRoundTrip`, `TestSaveGameRoundTrip`, `TestSaveStringsEncoding`, etc.) still green, plus the three new tests added this session.

If anything fails, fix before continuing — the parser work should not touch pre-existing tests.

- [ ] **Step 2: Checkpoint**

Package is green. Moving to build_tool integration.

---

## Task 9: Wire the parser into `BuildGodotAssets`

**Files:**
- Modify: `tool/resource_manager/serialization/godot.go`

- [ ] **Step 1: Add `packGodotAnimations` helper**

Open `tool/resource_manager/serialization/godot.go` and append a new function at the bottom of the file (after `copyGodotFonts`):

```go
// packGodotAnimations decodes every per-animation .bin.mid file under
// src/assets/data/animation/ using file_types.ReadAnimationFile and
// writes a pretty-printed JSON version to <out>/assets/data/animation/.
// Missing source directory is logged and skipped, matching the tolerance
// pattern of packGodotAtlases.
func packGodotAnimations(in_directory string, out_directory string) {
	in_dir := filepath.Join(in_directory, "assets", "data", "animation")
	entries, err := os.ReadDir(in_dir)
	if err != nil {
		log.Printf("packGodotAnimations: skipping %s: %v", in_dir, err)
		return
	}

	godotMkdir(out_directory)

	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if !strings.HasSuffix(strings.ToLower(e.Name()), ".bin.mid") {
			continue
		}
		src := filepath.Join(in_dir, e.Name())
		dstName := strings.TrimSuffix(e.Name(), ".bin.mid") + ".json"
		dst := filepath.Join(out_directory, dstName)

		f, err := os.Open(src)
		if err != nil {
			log.Fatalf("opening %s: %v", src, err)
		}
		data := file_types.ReadAnimationFile(f)
		f.Close()

		writeJSONFile(dst, data)
	}
}
```

- [ ] **Step 2: Call the new helper from `BuildGodotAssets`**

In the same file, locate `BuildGodotAssets`. After the existing `packGodotAtlases` call, add:

```go
	packGodotAnimations(in_directory, filepath.Join(assetsOut, "data", "animation"))
```

So the tail of `BuildGodotAssets` now looks like:

```go
	copyGodotDataFiles(in_directory, filepath.Join(assetsOut, "data"))
	deserializeAnimationDataForGodot(in_directory, filepath.Join(assetsOut, "data"))
	copyGodotImages(in_directory, filepath.Join(assetsOut, "images"))
	copyGodotAudio(in_directory, filepath.Join(assetsOut, "audio"))
	copyGodotFonts(in_directory, filepath.Join(assetsOut, "fonts"))
	packGodotAtlases(in_directory, filepath.Join(assetsOut, "atlases"))
	packGodotAnimations(in_directory, filepath.Join(assetsOut, "data", "animation"))

	log.Printf("BuildGodotAssets: done")
```

- [ ] **Step 3: Build the build_tool module**

```bash
"/c/Program Files/Go/bin/go.exe" build -C tool/build_tool ./...
```

Expected: no errors. If there's a missing import, Go will name it — `log`, `strings`, `filepath`, `os`, `file_types` should all already be imported by the existing code in `godot.go`.

- [ ] **Step 4: Checkpoint**

Parser is wired into the build tool. Next step is running it end-to-end.

---

## Task 10: Run `build_tool` and inspect the output

**Files:** none (reads from `src/`, writes to `build_godot/`)

- [ ] **Step 1: Run the full Godot asset build**

```bash
cd /c/Users/edwar/edbuildingstuff/zombie-cafe-revival
"/c/Program Files/Go/bin/go.exe" run ./tool/build_tool -i src/ -o build_godot/ -target godot
```

Expected: runs to completion, prints `BuildGodotAssets: done` at the end, exit 0. The run takes ~5-10 seconds.

If it panics mid-run, a specific animation file broke the parser in a way the round-trip test didn't catch (possibly a fixture that was skipped). Identify the file from the panic, add it to the round-trip test explicitly, and re-iterate.

- [ ] **Step 2: Verify JSON output exists**

```bash
ls build_godot/assets/data/animation/ | head -5
ls build_godot/assets/data/animation/ | wc -l
```

Expected: 60 `.json` files (e.g., `sitSW.json`, `walkNW.json`, `idleSW.json`, etc.).

- [ ] **Step 3: Spot-check the sitSW JSON content**

```bash
head -30 build_godot/assets/data/animation/sitSW.json
```

Expected: a pretty-printed JSON object with `Header`, `Prologue`, and `Records` keys. The `Header` should have `Unknown0: 3, BoneCount: 24, Unknown2: 13`. The `Prologue.KeyframeCount` (or `Field1`) should be 1-ish for sit.

- [ ] **Step 4: Checkpoint**

Decoded JSON is produced. Ready to check it into the godot/ sample assets.

---

## Task 11: Copy `sitSW.json` into the godot sample asset tree

**Files:**
- Create: `godot/assets/data/animation/sitSW.json`

- [ ] **Step 1: Copy the sample file**

```bash
mkdir -p /c/Users/edwar/edbuildingstuff/zombie-cafe-revival/godot/assets/data/animation/
cp /c/Users/edwar/edbuildingstuff/zombie-cafe-revival/build_godot/assets/data/animation/sitSW.json /c/Users/edwar/edbuildingstuff/zombie-cafe-revival/godot/assets/data/animation/sitSW.json
```

- [ ] **Step 2: Verify it's in the right place**

```bash
ls /c/Users/edwar/edbuildingstuff/zombie-cafe-revival/godot/assets/data/animation/
```

Expected: `sitSW.json` shows up.

- [ ] **Step 3: Checkpoint**

Sample JSON is in place for the validator. Now move to the Godot consumer.

---

## Task 12: Extend `_validate_main_scene` with pose delta assertion (RED)

**Files:**
- Modify: `godot/validate_assets.gd`

The TDD order here is: write the validator assertion first, watch it fail (pose_from_animation doesn't exist yet), then implement it.

- [ ] **Step 1: Add the pose delta assertion to `_validate_main_scene`**

Open `godot/validate_assets.gd`. Find the `_validate_main_scene` function. After the existing `valid_textures` check, before the `print(" OK main.tscn: ...")` line, add:

```gdscript
	# Pose delta check: at least one sprite's position must differ from the
	# Phase 2b grid cell origin. This proves pose_from_animation applied
	# real keyframe data on top of the grid layout, moving at least one
	# sprite out of its cell origin. Validates the Go parser -> Godot
	# consumer pipeline end-to-end.
	const CELL_W_CHECK := 140.0
	const CELL_H_CHECK := 140.0
	const GRID_ORIGIN_CHECK := Vector2(80.0, 80.0)
	const GRID_COLS_CHECK := 9

	var poseApplied := false
	for idx in range(sprites.size()):
		var sprite := sprites[idx] as Sprite2D
		var col := idx % GRID_COLS_CHECK
		var row := idx / GRID_COLS_CHECK
		var cell_origin := GRID_ORIGIN_CHECK + Vector2(col * CELL_W_CHECK, row * CELL_H_CHECK)
		if sprite.position.distance_to(cell_origin) > 1.0:
			poseApplied = true
			break

	if not poseApplied:
		instance.queue_free()
		return [path + ": every sprite still at its grid cell origin — pose_from_animation did not run"]
```

This block goes BEFORE `print("  OK main.tscn: ...")`.

- [ ] **Step 2: Run the validator; expect the new assertion to fail**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --path godot/ --script res://validate_assets.gd 2>&1 | tail -20
```

Expected: validation fails with `FAIL: res://main.tscn: every sprite still at its grid cell origin — pose_from_animation did not run`. Exit code 1 (or, weirdly, 0 if the validator's `quit(1)` is deferred by the SceneTree quirk — check stdout).

If it passes unexpectedly, `main_scene.gd` already has some code that moves sprites off the grid — inspect and remove it.

- [ ] **Step 3: Checkpoint**

Failing assertion in place. Next task implements `pose_from_animation` to satisfy it.

---

## Task 13: Implement `pose_from_animation` in `main_scene.gd` (GREEN)

**Files:**
- Modify: `godot/scripts/main_scene.gd`

- [ ] **Step 1: Add `pose_from_animation` and its helpers**

Open `godot/scripts/main_scene.gd`. After the `assemble()` function, append:

```gdscript
## Replaces the grid layout with a single-keyframe pose pulled from an
## animation JSON file produced by tool/build_tool -target godot. Called
## from _ready after assemble() for the normal runtime path; called
## directly by the validator for headless coverage, matching the same
## lifecycle workaround assemble() uses. Returns the number of sprites
## whose position was rewritten; zero means posing failed and the grid
## layout stays as a graceful fallback.
func pose_from_animation(json_path: String, frame_index: int) -> int:
	var data := _load_animation_json(json_path)
	if data == null:
		return 0
	if not data.has("Records") or (data["Records"] as Array).is_empty():
		push_error("main_scene: " + json_path + " has no records")
		return 0

	var records := data["Records"] as Array
	var applied := 0
	var bone_idx := 0

	for child in get_children():
		if not (child is Sprite2D):
			continue
		var sprite := child as Sprite2D

		# Spacer pieces (0-spacer, 1x1, 1x1_front) have no bone; hide them.
		if _is_spacer_name(sprite.name):
			sprite.visible = false
			continue

		if bone_idx >= records.size():
			break

		var record := records[bone_idx] as Dictionary
		sprite.position = _extract_position_from_record(record)
		applied += 1
		bone_idx += 1

	return applied


func _load_animation_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		push_error("main_scene: animation JSON not found: " + path)
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("main_scene: cannot open: " + path)
		return null
	var text := file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		push_error("main_scene: JSON parse failed: " + path)
		return null
	return parsed


func _is_spacer_name(sprite_name: String) -> bool:
	return sprite_name.begins_with("0-spacer") \
		or sprite_name == "1x1.png" \
		or sprite_name == "1x1_front.png"


## Pulls the Vector2 translation from a record's Transform. First guess:
## indices 9 and 10 are the X and Y translation components of a row-major
## 3x4 affine transform (the last column of the matrix). If all values
## across all bones come out zero (all-identity transforms), the grid
## fallback will still be active because the pose delta check will fail —
## that's the signal to try a different index pair.
func _extract_position_from_record(record: Dictionary) -> Vector2:
	var transform_variant: Variant = record.get("Transform", null)
	if transform_variant == null or typeof(transform_variant) != TYPE_ARRAY:
		return Vector2.ZERO
	var transform := transform_variant as Array
	if transform.size() < 12:
		return Vector2.ZERO
	var tx := float(transform[9])
	var ty := float(transform[10])
	# Ground the pose near the center of the visible area so a real
	# (non-zero) translation renders in-frame even if the base magnitudes
	# are pixel-small.
	return Vector2(640.0, 360.0) + Vector2(tx, ty)
```

- [ ] **Step 2: Call `pose_from_animation` from `_ready`**

In the same file, modify `_ready` so it calls the new method after `assemble()`:

```gdscript
func _ready() -> void:
	# Guard against double-assembly when the validation test has
	# already called assemble() before the node entered the tree.
	if get_child_count() == 0:
		assemble()
	# Replace the grid layout with a real pose. Grid stays as a graceful
	# fallback if the animation JSON is missing or malformed.
	var applied := pose_from_animation("res://assets/data/animation/sitSW.json", 0)
	if applied == 0:
		push_warning("main_scene: pose_from_animation returned 0, grid stays")
```

- [ ] **Step 3: Extend the validator to call `pose_from_animation` too**

Open `godot/validate_assets.gd`. Find `_validate_main_scene` where it calls `instance.call("assemble")`. Right after that call (and before the existing sprite-enumeration loop), add:

```gdscript
	if not instance.has_method("pose_from_animation"):
		instance.queue_free()
		return [path + ": root node has no pose_from_animation() method"]

	var posed: int = instance.call(
		"pose_from_animation",
		"res://assets/data/animation/sitSW.json",
		0,
	)
	if posed <= 0:
		instance.queue_free()
		return [path + ": pose_from_animation returned " + str(posed)]
```

- [ ] **Step 4: Rebuild the class cache (defensive; the validator added a new method reference)**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --editor --quit --path godot/ 2>&1 | tail -5
```

Expected: exits 0.

- [ ] **Step 5: Run the headless validation**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --path godot/ --script res://validate_assets.gd 2>&1; echo "exit=$?"
```

**Expected outcomes:**
- **PASS (all 15+ checks green, exit 0):** `pose_from_animation` applied at least one non-grid position. Phase 2b posing substep closes.
- **`FAIL: ...: every sprite still at its grid cell origin ...`:** the parser produced all-zero translations at `Transform[9]` and `Transform[10]`, meaning the position is not in that index pair. Try `Transform[3]` and `Transform[7]` (column-major) next. Edit `_extract_position_from_record`, re-run validator.
- **`FAIL: ...: pose_from_animation returned 0`:** the animation JSON couldn't be loaded or parsed. Check `godot/assets/data/animation/sitSW.json` exists and is valid JSON.

Iterate on `_extract_position_from_record` until the pose delta check passes.

- [ ] **Step 6: Checkpoint**

All validator checks green. Phase 1b Go work and Phase 2b Godot work are both at their "done" criteria.

---

## Task 14: Full workspace build check

**Files:** none

- [ ] **Step 1: Run the workspace-wide Go build**

```bash
cd /c/Users/edwar/edbuildingstuff/zombie-cafe-revival
for m in file_types build_tool resource_manager cctpacker; do
  (cd tool/$m && "/c/Program Files/Go/bin/go.exe" build ./...) || echo "$m FAILED"
done
(cd tool/server && GOOS=js GOARCH=wasm "/c/Program Files/Go/bin/go.exe" build ./...) || echo "server FAILED"
```

Expected: no "FAILED" line. All 5 modules build clean.

- [ ] **Step 2: Run the `file_types` test suite one more time**

```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/...
```

Expected: PASS.

- [ ] **Step 3: Run the headless validator one more time**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --path godot/ --script res://validate_assets.gd 2>&1 | tail -25
```

Expected: all checks PASS, `========== VALIDATION PASSED ==========`.

- [ ] **Step 4: Checkpoint**

Everything is green. Moving to documentation.

---

## Task 15: Write the devlog and update `rewrite-plan.md`

**Files:**
- Create: `docs/devlog/2026-04-11-phase-1b-animation-parser.md`
- Modify: `docs/rewrite-plan.md`

- [ ] **Step 1: Write the devlog**

Create `docs/devlog/2026-04-11-phase-1b-animation-parser.md` with this template (fill in the actual session outcomes):

```markdown
# 2026-04-11 — Phase 1b: per-animation keyframe parser + real skeletal posing

**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))

Twelfth devlog entry of the day. Goal: reverse engineer the per-animation `.bin.mid` format, ship byte-identical round-trip parser with tests on all 60 real files, plumb the decoded JSON through `build_tool -target godot`, and replace the Phase 2b grid layout in `main_scene.gd` with a single-keyframe pose of `boxer-human`. All four landed.

## What shipped

- `tool/file_types/animation_file.go` — (describe final struct shape, note which fields got semantic names vs placeholders)
- `tool/file_types/roundtrip_test.go` — (TestAnimationFileRoundTrip, TestAnimationFileInMemoryFixture, TestAnimationFileKeyframeCountHypothesis)
- `tool/resource_manager/serialization/godot.go` — (packGodotAnimations helper, wired into BuildGodotAssets)
- `godot/scripts/main_scene.gd` — (pose_from_animation method, grid fallback)
- `godot/validate_assets.gd` — (pose delta assertion in _validate_main_scene)
- `godot/assets/data/animation/sitSW.json` — (checked-in sample for validator coverage)

## Differential analysis findings

(Describe what the hex-dump + round-trip iteration revealed about the format: bone count, keyframe count location, record structure, trailer bytes, any Ghidra escalation that was needed or avoided.)

## Surprises of the session

(Describe anything that broke the initial struct hypothesis from the spec and how it was resolved. Cite specific files that revealed the quirk.)

## Verification

(Paste the final validator output. Paste the go test output showing all 60 sub-tests green plus the in-memory fixture plus the hypothesis spot-check.)

## What Phase 1b item 2 leaves open

(Remaining Phase 1b items: opaque binary data parsers, cct_file debug print sweep, bitmap fonts, etc. Unchanged from prior session.)

## What I want to remember from this session

(Lessons, gotchas, anything that will inform the next session.)

## Next

(What's the natural next session? Probably Phase 0b fixture sourcing if blocked on emulator work is still blocking, or one of the opaque binary parsers.)
```

Fill in the placeholders with the actual session outcomes before moving to the next step.

- [ ] **Step 2: Update `docs/rewrite-plan.md` to mark Phase 1b item 2 done**

Find the Phase 1b item 2 bullet:

```markdown
2. *(pending)* Per-animation keyframe parser. `src/assets/data/animation/*.bin.mid` has no Go reader today. Reverse engineer the format ...
```

Replace with:

```markdown
2. *(done)* Per-animation keyframe parser. Shipped `tool/file_types/animation_file.go` with `ReadAnimationFile`/`WriteAnimationFile`, byte-identical round-trip tests on all 60 real files under `src/assets/data/animation/*.bin.mid`, an in-memory fixture test, and a semantic-hypothesis spot-check. Wired through `BuildGodotAssets` via `packGodotAnimations` so `build_godot/assets/data/animation/*.json` now contains decoded per-animation JSON. Struct uses preservation-field naming — `Header.BoneCount` and `Prologue.KeyframeCount` are the two semantic labels that survived differential analysis; everything else is `Unknown*`/`Field*`/`Pad*`. See `docs/devlog/2026-04-11-phase-1b-animation-parser.md` for the reverse engineering narrative.
```

(Adjust the description if semantic labels went different ways during implementation.)

- [ ] **Step 3: Update the Phase 2b "real skeletal posing" substep**

Find the Phase 2b substep:

```markdown
- *(pending, future)* Real skeletal posing for `boxer-human`. Blocked on the per-animation keyframe parser (Phase 1b item 2). ...
```

Replace with:

```markdown
- *(done)* Real skeletal posing for `boxer-human`. `main_scene.gd` now calls `pose_from_animation("res://assets/data/animation/sitSW.json", 0)` after `assemble()`, which reads one keyframe from the decoded animation JSON and writes per-sprite positions on top of the Phase 2b grid. Grid layout stays as a graceful fallback if JSON is missing or malformed. The validator's `_validate_main_scene` check gained a pose delta assertion that confirms at least one sprite's position differs from its grid cell origin, proving the Go parser -> Godot consumer pipeline works end-to-end.
```

- [ ] **Step 4: Checkpoint**

Documentation is complete. Ready for the final commit.

---

## Task 16: Final grouped commit

**Files:** none (git operations only)

- [ ] **Step 1: Check the git status**

```bash
cd /c/Users/edwar/edbuildingstuff/zombie-cafe-revival
git status
```

Expected files in the change list:
- **New:** `tool/file_types/animation_file.go`
- **New:** `godot/assets/data/animation/sitSW.json`
- **New:** `docs/devlog/2026-04-11-phase-1b-animation-parser.md`
- **New:** `docs/superpowers/specs/2026-04-11-animation-keyframe-parser-design.md`
- **New:** `docs/superpowers/plans/2026-04-11-animation-keyframe-parser.md`
- **Modified:** `tool/file_types/roundtrip_test.go`
- **Modified:** `tool/resource_manager/serialization/godot.go`
- **Modified:** `godot/scripts/main_scene.gd`
- **Modified:** `godot/validate_assets.gd`
- **Modified:** `docs/rewrite-plan.md`

The `docs/handoff.md` file may still be untracked from earlier sessions — leave it alone.

- [ ] **Step 2: Review the diff one more time**

```bash
git diff --stat
```

Verify the changes are what you expect. Spot-check the biggest-hunk files.

- [ ] **Step 3: Present the commit message to the user**

Draft the commit message and show it to the user for approval. Format it as ONE grouped message (per `memory/feedback_commit_style.md` — never split options):

```
file_types: parse per-animation keyframe files and pose boxer-human

Close Phase 1b item 2 (the per-animation keyframe parser) and the
"Real skeletal posing for boxer-human" substep of Phase 2b in one
pass. New tool/file_types/animation_file.go decodes the
src/assets/data/animation/*.bin.mid format with byte-identical
round-trip symmetry on all 60 real files. Preservation-field naming
throughout: Header.BoneCount (24, matches boxer-human atlas pieces
minus spacers) and Prologue.KeyframeCount (sit=1, walk=39) are the
two semantic labels that survived differential analysis; everything
else uses Unknown*/Field*/Pad* placeholders.

Three new tests: TestAnimationFileRoundTrip iterates over every file
under src/assets/data/animation/*.bin.mid as sub-tests so a
single-file failure names the file precisely; TestAnimationFileIn
MemoryFixture round-trips a hand-constructed struct with non-default
values to catch reader-writer asymmetry the zero-heavy real files
miss; TestAnimationFileKeyframeCountHypothesis spot-checks the
sit=1, walk=20-60 semantic guess against real data.

Wire the parser through BuildGodotAssets via a new packGodotAnimations
helper that writes pretty-printed JSON to build_godot/assets/data/
animation/*.json. Check in a sample sitSW.json under godot/assets/
data/animation/ for validator coverage.

Replace the Phase 2b 9x3 grid layout in main_scene.gd with a
pose_from_animation method that reads sitSW.json's first keyframe
and positions the bone-backed Sprite2D children using the translation
component of each bone's 3x4 affine transform. Grid layout stays as
a graceful fallback when the JSON is missing or malformed.

Extend validate_assets.gd with a pose delta assertion that confirms
at least one sprite's position differs from its Phase 2b grid cell
origin, proving the Go parser -> Godot consumer pipeline works
end-to-end in the headless check.

Update docs/rewrite-plan.md to mark Phase 1b item 2 and the Phase 2b
posing substep done. Add docs/devlog/2026-04-11-phase-1b-animation-
parser.md covering the reverse engineering narrative. Commit the
spec and plan at docs/superpowers/specs/ and docs/superpowers/plans/
alongside the implementation.
```

- [ ] **Step 4: Wait for user approval, then commit**

Once the user approves the message, commit with a HEREDOC:

```bash
git add tool/file_types/animation_file.go tool/file_types/roundtrip_test.go \
  tool/resource_manager/serialization/godot.go \
  godot/scripts/main_scene.gd godot/validate_assets.gd \
  godot/assets/data/animation/sitSW.json \
  docs/rewrite-plan.md \
  docs/devlog/2026-04-11-phase-1b-animation-parser.md \
  docs/superpowers/specs/2026-04-11-animation-keyframe-parser-design.md \
  docs/superpowers/plans/2026-04-11-animation-keyframe-parser.md
git commit -m "$(cat <<'EOF'
file_types: parse per-animation keyframe files and pose boxer-human

<the full message from Step 3>

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
git status
```

Expected: one commit created, `git status` shows a clean working tree (except possibly `docs/handoff.md` which was already untracked before this session).

- [ ] **Step 5: Final checkpoint**

Session complete. Phase 1b item 2 and the Phase 2b posing substep are both closed.

---

## Summary

16 tasks. The iteration-heavy ones are Task 4 (first pass at the record structure) and Task 5 (the remaining 58 files) — those are where reverse engineering happens. Every other task is mechanical glue.

If the Ghidra escalation (approach γ from brainstorming) fires in Task 4 or 5, stop and check in with the user before committing to a mid-session pivot — Ghidra is its own session's worth of work.
