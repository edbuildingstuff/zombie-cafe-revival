# 2026-04-11 — Phase 0b step four: `WriteSaveGame` and the subtract-one encoding

**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))

Sixth devlog entry of the day. This is the one where Phase 0b comes within a single remaining item of closing: `WriteSaveGame` lands, the weird `readSaveStrings` encoding gets a preservation struct that actually works, the remaining debug prints get swept, and the only thing left between me and Phase 3 is "check in some real binary fixtures."

## The `readSaveStrings` puzzle

The last entry closed by describing `readSaveStrings` as "the remaining unresolved lossy read" and promising a focused design session for it. Here's what made it weird.

The reader looked like this:

```go
func readSaveStrings(file io.Reader) {
    readShort := ReadInt16(file)
    num := readShort - 1
    if num >= 0 {
        for i := num; i >= 1; i-- {
            ReadString(file)
        }
    }
}
```

Trace it by hand and you get a small table:

| `readShort` on disk | strings actually read |
|--------------------:|:----------------------|
| `0` | 0 |
| `1` | 0 |
| `2` | 1 |
| `3` | 2 |
| `N >= 2` | `N - 1` |

The surprise is the `0` / `1` collision: both decode to zero strings, but they write different bytes to disk. That means `len(Strings)` does not uniquely determine what was in the file — the raw count has to be stored *separately* from the strings, because losing it loses information that can't be recovered from the decoded structure.

The other surprise is the reverse-counting loop. `for i := num; i >= 1; i--` is unusual Go — normal style would be `for i := 0; i < num; i++`. The reverse iteration doesn't change how many strings are read (it's still `num` if `num >= 1`), so it's behaviorally equivalent to a forward loop. I kept the reverse loop in the new reader to minimize the diff from Airyz's original — this is a preservation pass, not a stylistic refactor.

The preservation struct fell out naturally once the puzzle was written down:

```go
type SaveStrings struct {
    RawCount int16    // as written to disk; stored explicitly because
                      // RawCount=0 and RawCount=1 both decode to zero
                      // strings and cannot be distinguished from
                      // len(Strings) alone.
    Strings  []string
}
```

Reader returns one of these instead of nothing. Writer emits `RawCount` as an `int16`, then emits each string unconditionally. No conditional logic on the writer side at all — if `len(Strings)` doesn't match `max(0, RawCount-1)`, the round-trip fails, but that's the caller's fault for constructing an inconsistent struct.

The test for this is its own sub-test group, `TestSaveStringsEncoding`, with four cases: `RawCount=0` with zero strings, `RawCount=1` with zero strings (the off-by-one boundary), `RawCount=2` with one string, and `RawCount=5` with four strings. All four round-trip green. The `0` / `1` pair is the important one — if my preservation struct were wrong, those two would collapse to the same bytes on write and fail to distinguish on read.

## `SaveGame`'s phantom fields

Related discovery. The existing `SaveGame` struct had two fields that weren't doing anything:

```go
U14 int16  // never read, never written
U15 Date
U16 int16  // never read, never written
U17 Date
```

The reader walked straight past them — from `save.State = readCafeState(...)` it went to `readSaveStrings(...)` (discarding the result), then `save.U15 = ReadDate(...)`, then another `readSaveStrings(...)`, then `save.U17 = ReadDate(...)`. `U14` and `U16` were declared but untouched.

Looking at the layout, it's obvious what happened: `U14` (int16) sits right before `U15` (Date), and `U16` (int16) sits right before `U17` (Date). Those are exactly the slots where an `int16` count prefix would go if the save-strings block had been captured as a single field. Airyz almost certainly reserved `U14` and `U16` for the save-strings count when sketching the struct, then later implemented `readSaveStrings` as a void-returning helper and never came back to wire the results into the struct. `U14` and `U16` are vestigial — frozen half-finished state from the original reverse engineering pass.

