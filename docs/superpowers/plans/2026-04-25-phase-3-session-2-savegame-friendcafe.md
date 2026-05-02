# Phase 3 Session 2: SaveGame + FriendCafe Round-Trip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Phase 3 save format bridge to cover the remaining two formats — `SaveGame` and `FriendCafe`. After this session, all 5 real device fixtures (`playerCafe.caf`, `BACKUP1.caf`, `globalData.dat`, `BACKUP1.dat`, `ServerData.dat`) round-trip byte-identically through pure GDScript, completing Layer 1 of the spec's three-layer test plan. Sessions 3-4 add the cross-language oracle, the JSON envelope, CI wiring, and the close-out docs.

**Architecture:** Pure GDScript continuation of Session 1. Same Dictionary-with-PascalCase-keys representation, same `BinaryReader` / `BinaryWriter` primitives, same `LegacyLoader` / `LegacyWriter` instance-method dispatch. New parsers/writers added to the existing class files; no new `class_name`s introduced. The `SaveStrings` subtract-one count quirk and the ~1 KB `Trailing []byte` preservation field are the two non-obvious shapes the port has to faithfully reproduce. `FriendCafe` is mostly orchestration on top of Session 1's `Cafe` work plus this session's `CafeState`.

**Tech Stack:** GDScript 4.x (Godot 4.6.2), `PackedByteArray` for byte buffers, `Dictionary` as the canonical in-memory representation, `Marshalls.raw_to_base64` / `base64_to_raw` for the trailing-bytes preservation field, no external dependencies.

**Spec:** `docs/superpowers/specs/2026-04-25-godot-save-format-bridge-design.md`

**Predecessor plan:** `docs/superpowers/plans/2026-04-25-phase-3-session-1-cafe-round-trip.md` (committed as `d02a00de`; result: 87 PASS / 0 FAIL on the headless test runner).

**Go reference:** `tool/file_types/save_game.go` and `tool/file_types/friend_cafe.go`. The GDScript port is field-for-field — every branch on `version > N` and every read in those files maps to a corresponding GDScript line.

**Environment gotchas** (from `docs/handoff.md`):
- Repo root: `/c/Users/edwar/edbuildingstuff/zombie-cafe-revival` (also valid as `C:/Users/edwar/Documents/edbuildingstuff/zombie-cafe-revival` on the other authoring machine)
- Godot 4.6.2 console binary: `/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe`
- Use the `_console` variant for headless runs (the plain `.exe` spawns a separate window that is hard to capture)
- The class-name registry is lazy. Session 2 does **not** add new `class_name` directives (only extends existing classes), so the cache rebuild step (`godot --headless --editor --quit --path godot/`) should not be required. Run it only if a "Identifier not declared" error appears after the GDScript edits.
- Windows `autocrlf` produces benign `.import` modifications when Godot is run; ignore them with `git diff --ignore-all-space` or restage selectively.

**Commit policy:** Per `feedback_commit_style`, produce **one grouped commit** for the whole session — not per-task and not "three options or one." Per `feedback_no_coauthor_trailer`, **omit** the `Co-Authored-By: Claude` trailer. Task 11 below creates this single commit.

**Out of scope for this session:**
- Cross-language Dictionary deep-equal against Go-decoded JSON oracle (Layer 2). Session 3.
- JSON envelope (`save_v1.gd`, `user://save.json`). Session 3.
- CI wiring of the test runner into `.github/workflows/godot-validation.yml`. Session 3.
- `tool/dump_legacy_fixtures/` Go CLI. Session 3.
- Devlog / handoff close-out. Session 4.

---

## File structure

After this session, the repository will gain:

```
godot/
├── scripts/
│   └── save/
│       ├── binary_reader.gd       MODIFIED — adds read_int8
│       ├── binary_writer.gd       MODIFIED — adds write_int8
│       ├── legacy_loader.gd       MODIFIED — adds parse_save_strings, parse_character_instance,
│       │                                     parse_cafe_state, parse_save_game, parse_friend_cafe,
│       │                                     and matching static parse_*_bytes wrappers
│       └── legacy_writer.gd       MODIFIED — adds write_save_strings, write_character_instance,
│                                             write_cafe_state, write_save_game, write_friend_cafe,
│                                             and matching static write_*_bytes wrappers
└── test/
    ├── test_save_round_trip.gd    MODIFIED — adds 8 new _test_* calls and renames the summary line
    └── fixtures/
        └── save/
            ├── globalData.dat     NEW — copied from tool/file_types/testdata/
            ├── BACKUP1.dat        NEW
            └── ServerData.dat     NEW
```

No new files introduced; no new `class_name` directives.

**Dictionary-shape decisions for new types:**

- `SaveStrings` — `{"RawCount": int, "Strings": Array[String]}`. The raw count and the string list are stored separately because `RawCount=0` and `RawCount=1` both decode to zero strings — the on-disk count cannot be derived from `len(Strings)`. The writer trusts whatever `RawCount` the caller supplies.
- `CharacterInstance` — direct field-for-field mirror of the Go struct. Float32 fields (`U4`) round-trip via the existing `read_float` / `write_float` primitives (which already use `PackedByteArray.encode_float` — IEEE 754 binary32 LE).
- `CafeState` — direct mirror. The `U12` array of `int8` motivates the new `read_int8` / `write_int8` primitives in Task 2 so that JSON cross-validation in Session 3 sees `[-1, 2, 3]` rather than `[255, 2, 3]`.
- `SaveGame` — direct mirror plus a `"Trailing_b64": String` field (always present; empty string when there are no trailing bytes, base64 of the remaining file bytes when there are). The `_b64` suffix is the spec's standard marker (see `docs/superpowers/specs/2026-04-25-godot-save-format-bridge-design.md` §2).
- `FriendCafe` — `{"Version": int, "State": Dictionary, "Cafe": Dictionary}`. `State` reuses `parse_cafe_state` from Task 5; `Cafe` reuses `parse_cafe` from Session 1.

---

## Task 1: Copy SaveGame and FriendCafe fixtures

**Files:**
- Copy: `tool/file_types/testdata/globalData.dat` → `godot/test/fixtures/save/globalData.dat`
- Copy: `tool/file_types/testdata/BACKUP1.dat` → `godot/test/fixtures/save/BACKUP1.dat`
- Copy: `tool/file_types/testdata/ServerData.dat` → `godot/test/fixtures/save/ServerData.dat`

- [ ] **Step 1: Copy fixtures**

```bash
cp tool/file_types/testdata/globalData.dat godot/test/fixtures/save/globalData.dat
cp tool/file_types/testdata/BACKUP1.dat    godot/test/fixtures/save/BACKUP1.dat
cp tool/file_types/testdata/ServerData.dat godot/test/fixtures/save/ServerData.dat
```

