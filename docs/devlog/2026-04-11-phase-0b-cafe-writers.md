# 2026-04-11 — Phase 0b step three: the cafe writer family, and passing on the first run

**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))

Fifth entry of the day. The last session laid the groundwork — primitive writers, preservation fields, debug prints stripped — and called the remaining work "extremely mechanical." This session was the cash-in on that claim: write ten writer functions, add two round-trip tests, run `go test`, find out whether mechanical was actually mechanical. It was.

## What landed

Three files touched.

**`tool/file_types/cafe.go`** grew nine new writer functions appended after `ReadCafe`: `writeFoodStack`, `writeFood`, `writeStove`, `writeServingCounter`, `writeCafeFurniture`, `writeCafeWall`, `writeCafeObject`, `writeCafeTile`, and the top-level `WriteCafe`. Each one is a field-for-field mirror of its reader with the same version conditionals. The only non-obvious bits were the three places where the reader stores a value narrower than the field type — `readStove` reads `int32(ReadByte(file))` into a `int32` field for version ≤ 48, same pattern in `readServingCounter` for both `U1` and `U6`, same in `readCafeTile` and `readCafeWall` for `U1`. On the writer side those become `WriteByte(file, byte(s.U1))` — narrowing the `int32` back to a byte. Version 63 doesn't hit any of those branches (everything at version 63 uses the wider type), but the writers handle older versions for free.

**`tool/file_types/save_game.go`** gained `writeCharacter` (for `CharacterInstance`, not to be confused with the unrelated game-data `Character` in `character.go` which already had `WriteCharacters`) and `writeCafeState`. Both mechanical. The version-conditional bits in `readCharacter` — `fileVersion > 29` gates `U14`, nested `> 46` gates `U15` and `U16` — get mirrored exactly. In `readCafeState`, the `version > 62` branch reads `U11` as an `int32` whereas older versions read it as a byte promoted to `int32`; the writer handles both directions. No `WriteSaveGame` yet — `readSaveStrings`'s subtract-one count encoding still needs a thought-through preservation struct, which is the session-after-this topic.

**`tool/file_types/friend_cafe.go`** got a structural change. The existing `ReadFriendData` was reading a leading version byte into a local variable `version` and then passing it to `readCafeState` and letting `ReadCafe` read its own version byte. That leading byte was never stored, so a round-trip would have silently dropped it. Added `FriendCafe.Version byte` as a new field and updated the reader to populate it. `WriteFriendData` then writes `f.Version`, calls `writeCafeState` with `int(f.Version)`, and calls `WriteCafe` (which writes its own inner version byte from `f.Cafe.Version`). The result is that a file produced by `ReadFriendData → WriteFriendData` has both version bytes exactly where they were in the original.

**`tool/file_types/roundtrip_test.go`** gained two tests (`TestCafeRoundTrip`, `TestFriendCafeRoundTrip`) and two fixture builders (`makeCafeFixture`, `makeCafeStateFixture`). The cafe fixture is the interesting part of the work — it's a 2×2 tile map that deliberately exercises every branch in the reader tree: all three `CafeFurniture` variants (`Food`, `Stove`, `ServingCounter`, and plain furniture with a `FurnitureType` byte of 7 to prove preservation), an undecorated `CafeWall`, a decorated `CafeWall` whose decoration is itself a plain furniture object, a `Stove` with a `FoodStack`, a `ServingCounter` with two different `FoodStack`s (different strings, different `U7` dates), a `Food` with `U3 = false` (no inner object), tiles that use every combination of the three object slots (`U5`-only, `U5 + U7`, `U9`-only, `U5 + U7`), non-empty `TrailingInts1`, non-empty `TrailingInts2`, and an `U8` count of 3 to match `len(TrailingInts1)`. The friend-cafe fixture composes that cafe with a realistic `CafeState`: main character, one zombie, a three-element `U12` slice, `U11 = 3`, `U13 = true`.

## Verification

```
=== RUN   TestFoodRoundTrip              --- PASS
=== RUN   TestFurnitureRoundTrip         --- PASS
=== RUN   TestCharacterRoundTrip         --- PASS
=== RUN   TestCharacterArtRoundTrip      --- PASS
=== RUN   TestImageOffsetsType2RoundTrip --- PASS
=== RUN   TestImageOffsetsType1RoundTrip --- PASS
=== RUN   TestCharacterJPRoundTrip       --- PASS
=== RUN   TestAnimationDataRoundTrip     --- PASS
=== RUN   TestCafeRoundTrip              --- PASS
=== RUN   TestFriendCafeRoundTrip        --- PASS
=== RUN   TestAnimationDataFixture       --- PASS
PASS
ok      file_types      2.706s
```