Removing them was a minor risk decision. I grepped the whole `tool/` tree for `.U14` and `.U16` and every match was on `CharacterInstance` or `Character` or `CharacterJP`, none on `SaveGame`. Nothing outside `save_game.go` references either field on the `SaveGame` type specifically. Safe to remove.

The replacement fields are `PreStrings SaveStrings` (where `U14` used to live) and `PostStrings SaveStrings` (where `U16` used to live), named after when they appear in the reader flow relative to the two `Date` fields. The names aren't pretty but they're accurate.

## What else shipped

**`SaveGame.Version byte`**. The old `ReadSaveGame` read a leading version byte into a local `version` variable and discarded it after using it to dispatch to `readSaveGameVersion63`. On the writer side I need to emit that byte back, so it has to live on the struct. Added.

**`WriteSaveGame` and `writeSaveGameVersion63`**. Mechanical mirrors of their readers. `writeSaveGameVersion63` has the same `NumOrders > 0 → panic` that the reader has — the orders serialization format isn't implemented on either side, and no save file I've seen in testing has a non-zero `NumOrders` at version 63, so it's a fault-on-unexpected-input rather than a blocker. When Phase 4 starts implementing the game tick loop and needs orders, that's when someone figures out what an order on disk looks like. For now the round-trip test uses `NumOrders = 0` and the panic path stays dormant.

**Debug print sweep in `furniture.go`, `character.go`, `file_types.go`**. Three stray `fmt.Println` / `fmt.Printf` calls that were polluting test output:

- `readSingleFurnitureData` was calling `fmt.Println(furniture.Name)` every iteration, so `TestFurnitureRoundTrip` would spew `"Zombie Table"` and `"Toxin Lamp"` into captured test output.
- `ReadCharacters` had `fmt.Println(fmt.Sprintf("Num characters: %d", num))` — a double-invocation anti-pattern that was printing `"Num characters: 2"` every run of `TestCharacterRoundTrip`.
- `ValidateFriendData` had `fmt.Printf("Read bytes: %d\n", n)` as a leftover debug line from when Airyz was first figuring out where the friend data format ended.

All three removed. `fmt` imports dropped from all three files where they were the only `fmt` usage. Test output is now genuinely silent on success, which matters because `TestCafeRoundTrip` with a real binary fixture (coming next) is going to have a much larger parse tree and any debug print in that tree would blow up the output-on-failure buffer.

## Verification

```
=== RUN   TestFoodRoundTrip                                  --- PASS
=== RUN   TestFurnitureRoundTrip                             --- PASS
=== RUN   TestCharacterRoundTrip                             --- PASS
=== RUN   TestCharacterArtRoundTrip                          --- PASS
=== RUN   TestImageOffsetsType2RoundTrip                     --- PASS
=== RUN   TestImageOffsetsType1RoundTrip                     --- PASS
=== RUN   TestCharacterJPRoundTrip                           --- PASS
=== RUN   TestAnimationDataRoundTrip                         --- PASS
=== RUN   TestCafeRoundTrip                                  --- PASS
=== RUN   TestFriendCafeRoundTrip                            --- PASS
=== RUN   TestSaveStringsEncoding                            --- PASS
    --- PASS: TestSaveStringsEncoding/raw_count_0,_zero_strings
    --- PASS: TestSaveStringsEncoding/raw_count_1,_zero_strings_(boundary)
    --- PASS: TestSaveStringsEncoding/raw_count_2,_one_string
    --- PASS: TestSaveStringsEncoding/raw_count_5,_four_strings
=== RUN   TestSaveGameRoundTrip                              --- PASS
=== RUN   TestAnimationDataFixture                           --- PASS
PASS
ok      file_types      2.405s
```

13 tests, 4 sub-tests, 17 passing assertions total. Full workspace still builds clean. Every binary format in `tool/file_types/` that has a reader now has a symmetric writer, every reader is lossless, every round-trip is byte-stable against in-memory fixtures.