- [ ] **Step 2: Verify byte counts**

```bash
wc -c godot/test/fixtures/save/globalData.dat \
       godot/test/fixtures/save/BACKUP1.dat \
       godot/test/fixtures/save/ServerData.dat
```

Expected: `1626` for `globalData.dat`, `1556` for `BACKUP1.dat`, `20747` for `ServerData.dat`. Mismatched sizes mean a copy went wrong; re-copy.

- [ ] **Step 3: Confirm git sees them as untracked**

```bash
git status godot/test/fixtures/save/
```

Expected: three new `??` entries. They will be committed in Task 11 alongside the code.

---

## Task 2: Add `read_int8` / `write_int8` primitives

**Files:**
- Modify: `godot/scripts/save/binary_reader.gd`
- Modify: `godot/scripts/save/binary_writer.gd`
- Modify: `godot/test/test_save_round_trip.gd`

Go reads `CafeState.U12 []int8` as `int8(ReadByte(file))` — the byte is reinterpreted as signed two's-complement. The wire bytes round-trip identically whether the Dictionary holds `255` or `-1`, but Go's default `json.Marshal` will emit `-1` for a `[]int8` value containing `0xFF`. To keep the GDScript Dictionary shape identical to the Go-side JSON oracle in Session 3, we represent these as signed integers in the Dictionary.

- [ ] **Step 1: Append `read_int8` to `binary_reader.gd`**

Append at the end of the file (after `read_date`):

```gdscript


func read_int8() -> int:
	var v: int = read_byte()
	if v >= 0x80:
		v -= 0x100
	return v
```

- [ ] **Step 2: Append `write_int8` to `binary_writer.gd`**

Append at the end of the file (after `write_date`):

```gdscript


func write_int8(v: int) -> void:
	write_byte(v & 0xFF)
```

- [ ] **Step 3: Extend `_test_primitives_round_trip` with int8 cases**

In `godot/test/test_save_round_trip.gd`, append after the existing `write_date(...)` line in the writer block:

```gdscript
	w.write_int8(-128)
	w.write_int8(127)
	w.write_int8(-1)
```

And after the existing `_check("read_date round-trip", ...)` call in the reader block (before the `reader fully consumed` check):

```gdscript
	_check("read_int8 -128", r.read_int8() == -128)
	_check("read_int8 127", r.read_int8() == 127)
	_check("read_int8 -1", r.read_int8() == -1)
```

The position matters — these three assertions must come before the `reader fully consumed` check so the reader is at end-of-buffer at that check.

- [ ] **Step 4: Run the test runner and confirm 90 PASS**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" \
  --headless --path godot/ --script res://test/test_save_round_trip.gd
```

Expected: 87 (Session 1) + 3 (new int8 cases) = **90 passed, 0 failed**, exit 0.

If the run fails with `Identifier "BinaryReader" not declared` (unlikely since we're not adding `class_name`s), rebuild the class cache with `godot --headless --editor --quit --path godot/` and re-run.

---

## Task 3: Add `parse_save_strings` / `write_save_strings` with the subtract-one quirk

**Files:**
- Modify: `godot/scripts/save/legacy_loader.gd`
- Modify: `godot/scripts/save/legacy_writer.gd`
- Modify: `godot/test/test_save_round_trip.gd`

Go reference (`save_game.go:79-96`):

```go
func readSaveStrings(file io.Reader) SaveStrings {
    var s SaveStrings
    s.RawCount = ReadInt16(file)
    num := int(s.RawCount) - 1
    if num >= 0 {
        for i := num; i >= 1; i-- {
            s.Strings = append(s.Strings, ReadString(file))
        }
    }
    return s
}

func writeSaveStrings(file io.Writer, s SaveStrings) {
    WriteInt16(file, s.RawCount)
    for _, str := range s.Strings {
        WriteString(file, str)
    }
}
```

Reading: `RawCount` is read as int16. The number of strings to read is `max(0, RawCount - 1)`. Writing: write `RawCount` as int16, then write each string. **Both `RawCount=0` and `RawCount=1` decode to zero strings**, so the raw count must be preserved separately from the string list. The writer trusts the caller to keep `len(Strings) == max(0, RawCount - 1)` — if the caller violates that invariant the round-trip won't be byte-identical.

Test with the same boundary cases Go's `TestSaveStringsEncoding` uses: `RawCount=0`, `RawCount=1` (zero strings, the boundary), `RawCount=2` (one string), `RawCount=5` (four strings).

- [ ] **Step 1: Append `parse_save_strings` to `legacy_loader.gd`**

Append after `parse_cafe_tile`:

```gdscript


func parse_save_strings(r: BinaryReader) -> Dictionary:
	var d: Dictionary = {"RawCount": 0, "Strings": []}
	d["RawCount"] = r.read_int16()
	var num: int = int(d["RawCount"]) - 1
	if num >= 0:
		var i: int = num
		var arr: Array = d["Strings"] as Array
		while i >= 1:
			arr.append(r.read_string())
			i -= 1
	return d
```

- [ ] **Step 2: Append `write_save_strings` to `legacy_writer.gd`**

Append after `write_cafe_tile`:

```gdscript


func write_save_strings(w: BinaryWriter, s: Dictionary) -> void:
	w.write_int16(int(s["RawCount"]))
	for str in (s["Strings"] as Array):
		w.write_string(str as String)
```

- [ ] **Step 3: Append `_test_save_strings_round_trip` to `test_save_round_trip.gd`**

Add a call to `_test_save_strings_round_trip()` in `_init()` (after the existing `_test_cafe_fixtures()` call) and append the helper:

```gdscript


func _test_save_strings_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()

	var cases: Array = [
		{"name": "raw count 0, zero strings",            "RawCount": 0, "Strings": []},
		{"name": "raw count 1, zero strings (boundary)", "RawCount": 1, "Strings": []},
		{"name": "raw count 2, one string",              "RawCount": 2, "Strings": ["first"]},
		{"name": "raw count 5, four strings",            "RawCount": 5, "Strings": ["a", "b", "c", "d"]},
	]

	for c in cases:
		var name: String = c["name"]
		var original: Dictionary = {"RawCount": c["RawCount"], "Strings": c["Strings"]}

		var w := BinaryWriter.make()
		writer.write_save_strings(w, original)

		var r := BinaryReader.wrap(w.to_bytes())
		var decoded: Dictionary = loader.parse_save_strings(r)

		_check("save_strings %s consumed" % name, r.remaining() == 0)
		_check("save_strings %s no fail" % name, r.failed == false)
		_check("save_strings %s RawCount" % name, int(decoded["RawCount"]) == int(original["RawCount"]))
		_check("save_strings %s Strings deep-eq" % name, _string_array_eq(decoded["Strings"], original["Strings"]))


