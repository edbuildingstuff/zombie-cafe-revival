# Phase 3 Session 1: Primitives + Cafe Round-Trip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the GDScript foundation for the Phase 3 save format bridge — `BinaryReader` / `BinaryWriter` primitives, all `Cafe`-family parsers and writers (`FoodStack`, `Food`, `CafeObject`, `CafeWall`, `CafeFurniture`, `Stove`, `ServingCounter`, `CafeTile`, top-level `Cafe`), and a Layer-1 round-trip test runner that exits `OK 2/2` on the real device fixtures `playerCafe.caf` and `BACKUP1.caf`. After this session, `SaveGame` and `FriendCafe` (Session 2) and the cross-validation oracle (Session 3) sit on top of the foundation this session lands.

**Architecture:** Pure GDScript port of `tool/file_types/binary_reader.go` + `binary_writer.go` + `cafe.go` (relevant subset). Each `parse_*` function takes a `BinaryReader` and a `version: int`, returns a `Dictionary` with PascalCase keys mirroring the Go struct shape. Each `write_*` function takes a `BinaryWriter`, a `Dictionary`, and a `version: int`, writes the bytes in the same order Go's writer does. Optional/version-conditional fields are gated by either `bool` flags (matching Go's `Has*` pattern) or `version > N` checks (matching Go's branches). All recursion lives within `legacy_loader.gd` and `legacy_writer.gd` as same-class method calls — no forward-declaration concerns in GDScript.

**Tech Stack:** GDScript 4.x (Godot 4.6.2), `PackedByteArray` for byte buffers, `Dictionary` as the canonical in-memory representation, no external dependencies.

**Spec:** `docs/superpowers/specs/2026-04-25-godot-save-format-bridge-design.md`

**Environment gotchas** (from `docs/handoff.md`):
- Repo root: `/c/Users/edwar/edbuildingstuff/zombie-cafe-revival` (your shell may also see it as `C:/Users/edwar/Documents/edbuildingstuff/zombie-cafe-revival` on Windows; both are the same workspace)
- Godot 4.6.2 console binary: `/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe`
- Use the `_console` variant for headless runs (the plain `.exe` spawns a separate window that is hard to capture)
- Godot's class-name registry is lazy. After adding any new `class_name` directive, run `godot --headless --editor --quit --path godot/` once to rebuild the class cache before running tests. Symptom of forgetting: `Identifier "FooClass" not declared`.

**Commit policy:** Per the user's `feedback_commit_style` preference (one grouped commit per session, not per task), do **NOT** commit between tasks. Task 14 creates the single commit covering all of Session 1's work. Per the user's `feedback_no_coauthor_trailer` preference, do **NOT** include a `Co-Authored-By` trailer.

---

## File structure

After this session, the repository will gain:

```
godot/
├── scripts/
│   └── save/
│       ├── primitives.gd          NEW — BinaryReader + BinaryWriter classes
│       ├── legacy_loader.gd       NEW — parse_cafe + Cafe sub-record parsers
│       └── legacy_writer.gd       NEW — write_cafe + Cafe sub-record writers
└── test/
    ├── test_save_round_trip.gd    NEW — test runner script with embedded asserts
    └── fixtures/
        └── save/
            ├── playerCafe.caf     NEW — copied from tool/file_types/testdata/
            └── BACKUP1.caf        NEW — copied from tool/file_types/testdata/
```

Sessions 2-4 will add `parse_save_game` / `parse_friend_cafe` to `legacy_loader.gd` (and corresponding writers), `save_v1.gd` for the JSON envelope, and the `tool/dump_legacy_fixtures/` Go CLI. None of those land in this session.

**Class layout decision:** `primitives.gd` exposes two `class_name`s (`BinaryReader`, `BinaryWriter`). `legacy_loader.gd` and `legacy_writer.gd` expose `LegacyLoader` and `LegacyWriter` respectively, each `extends RefCounted` so they can be instantiated and passed around. All parser methods are instance methods on `LegacyLoader`; all writer methods are instance methods on `LegacyWriter`. This avoids the static-vs-instance confusion that comes up when functions have shared state (the reader's cursor is per-instance).

---

## Task 1: Create directory structure and copy `Cafe` fixtures

**Files:**
- Create: `godot/scripts/save/` (directory)
- Create: `godot/test/` (directory)
- Create: `godot/test/fixtures/save/` (directory)
- Copy: `tool/file_types/testdata/playerCafe.caf` → `godot/test/fixtures/save/playerCafe.caf`
- Copy: `tool/file_types/testdata/BACKUP1.caf` → `godot/test/fixtures/save/BACKUP1.caf`

- [ ] **Step 1: Create the directories**

```bash
mkdir -p godot/scripts/save
mkdir -p godot/test/fixtures/save
```

- [ ] **Step 2: Copy fixtures**

```bash
cp tool/file_types/testdata/playerCafe.caf godot/test/fixtures/save/playerCafe.caf
cp tool/file_types/testdata/BACKUP1.caf godot/test/fixtures/save/BACKUP1.caf
```

- [ ] **Step 3: Verify byte counts match the spec**

```bash
wc -c godot/test/fixtures/save/playerCafe.caf godot/test/fixtures/save/BACKUP1.caf
```

Expected output: `20129` for `playerCafe.caf` and `20017` for `BACKUP1.caf`. Mismatched sizes mean a copy went wrong; re-copy.

---

## Task 2: Scaffold `primitives.gd` with `BinaryReader` skeleton

**Files:**
- Create: `godot/scripts/save/primitives.gd`

`BinaryReader` wraps a `PackedByteArray` and tracks a cursor position. On a short read, sets a `failed` flag and emits a `push_error` (GDScript has no exceptions; the failed-flag pattern is the idiomatic substitute). All later read methods short-circuit if `failed` is already true, so a single short-read cascades into a clean failure rather than reading garbage.

- [ ] **Step 1: Create `primitives.gd` with the `BinaryReader` class skeleton**

Create `godot/scripts/save/primitives.gd` with this content:

```gdscript
class_name BinaryReader
extends RefCounted

## Mirrors tool/file_types/binary_reader.go.
## Big-endian for ints/strings; little-endian for floats and a few
## explicitly-marked LE int helpers (see read_int32_le / read_uint32_le).
## Strings are BE int16 length-prefixed UTF-8.
## On short read, sets `failed = true` and pushes an error. All later
## reads short-circuit while failed is true so the first failure is the
## one that gets reported.

var bytes: PackedByteArray
var pos: int = 0
var failed: bool = false


static func wrap(b: PackedByteArray) -> BinaryReader:
	var r := BinaryReader.new()
	r.bytes = b
	return r


func remaining() -> int:
	return bytes.size() - pos


func _need(n: int) -> bool:
	if failed:
		return false
	if remaining() < n:
		push_error("BinaryReader: short read at pos=%d (have %d, need %d)" % [pos, remaining(), n])
		failed = true
		return false
	return true
```

- [ ] **Step 2: Append a separate `BinaryWriter` class to the same file**

`primitives.gd` carries both classes — they're closely related and tested together. Append after the BinaryReader code:

```gdscript


class_name BinaryWriter
extends RefCounted

## Mirrors tool/file_types/binary_writer.go.
## Appends bytes to an internal PackedByteArray; call `to_bytes()` at the
## end to retrieve the result.

var _buf: PackedByteArray = PackedByteArray()


static func make() -> BinaryWriter:
	return BinaryWriter.new()


func to_bytes() -> PackedByteArray:
	return _buf


func size() -> int:
	return _buf.size()
```

**Note:** GDScript only allows one `class_name` per file. The above won't actually compile as-is — split them into two files in Step 3.

- [ ] **Step 3: Split into two files**

GDScript permits exactly one top-level `class_name` per file. Create two files instead of one:

`godot/scripts/save/binary_reader.gd`:

```gdscript
class_name BinaryReader
extends RefCounted

var bytes: PackedByteArray
var pos: int = 0
var failed: bool = false


static func wrap(b: PackedByteArray) -> BinaryReader:
	var r := BinaryReader.new()
	r.bytes = b
	return r


func remaining() -> int:
	return bytes.size() - pos


func _need(n: int) -> bool:
	if failed:
		return false
	if remaining() < n:
		push_error("BinaryReader: short read at pos=%d (have %d, need %d)" % [pos, remaining(), n])
		failed = true
		return false
	return true
```

`godot/scripts/save/binary_writer.gd`:

```gdscript
class_name BinaryWriter
extends RefCounted

var _buf: PackedByteArray = PackedByteArray()


static func make() -> BinaryWriter:
	return BinaryWriter.new()


func to_bytes() -> PackedByteArray:
	return _buf


func size() -> int:
	return _buf.size()
```

Delete the temporary `primitives.gd` if it was created in Step 1 — we'll use the two-file split instead. Update the file-structure comment at the top of the plan accordingly: `primitives.gd` becomes `binary_reader.gd` + `binary_writer.gd`.

---

## Task 3: Add primitive read/write methods (single-byte + bool)

**Files:**
- Modify: `godot/scripts/save/binary_reader.gd`
- Modify: `godot/scripts/save/binary_writer.gd`

- [ ] **Step 1: Add `read_byte` and `read_bool` to `binary_reader.gd`**

Append:

```gdscript
func read_byte() -> int:
	if not _need(1):
		return 0
	var v: int = bytes[pos]
	pos += 1
	return v


func read_bool() -> bool:
	if not _need(1):
		return false
	var b: int = bytes[pos]
	pos += 1
	if b > 1:
		push_error("BinaryReader.read_bool: byte was %d, not 0 or 1" % b)
		failed = true
		return false
	return b == 1
```

- [ ] **Step 2: Add `write_byte` and `write_bool` to `binary_writer.gd`**

Append:

```gdscript
func write_byte(v: int) -> void:
	_buf.append(v & 0xFF)


func write_bool(v: bool) -> void:
	_buf.append(1 if v else 0)
```

---

## Task 4: Add big-endian integer read/write methods

**Files:**
- Modify: `godot/scripts/save/binary_reader.gd`
- Modify: `godot/scripts/save/binary_writer.gd`

The legacy save format uses big-endian for all `uint16` / `int16` / `uint32` / `int32` / `int64` values **except** the LE-marked helpers (a few specific call sites; see Task 5).

- [ ] **Step 1: Append BE int readers to `binary_reader.gd`**

```gdscript
func read_uint16() -> int:
	if not _need(2):
		return 0
	var v: int = (bytes[pos] << 8) | bytes[pos + 1]
	pos += 2
	return v


func read_int16() -> int:
	var v: int = read_uint16()
	if v >= 0x8000:
		v -= 0x10000
	return v


func read_uint32() -> int:
	if not _need(4):
		return 0
	var v: int = (bytes[pos] << 24) | (bytes[pos + 1] << 16) | (bytes[pos + 2] << 8) | bytes[pos + 3]
	pos += 4
	return v


func read_int32() -> int:
	var v: int = read_uint32()
	if v >= 0x80000000:
		v -= 0x100000000
	return v


func read_int64() -> int:
	if not _need(8):
		return 0
	var v: int = 0
	for i in range(8):
		v = (v << 8) | bytes[pos + i]
	pos += 8
	# GDScript int is 64-bit signed; the byte-shift above already
	# produces the correct two's-complement value for negative inputs
	# because GDScript's << on a 64-bit int sign-extends.
	return v
```

- [ ] **Step 2: Append BE int writers to `binary_writer.gd`**

```gdscript
func write_uint16(v: int) -> void:
	_buf.append((v >> 8) & 0xFF)
	_buf.append(v & 0xFF)


func write_int16(v: int) -> void:
	# Mask to 16 bits first to handle negatives correctly
	var u: int = v & 0xFFFF
	write_uint16(u)


func write_uint32(v: int) -> void:
	_buf.append((v >> 24) & 0xFF)
	_buf.append((v >> 16) & 0xFF)
	_buf.append((v >> 8) & 0xFF)
	_buf.append(v & 0xFF)


func write_int32(v: int) -> void:
	var u: int = v & 0xFFFFFFFF
	write_uint32(u)


func write_int64(v: int) -> void:
	for i in range(7, -1, -1):
		_buf.append((v >> (i * 8)) & 0xFF)
```

---

## Task 5: Add little-endian integer + float read/write methods

**Files:**
- Modify: `godot/scripts/save/binary_reader.gd`
- Modify: `godot/scripts/save/binary_writer.gd`

The Go primitives include LE variants used by `enemy_cafe_data.go` (header) and float reads (which are always LE). Floats are IEEE 754 32-bit / 64-bit, stored little-endian.

- [ ] **Step 1: Append LE int readers + float readers to `binary_reader.gd`**

```gdscript
func read_uint32_le() -> int:
	if not _need(4):
		return 0
	var v: int = bytes[pos] | (bytes[pos + 1] << 8) | (bytes[pos + 2] << 16) | (bytes[pos + 3] << 24)
	pos += 4
	return v


func read_int32_le() -> int:
	var v: int = read_uint32_le()
	if v >= 0x80000000:
		v -= 0x100000000
	return v


func read_float() -> float:
	if not _need(4):
		return 0.0
	# IEEE 754 binary32, little-endian
	var sub: PackedByteArray = bytes.slice(pos, pos + 4)
	pos += 4
	return sub.decode_float(0)


func read_float64() -> float:
	if not _need(8):
		return 0.0
	# IEEE 754 binary64, little-endian
	var sub: PackedByteArray = bytes.slice(pos, pos + 8)
	pos += 8
	return sub.decode_double(0)
```

- [ ] **Step 2: Append LE int writers + float writers to `binary_writer.gd`**

```gdscript
func write_uint32_le(v: int) -> void:
	_buf.append(v & 0xFF)
	_buf.append((v >> 8) & 0xFF)
	_buf.append((v >> 16) & 0xFF)
	_buf.append((v >> 24) & 0xFF)


func write_int32_le(v: int) -> void:
	var u: int = v & 0xFFFFFFFF
	write_uint32_le(u)


func write_float(v: float) -> void:
	var sub := PackedByteArray()
	sub.resize(4)
	sub.encode_float(0, v)
	_buf.append_array(sub)


func write_float64(v: float) -> void:
	var sub := PackedByteArray()
	sub.resize(8)
	sub.encode_double(0, v)
	_buf.append_array(sub)
```

**Note:** `PackedByteArray.encode_float` / `encode_double` and `decode_float` / `decode_double` are little-endian by Godot 4 convention, matching Go's choice for this format.

---

## Task 6: Add string (BE int16 length-prefixed UTF-8) and `Date` read/write methods

**Files:**
- Modify: `godot/scripts/save/binary_reader.gd`
- Modify: `godot/scripts/save/binary_writer.gd`

Strings: BE `int16` length (in *bytes*, not code points) followed by UTF-8. Empty string = `int16(0)` + zero bytes.

`Date` struct (from `binary_reader.go`):
```go
type Date struct {
    Year   int16
    Month  byte
    Day    byte
    Hour   byte
    Minute byte
    Second byte
}
```
The Dictionary representation for a Date is `{"Year": int, "Month": int, "Day": int, "Hour": int, "Minute": int, "Second": int}`.

- [ ] **Step 1: Append `read_string` and `read_date` to `binary_reader.gd`**

```gdscript
func read_string() -> String:
	var length: int = read_int16()
	if failed:
		return ""
	if length == 0:
		return ""
	if length < 0:
		push_error("BinaryReader.read_string: negative length %d at pos=%d" % [length, pos - 2])
		failed = true
		return ""
	if not _need(length):
		return ""
	var sub: PackedByteArray = bytes.slice(pos, pos + length)
	pos += length
	return sub.get_string_from_utf8()


func read_date() -> Dictionary:
	var d := {}
	d["Year"] = read_int16()
	d["Month"] = read_byte()
	d["Day"] = read_byte()
	d["Hour"] = read_byte()
	d["Minute"] = read_byte()
	d["Second"] = read_byte()
	return d
```

- [ ] **Step 2: Append `write_string` and `write_date` to `binary_writer.gd`**

```gdscript
func write_string(v: String) -> void:
	var b: PackedByteArray = v.to_utf8_buffer()
	write_int16(b.size())
	_buf.append_array(b)


func write_date(d: Dictionary) -> void:
	write_int16(int(d["Year"]))
	write_byte(int(d["Month"]))
	write_byte(int(d["Day"]))
	write_byte(int(d["Hour"]))
	write_byte(int(d["Minute"]))
	write_byte(int(d["Second"]))
```

**Note on `int()` casts:** `JSON.parse_string` (used in Layer 2/3 in later sessions) returns floats for all numbers. Although Layer 1 doesn't go through JSON, the writers cast inputs to `int` defensively so the same writer code can be reused unmodified when JSON-sourced Dictionaries flow through it in Session 3.

---

## Task 7: Create the test runner skeleton with primitive round-trip tests

**Files:**
- Create: `godot/test/test_save_round_trip.gd`

The runner is a simple `extends SceneTree` script invoked via `godot --headless --script`. It collects pass/fail counts and exits non-zero on failure. New tests are added by appending `_test_*` calls inside `_init`.

- [ ] **Step 1: Create the runner skeleton**

`godot/test/test_save_round_trip.gd`:

```gdscript
extends SceneTree

## Phase 3 Layer-1 round-trip test runner. Builds up over Sessions 1-3:
##   Session 1: primitive round-trip + Cafe fixture round-trip
##   Session 2: SaveGame + FriendCafe fixture round-trip
##   Session 3: cross-validation (Layer 2) + envelope round-trip (Layer 3)

const FIXTURES_DIR := "res://test/fixtures/save"

var _passed: int = 0
var _failed: int = 0


func _init() -> void:
	_test_primitives_round_trip()
	# Tasks 8-13 append more _test_* calls here.

	print("\n=== Session 1 results: %d passed, %d failed ===" % [_passed, _failed])
	if _failed > 0:
		quit(1)
	else:
		quit(0)


func _check(name: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
		print("PASS: %s" % name)
	else:
		_failed += 1
		var msg := "FAIL: %s" % name
		if detail != "":
			msg += " (%s)" % detail
		printerr(msg)


func _test_primitives_round_trip() -> void:
	# Round-trip every primitive at both extreme and benign values.
	var w := BinaryWriter.make()

	w.write_byte(0x00)
	w.write_byte(0xFF)
	w.write_bool(true)
	w.write_bool(false)
	w.write_uint16(0)
	w.write_uint16(65535)
	w.write_int16(-32768)
	w.write_int16(32767)
	w.write_uint32(0)
	w.write_uint32(0xFFFFFFFF)
	w.write_int32(-2147483648)
	w.write_int32(2147483647)
	w.write_int64(-9223372036854775808)
	w.write_int64(9223372036854775807)
	w.write_uint32_le(0xDEADBEEF)
	w.write_int32_le(-1)
	w.write_float(3.140625)  # exactly representable in float32
	w.write_float64(2.718281828459045)
	w.write_string("")
	w.write_string("hello, 世界")
	w.write_date({"Year": 2026, "Month": 4, "Day": 25, "Hour": 15, "Minute": 18, "Second": 0})

	var r := BinaryReader.wrap(w.to_bytes())

	_check("read_byte 0x00", r.read_byte() == 0x00)
	_check("read_byte 0xFF", r.read_byte() == 0xFF)
	_check("read_bool true", r.read_bool() == true)
	_check("read_bool false", r.read_bool() == false)
	_check("read_uint16 0", r.read_uint16() == 0)
	_check("read_uint16 65535", r.read_uint16() == 65535)
	_check("read_int16 -32768", r.read_int16() == -32768)
	_check("read_int16 32767", r.read_int16() == 32767)
	_check("read_uint32 0", r.read_uint32() == 0)
	_check("read_uint32 max", r.read_uint32() == 0xFFFFFFFF)
	_check("read_int32 min", r.read_int32() == -2147483648)
	_check("read_int32 max", r.read_int32() == 2147483647)
	_check("read_int64 min", r.read_int64() == -9223372036854775808)
	_check("read_int64 max", r.read_int64() == 9223372036854775807)
	_check("read_uint32_le", r.read_uint32_le() == 0xDEADBEEF)
	_check("read_int32_le -1", r.read_int32_le() == -1)
	_check("read_float", abs(r.read_float() - 3.140625) < 1e-9)
	_check("read_float64", abs(r.read_float64() - 2.718281828459045) < 1e-15)
	_check("read_string empty", r.read_string() == "")
	_check("read_string utf8", r.read_string() == "hello, 世界")
	var d: Dictionary = r.read_date()
	_check("read_date round-trip",
		d["Year"] == 2026 and d["Month"] == 4 and d["Day"] == 25
		and d["Hour"] == 15 and d["Minute"] == 18 and d["Second"] == 0)
	_check("reader fully consumed", r.remaining() == 0,
		"%d bytes remaining" % r.remaining())
	_check("reader did not fail", r.failed == false)
```

- [ ] **Step 2: Build the class cache and run the test**

Class names `BinaryReader` and `BinaryWriter` are new, so the class cache must be rebuilt before the test can resolve them.

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" \
  --headless --editor --quit --path godot/
```

Then run the test:

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" \
  --headless --path godot/ --script res://test/test_save_round_trip.gd
```

Expected: every primitive line prints `PASS:`, summary line prints `Session 1 results: 22 passed, 0 failed`, exit code 0.

If any line prints `FAIL:`, debug the corresponding read/write pair before continuing. Most likely cause: signedness handling in the int readers (the `>= 0x8000` / `>= 0x80000000` two's-complement adjustment).

---

## Task 8: Scaffold `legacy_loader.gd` and `legacy_writer.gd`, add `parse_food_stack` / `write_food_stack`

**Files:**
- Create: `godot/scripts/save/legacy_loader.gd`
- Create: `godot/scripts/save/legacy_writer.gd`
- Modify: `godot/test/test_save_round_trip.gd` (add `_test_food_stack`)

`FoodStack` is the lowest-level sub-record (no recursive references; only primitives). Mirrors `readFoodStack` / `writeFoodStack` in `tool/file_types/cafe.go:201-225` and `:424-445`.

Version branching for FoodStack at `version=63` (the only version we test):
- `version > 24`: read/write `U0` byte → **active**
- `version > 48`: read/write `U3` int32 → **active**
- `version <= 48`: read/write `U4` int16 → **inactive**
- `version > 51`: read/write `U7` Date → **active**

Other fields (`U1`, `U2`-vestigial, `U5`, `U6`, `U6Alt`) are unconditional.

**Note on `U2`:** Go declares `U2` in the struct but never reads or writes it (vestigial, see comment in `cafe.go:73`). The Dictionary should also omit `U2` to match.

- [ ] **Step 1: Create `godot/scripts/save/legacy_loader.gd`**

```gdscript
class_name LegacyLoader
extends RefCounted

## Pure parsers from legacy .caf / .dat byte streams to PascalCase
## Dictionary representations. Mirrors tool/file_types/{cafe,save_game,
## friend_cafe}.go field-for-field. Session 1 covers the Cafe family;
## SaveGame and FriendCafe land in Session 2.


static func parse_cafe_bytes(data: PackedByteArray) -> Dictionary:
	var loader := LegacyLoader.new()
	var reader := BinaryReader.wrap(data)
	var result: Dictionary = loader.parse_cafe(reader)
	if reader.failed or reader.remaining() != 0:
		push_error("parse_cafe_bytes: reader failed=%s remaining=%d" % [reader.failed, reader.remaining()])
		return {}
	return result


# === Sub-record parsers ===
# All take a BinaryReader and a version: int. They return Dictionary.
# Recursive references stay within this class so GDScript resolves them
# at call-time without forward-declaration concerns.


func parse_food_stack(r: BinaryReader, version: int) -> Dictionary:
	var d: Dictionary = {}
	if version > 24:
		d["U0"] = r.read_byte()
	d["U1"] = r.read_byte()
	if version > 48:
		d["U3"] = r.read_int32()
	if version <= 48:
		d["U4"] = r.read_int16()
	d["U5"] = r.read_byte()
	d["U6"] = r.read_string()
	d["U6Alt"] = r.read_string()
	if version > 51:
		d["U7"] = r.read_date()
	return d
```

**Important:** The `parse_cafe` method is referenced in `parse_cafe_bytes` but defined in Task 13. Until then, the file does not compile cleanly. Add a placeholder method to keep the class compilable:

```gdscript
func parse_cafe(_r: BinaryReader) -> Dictionary:
	# Filled in by Task 13.
	return {}
```

Add this placeholder right before the `# === Sub-record parsers ===` comment.

- [ ] **Step 2: Create `godot/scripts/save/legacy_writer.gd`**

```gdscript
class_name LegacyWriter
extends RefCounted

## Symmetric writers for legacy_loader.gd's parsers. Each write_*
## method consumes a Dictionary in the same shape parse_* produces and
## emits bytes that round-trip to the same Dictionary when fed back
## through the loader.


static func write_cafe_bytes(cafe: Dictionary) -> PackedByteArray:
	var writer := LegacyWriter.new()
	var w := BinaryWriter.make()
	writer.write_cafe(w, cafe)
	return w.to_bytes()


# Placeholder; Task 13 fills it in.
func write_cafe(_w: BinaryWriter, _cafe: Dictionary) -> void:
	pass


# === Sub-record writers ===


func write_food_stack(w: BinaryWriter, f: Dictionary, version: int) -> void:
	if version > 24:
		w.write_byte(int(f["U0"]))
	w.write_byte(int(f["U1"]))
	if version > 48:
		w.write_int32(int(f["U3"]))
	if version <= 48:
		w.write_int16(int(f["U4"]))
	w.write_byte(int(f["U5"]))
	w.write_string(f["U6"] as String)
	w.write_string(f["U6Alt"] as String)
	if version > 51:
		w.write_date(f["U7"] as Dictionary)
```

- [ ] **Step 3: Append `_test_food_stack` test to `test_save_round_trip.gd`**

Add a call to `_test_food_stack_round_trip()` in `_init()` and append the function:

```gdscript
func _test_food_stack_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	var original: Dictionary = {
		"U0": 7,
		"U1": 12,
		"U3": -123456,
		"U5": 3,
		"U6": "Mystery Meat",
		"U6Alt": "after",
		"U7": {"Year": 2026, "Month": 4, "Day": 25, "Hour": 15, "Minute": 18, "Second": 0},
	}

	var w := BinaryWriter.make()
	writer.write_food_stack(w, original, version)

	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_food_stack(r, version)

	_check("food_stack reader fully consumed", r.remaining() == 0)
	_check("food_stack reader did not fail", r.failed == false)
	_check("food_stack U0", decoded["U0"] == original["U0"])
	_check("food_stack U1", decoded["U1"] == original["U1"])
	_check("food_stack U3", decoded["U3"] == original["U3"])
	_check("food_stack U5", decoded["U5"] == original["U5"])
	_check("food_stack U6", decoded["U6"] == original["U6"])
	_check("food_stack U6Alt", decoded["U6Alt"] == original["U6Alt"])
	_check("food_stack U7", _date_eq(decoded["U7"], original["U7"]))


func _date_eq(a: Dictionary, b: Dictionary) -> bool:
	return a["Year"] == b["Year"] and a["Month"] == b["Month"] \
		and a["Day"] == b["Day"] and a["Hour"] == b["Hour"] \
		and a["Minute"] == b["Minute"] and a["Second"] == b["Second"]
```

- [ ] **Step 4: Rebuild class cache and run**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" \
  --headless --editor --quit --path godot/

"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" \
  --headless --path godot/ --script res://test/test_save_round_trip.gd
```

Expected: 22 primitive PASSes (Task 7) + 9 food_stack PASSes (this task) = 31 passed, 0 failed.

---

## Task 9: Add `parse_food` / `write_food` and `parse_cafe_object` / `write_cafe_object` (with leaf Type=0 case)

**Files:**
- Modify: `godot/scripts/save/legacy_loader.gd`
- Modify: `godot/scripts/save/legacy_writer.gd`
- Modify: `godot/test/test_save_round_trip.gd`

`CafeObject` is the recursion hub for the entire `Cafe` family. We implement its **leaf case** (`Type == 0`) here, plus `parse_food` which depends on it. Type=1 / Type=2 cases come in Task 12 once their callees (`CafeFurniture`, `CafeWall`) exist.

`Food` (`CafeFoodData` in Go) at `version=63`:
- `version > 48`: `U1` int32 → **active**
- `U2` byte
- `U3` bool — gates `Object`
- `U3 == true`: `Object` = parsed CafeObject → write only when present
- `U4` byte
- `version > 23`: `U5` int16 + (`version > 47` → `U6` Date) → **active**
- `U7` FoodStack — unconditional

`CafeObject` at any version:
- `Type` byte
- `Type == 1`: read CafeFurniture (Task 12)
- `Type == 2`: read CafeWall (Task 11)
- `Type == 1 || Type == 2`: `U1` int32 + `U2` int16 + `U3` int16 + `U4` bool

For Type=0, only the `Type` byte is consumed. Dictionary representation:
- `{"Type": 0}` for leaf
- `{"Type": 1, "Furniture": {...}, "U1": ..., "U2": ..., "U3": ..., "U4": ...}` for furniture object
- `{"Type": 2, "Wall": {...}, "U1": ..., "U2": ..., "U3": ..., "U4": ...}` for wall object

For Food.Object (the optional pointer field): match Go's JSON convention — always present in the Dictionary, set to `null` when absent. Same for every other `*CafeObject` / `*Cafe*` pointer field in subsequent records.

- [ ] **Step 1: Append `parse_cafe_object` (leaf) to `legacy_loader.gd`**

```gdscript
func parse_cafe_object(r: BinaryReader, version: int) -> Dictionary:
	var d: Dictionary = {}
	d["Type"] = r.read_byte()
	# Type=1 (Furniture) and Type=2 (Wall) cases land in Task 12 once
	# parse_cafe_furniture and parse_cafe_wall exist. For now, anything
	# above Type=0 is a parser hole; flag it.
	if d["Type"] == 1 or d["Type"] == 2:
		push_error("parse_cafe_object: Type=%d unhandled until Task 12" % d["Type"])
		r.failed = true
	return d
```

- [ ] **Step 2: Append `parse_food` to `legacy_loader.gd`**

```gdscript
func parse_food(r: BinaryReader, version: int) -> Dictionary:
	var d: Dictionary = {}
	if version > 48:
		d["U1"] = r.read_int32()
	else:
		d["U1"] = int(r.read_byte())
	d["U2"] = r.read_byte()
	d["U3"] = r.read_bool()
	if d["U3"]:
		d["Object"] = parse_cafe_object(r, version)
	else:
		d["Object"] = null
	d["U4"] = r.read_byte()
	if version > 23:
		d["U5"] = r.read_int16()
		if version > 47:
			d["U6"] = r.read_date()
	d["U7"] = parse_food_stack(r, version)
	return d
```

- [ ] **Step 3: Append `write_cafe_object` (leaf) to `legacy_writer.gd`**

```gdscript
func write_cafe_object(w: BinaryWriter, o: Dictionary, version: int) -> void:
	var t: int = int(o["Type"])
	w.write_byte(t)
	if t == 1 or t == 2:
		# Filled in by Task 12.
		push_error("write_cafe_object: Type=%d unhandled until Task 12" % t)
```

- [ ] **Step 4: Append `write_food` to `legacy_writer.gd`**

```gdscript
func write_food(w: BinaryWriter, f: Dictionary, version: int) -> void:
	if version > 48:
		w.write_int32(int(f["U1"]))
	else:
		w.write_byte(int(f["U1"]))
	w.write_byte(int(f["U2"]))
	var u3: bool = f["U3"]
	w.write_bool(u3)
	if u3:
		write_cafe_object(w, f["Object"] as Dictionary, version)
	w.write_byte(int(f["U4"]))
	if version > 23:
		w.write_int16(int(f["U5"]))
		if version > 47:
			w.write_date(f["U6"] as Dictionary)
	write_food_stack(w, f["U7"] as Dictionary, version)
```

- [ ] **Step 5: Append `_test_food_round_trip` to `test_save_round_trip.gd`**

Add the call in `_init` and the function:

```gdscript
func _test_food_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	# U3=false case so we don't hit the Object recursion (which still
	# only handles Type=0 at this point).
	var original: Dictionary = {
		"U1": 12345,
		"U2": 7,
		"U3": false,
		"Object": null,
		"U4": 9,
		"U5": -42,
		"U6": {"Year": 2025, "Month": 1, "Day": 1, "Hour": 0, "Minute": 0, "Second": 0},
		"U7": {
			"U0": 1, "U1": 2, "U3": 3, "U5": 4,
			"U6": "first", "U6Alt": "second",
			"U7": {"Year": 2024, "Month": 12, "Day": 31, "Hour": 23, "Minute": 59, "Second": 59},
		},
	}

	var w := BinaryWriter.make()
	writer.write_food(w, original, version)

	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_food(r, version)

	_check("food reader fully consumed", r.remaining() == 0)
	_check("food reader did not fail", r.failed == false)
	_check("food U1", decoded["U1"] == original["U1"])
	_check("food U2", decoded["U2"] == original["U2"])
	_check("food U3", decoded["U3"] == original["U3"])
	_check("food Object null", decoded["Object"] == null)
	_check("food U4", decoded["U4"] == original["U4"])
	_check("food U5", decoded["U5"] == original["U5"])
	_check("food U6 date", _date_eq(decoded["U6"], original["U6"]))
	_check("food U7 nested food_stack U6", decoded["U7"]["U6"] == "first")


func _test_cafe_object_leaf_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	var original: Dictionary = {"Type": 0}

	var w := BinaryWriter.make()
	writer.write_cafe_object(w, original, version)

	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_cafe_object(r, version)

	_check("cafe_object leaf fully consumed", r.remaining() == 0)
	_check("cafe_object leaf did not fail", r.failed == false)
	_check("cafe_object leaf Type=0", decoded["Type"] == 0)
```

- [ ] **Step 6: Rebuild class cache and run; expect all PASS so far**

Same commands as Task 8 Step 4. Expected pass count: 31 (Tasks 7-8) + 8 food + 3 cafe_object_leaf = 42 PASS, 0 FAIL.

---

## Task 10: Add `parse_cafe_wall` / `write_cafe_wall`

**Files:**
- Modify: `godot/scripts/save/legacy_loader.gd`
- Modify: `godot/scripts/save/legacy_writer.gd`
- Modify: `godot/test/test_save_round_trip.gd`

`CafeWall` at `version=63`:
- `version > 58`: `U1` int16 → **active** (we read `int16(byte)` for older versions)
- `U2` bool, `U3` bool, `U4` bool, `U5` int32, `HasDecoration` bool
- `HasDecoration == true`: `DecorationObject` = parsed CafeObject

We test with `HasDecoration=false` to keep `parse_cafe_object` at its current Type=0 leaf state. Real fixtures will exercise `HasDecoration=true` once Task 12 completes the recursion.

- [ ] **Step 1: Append `parse_cafe_wall` to `legacy_loader.gd`**

```gdscript
func parse_cafe_wall(r: BinaryReader, version: int) -> Dictionary:
	var d: Dictionary = {}
	if version > 58:
		d["U1"] = r.read_int16()
	else:
		d["U1"] = int(r.read_byte())
	d["U2"] = r.read_bool()
	d["U3"] = r.read_bool()
	d["U4"] = r.read_bool()
	d["U5"] = r.read_int32()
	d["HasDecoration"] = r.read_bool()
	if d["HasDecoration"]:
		d["DecorationObject"] = parse_cafe_object(r, version)
	else:
		d["DecorationObject"] = null
	return d
```

- [ ] **Step 2: Append `write_cafe_wall` to `legacy_writer.gd`**

```gdscript
func write_cafe_wall(w: BinaryWriter, c: Dictionary, version: int) -> void:
	if version > 58:
		w.write_int16(int(c["U1"]))
	else:
		w.write_byte(int(c["U1"]))
	w.write_bool(c["U2"])
	w.write_bool(c["U3"])
	w.write_bool(c["U4"])
	w.write_int32(int(c["U5"]))
	var has: bool = c["HasDecoration"]
	w.write_bool(has)
	if has:
		write_cafe_object(w, c["DecorationObject"] as Dictionary, version)
```

- [ ] **Step 3: Append `_test_cafe_wall_round_trip` to `test_save_round_trip.gd`**

```gdscript
func _test_cafe_wall_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	var original: Dictionary = {
		"U1": 12345,
		"U2": true,
		"U3": false,
		"U4": true,
		"U5": -987654,
		"HasDecoration": false,
		"DecorationObject": null,
	}

	var w := BinaryWriter.make()
	writer.write_cafe_wall(w, original, version)

	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_cafe_wall(r, version)

	_check("cafe_wall fully consumed", r.remaining() == 0)
	_check("cafe_wall did not fail", r.failed == false)
	_check("cafe_wall U1", decoded["U1"] == original["U1"])
	_check("cafe_wall U2", decoded["U2"] == original["U2"])
	_check("cafe_wall U3", decoded["U3"] == original["U3"])
	_check("cafe_wall U4", decoded["U4"] == original["U4"])
	_check("cafe_wall U5", decoded["U5"] == original["U5"])
	_check("cafe_wall HasDecoration false", decoded["HasDecoration"] == false)
	_check("cafe_wall DecorationObject null", decoded["DecorationObject"] == null)
```

Add `_test_cafe_wall_round_trip()` to `_init`.

- [ ] **Step 4: Run, expect 42 + 9 = 51 PASS**

---

## Task 11: Add `parse_stove`, `parse_serving_counter`, and `parse_cafe_furniture` (plus writers)

**Files:**
- Modify: `godot/scripts/save/legacy_loader.gd`
- Modify: `godot/scripts/save/legacy_writer.gd`
- Modify: `godot/test/test_save_round_trip.gd`

These three records sit between `Food` / `CafeWall` and the `CafeObject` recursion that Task 12 will close. Each can be tested in isolation with its `HasObject` / `HasFoodStack` flags set to `false` so the (still-leaf-only) `parse_cafe_object` doesn't get exercised yet.

**Stove** at `version=63`:
- `version <= 48`: `U1` byte (cast to int32) | `version > 48`: `U1` int32 → **active path: int32**
- `U2` byte, `HasObject` bool, [optional `Object`], `U5` byte
- `version > 23`: `U6` int16 → **active**
- `version > 47`: `U7` Date → **active**
- `HasFoodStack` bool, [optional `FoodStack`], `U8` int64, `U9` int64

**ServingCounter** at `version=63`:
- `version > 48`: `U1` int32 (else byte→int32) → **active path: int32**
- `U2` byte, `HasObject` bool, [optional `Object`], `U3` byte
- `version > 23`: `U4` int16 → **active**
- `version > 47`: `U5` Date → **active**
- `version > 25`: `U6` int32 (else int16→int32) → **active path: int32**
- `NumFoodStacks` int16 + that many FoodStacks

**CafeFurniture** at `version=63`:
- `isFood` bool — top-level branch
- isFood=true: `U1` byte + Food
- isFood=false:
  - `FurnitureType` byte
  - FurnitureType==1: Stove
  - FurnitureType==2: ServingCounter
  - else (the "plain furniture" branch):
    - `version > 48`: `U2` int32 → **active**
    - `Orientation` byte, `HasObject` bool, [Object]
    - `U3` byte, `version > 23`: `U4` int16, `version > 47`: `U5` Date

Dictionary representation note: `CafeFurniture` has multiple mutually-exclusive payloads. To match Go's JSON output (which would emit `null` for the nil pointer fields and the actual struct for the non-nil one), we represent every payload field with its expected key, set to `null` when not active. So a plain-furniture dict has `{"Food": null, "Stove": null, "ServingCounter": null, "FurnitureType": 0, "U2": ..., "Orientation": ..., ...}`.

- [ ] **Step 1: Append `parse_stove` and `parse_serving_counter` to `legacy_loader.gd`**

```gdscript
func parse_stove(r: BinaryReader, version: int) -> Dictionary:
	var s: Dictionary = {}
	if version <= 48:
		s["U1"] = int(r.read_byte())
	else:
		s["U1"] = r.read_int32()
	s["U2"] = r.read_byte()
	s["HasObject"] = r.read_bool()
	if s["HasObject"]:
		s["Object"] = parse_cafe_object(r, version)
	else:
		s["Object"] = null
	s["U5"] = r.read_byte()
	if version > 23:
		s["U6"] = r.read_int16()
	if version > 47:
		s["U7"] = r.read_date()
	s["HasFoodStack"] = r.read_bool()
	if s["HasFoodStack"]:
		s["FoodStack"] = parse_food_stack(r, version)
	else:
		s["FoodStack"] = null
	s["U8"] = r.read_int64()
	s["U9"] = r.read_int64()
	return s


func parse_serving_counter(r: BinaryReader, version: int) -> Dictionary:
	var s: Dictionary = {}
	if version > 48:
		s["U1"] = r.read_int32()
	else:
		s["U1"] = int(r.read_byte())
	s["U2"] = r.read_byte()
	s["HasObject"] = r.read_bool()
	if s["HasObject"]:
		s["Object"] = parse_cafe_object(r, version)
	else:
		s["Object"] = null
	s["U3"] = r.read_byte()
	if version > 23:
		s["U4"] = r.read_int16()
	if version > 47:
		s["U5"] = r.read_date()
	if version > 25:
		s["U6"] = r.read_int32()
	else:
		s["U6"] = int(r.read_int16())
	s["NumFoodStacks"] = r.read_int16()
	var stacks: Array = []
	for i in range(s["NumFoodStacks"]):
		stacks.append(parse_food_stack(r, version))
	s["FoodStacks"] = stacks
	return s
```

- [ ] **Step 2: Append `parse_cafe_furniture` to `legacy_loader.gd`**

```gdscript
func parse_cafe_furniture(r: BinaryReader, version: int) -> Dictionary:
	var c: Dictionary = {
		"Food": null,
		"Stove": null,
		"ServingCounter": null,
		"Object": null,
		"FurnitureType": 0,
		"U1": 0,
		"U2": 0,
		"Orientation": 0,
		"HasObject": false,
		"U3": 0,
		"U4": 0,
		"U5": {"Year": 0, "Month": 0, "Day": 0, "Hour": 0, "Minute": 0, "Second": 0},
	}

	var is_food: bool = r.read_bool()
	if is_food:
		c["U1"] = r.read_byte()
		c["Food"] = parse_food(r, version)
		return c

	c["FurnitureType"] = r.read_byte()
	if c["FurnitureType"] == 1:
		c["Stove"] = parse_stove(r, version)
		return c
	if c["FurnitureType"] == 2:
		c["ServingCounter"] = parse_serving_counter(r, version)
		return c

	# Plain furniture branch.
	if version > 48:
		c["U2"] = r.read_int32()
	else:
		c["U2"] = int(r.read_byte())
	c["Orientation"] = r.read_byte()
	c["HasObject"] = r.read_bool()
	if c["HasObject"]:
		c["Object"] = parse_cafe_object(r, version)
	c["U3"] = r.read_byte()
	if version > 23:
		c["U4"] = r.read_int16()
	if version > 47:
		c["U5"] = r.read_date()
	return c
```

- [ ] **Step 3: Append corresponding writers to `legacy_writer.gd`**

```gdscript
func write_stove(w: BinaryWriter, s: Dictionary, version: int) -> void:
	if version <= 48:
		w.write_byte(int(s["U1"]))
	else:
		w.write_int32(int(s["U1"]))
	w.write_byte(int(s["U2"]))
	var has_obj: bool = s["HasObject"]
	w.write_bool(has_obj)
	if has_obj:
		write_cafe_object(w, s["Object"] as Dictionary, version)
	w.write_byte(int(s["U5"]))
	if version > 23:
		w.write_int16(int(s["U6"]))
	if version > 47:
		w.write_date(s["U7"] as Dictionary)
	var has_fs: bool = s["HasFoodStack"]
	w.write_bool(has_fs)
	if has_fs:
		write_food_stack(w, s["FoodStack"] as Dictionary, version)
	w.write_int64(int(s["U8"]))
	w.write_int64(int(s["U9"]))


func write_serving_counter(w: BinaryWriter, s: Dictionary, version: int) -> void:
	if version > 48:
		w.write_int32(int(s["U1"]))
	else:
		w.write_byte(int(s["U1"]))
	w.write_byte(int(s["U2"]))
	var has_obj: bool = s["HasObject"]
	w.write_bool(has_obj)
	if has_obj:
		write_cafe_object(w, s["Object"] as Dictionary, version)
	w.write_byte(int(s["U3"]))
	if version > 23:
		w.write_int16(int(s["U4"]))
	if version > 47:
		w.write_date(s["U5"] as Dictionary)
	if version > 25:
		w.write_int32(int(s["U6"]))
	else:
		w.write_int16(int(s["U6"]))
	w.write_int16(int(s["NumFoodStacks"]))
	var stacks: Array = s["FoodStacks"] as Array
	for fs in stacks:
		write_food_stack(w, fs as Dictionary, version)


func write_cafe_furniture(w: BinaryWriter, c: Dictionary, version: int) -> void:
	var is_food: bool = c["Food"] != null
	w.write_bool(is_food)
	if is_food:
		w.write_byte(int(c["U1"]))
		write_food(w, c["Food"] as Dictionary, version)
		return

	w.write_byte(int(c["FurnitureType"]))
	if int(c["FurnitureType"]) == 1:
		write_stove(w, c["Stove"] as Dictionary, version)
		return
	if int(c["FurnitureType"]) == 2:
		write_serving_counter(w, c["ServingCounter"] as Dictionary, version)
		return

	# Plain furniture branch.
	if version > 48:
		w.write_int32(int(c["U2"]))
	else:
		w.write_byte(int(c["U2"]))
	w.write_byte(int(c["Orientation"]))
	var has_obj: bool = c["HasObject"]
	w.write_bool(has_obj)
	if has_obj:
		write_cafe_object(w, c["Object"] as Dictionary, version)
	w.write_byte(int(c["U3"]))
	if version > 23:
		w.write_int16(int(c["U4"]))
	if version > 47:
		w.write_date(c["U5"] as Dictionary)
```

- [ ] **Step 4: Append three sub-record tests**

Add `_test_stove_round_trip()`, `_test_serving_counter_round_trip()`, `_test_cafe_furniture_plain_round_trip()` to `_init` and append:

```gdscript
func _test_stove_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	var original: Dictionary = {
		"U1": 1234567,
		"U2": 5,
		"HasObject": false,
		"Object": null,
		"U5": 9,
		"U6": -100,
		"U7": {"Year": 2026, "Month": 4, "Day": 25, "Hour": 0, "Minute": 0, "Second": 0},
		"HasFoodStack": false,
		"FoodStack": null,
		"U8": -987654321987,
		"U9": 12345678901234,
	}

	var w := BinaryWriter.make()
	writer.write_stove(w, original, version)
	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_stove(r, version)

	_check("stove fully consumed", r.remaining() == 0)
	_check("stove no fail", r.failed == false)
	_check("stove U1", decoded["U1"] == original["U1"])
	_check("stove HasObject", decoded["HasObject"] == false)
	_check("stove HasFoodStack", decoded["HasFoodStack"] == false)
	_check("stove U8 negative int64", decoded["U8"] == original["U8"])
	_check("stove U9 large positive int64", decoded["U9"] == original["U9"])


func _test_serving_counter_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	var fs: Dictionary = {
		"U0": 1, "U1": 2, "U3": 3, "U5": 4,
		"U6": "alpha", "U6Alt": "beta",
		"U7": {"Year": 2024, "Month": 1, "Day": 1, "Hour": 0, "Minute": 0, "Second": 0},
	}
	var original: Dictionary = {
		"U1": 42,
		"U2": 1,
		"HasObject": false,
		"Object": null,
		"U3": 2,
		"U4": 3,
		"U5": {"Year": 2026, "Month": 1, "Day": 1, "Hour": 0, "Minute": 0, "Second": 0},
		"U6": 99,
		"NumFoodStacks": 2,
		"FoodStacks": [fs, fs],
	}

	var w := BinaryWriter.make()
	writer.write_serving_counter(w, original, version)
	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_serving_counter(r, version)

	_check("sc fully consumed", r.remaining() == 0)
	_check("sc no fail", r.failed == false)
	_check("sc NumFoodStacks", decoded["NumFoodStacks"] == 2)
	_check("sc FoodStacks length", (decoded["FoodStacks"] as Array).size() == 2)
	_check("sc FoodStacks[0].U6", (decoded["FoodStacks"] as Array)[0]["U6"] == "alpha")


func _test_cafe_furniture_plain_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	# Plain (non-food, non-stove, non-serving-counter) furniture branch.
	var original: Dictionary = {
		"Food": null,
		"Stove": null,
		"ServingCounter": null,
		"Object": null,
		"FurnitureType": 0,
		"U1": 0,
		"U2": 17,
		"Orientation": 1,
		"HasObject": false,
		"U3": 2,
		"U4": 3,
		"U5": {"Year": 2026, "Month": 1, "Day": 1, "Hour": 0, "Minute": 0, "Second": 0},
	}

	var w := BinaryWriter.make()
	writer.write_cafe_furniture(w, original, version)
	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_cafe_furniture(r, version)

	_check("cf-plain consumed", r.remaining() == 0)
	_check("cf-plain no fail", r.failed == false)
	_check("cf-plain FurnitureType", decoded["FurnitureType"] == 0)
	_check("cf-plain U2", decoded["U2"] == 17)
	_check("cf-plain Orientation", decoded["Orientation"] == 1)
	_check("cf-plain U3", decoded["U3"] == 2)
```

- [ ] **Step 5: Run, expect 51 + 6 + 5 + 5 = 67 PASS**

---

## Task 12: Wire `parse_cafe_object` / `write_cafe_object` Type=1 and Type=2 cases

**Files:**
- Modify: `godot/scripts/save/legacy_loader.gd`
- Modify: `godot/scripts/save/legacy_writer.gd`
- Modify: `godot/test/test_save_round_trip.gd`

This task closes the recursion. After it lands, `parse_cafe_object` can recurse through `parse_cafe_furniture` (which calls back into `parse_cafe_object` via `Object`-bearing branches) without parser holes.

`CafeObject` Dictionary shape:
- Always: `{"Type": int}`
- When Type ∈ {1, 2}: also `"U1": int32`, `"U2": int16`, `"U3": int16`, `"U4": bool`
- When Type == 1: also `"Furniture": Dictionary` (and `"Wall": null`)
- When Type == 2: also `"Wall": Dictionary` (and `"Furniture": null`)
- When Type == 0: `"Furniture": null`, `"Wall": null`, `"U1": 0`, `"U2": 0`, `"U3": 0`, `"U4": false` (defaults)

We initialize all keys with default values so the Dictionary shape is consistent across all Types — easier to round-trip and easier to deep-equal in Layer 2 later.

- [ ] **Step 1: Replace the placeholder body of `parse_cafe_object` in `legacy_loader.gd`**

Replace the existing function (the placeholder added in Task 9 Step 1) with:

```gdscript
func parse_cafe_object(r: BinaryReader, version: int) -> Dictionary:
	var d: Dictionary = {
		"Type": 0,
		"Furniture": null,
		"Wall": null,
		"U1": 0,
		"U2": 0,
		"U3": 0,
		"U4": false,
	}
	d["Type"] = r.read_byte()
	if d["Type"] == 1:
		d["Furniture"] = parse_cafe_furniture(r, version)
	elif d["Type"] == 2:
		d["Wall"] = parse_cafe_wall(r, version)
	if d["Type"] == 1 or d["Type"] == 2:
		d["U1"] = r.read_int32()
		d["U2"] = r.read_int16()
		d["U3"] = r.read_int16()
		d["U4"] = r.read_bool()
	return d
```

- [ ] **Step 2: Replace `write_cafe_object` placeholder body in `legacy_writer.gd`**

```gdscript
func write_cafe_object(w: BinaryWriter, o: Dictionary, version: int) -> void:
	var t: int = int(o["Type"])
	w.write_byte(t)
	if t == 1:
		write_cafe_furniture(w, o["Furniture"] as Dictionary, version)
	elif t == 2:
		write_cafe_wall(w, o["Wall"] as Dictionary, version)
	if t == 1 or t == 2:
		w.write_int32(int(o["U1"]))
		w.write_int16(int(o["U2"]))
		w.write_int16(int(o["U3"]))
		w.write_bool(o["U4"])
```

- [ ] **Step 3: Append `_test_cafe_object_recursive_round_trip` to test the closed loop**

```gdscript
func _test_cafe_object_recursive_round_trip() -> void:
	var loader := LegacyLoader.new()
	var writer := LegacyWriter.new()
	var version: int = 63

	# Type=2 (wall) with no recursive decoration → exercises the Type=2
	# branch end-to-end without nesting.
	var wall: Dictionary = {
		"U1": 7, "U2": false, "U3": true, "U4": false, "U5": 99,
		"HasDecoration": false, "DecorationObject": null,
	}
	var original: Dictionary = {
		"Type": 2,
		"Furniture": null,
		"Wall": wall,
		"U1": 100, "U2": 200, "U3": 300, "U4": true,
	}

	var w := BinaryWriter.make()
	writer.write_cafe_object(w, original, version)
	var r := BinaryReader.wrap(w.to_bytes())
	var decoded: Dictionary = loader.parse_cafe_object(r, version)

	_check("co-type2 consumed", r.remaining() == 0)
	_check("co-type2 no fail", r.failed == false)
	_check("co-type2 Type", decoded["Type"] == 2)
	_check("co-type2 Wall.U1", decoded["Wall"]["U1"] == 7)
	_check("co-type2 U1/U2/U3/U4 trailer",
		decoded["U1"] == 100 and decoded["U2"] == 200
		and decoded["U3"] == 300 and decoded["U4"] == true)
```

- [ ] **Step 4: Run, expect 67 + 5 = 72 PASS**

---

## Task 13: Add `parse_cafe_tile` / `write_cafe_tile` and the top-level `parse_cafe` / `write_cafe`

**Files:**
- Modify: `godot/scripts/save/legacy_loader.gd`
- Modify: `godot/scripts/save/legacy_writer.gd`

`CafeTile` at `version=63`:
- `version > 58`: `U1` int16 (else byte→int16) → **active path: int16**
- `U2` int32, `U3` bool, `U4` bool, [`U5` if U4], `U6` bool, [`U7` if U6], `U8` bool, [`U9` if U8]

Each `U5`/`U7`/`U9` is a CafeObject whose presence is gated by the preceding bool — this is the dominant repeating record in the file (one per cafe tile) and is where the bulk of the byte volume lives.

`Cafe` (top-level) at `version=63`:
- `Version` byte (must be 63 in fixtures, but we don't enforce — we round-trip whatever's there)
- `U0` float64
- `SizeX` byte, `SizeY` byte, `U3` int16, `U4` int16
- `version > 48`: `MapSizeX` int32 + `MapSizeY` int32 → **active**
- `U7` bool
- Tile loop: `MapSizeX * MapSizeY` tiles
- `U8` int32 — **count of TrailingInts1**
- `TrailingInts1`: that many int32s
- `version > 61`: int32 count + that many int32s into `TrailingInts2` → **active**

Replace the placeholders from Tasks 8 / 9.

- [ ] **Step 1: Append `parse_cafe_tile` to `legacy_loader.gd`**

```gdscript
func parse_cafe_tile(r: BinaryReader, version: int) -> Dictionary:
	var t: Dictionary = {}
	if version <= 58:
		t["U1"] = int(r.read_byte())
	else:
		t["U1"] = r.read_int16()
	t["U2"] = r.read_int32()
	t["U3"] = r.read_bool()
	t["U4"] = r.read_bool()
	if t["U4"]:
		t["U5"] = parse_cafe_object(r, version)
	else:
		t["U5"] = null
	t["U6"] = r.read_bool()
	if t["U6"]:
		t["U7"] = parse_cafe_object(r, version)
	else:
		t["U7"] = null
	t["U8"] = r.read_bool()
	if t["U8"]:
		t["U9"] = parse_cafe_object(r, version)
	else:
		t["U9"] = null
	return t
```

- [ ] **Step 2: Replace `parse_cafe` placeholder in `legacy_loader.gd`**

```gdscript
func parse_cafe(r: BinaryReader) -> Dictionary:
	var c: Dictionary = {
		"Version": 0,
		"U0": 0.0,
		"SizeX": 0,
		"SizeY": 0,
		"U3": 0,
		"U4": 0,
		"MapSizeX": 0,
		"MapSizeY": 0,
		"U7": false,
		"Tiles": [],
		"U8": 0,
		"TrailingInts1": [],
		"TrailingInts2": [],
	}
	c["Version"] = r.read_byte()
	c["U0"] = r.read_float64()
	c["SizeX"] = r.read_byte()
	c["SizeY"] = r.read_byte()
	c["U3"] = r.read_int16()
	c["U4"] = r.read_int16()
	if int(c["Version"]) > 48:
		c["MapSizeX"] = r.read_int32()
		c["MapSizeY"] = r.read_int32()
	c["U7"] = r.read_bool()
	var num_tiles: int = int(c["MapSizeX"]) * int(c["MapSizeY"])
	var tiles: Array = []
	for i in range(num_tiles):
		tiles.append(parse_cafe_tile(r, int(c["Version"])))
	c["Tiles"] = tiles
	c["U8"] = r.read_int32()
	var t1: Array = []
	for i in range(int(c["U8"])):
		t1.append(r.read_int32())
	c["TrailingInts1"] = t1
	if int(c["Version"]) > 61:
		var num_t2: int = r.read_int32()
		var t2: Array = []
		for i in range(num_t2):
			t2.append(r.read_int32())
		c["TrailingInts2"] = t2
	return c
```

- [ ] **Step 3: Append `write_cafe_tile` to `legacy_writer.gd`**

```gdscript
func write_cafe_tile(w: BinaryWriter, t: Dictionary, version: int) -> void:
	if version <= 58:
		w.write_byte(int(t["U1"]))
	else:
		w.write_int16(int(t["U1"]))
	w.write_int32(int(t["U2"]))
	w.write_bool(t["U3"])
	var u4: bool = t["U4"]
	w.write_bool(u4)
	if u4:
		write_cafe_object(w, t["U5"] as Dictionary, version)
	var u6: bool = t["U6"]
	w.write_bool(u6)
	if u6:
		write_cafe_object(w, t["U7"] as Dictionary, version)
	var u8: bool = t["U8"]
	w.write_bool(u8)
	if u8:
		write_cafe_object(w, t["U9"] as Dictionary, version)
```

- [ ] **Step 4: Replace `write_cafe` placeholder in `legacy_writer.gd`**

```gdscript
func write_cafe(w: BinaryWriter, c: Dictionary) -> void:
	w.write_byte(int(c["Version"]))
	w.write_float64(float(c["U0"]))
	w.write_byte(int(c["SizeX"]))
	w.write_byte(int(c["SizeY"]))
	w.write_int16(int(c["U3"]))
	w.write_int16(int(c["U4"]))
	if int(c["Version"]) > 48:
		w.write_int32(int(c["MapSizeX"]))
		w.write_int32(int(c["MapSizeY"]))
	w.write_bool(c["U7"])
	for tile in (c["Tiles"] as Array):
		write_cafe_tile(w, tile as Dictionary, int(c["Version"]))
	w.write_int32(int(c["U8"]))
	for v in (c["TrailingInts1"] as Array):
		w.write_int32(int(v))
	if int(c["Version"]) > 61:
		var t2: Array = c["TrailingInts2"] as Array
		w.write_int32(t2.size())
		for v in t2:
			w.write_int32(int(v))
```

- [ ] **Step 5: Rebuild class cache and run; nothing new tested yet, but verify compilation**

Same commands as Task 8 Step 4. Expected: still 72 passed (no new tests added in this task; Task 14 adds the fixture round-trip).

If GDScript reports a compilation error, fix it before continuing. Most likely cause: a typo in field names between loader and writer (PascalCase consistency).

---

## Task 14: Add Layer-1 fixture round-trip test, run, and create the session commit

**Files:**
- Modify: `godot/test/test_save_round_trip.gd`

The headline test. Loads each `.caf` fixture, parses it, writes it back, and asserts the byte arrays are equal. This is the Phase 3 Session 1 acceptance gate.

- [ ] **Step 1: Append `_test_cafe_fixtures` to `test_save_round_trip.gd`**

Add `_test_cafe_fixtures()` to `_init` and append:

```gdscript
func _test_cafe_fixtures() -> void:
	for name in ["playerCafe.caf", "BACKUP1.caf"]:
		var path: String = FIXTURES_DIR + "/" + name
		var bytes_in: PackedByteArray = FileAccess.get_file_as_bytes(path)
		_check("fixture %s loaded" % name, bytes_in.size() > 0,
			"FileAccess.get_open_error=%d" % FileAccess.get_open_error())

		var dict: Dictionary = LegacyLoader.parse_cafe_bytes(bytes_in)
		_check("fixture %s parsed non-empty" % name, dict.size() > 0)
		_check("fixture %s Version=63" % name, int(dict.get("Version", 0)) == 63)

		var bytes_out: PackedByteArray = LegacyWriter.write_cafe_bytes(dict)
		_check("fixture %s round-trip size" % name,
			bytes_out.size() == bytes_in.size(),
			"in=%d out=%d" % [bytes_in.size(), bytes_out.size()])
		_check("fixture %s round-trip byte-identical" % name,
			bytes_in == bytes_out,
			"first diff at byte %d" % _first_diff(bytes_in, bytes_out))


func _first_diff(a: PackedByteArray, b: PackedByteArray) -> int:
	var n: int = min(a.size(), b.size())
	for i in range(n):
		if a[i] != b[i]:
			return i
	if a.size() != b.size():
		return n
	return -1
```

- [ ] **Step 2: Rebuild class cache and run the full suite**

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" \
  --headless --editor --quit --path godot/

"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" \
  --headless --path godot/ --script res://test/test_save_round_trip.gd
```

Expected: previous 72 + 8 new (4 per fixture × 2 fixtures) = **80 passed, 0 failed**, summary `=== Session 1 results: 80 passed, 0 failed ===`, exit 0.

If any fixture-level test fails:
- **`first diff at byte N`** in the byte-identical assertion is the diagnostic. Read the Go `cafe.go` for the field family that lives near offset N (header is bytes 0-13, then tiles, then `TrailingInts1` count + entries at offset header+tiles_size, then optional `TrailingInts2`). Compare the GDScript `parse_cafe` / `write_cafe` to the Go reader/writer for the responsible field.
- **Missing key error** in any `parse_*` (e.g. `Invalid get index 'U6Alt' on base 'Dictionary'`) means the writer is reading a key the parser didn't populate or vice-versa. Cross-check the parser/writer pair for that record.
- **Reader.failed=true with no parse_* fail** means a primitive ate past the end of the buffer — likely a missing version branch or a wrong-endianness read.

Iterate until both fixtures show all 4 `PASS:` lines (`loaded`, `parsed non-empty`, `Version=63`, `round-trip size`, `round-trip byte-identical`). The session is not complete until this is green.

- [ ] **Step 3: Verify the existing `validate_assets.gd` is still green**

The save round-trip work shouldn't have touched anything `validate_assets.gd` depends on, but it's worth confirming nothing regressed. Run:

```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" \
  --headless --path godot/ --script res://validate_assets.gd
```

Expected: 15/15 checks pass, exit 0. If anything regressed, fix it before committing.

- [ ] **Step 4: Update `docs/rewrite-plan.md` to reflect Session 1 progress**

Edit the Phase 3 section in `docs/rewrite-plan.md`. Currently the Phase 3 entry says:

```
### Phase 3 — Save-load round-trip *(blocked on Phase 0b)*
```

Change the status marker to indicate progress:

```
### Phase 3 — Save-load round-trip *(in progress)*
```

Append a "Landed" sub-list under the existing description, mirroring the structure used by Phase 1b / Phase 2a / Phase 2b:

```markdown
Landed (Session 1 of 4 per `docs/superpowers/specs/2026-04-25-godot-save-format-bridge-design.md`):

- *(done)* `godot/scripts/save/binary_reader.gd`, `binary_writer.gd` — primitive read/write helpers mirroring the Go `binary_reader.go` / `binary_writer.go` (BE ints, LE ints + floats, bool, BE int16 length-prefixed UTF-8 strings, Date struct).
- *(done)* `godot/scripts/save/legacy_loader.gd`, `legacy_writer.gd` — `parse_cafe` and `write_cafe` plus all 8 sub-record parsers/writers (`FoodStack`, `Food`, `CafeObject`, `CafeWall`, `CafeFurniture`, `Stove`, `ServingCounter`, `CafeTile`). PascalCase Dictionary keys mirror Go's default `json.Marshal` output.
- *(done)* `godot/test/test_save_round_trip.gd` — Layer-1 round-trip runner. Real fixtures `playerCafe.caf` (20,129 B) and `BACKUP1.caf` (20,017 B) round-trip byte-identically through GDScript. 80 PASS / 0 FAIL.
```

- [ ] **Step 5: Stage all the new and modified files**

```bash
cd /c/Users/edwar/Documents/edbuildingstuff/zombie-cafe-revival
git add godot/scripts/save/binary_reader.gd
git add godot/scripts/save/binary_writer.gd
git add godot/scripts/save/legacy_loader.gd
git add godot/scripts/save/legacy_writer.gd
git add godot/test/test_save_round_trip.gd
git add godot/test/fixtures/save/playerCafe.caf
git add godot/test/fixtures/save/BACKUP1.caf
git add docs/superpowers/plans/2026-04-25-phase-3-session-1-cafe-round-trip.md
git add docs/rewrite-plan.md
git status
```

`git status` should show every file above as `new file:` or `modified:`, with no unstaged changes that belong to this session. If anything else is staged accidentally, unstage it with `git restore --staged <path>`.

- [ ] **Step 6: Create the single grouped commit**

Per the user's `feedback_commit_style` preference, ship the entire session as one commit. Per `feedback_no_coauthor_trailer`, omit the Co-Authored-By trailer.

```bash
git commit -m "$(cat <<'EOF'
godot: phase 3 session 1 - GDScript Cafe round-trip

Foundation for the Phase 3 save format bridge per the 2026-04-25
spec. Pure GDScript port of the Go file_types Cafe family, with
real device fixtures playerCafe.caf and BACKUP1.caf round-tripping
byte-identically through parse_cafe -> Dictionary -> write_cafe.

Five new GDScript modules under godot/scripts/save/:

- binary_reader.gd / binary_writer.gd - primitive read/write
  helpers. BE ints (uint16/int16/uint32/int32/int64), LE int32,
  IEEE 754 floats (LE), bool, BE int16 length-prefixed UTF-8
  strings, Date struct. BinaryReader uses the failed-flag pattern
  in lieu of GDScript exceptions: short reads push_error and
  short-circuit later reads so the first failure is reported.

- legacy_loader.gd / legacy_writer.gd - parse_cafe + write_cafe
  plus all eight sub-record pairs (FoodStack, Food, CafeObject,
  CafeWall, CafeFurniture, Stove, ServingCounter, CafeTile). All
  recursion lives within the same class so GDScript resolves it
  at call-time. Dictionary keys are PascalCase, matching Go's
  default json.Marshal output - sets up the cross-validation
  oracle reuse path for Session 3.

- test_save_round_trip.gd - test runner. Layer-1 round-trip on
  the two real Cafe fixtures (20,129 B + 20,017 B) plus a
  scaffolding suite of primitive and sub-record round-trips that
  prevent silent reader/writer asymmetry from hiding behind the
  fixture pass. 80 PASS / 0 FAIL.

Sessions 2-4 (SaveGame, FriendCafe, JSON envelope, cross-
validation oracle, CI wiring, devlog/handoff close-out) remain
per spec; their plans get written when this session lands.

Spec: docs/superpowers/specs/2026-04-25-godot-save-format-bridge-design.md
Plan: docs/superpowers/plans/2026-04-25-phase-3-session-1-cafe-round-trip.md
EOF
)"
```

- [ ] **Step 7: Verify commit landed cleanly**

```bash
git log -1
git status
```

Expected: the new commit is the head commit, working tree is clean (`nothing to commit, working tree clean`).

If a pre-commit hook fails (the repo doesn't currently configure one, but check), do not skip with `--no-verify`. Investigate and fix the underlying issue, then create a NEW commit with the fix bundled in.

---

## Acceptance criteria for Session 1

The session is **done** when all of the following are true:

1. **`OK 80/0` from the test runner.** Re-running the full test invocation prints `Session 1 results: 80 passed, 0 failed` and exits 0. The `playerCafe.caf` and `BACKUP1.caf` fixtures round-trip byte-identically through GDScript.
2. **No regressions in `validate_assets.gd`.** The existing 15-check headless validator still passes.
3. **One commit landed on `main`.** The session's work ships as a single commit per `feedback_commit_style`. `git log -1` shows the Session 1 commit.
4. **`docs/rewrite-plan.md` reflects Session 1 progress.** The Phase 3 entry shows status `*(in progress)*` and a "Landed (Session 1 of 4)" sub-list.
5. **Plan file is committed alongside the work.** The plan at `docs/superpowers/plans/2026-04-25-phase-3-session-1-cafe-round-trip.md` is in the same commit so the next session has a clean reference point.

If any of the above is not true, the session is not done — diagnose and fix in place rather than declaring partial success.

---

## What's not in this session (handoff to Session 2)

To set context for the next session's plan author:

- **`SaveGame` parser/writer.** The trickier of the remaining two formats because of the `SaveStrings` `RawCount=0`/`RawCount=1` collapse and the ~1 KB `Trailing []byte` preservation field that becomes `Trailing_b64` in the Dictionary. Lives in `legacy_loader.gd` / `legacy_writer.gd`.
- **`FriendCafe` parser/writer.** Mostly orchestration on top of `parse_cafe` + a new `parse_cafe_state`. Three lines of plumbing: leading byte version + CafeState + Cafe.
- **`CharacterInstance` and `CafeState`.** Sub-records of `SaveGame` (and `FriendCafe`). Not in the Cafe family, so they didn't land here.
- **3 more fixtures.** `globalData.dat`, `BACKUP1.dat`, `ServerData.dat` get copied into `godot/test/fixtures/save/` next session.

The Session 2 plan extends `legacy_loader.gd` / `legacy_writer.gd` rather than creating new files, and extends `_init` in `test_save_round_trip.gd` with three more `_test_*_fixture` calls. The class-cache rebuild is only needed once per session of new `class_name` introductions, so Session 2 won't need it.
