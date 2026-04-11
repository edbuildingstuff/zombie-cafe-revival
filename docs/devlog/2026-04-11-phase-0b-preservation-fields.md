# 2026-04-11 — Phase 0b step two: the Ghidra pivot, and extending parsers to preserve bytes

**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))

Fourth entry of the day. The last entry closed with "realistically the next productive session is not more file_types writing — it's a Ghidra pass on `libZombieCafeAndroid.so`." I want to record that I changed my mind about that before a single byte of Ghidra output, and why. This is exactly the kind of small course-correction that doesn't show up in a commit history but does show up in how fast the project moves over the next few weeks.

## Why the Ghidra plan was wrong

The Ghidra plan was: open `src/lib/armeabi/libZombieCafeAndroid.so` in a disassembler, use the offsets labelled in `src/lib/cpp/ZombieCafeExtension.cpp` as anchors, chase the save game serializer and the cafe serializer entry points, figure out what the currently-discarded bytes *semantically represent* (an order list? a localization key table? a path planner's scratch buffer?), and then come back to the Go code and give the preserved fields meaningful names on the struct.

When I wrote that plan, the implicit premise was: "we need to know what the discarded bytes mean before we can preserve them." That's obviously wrong once you say it out loud. **Byte preservation doesn't require byte understanding.** The round-trip contract — read a file, write it back, assert equality — only cares that every byte on disk has a corresponding struct field on the Go side. It does not care what those fields are called or what they mean.

The pattern already exists everywhere in Airyz's code, too: the structs are full of `U1`, `U2`, `U3`, `U11`, `U15` fields that are clearly "unknown slot 1," "unknown slot 2," etc. — placeholders for data whose semantics will become clear later. Adding more placeholders for the currently-discarded bytes is just extending that convention one more step. Ghidra eventually becomes useful — when Phase 4 starts implementing the game tick loop in Godot and needs to know what a specific timer or flag is for — but it's not useful *for Phase 0b*. Phase 0b only needs fields with names, not fields with meanings.

Once I saw this, the whole shape of the session flipped. Instead of "install Ghidra, spend hours staring at disassembly, come back with a devlog entry and no code," the actual work became "extend parsers to capture discarded bytes into new placeholder fields, strip debug prints, add primitive writers for types that will need them, verify nothing regresses." All in Go, all testable against existing fixtures, no new tools, no new dependencies.

## What I changed

Three files, all in `tool/file_types/`.

### `binary_writer.go` — primitive additions

Added `WriteInt64` (big-endian, mirrors `ReadInt64`), `WriteFloat64` (little-endian, mirrors `ReadFloat64`), and `WriteDate` (delegates to the existing primitive writers in the same order as `ReadDate`). These unblock every writer in the Cafe and SaveGame families — `readStove` and `readCharacter` (the one in `save_game.go`, not `character.go`) both call `ReadInt64`, the cafe state reader calls `ReadFloat64` right out of the gate, and almost every cafe sub-type has at least one `ReadDate` call that was tied to the version > 47 or version > 51 branch.

I'm treating these as plumbing: they're the primitives the next session will need in quantity, and they cost nothing to land ahead of time.

### `cafe.go` — three lossy-read fixes and a major debug-print sweep

Four changes, each corresponding to a place where the reader was throwing bytes on the floor.

**`ReadCafe`'s header double.** Right after the version byte, `ReadCafe` was reading a `float64` into a local variable `d` that only existed to be `fmt.Printf`'d to stdout. The value itself was never stored on the `Cafe` struct. Added `Cafe.U0 float64` and populated it from the read. Best guess is this is a save timestamp (days since epoch, maybe), but that guess is unvalidated and doesn't matter for preservation. `U0` is fine.

**`ReadCafe`'s trailing int32 blocks.** The original code had the memorable comment `// Tbh this might not be right` above a `for i := 0; i < int(c.U8); i++ { ReadInt32(file) }` loop that discarded every value. Then a second loop below it for the `version > 61` case did the same thing. Added `Cafe.TrailingInts1 []int32` and `Cafe.TrailingInts2 []int32`, populated both from the read loops. The invariant `len(c.TrailingInts1) == c.U8` has to be maintained by anyone constructing a `Cafe` struct by hand, but on the read path the invariant is automatic. I'll decide later whether to drop `c.U8` in favor of a derived `len()` once the writer lands.

**`readFoodStack`'s double-read byte.** This was the ugliest lossy read in the file. The original code read a byte into `f.U1`, then — if `version > 24` — read a *second* byte into `f.U1`, overwriting the first one. The first byte was gone forever, and the version-condition logic made it look deliberate rather than a bug. I reinterpreted the structure: in versions > 24 there's a one-byte *prefix*, then `f.U1`, otherwise just `f.U1`. Added `FoodStack.U0 byte` for the prefix, rewrote the read order as `if version > 24 { f.U0 = ReadByte(file) }; f.U1 = ReadByte(file)`. The byte stream consumption is identical, the struct state is now lossless.

While I was in there I also noticed `f.U4` had a weirdly-written version guard: `version <= 24 || (version > 24 && version <= 48)` simplifies to `version <= 48`. Simplified it. No behavior change.

**`readFoodStack`'s discarded second string.** After reading `f.U6`, the reader called `ReadString(file)` with no assignment — the returned string was discarded. Added `FoodStack.U6Alt string` to capture it. No idea what it is semantically (food name variant? image key? localization?) and it doesn't matter.

**`readCafeFurniture`'s discarded `furnitureType` byte.** Not a lossy read in the sense of "bytes gone," but close: the reader read a `furnitureType` byte into a local variable, branched on whether it was 1 (Stove), 2 (ServingCounter), or anything else (plain furniture), and never stored the value anywhere. For the 1/2 cases this is fine because the pointer field (`c.Stove != nil`) implicitly carries the information. For the "anything else" case, the exact value of the byte is lost — if the original file had `furnitureType = 3` or `furnitureType = 7` or whatever, we'd write it back as whatever default the writer picks, and the round-trip would silently diverge. Added `CafeFurniture.FurnitureType byte` that captures the byte unconditionally when not in the `isFood` branch, and the writer (next session) will key off it rather than off whichever pointer happens to be non-nil.

That's the four lossy-read fixes in one file.

### Debug print cleanup in `cafe.go`

The file had something like fifteen `fmt.Println` / `fmt.Printf` debug statements scattered through the readers — `"Reading serving counter"`, `"Num food stacks: %d"`, `"Cafe version: %d"`, `"double: %f"`, `"Reading %d ints"`, and several more. Stripped all of them. Dropped the `fmt` import entirely as a result. Anyone running a round-trip test against a real cafe file in the next session will now get silent output on success instead of hundreds of lines of "Reading food stack \n Reading food stack \n Reading food stack".

This cleanup is load-bearing for the next session's cafe writer tests: without it, the test output from a single `TestCafeRoundTrip` with a non-trivial fixture would be unreadable.

## What I deliberately did *not* do

Per the session plan, I did not add any writer functions for Cafe, FriendCafe, or SaveGame. The reason is scope discipline: the cafe type family is recursively structured (`Cafe` → `CafeTile` → `CafeObject` → `CafeFurniture` → `Stove`/`ServingCounter` → `CafeObject` → ... mutually recursive), which means you have to land roughly ten writer functions at once to get any one of them testable end-to-end. Landing that much code in a single session — with version-conditional branches that have to match their readers exactly, byte-for-byte — is a higher-risk operation than I wanted to close the day with.

The next session's work is therefore "extremely mechanical": for each of the ten-ish writer functions, mirror the corresponding reader, preserve the same version-conditional structure, call the same primitive writers in the same order, and confirm each one matches its reader by running an in-memory round-trip test with realistic fixtures.

I also did not touch `save_game.go`. The save game writer is blocked on one specific detail: `readSaveStrings` reads an `int16` count, subtracts one, and reads `(count - 1)` strings into the void. The subtract-one is weird enough that I want to design the preservation struct for it carefully — capturing both the raw count and the strings, with a documented invariant — rather than improvising it at the end of a tired session. That's a small focused session of its own.

## Verification

Nine round-trip tests still pass:

```
=== RUN   TestFoodRoundTrip              --- PASS
=== RUN   TestFurnitureRoundTrip         --- PASS
=== RUN   TestCharacterRoundTrip         --- PASS
=== RUN   TestCharacterArtRoundTrip      --- PASS
=== RUN   TestImageOffsetsType2RoundTrip --- PASS
=== RUN   TestImageOffsetsType1RoundTrip --- PASS
=== RUN   TestCharacterJPRoundTrip       --- PASS
=== RUN   TestAnimationDataRoundTrip     --- PASS
=== RUN   TestAnimationDataFixture       --- PASS
PASS
ok      file_types      2.961s
```

And the full workspace still builds: `file_types`, `build_tool`, `resource_manager`, `cctpacker` native, `server` under `GOOS=js GOARCH=wasm`. The struct extensions and reader changes did not break any existing downstream caller in the other modules.

No new tests in this session. The new fields don't exercise any new behavior until the next session's writers exist to serialize them, at which point they'll get proper coverage via `TestCafeRoundTrip`.

## What this session reinforces about the rewrite plan

The Phase 0 → Phase 0a → Phase 0b → "Phase 0b without Ghidra after all" chain of amendments is doing its job. When I wrote the Phase 0 paragraph this morning, I thought it was a tests-only phase. By lunch I knew it was actually two phases. By the end of Phase 0a I thought Phase 0b would need Ghidra. Now I know it doesn't. Each amendment has been smaller than the previous one and has happened after actually reading the affected code, which is exactly the discipline I wanted the devlog to enforce.

Going to amend `docs/rewrite-plan.md` to reflect the Ghidra pivot: the "needs Ghidra work" note in the Phase 0b description should be replaced with "preservation-fields approach: add placeholder struct fields for discarded bytes, write symmetric writers, defer semantic naming to Phase 4." Less intimidating, more accurate.

## Next

1. Write `writeCharacter` (for `CharacterInstance` in save_game.go, not the game-data `Character` in character.go — they're different types), `writeCafeState`, `writeFoodStack`, `writeFood`, `writeStove`, `writeServingCounter`, `writeCafeWall`, `writeCafeObject`, `writeCafeFurniture`, `writeCafeTile`, `WriteCafe`, `WriteFriendData`. All mechanical now that the primitives are in place.
2. Add `TestCafeRoundTrip` and `TestFriendDataRoundTrip` with in-memory fixtures covering multiple cafe versions, stove/serving-counter/plain-furniture variants, decorated walls, and non-empty `TrailingInts1`/`TrailingInts2`.
3. Separately, design `readSaveStrings`'s preservation struct with the weird subtract-one count semantics captured cleanly, then add `writeSaveStrings`, `WriteSaveGame`, and a save-game round-trip test.
4. Only after Phase 0b is complete does Phase 1 (Godot asset export pipeline) become the critical path. Phase 3 (save-load contract) unblocks once Phase 0b closes.