func _string_array_eq(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if String(a[i]) != String(b[i]):
			return false
	return true
```

- [ ] **Step 4: Run, expect 90 + 16 = 106 PASS**

Each of the 4 cases produces 4 checks (consumed, no fail, RawCount, Strings deep-eq) = 16 new checks.

---

## Task 4: Add `parse_character_instance` / `write_character_instance`

**Files:**
- Modify: `godot/scripts/save/legacy_loader.gd`
- Modify: `godot/scripts/save/legacy_writer.gd`
- Modify: `godot/test/test_save_round_trip.gd`

Go reference (`save_game.go:7-25` and `:98-124`):

```go
type CharacterInstance struct {
    Type byte
    Name string
    U2   byte
    U3   byte
    U4   float32
    U5   byte
    U6   int64
    U7   byte
    U8   int64
    U9   int64
    U10  int32
    U11  int32
    U12  int32
    U13  int32
    U14  byte
    U15  int32
    U16  int32
}
```

Version branching at `version=63` (the only version we test):
- `version > 29`: read `U14` byte → **active**
- `version > 46`: read `U15` int32 + `U16` int32 → **active** (nested under the `version > 29` branch in Go, so `U15`/`U16` only appear when both are true; at v63 both are true)

- [ ] **Step 1: Append `parse_character_instance` to `legacy_loader.gd`**

```gdscript


func parse_character_instance(r: BinaryReader, version: int) -> Dictionary:
	var c: Dictionary = {
		"Type": 0, "Name": "",
		"U2": 0, "U3": 0, "U4": 0.0, "U5": 0,
		"U6": 0, "U7": 0, "U8": 0, "U9": 0,
		"U10": 0, "U11": 0, "U12": 0, "U13": 0,
		"U14": 0, "U15": 0, "U16": 0,
	}
	c["Type"] = r.read_byte()
	c["Name"] = r.read_string()
	c["U2"] = r.read_byte()
	c["U3"] = r.read_byte()
	c["U4"] = r.read_float()
	c["U5"] = r.read_byte()
	c["U6"] = r.read_int64()
	c["U7"] = r.read_byte()
	c["U8"] = r.read_int64()
	c["U9"] = r.read_int64()
	c["U10"] = r.read_int32()
	c["U11"] = r.read_int32()
	c["U12"] = r.read_int32()
	c["U13"] = r.read_int32()
	if version > 29:
		c["U14"] = r.read_byte()
		if version > 46:
			c["U15"] = r.read_int32()
			c["U16"] = r.read_int32()
	return c
```

- [ ] **Step 2: Append `write_character_instance` to `legacy_writer.gd`**

```gdscript


func write_character_instance(w: BinaryWriter, c: Dictionary, version: int) -> void:
	w.write_byte(int(c["Type"]))
	w.write_string(c["Name"] as String)
	w.write_byte(int(c["U2"]))
	w.write_byte(int(c["U3"]))
	w.write_float(float(c["U4"]))
	w.write_byte(int(c["U5"]))
	w.write_int64(int(c["U6"]))
	w.write_byte(int(c["U7"]))
	w.write_int64(int(c["U8"]))
	w.write_int64(int(c["U9"]))
	w.write_int32(int(c["U10"]))
	w.write_int32(int(c["U11"]))
	w.write_int32(int(c["U12"]))
	w.write_int32(int(c["U13"]))
	if version > 29:
		w.write_byte(int(c["U14"]))
		if version > 46:
			w.write_int32(int(c["U15"]))
			w.write_int32(int(c["U16"]))
```

- [ ] **Step 3: Append `_test_character_instance_round_trip` to `test_save_round_trip.gd`**

Mirroring Go's `mainChar` fixture from `makeCafeStateFixture()`:

```gdscript


func _test_character_instance_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	# Mirrors Go's mainChar fixture in tool/file_types/roundtrip_test.go:463.
	# U4=3.5 is exactly representable in float32, so no epsilon tolerance is needed.
	var original: Dictionary = {
		"Type": 1, "Name": "MainZombie",
		"U2": 1, "U3": 2, "U4": 3.5, "U5": 4,
		"U6": 1000000000, "U7": 5, "U8": 2000000000, "U9": 3000000000,
		"U10": 10, "U11": 20, "U12": 30, "U13": 40,
		"U14": 50, "U15": 60, "U16": 70,
	}

	var w := BinaryWriter.make()
	writer.write_character_instance(w, original, version)
	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_character_instance(r, version)

	_check("char consumed", r.remaining() == 0)
	_check("char no fail", r.failed == false)
	_check("char Type", decoded["Type"] == 1)
	_check("char Name", decoded["Name"] == "MainZombie")
	_check("char U4 float32", decoded["U4"] == 3.5)
	_check("char U6 large int64", decoded["U6"] == 1000000000)
	_check("char U9 large int64", decoded["U9"] == 3000000000)
	_check("char U13", decoded["U13"] == 40)
	_check("char U14 (gated)", decoded["U14"] == 50)
	_check("char U15 (gated)", decoded["U15"] == 60)
	_check("char U16 (gated)", decoded["U16"] == 70)
```

Add the call to `_init()`.

- [ ] **Step 4: Run, expect 106 + 11 = 117 PASS**

---

## Task 5: Add `parse_cafe_state` / `write_cafe_state`

**Files:**
- Modify: `godot/scripts/save/legacy_loader.gd`
- Modify: `godot/scripts/save/legacy_writer.gd`
- Modify: `godot/test/test_save_round_trip.gd`

Go reference (`save_game.go:27-44` and `:126-162`):

```go
type CafeState struct {
    U1               float64
    ExperiencePoints float32
    Toxin            int32
    Money            int32
    Level            int32
    U6               int32
    U7               int32
    U8               float32
    U9               int32
    U10              bool
    Character        CharacterInstance
    NumZombies       byte
    Zombies          []CharacterInstance
    U11              int32
    U12              []int8
    U13              bool
}
```

Version branching at `version=63`:
- `version > 62`: `U11` int32 (else byte→int32 cast). At v63 → **active path: int32**
- `version > 33`: `U13` bool. At v63 → **active**

`U12 []int8` is `U11` bytes worth of signed 8-bit ints. Use the new `read_int8`/`write_int8` primitives from Task 2.

- [ ] **Step 1: Append `parse_cafe_state` to `legacy_loader.gd`**

```gdscript


func parse_cafe_state(r: BinaryReader, version: int) -> Dictionary:
	var s: Dictionary = {
		"U1": 0.0, "ExperiencePoints": 0.0,
		"Toxin": 0, "Money": 0, "Level": 0,
		"U6": 0, "U7": 0, "U8": 0.0, "U9": 0, "U10": false,
		"Character": {},
		"NumZombies": 0, "Zombies": [],
		"U11": 0, "U12": [], "U13": false,
	}
	s["U1"] = r.read_float64()
	s["ExperiencePoints"] = r.read_float()
	s["Toxin"] = r.read_int32()
	s["Money"] = r.read_int32()
	s["Level"] = r.read_int32()
	s["U6"] = r.read_int32()
	s["U7"] = r.read_int32()
	s["U8"] = r.read_float()
	s["U9"] = r.read_int32()
	s["U10"] = r.read_bool()
	s["Character"] = parse_character_instance(r, version)

	s["NumZombies"] = r.read_byte()
	var zombies: Array = []
	for i in range(int(s["NumZombies"])):
		zombies.append(parse_character_instance(r, version))
	s["Zombies"] = zombies

	if version > 62:
		s["U11"] = r.read_int32()
	else:
		s["U11"] = int(r.read_byte())

	var u12: Array = []
	for i in range(int(s["U11"])):
		u12.append(r.read_int8())
	s["U12"] = u12

	if version > 33:
		s["U13"] = r.read_bool()
	return s
```

- [ ] **Step 2: Append `write_cafe_state` to `legacy_writer.gd`**

```gdscript


func write_cafe_state(w: BinaryWriter, s: Dictionary, version: int) -> void:
	w.write_float64(float(s["U1"]))
	w.write_float(float(s["ExperiencePoints"]))
	w.write_int32(int(s["Toxin"]))
	w.write_int32(int(s["Money"]))
	w.write_int32(int(s["Level"]))
	w.write_int32(int(s["U6"]))
	w.write_int32(int(s["U7"]))
	w.write_float(float(s["U8"]))
	w.write_int32(int(s["U9"]))
	w.write_bool(s["U10"])
	write_character_instance(w, s["Character"] as Dictionary, version)

	w.write_byte(int(s["NumZombies"]))
	for z in (s["Zombies"] as Array):
		write_character_instance(w, z as Dictionary, version)

	if version > 62:
		w.write_int32(int(s["U11"]))
	else:
		w.write_byte(int(s["U11"]))

	for v in (s["U12"] as Array):
		w.write_int8(int(v))

	if version > 33:
		w.write_bool(s["U13"])
```

- [ ] **Step 3: Append a `_make_cafe_state_fixture` helper plus `_test_cafe_state_round_trip` to `test_save_round_trip.gd`**

Mirroring Go's `makeCafeStateFixture()` at `tool/file_types/roundtrip_test.go:462`:

```gdscript


func _make_cafe_state_fixture() -> Dictionary:
	# Mirrors Go's makeCafeStateFixture() — used here and in the SaveGame
	# / FriendCafe in-memory fixture tests below.
	var main_char: Dictionary = {
		"Type": 1, "Name": "MainZombie",
		"U2": 1, "U3": 2, "U4": 3.5, "U5": 4,
		"U6": 1000000000, "U7": 5, "U8": 2000000000, "U9": 3000000000,
		"U10": 10, "U11": 20, "U12": 30, "U13": 40,
		"U14": 50, "U15": 60, "U16": 70,
	}
	var zombie: Dictionary = {
		"Type": 2, "Name": "Z1",
		"U2": 3, "U3": 4, "U4": 5.5, "U5": 6,
		"U6": 1500000000, "U7": 7, "U8": 2500000000, "U9": 3500000000,
		"U10": 11, "U11": 21, "U12": 31, "U13": 41,
		"U14": 51, "U15": 61, "U16": 71,
	}
	return {
		"U1": 123.456,
		"ExperiencePoints": 999.5,
		"Toxin": 50,
		"Money": 500,
		"Level": 5,
		"U6": 1, "U7": 2,
		"U8": 3.0, "U9": 4,
		"U10": true,
		"Character": main_char,
		"NumZombies": 1,
		"Zombies": [zombie],
		"U11": 3,
		"U12": [1, 2, 3],
		"U13": true,
	}


func _test_cafe_state_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	var original: Dictionary = _make_cafe_state_fixture()

	var w := BinaryWriter.make()
	writer.write_cafe_state(w, original, version)
	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_cafe_state(r, version)

	_check("cafe_state consumed", r.remaining() == 0)
	_check("cafe_state no fail", r.failed == false)
	_check("cafe_state U1 float64", abs(float(decoded["U1"]) - 123.456) < 1e-12)
	_check("cafe_state ExperiencePoints float32", abs(float(decoded["ExperiencePoints"]) - 999.5) < 1e-3)
	_check("cafe_state Toxin", decoded["Toxin"] == 50)
	_check("cafe_state Money", decoded["Money"] == 500)
	_check("cafe_state Level", decoded["Level"] == 5)
	_check("cafe_state Character.Name", decoded["Character"]["Name"] == "MainZombie")
	_check("cafe_state NumZombies", decoded["NumZombies"] == 1)
	_check("cafe_state Zombies[0].Name", (decoded["Zombies"] as Array)[0]["Name"] == "Z1")
	_check("cafe_state U11", decoded["U11"] == 3)
	_check("cafe_state U12 length", (decoded["U12"] as Array).size() == 3)
	_check("cafe_state U12[0]", (decoded["U12"] as Array)[0] == 1)
	_check("cafe_state U13", decoded["U13"] == true)
```

Add the call to `_init()`.

- [ ] **Step 4: Run, expect 117 + 13 = 130 PASS**

---

## Task 6: Add `parse_save_game` / `write_save_game` (top-level) with Trailing_b64

**Files:**
- Modify: `godot/scripts/save/legacy_loader.gd`
- Modify: `godot/scripts/save/legacy_writer.gd`
- Modify: `godot/test/test_save_round_trip.gd`

Go reference (`save_game.go:56-77` and `:164-306`):

```go
type SaveGame struct {
    Version     byte
    State       CafeState
    PreStrings  SaveStrings
    U15         Date
    PostStrings SaveStrings
    U17         Date
    NumOrders   int16
    U18         byte
    U19         byte
    U20         bool
    Trailing []byte
}
```

Reader logic at `version=63`:
1. read `Version` byte
2. if `Version != 63`: return early (default-zero struct)
3. parse `State` via `readCafeState(version=63)`
4. parse `PreStrings` via `readSaveStrings`
5. read `U15` Date
6. parse `PostStrings` via `readSaveStrings`
7. read `U17` Date
8. read `NumOrders` int16; **panic if > 0** (orders not implemented)
9. read `U18` byte, `U19` byte, `U20` bool
10. `io.ReadAll` the rest into `Trailing` (preserve only if non-empty in Go)

GDScript port mirrors all of the above. The "non-empty Trailing" preservation rule maps cleanly: store `Trailing_b64` as a String — empty string when no trailing bytes, base64-encoded String otherwise.

`Marshalls.raw_to_base64(PackedByteArray)` and `Marshalls.base64_to_raw(String)` are the canonical Godot 4 codecs (standard base64 with padding, matching Go's `encoding/base64.StdEncoding`).

- [ ] **Step 1: Append `parse_save_game` to `legacy_loader.gd`**

```gdscript


func parse_save_game(r: BinaryReader) -> Dictionary:
	var s: Dictionary = {
		"Version": 0,
		"State": {},
		"PreStrings": {"RawCount": 0, "Strings": []},
		"U15": {"Year": 0, "Month": 0, "Day": 0, "Hour": 0, "Minute": 0, "Second": 0},
		"PostStrings": {"RawCount": 0, "Strings": []},
		"U17": {"Year": 0, "Month": 0, "Day": 0, "Hour": 0, "Minute": 0, "Second": 0},
		"NumOrders": 0,
		"U18": 0, "U19": 0, "U20": false,
		"Trailing_b64": "",
	}
	s["Version"] = r.read_byte()
	if int(s["Version"]) != 63:
		# Default-zero return matches Go's behavior for unknown versions.
		return s

	var version: int = int(s["Version"])
	s["State"] = parse_cafe_state(r, version)
	s["PreStrings"] = parse_save_strings(r)
	s["U15"] = r.read_date()
	s["PostStrings"] = parse_save_strings(r)
	s["U17"] = r.read_date()
	s["NumOrders"] = r.read_int16()
	if int(s["NumOrders"]) > 0:
		push_error("parse_save_game: NumOrders > 0 — orders deserialization not implemented")
		r.failed = true
		return s
	s["U18"] = r.read_byte()
	s["U19"] = r.read_byte()
	s["U20"] = r.read_bool()
	# Preserve any trailing bytes the struct doesn't know about — globalData.dat
	# carries ~1 KB of additional data past U20 (probably an extended character
	# / friend list). Storing as base64 keeps the JSON envelope round-trip in
	# Sessions 3+ readable.
	if r.remaining() > 0:
		var tail: PackedByteArray = r.bytes.slice(r.pos, r.bytes.size())
		s["Trailing_b64"] = Marshalls.raw_to_base64(tail)
		r.pos = r.bytes.size()
	return s


static func parse_save_game_bytes(data: PackedByteArray) -> Dictionary:
	var loader := LegacyLoader.new()
	var reader := BinaryReader.wrap(data)
	var result: Dictionary = loader.parse_save_game(reader)
	if reader.failed or reader.remaining() != 0:
		push_error("parse_save_game_bytes: reader failed=%s remaining=%d" % [reader.failed, reader.remaining()])
		return {}
	return result
```

- [ ] **Step 2: Append `write_save_game` to `legacy_writer.gd`**

```gdscript


func write_save_game(w: BinaryWriter, s: Dictionary) -> void:
	w.write_byte(int(s["Version"]))
	if int(s["Version"]) != 63:
		return

	var version: int = int(s["Version"])
	write_cafe_state(w, s["State"] as Dictionary, version)
	write_save_strings(w, s["PreStrings"] as Dictionary)
	w.write_date(s["U15"] as Dictionary)
	write_save_strings(w, s["PostStrings"] as Dictionary)
	w.write_date(s["U17"] as Dictionary)
	w.write_int16(int(s["NumOrders"]))
	if int(s["NumOrders"]) > 0:
		push_error("write_save_game: NumOrders > 0 — orders serialization not implemented")
		return
	w.write_byte(int(s["U18"]))
	w.write_byte(int(s["U19"]))
	w.write_bool(s["U20"])

	var b64: String = String(s.get("Trailing_b64", ""))
	if b64 != "":
		var tail: PackedByteArray = Marshalls.base64_to_raw(b64)
		# append_array on the underlying buffer keeps the writer's contract
		# (only emit the remaining bytes; the consumer counts the writer's
		# total output). BinaryWriter has no append_bytes helper, so we
		# expose the bytes via tail iteration to keep the surface minimal.
		for byte_value in tail:
			w.write_byte(byte_value)


static func write_save_game_bytes(save: Dictionary) -> PackedByteArray:
	var writer := LegacyWriter.new()
	var w := BinaryWriter.make()
	writer.write_save_game(w, save)
	return w.to_bytes()
```

**Note on the `for byte_value in tail` loop:** an alternative would be to add a `BinaryWriter.append_bytes(bytes: PackedByteArray)` helper that uses `_buf.append_array(bytes)`. That is cleaner; if subagent wants it, add it as a one-liner during this step and use it here. Either way works. Recommended: add `append_bytes` so the writer surface stays uniform with `write_*` helpers — see the optional refactor at the end of this Task 6.

- [ ] **Step 3 (optional polish): Add `BinaryWriter.append_bytes`**

If preferred over the per-byte loop, append to `binary_writer.gd` after `write_int8`:

```gdscript


func append_bytes(bytes: PackedByteArray) -> void:
	_buf.append_array(bytes)
```

Then replace the `for byte_value in tail` loop in `write_save_game` with:

```gdscript
	if b64 != "":
		var tail: PackedByteArray = Marshalls.base64_to_raw(b64)
		w.append_bytes(tail)
```

- [ ] **Step 4: Append `_test_save_game_in_memory_round_trip` to `test_save_round_trip.gd`**

Mirroring Go's `TestSaveGameRoundTrip`:

```gdscript


func _test_save_game_in_memory_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()

	var original: Dictionary = {
		"Version": 63,
		"State": _make_cafe_state_fixture(),
		"PreStrings": {"RawCount": 3, "Strings": ["pre_alpha", "pre_beta"]},
		"U15": {"Year": 2026, "Month": 4, "Day": 11, "Hour": 14, "Minute": 0, "Second": 0},
		"PostStrings": {"RawCount": 2, "Strings": ["post_solo"]},
		"U17": {"Year": 2026, "Month": 4, "Day": 11, "Hour": 14, "Minute": 30, "Second": 30},
		"NumOrders": 0,
		"U18": 7, "U19": 42, "U20": true,
		"Trailing_b64": "",
	}

	var bytes: PackedByteArray = LegacyWriter.write_save_game_bytes(original)
	var decoded: Dictionary = LegacyLoader.parse_save_game_bytes(bytes)

	_check("save_game in-memory parsed non-empty", decoded.size() > 0)
	_check("save_game in-memory Version", int(decoded["Version"]) == 63)
	_check("save_game in-memory State.Money", int((decoded["State"] as Dictionary)["Money"]) == 500)
	_check("save_game in-memory PreStrings.RawCount", int((decoded["PreStrings"] as Dictionary)["RawCount"]) == 3)
	_check("save_game in-memory PreStrings[0]", String(((decoded["PreStrings"] as Dictionary)["Strings"] as Array)[0]) == "pre_alpha")
	_check("save_game in-memory U15 date", _date_eq(decoded["U15"], original["U15"]))
	_check("save_game in-memory PostStrings.RawCount", int((decoded["PostStrings"] as Dictionary)["RawCount"]) == 2)
	_check("save_game in-memory U17 date", _date_eq(decoded["U17"], original["U17"]))
	_check("save_game in-memory NumOrders", int(decoded["NumOrders"]) == 0)
	_check("save_game in-memory U18", int(decoded["U18"]) == 7)
	_check("save_game in-memory U20", decoded["U20"] == true)
	_check("save_game in-memory Trailing_b64 empty", String(decoded["Trailing_b64"]) == "")

	# Re-encode the decoded dict and confirm bytes match
	var bytes_again: PackedByteArray = LegacyWriter.write_save_game_bytes(decoded)
	_check("save_game in-memory re-encode size", bytes_again.size() == bytes.size())
	_check("save_game in-memory re-encode bytes match", bytes_again == bytes)
```

Add the call to `_init()`.

- [ ] **Step 5: Run, expect 130 + 14 = 144 PASS**

---

## Task 7: Add real-fixture round-trip tests for `globalData.dat` + `BACKUP1.dat`

**Files:**
- Modify: `godot/test/test_save_round_trip.gd`

This is the headline Layer-1 test for `SaveGame`. The two real device fixtures (1626 B and 1556 B) carry the ~1 KB `Trailing_b64` blob that the in-memory test couldn't exercise.

- [ ] **Step 1: Append `_test_save_game_fixtures` to `test_save_round_trip.gd`**

Modeled on `_test_cafe_fixtures` from Session 1:

```gdscript


func _test_save_game_fixtures() -> void:
	for name in ["globalData.dat", "BACKUP1.dat"]:
		var path: String = FIXTURES_DIR + "/" + name
		var bytes_in: PackedByteArray = FileAccess.get_file_as_bytes(path)
		_check("fixture %s loaded" % name, bytes_in.size() > 0,
			"FileAccess.get_open_error=%d" % FileAccess.get_open_error())

		var dict: Dictionary = LegacyLoader.parse_save_game_bytes(bytes_in)
		_check("fixture %s parsed non-empty" % name, dict.size() > 0)
		_check("fixture %s Version=63" % name, int(dict.get("Version", 0)) == 63)
		_check("fixture %s Trailing_b64 non-empty" % name,
			String(dict.get("Trailing_b64", "")) != "",
			"trailing was empty — preservation field not populated?")

		var bytes_out: PackedByteArray = LegacyWriter.write_save_game_bytes(dict)
		_check("fixture %s round-trip size" % name,
			bytes_out.size() == bytes_in.size(),
			"in=%d out=%d" % [bytes_in.size(), bytes_out.size()])
		_check("fixture %s round-trip byte-identical" % name,
			bytes_in == bytes_out,
			"first diff at byte %d" % _first_diff(bytes_in, bytes_out))
```

Add the call to `_init()`.

- [ ] **Step 2: Run, expect 144 + 12 = 156 PASS** (6 checks per fixture × 2 fixtures)

If a `first diff` is reported, narrow it down by hex-dumping the surrounding region in both files:

```bash
xxd -s $((DIFF - 16)) -l 64 godot/test/fixtures/save/globalData.dat
```

The most likely failure modes:
- **`SaveStrings` writer counts** — if the in-memory test passed but the fixture fails near offset where strings live, double-check that `RawCount` is being written rather than `len(Strings)` (the most common port-error)
- **`Trailing_b64` base64 round-trip** — ensure `Marshalls.raw_to_base64` and `Marshalls.base64_to_raw` round-trip the bytes byte-identically (they should — both use standard base64 with padding, but a manual sanity-check at the GDScript REPL never hurts)
- **Float32 round-trip in `CharacterInstance.U4`** — should never fail because `decode_float`/`encode_float` are bit-identical IEEE 754 binary32 LE codecs, but a regression here would surface as a 4-byte difference at a very specific offset

---

## Task 8: Add `parse_friend_cafe` / `write_friend_cafe` (top-level)

**Files:**
- Modify: `godot/scripts/save/legacy_loader.gd`
- Modify: `godot/scripts/save/legacy_writer.gd`
- Modify: `godot/test/test_save_round_trip.gd`

Go reference (`friend_cafe.go`):

```go
type FriendCafe struct {
    Version byte
    State   CafeState
    Cafe    Cafe
}

func ReadFriendData(file io.Reader) FriendCafe {
    var s FriendCafe
    s.Version = ReadByte(file)
    if s.Version != 63 {
        panic("Unable to handle this cafe version")
    }
    s.State = readCafeState(file, int(s.Version))
    s.Cafe = ReadCafe(file)
    return s
}
```

Three lines of orchestration: leading version byte, embedded `CafeState`, embedded `Cafe`. The `Cafe` and `CafeState` parsers from Session 1 + Task 5 do all the work.

- [ ] **Step 1: Append `parse_friend_cafe` to `legacy_loader.gd`**

```gdscript


func parse_friend_cafe(r: BinaryReader) -> Dictionary:
	var f: Dictionary = {"Version": 0, "State": {}, "Cafe": {}}
	f["Version"] = r.read_byte()
	if int(f["Version"]) != 63:
		push_error("parse_friend_cafe: unsupported version %d" % int(f["Version"]))
		r.failed = true
		return f
	f["State"] = parse_cafe_state(r, int(f["Version"]))
	f["Cafe"] = parse_cafe(r)
	return f


static func parse_friend_cafe_bytes(data: PackedByteArray) -> Dictionary:
	var loader := LegacyLoader.new()
	var reader := BinaryReader.wrap(data)
	var result: Dictionary = loader.parse_friend_cafe(reader)
	if reader.failed or reader.remaining() != 0:
		push_error("parse_friend_cafe_bytes: reader failed=%s remaining=%d" % [reader.failed, reader.remaining()])
		return {}
	return result
```

- [ ] **Step 2: Append `write_friend_cafe` to `legacy_writer.gd`**

```gdscript


func write_friend_cafe(w: BinaryWriter, f: Dictionary) -> void:
	w.write_byte(int(f["Version"]))
	write_cafe_state(w, f["State"] as Dictionary, int(f["Version"]))
	write_cafe(w, f["Cafe"] as Dictionary)


static func write_friend_cafe_bytes(fc: Dictionary) -> PackedByteArray:
	var writer := LegacyWriter.new()
	var w := BinaryWriter.make()
	writer.write_friend_cafe(w, fc)
	return w.to_bytes()
```

- [ ] **Step 3: Append `_test_friend_cafe_in_memory_round_trip` to `test_save_round_trip.gd`**

Mirroring Go's `TestFriendCafeRoundTrip`:

```gdscript


func _test_friend_cafe_in_memory_round_trip() -> void:
	# We can't easily build a Cafe-by-hand fixture for in-memory testing
	# without re-implementing makeCafeFixture from the Go side. Instead,
	# round-trip the playerCafe.caf bytes through parse_cafe so we get
	# a known-good Cafe Dictionary, then wrap it in a FriendCafe envelope.
	var cafe_bytes: PackedByteArray = FileAccess.get_file_as_bytes(FIXTURES_DIR + "/playerCafe.caf")
	var cafe_dict: Dictionary = LegacyLoader.parse_cafe_bytes(cafe_bytes)
	_check("friend_cafe in-memory: cafe sub-fixture loaded", cafe_dict.size() > 0)

	var original: Dictionary = {
		"Version": 63,
		"State": _make_cafe_state_fixture(),
		"Cafe": cafe_dict,
	}

	var bytes: PackedByteArray = LegacyWriter.write_friend_cafe_bytes(original)
	var decoded: Dictionary = LegacyLoader.parse_friend_cafe_bytes(bytes)

	_check("friend_cafe in-memory parsed non-empty", decoded.size() > 0)
	_check("friend_cafe in-memory Version", int(decoded["Version"]) == 63)
	_check("friend_cafe in-memory State.Money", int((decoded["State"] as Dictionary)["Money"]) == 500)
	_check("friend_cafe in-memory Cafe.Version", int((decoded["Cafe"] as Dictionary)["Version"]) == 63)

	var bytes_again: PackedByteArray = LegacyWriter.write_friend_cafe_bytes(decoded)
	_check("friend_cafe in-memory re-encode size", bytes_again.size() == bytes.size())
	_check("friend_cafe in-memory re-encode bytes match", bytes_again == bytes)
```

Add the call to `_init()`.

- [ ] **Step 4: Run, expect 156 + 6 = 162 PASS**

---

## Task 9: Add real-fixture round-trip test for `ServerData.dat`

**Files:**
- Modify: `godot/test/test_save_round_trip.gd`

`ServerData.dat` is the legacy game's last-cached friend cafe (downloaded during a server raid). It's `byte Version + CafeState State + Cafe Cafe`, exactly the `FriendCafe` shape.

- [ ] **Step 1: Append `_test_friend_cafe_fixture` to `test_save_round_trip.gd`**

```gdscript


func _test_friend_cafe_fixture() -> void:
	var name: String = "ServerData.dat"
	var path: String = FIXTURES_DIR + "/" + name
	var bytes_in: PackedByteArray = FileAccess.get_file_as_bytes(path)
	_check("fixture %s loaded" % name, bytes_in.size() > 0,
		"FileAccess.get_open_error=%d" % FileAccess.get_open_error())

	var dict: Dictionary = LegacyLoader.parse_friend_cafe_bytes(bytes_in)
	_check("fixture %s parsed non-empty" % name, dict.size() > 0)
	_check("fixture %s Version=63" % name, int(dict.get("Version", 0)) == 63)
	_check("fixture %s Cafe.Version=63" % name,
		int((dict.get("Cafe", {}) as Dictionary).get("Version", 0)) == 63)

	var bytes_out: PackedByteArray = LegacyWriter.write_friend_cafe_bytes(dict)
	_check("fixture %s round-trip size" % name,
		bytes_out.size() == bytes_in.size(),
		"in=%d out=%d" % [bytes_in.size(), bytes_out.size()])
	_check("fixture %s round-trip byte-identical" % name,
		bytes_in == bytes_out,
		"first diff at byte %d" % _first_diff(bytes_in, bytes_out))
```

Add the call to `_init()`.

- [ ] **Step 2: Run, expect 162 + 6 = 168 PASS**

If `first diff` is reported, the dominant suspects are:
- **`CafeState.U11` / `U12` length mismatch** — at v=63 we read `U11` as int32. If the file's `U11` happens to be 0 (no `U12` bytes), the reader still reads the int32. A miscount in either direction shifts every subsequent byte.
- **`Cafe.Version` byte read inside `parse_cafe`** — Session 1's parser reads this; for `FriendCafe`, the reader has already consumed the leading version byte, so `parse_cafe` sees the second `Version` byte in the file (which should also be 63, encoded inside the embedded Cafe). Confirm this by checking the byte at offset where the embedded Cafe starts.

---

## Task 10: Update test runner header and rewrite-plan checklist

**Files:**
- Modify: `godot/test/test_save_round_trip.gd`
- Modify: `docs/rewrite-plan.md`

- [ ] **Step 1: Rename the summary line in `test_save_round_trip.gd`**

The runner currently prints `Session 1 results: ...`. Replace with a session-agnostic banner so Session 3 doesn't need to touch it again. Find:

```gdscript
	print("\n=== Session 1 results: %d passed, %d failed ===" % [_passed, _failed])
```

Replace with:

```gdscript
	print("\n=== Save round-trip results: %d passed, %d failed ===" % [_passed, _failed])
```

Also update the docstring at the top of the file. Find:

```gdscript
## Phase 3 Layer-1 round-trip test runner. Builds up over Sessions 1-3:
##   Session 1: primitive round-trip + Cafe fixture round-trip
##   Session 2: SaveGame + FriendCafe fixture round-trip
##   Session 3: cross-validation (Layer 2) + envelope round-trip (Layer 3)
```

Leave it as-is — it already describes the multi-session arc. The contents will continue to grow in Session 3 without further header changes.

- [ ] **Step 2: Append a "Session 2 of 4" landed entry to `docs/rewrite-plan.md`**

Find the existing "Landed (Session 1 of 4 per ..." block under the Phase 3 heading. Append a new "Landed (Session 2 of 4)" block immediately after the Session 1 block:

```markdown
Landed (Session 2 of 4 per `docs/superpowers/specs/2026-04-25-godot-save-format-bridge-design.md`):

- *(done)* `legacy_loader.gd` / `legacy_writer.gd` extended with `parse_save_strings`, `parse_character_instance`, `parse_cafe_state`, `parse_save_game`, `parse_friend_cafe`, plus matching writers and `parse_*_bytes` / `write_*_bytes` static dispatch wrappers. The `SaveStrings` count-1 quirk (`RawCount=0` and `RawCount=1` both decode to zero strings) is preserved by storing `RawCount` separately from the string list. The ~1 KB `SaveGame.Trailing` preservation field is stored as `Trailing_b64` (standard base64) per the spec's `_b64` suffix convention.
- *(done)* New primitives `read_int8` / `write_int8` (and `BinaryWriter.append_bytes`) added to support `CafeState.U12 []int8` and the `Trailing_b64` re-emit path.
- *(done)* Three more fixtures copied into `godot/test/fixtures/save/`: `globalData.dat` (1,626 B), `BACKUP1.dat` (1,556 B), `ServerData.dat` (20,747 B).
- *(done)* `godot/test/test_save_round_trip.gd` extended with 8 new `_test_*` functions covering all five real fixtures plus boundary in-memory cases. Final count: 168 PASS / 0 FAIL.
```

(Leave the "Sessions 2-4 remain" prose in the surrounding handoff context for the moment — Session 4's close-out will rewrite the section as a single "Phase 3 done" line.)

---

## Task 11: Final verification, optional polish, and the single grouped commit

**Files:**
- N/A — verification + commit

- [ ] **Step 1: Final test run**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" \
  --headless --path godot/ --script res://test/test_save_round_trip.gd
```

Expected (verbatim): `=== Save round-trip results: 168 passed, 0 failed ===`, exit 0.

If the run shows `Identifier "..." not declared`, rebuild the class cache and re-run:

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" \
  --headless --editor --quit --path godot/
```

- [ ] **Step 2: Confirm Go side still green (no regressions to the canonical oracle)**

```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/...
```

Expected: all green. Session 2 should not have touched any Go file, so a regression here would mean an accidental edit landed.

- [ ] **Step 3: Confirm headless asset validator still green**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" \
  --headless --path godot/ --script res://validate_assets.gd
```

Expected: 15/15 checks pass. Session 2 doesn't touch the asset path, but cheap to confirm.

- [ ] **Step 4: Inspect `git status` and stage the right files**

```bash
git status
```

Expected new/modified set:
- `M godot/scripts/save/binary_reader.gd`
- `M godot/scripts/save/binary_writer.gd`
- `M godot/scripts/save/legacy_loader.gd`
- `M godot/scripts/save/legacy_writer.gd`
- `M godot/test/test_save_round_trip.gd`
- `M docs/rewrite-plan.md`
- `?? godot/test/fixtures/save/globalData.dat`
- `?? godot/test/fixtures/save/BACKUP1.dat`
- `?? godot/test/fixtures/save/ServerData.dat`
- `?? docs/superpowers/plans/2026-04-25-phase-3-session-2-savegame-friendcafe.md` (this plan, if not yet committed)

Stage explicitly (avoid `git add -A` per repo convention):

```bash
git add godot/scripts/save/binary_reader.gd \
        godot/scripts/save/binary_writer.gd \
        godot/scripts/save/legacy_loader.gd \
        godot/scripts/save/legacy_writer.gd \
        godot/test/test_save_round_trip.gd \
        godot/test/fixtures/save/globalData.dat \
        godot/test/fixtures/save/BACKUP1.dat \
        godot/test/fixtures/save/ServerData.dat \
        docs/rewrite-plan.md \
        docs/superpowers/plans/2026-04-25-phase-3-session-2-savegame-friendcafe.md
```

If `git status` shows `*.import` files modified by the autocrlf path, do not stage them. They'll resolve on the next genuine update.

- [ ] **Step 5: Create the single grouped commit**

```bash
git commit -m "$(cat <<'EOF'
godot: phase 3 session 2 — SaveGame + FriendCafe round-trip

Extend the GDScript save format port from Session 1 to cover the remaining
two formats. All five real device fixtures (playerCafe.caf, BACKUP1.caf,
globalData.dat, BACKUP1.dat, ServerData.dat) now round-trip byte-identically
through pure GDScript; the headless test runner reports 168 PASS / 0 FAIL.

New parsers/writers in legacy_loader.gd / legacy_writer.gd:
  parse_save_strings / write_save_strings — preserves the count-1 quirk
    (RawCount=0 and RawCount=1 both decode to zero strings, so the raw
    count is stored separately from the string list)
  parse_character_instance / write_character_instance
  parse_cafe_state / write_cafe_state — uses int8 for U12
  parse_save_game / write_save_game — preserves the ~1 KB SaveGame.Trailing
    blob as Trailing_b64 (standard base64 per the spec's _b64 convention)
  parse_friend_cafe / write_friend_cafe — orchestration on top of CafeState
    + Cafe (the latter from Session 1)

Plus parse_*_bytes / write_*_bytes static dispatch wrappers matching the
Session 1 surface, and read_int8 / write_int8 / append_bytes primitives.

Three fixtures copied from tool/file_types/testdata/ to godot/test/fixtures/
save/ to make the runner self-contained.

docs/rewrite-plan.md gets a Session 2 of 4 landed entry under Phase 3.

Sessions 3-4 remain: cross-validation oracle + JSON envelope + CI wiring
(Session 3), devlog/handoff close-out (Session 4).
EOF
)"
```

Per `feedback_no_coauthor_trailer`: do **not** add a `Co-Authored-By:` line.

- [ ] **Step 6: Confirm the commit**

```bash
git log -1 --stat
```

Should show the 10 staged paths above (5 modified, 5 added).

---

## Acceptance criteria summary

Session 2 is complete when:

1. `godot --headless --path godot/ --script res://test/test_save_round_trip.gd` prints `=== Save round-trip results: 168 passed, 0 failed ===` and exits 0.
2. All five real device fixtures round-trip byte-identically:
   - `playerCafe.caf` (Session 1, no regression)
   - `BACKUP1.caf` (Session 1, no regression)
   - `globalData.dat` (this session)
   - `BACKUP1.dat` (this session)
   - `ServerData.dat` (this session)
3. `go test ./tool/file_types/...` still green (no Go side touched).
4. Single grouped commit landed with no `Co-Authored-By` trailer.
5. `docs/rewrite-plan.md` includes the new "Session 2 of 4 landed" block.

Sessions 3 (cross-validation oracle + JSON envelope + CI) and 4 (close-out docs) inherit a foundation that needs no further binary-format work.

---

## Expected total PASS count progression

For audit:

| Task | New checks | Cumulative |
|---|---|---|
| (Session 1 baseline) | 87 | 87 |
| Task 2 (`int8` primitives) | 3 | 90 |
| Task 3 (`save_strings` × 4 cases × 4 checks) | 16 | 106 |
| Task 4 (`character_instance`) | 11 | 117 |
| Task 5 (`cafe_state`) | 13 | 130 |
| Task 6 (`save_game` in-memory) | 14 | 144 |
| Task 7 (`save_game` real fixtures × 2) | 12 | 156 |
| Task 8 (`friend_cafe` in-memory) | 6 | 162 |
| Task 9 (`friend_cafe` real fixture) | 6 | 168 |

Final: **168 PASS / 0 FAIL**.

If the cumulative is off by ±1-2 because of an extra or missing check during implementation, that's fine — the byte-identical round-trip on real fixtures is the load-bearing signal. Update the commit message and the rewrite-plan landed-entry to match the actual final count.