## Phase 0b status

Essentially done except for the fixtures:

- *(done)* `ReadNextBytes` hardening (`io.ReadFull` + `panic`)
- *(done)* `WriteCharactersJP` + round-trip test
- *(done)* Primitive writers `WriteInt64`, `WriteFloat64`, `WriteDate`
- *(done)* Lossy read fixes in `cafe.go` (`Cafe.U0`, `Cafe.TrailingInts1`, `Cafe.TrailingInts2`, `FoodStack.U0`, `FoodStack.U6Alt`, `CafeFurniture.FurnitureType`)
- *(done)* Cafe family writers + `TestCafeRoundTrip`, `TestFriendCafeRoundTrip`
- *(done, this session)* `SaveStrings` preservation struct, `WriteSaveGame`, `TestSaveGameRoundTrip`, `TestSaveStringsEncoding`
- *(done, this session)* Debug print sweep in `furniture.go`, `character.go`, `file_types.go`
- *(pending)* Check in real binary fixtures under `tool/file_types/testdata/` and extend tests to diff them at the byte level

One item left. That item is also the most interesting one, because it's the first time the in-memory round-trip claims will get tested against real game data — and real data always has edge cases that synthetic fixtures miss. Not going to declare Phase 0b "done" until the fixtures pass.

## What I'm thinking about for the fixture session

The fixture step has a sourcing problem I need to solve before writing any test code. The repo has `src/assets/` containing the extracted APK's data (11,000+ files), but none of it is a save game — the save data lives on-device under the app's private storage and isn't in the APK. Options:

1. **Install the legacy APK on a device/emulator, play briefly, extract the save from `/data/data/com.capcom.zombiecafeandroid/`.** Most authentic, but needs a rooted emulator or an ADB backup. Produces one real save per test run, which is fine for Phase 0b's "at least one fixture per format" contract.
2. **Hit the live Cloudflare Workers backend and grab whatever `getgamestate` or `getrandomgamestate` returns.** That's actual saved state, but it's whatever arbitrary player's data happens to be in KV at the moment the test fixture is captured. Legally iffy in spirit even though the endpoint is public.
3. **Synthesize a "real-looking" save by writing the in-memory fixture to disk, then checking in the binary.** Self-referential — if `WriteSaveGame` has a latent bug, the fixture file encodes the bug, and the round-trip test would pass anyway. Doesn't actually provide any new signal.

Option 1 is the right answer for Phase 0b's intent. I need to set up an emulator, install the current legacy APK build (the one the current repo produces via `apktool b`), play long enough to generate a save with a non-trivial cafe layout, and extract it via `adb pull /data/data/com.capcom.zombiecafeandroid/files/` or similar. That's a session of its own and it's blocked on me having a working Android build workflow, which is itself the thing I've been trying to retire.

Shortcut: if anyone on the Airyz-era project has an old save file sitting around from their own testing, that's an immediate win — it bypasses the APK build entirely. Worth asking before setting up the emulator pipeline.

Either way, this is the work I want to think about before diving into it, not something to mechanically execute at the end of an already-long session. I'm stopping here.

## Next

1. Decide the fixture sourcing: emulator extraction, existing Airyz-era saves, or something else. This is a planning question, not a coding one.
2. Once a real save/cafe/friend-cafe blob is in hand, check it in under `tool/file_types/testdata/`, add fixture-reading tests that diff against the checked-in file byte-for-byte, and declare Phase 0b closed.
3. After Phase 0b closes, Phase 1 (Godot asset export pipeline) opens as the new critical path. That's where the project shifts from "extend the existing Go reverse engineering code" to "build the Godot import plugin that consumes it."

Six devlog entries, one day, Phase 0 through Phase 0b-except-for-fixtures. The rate is going to slow down from here — fixture sourcing has a physical component (device or emulator), and Phase 1 is where the first actual Godot code gets written, which is new territory for this project. But the plumbing is finished.