Eleven tests, two new ones at the bottom, both green on the first run. Full workspace still builds: `file_types`, `build_tool`, `resource_manager`, `cctpacker` native, `server` under `GOOS=js GOARCH=wasm`.

## The thing I want to remember about this

I wrote roughly 280 lines of writer code in one sitting and hit zero bugs on the first run. That's not normal. Usually you get one or two — an inverted version condition, a swapped narrow/wide type, a forgotten field — and you fix them over two or three iterations. This time nothing. I want to understand why before I assume the next session will go as smoothly.

I think the answer is the groundwork sessions. The Phase 0a tests locked in a round-trip *infrastructure* (the generic `assertRoundTrip` helper, the `bytes.Buffer` pattern, the fixture construction style) so I wasn't also making infrastructure decisions on top of the writer decisions. The Phase 0b preservation-fields session made the readers *lossless* before I wrote the writers, which meant every writer had a 1:1 field target to aim at — no "what goes here?" questions while I was mid-function. And the Ghidra pivot avoided the distraction of semantic naming: fields were `U0`/`U1`/`TrailingInts1`, and the writer's job was to put bytes in the same order the reader took them out, not to understand them.

In other words, each preparatory session removed a *class* of decisions that would otherwise have been made simultaneously with the mechanical mirroring, and that's what let the mechanical mirroring actually be mechanical. The lesson is specific: when the next phase is going to be mechanical, the phase before it should be a decision-clearing exercise, not a delivery milestone. Phase 0a and the preservation-fields pass were *decision-clearing* for this session, and that's what made this session fast.

The generalized lesson is older and better-known — "separate decisions from execution" is a textbook software engineering move — but the specific one I want to remember for this project is: *when a reverse engineering rewrite produces a writer family, do the preservation pass first, and do it in a session of its own*. Don't combine "decide what to preserve" with "write the writers." Split them.

## What's still outstanding

Three items.

**`SaveGame` writer.** `readSaveStrings` is the remaining unresolved lossy read. It reads an `int16` count, subtracts one, and reads `count - 1` strings which are all thrown away. To preserve the bytes, the save game struct needs a new field — probably `PreStrings SaveStrings` and `PostStrings SaveStrings`, where `SaveStrings` is a tiny struct that captures both the raw int16 count and the actual strings. The raw count has to stay explicit because a `count` of 0 and a `count` of 1 both produce zero strings (since `count - 1` is `-1` or `0`), so `len(Strings)` can't uniquely reverse the encoding. That's its own focused session.

**Pre-existing debug prints I didn't touch.** The test output from `TestFurnitureRoundTrip` still includes `"Zombie Table"` and `"Toxin Lamp"` because `readSingleFurnitureData` in `furniture.go` has an `fmt.Println(furniture.Name)` baked in. `TestCharacterRoundTrip` still prints `"Num characters: 2"` because `ReadCharacters` has `fmt.Println(fmt.Sprintf("Num characters: %d", num))`. These don't fail tests — Go captures test stdout and only shows it on failure — but they're noise, and they're exactly the same category of issue the `cafe.go` cleanup addressed. A short follow-up session can strip them from `furniture.go`, `character.go`, and check every other reader file for similar leftovers.

**Real binary fixtures.** Every test today uses in-memory constructed fixtures. The Phase 0b contract includes "round-trip at least one real binary fixture per format" — an actual save file pulled from a device, an actual cafe file, an actual friend-cafe blob. Those need to be located, extracted, and checked in under `tool/file_types/testdata/`, and the tests extended to load them and diff bytes. This is a real-data reality check, and it's the thing most likely to surface edge cases that in-memory fixtures miss.

## Next

1. `WriteSaveGame` + preservation struct design for `readSaveStrings`. One focused session.
2. Debug print sweep across `furniture.go`, `character.go`, and any other reader file with stray `fmt.Println`/`Printf` calls.
3. Check in real binary fixtures under `tool/file_types/testdata/` and extend the round-trip tests to diff them at the byte level.
4. Then Phase 0b closes, Phase 3 unblocks, and Phase 1 (Godot asset export pipeline) becomes the critical path.

Phase 0b is within sight of done. A morning that started with "the validation harness is the thing that tells you your reverse engineering isn't done yet" is ending with most of the reverse engineering actually done, and the remaining pieces neatly scoped and blocked on understanding one specific encoding quirk and producing some fixtures. Good day.
