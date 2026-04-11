# 2026-04-11 — Phase 0a: the validation harness and what it revealed about the parsers

**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))

Second entry of the day. Kicked off the morning with the [Godot rewrite plan](../rewrite-plan.md) and Phase 0 was supposed to be the easy warmup: write round-trip tests for every `.bin.mid` file in `src/assets/data/`, assert byte-level equality, move on. It turned into something more interesting because the moment you start reading the `file_types` package with the specific question "can I write this back out byte-identically?" you find out the answer is no — and then the interesting part is understanding *why* no, and what that means for the rewrite plan.

## What I was going to write

One test per binary format. Load a fixture file, call `Deserialize` to get a struct, call `Serialize` to get bytes back, assert the output bytes are equal to the input bytes. Fifteen formats, fifteen tests, done in an afternoon. That was the plan when I wrote the rewrite document this morning.

## What I actually found in `file_types`

Half the formats don't have a serializer at all.

Of the ten format source files in `tool/file_types/`, only five have a matching `Write*` function:

| Format         | Reads        | Writes       | Fixture on disk |
|----------------|--------------|--------------|----------------|
| `Food`         | `ReadFoods` | `WriteFoods` | JSON only (`foodData.bin.mid.json`) |
| `Furniture`    | `ReadFurnitureData` | `WriteFurnitureData` | JSON only (`furnitureData.bin.mid.json`) |
| `Character`    | `ReadCharacters` | `WriteCharacters` | JSON only (`characterData.bin.mid.json`) |
| `CharacterArt` | `ReadCharacterArt` | `WriteCharacterArt` | (not in `data/`) |
| `ImageOffsets` | `ReadImageOffsets` | `WriteImageOffsets` | (not in `data/`) |
| `AnimationData`| `ReadAnimationData` | *(missing)* | `animationData.bin.mid` |
| `SaveGame`     | `ReadSaveGame` | *(missing)* | — |
| `Cafe`         | `ReadCafe`    | *(missing)* | — |
| `FriendCafe`   | `ReadFriendData` | *(missing)* | — |
| `CharacterJP`  | `ReadCharactersJP` | *(missing)* | — |

And even the "has both" side of that table isn't as clean as it looks, because the three formats the build pipeline actually touches in anger — `Food`, `Furniture`, `Character` — live in the repo as `.bin.mid.json` files, not `.bin.mid` files. The canonical editable source is JSON; the binary is produced at build time by `SerializeFood` / `SerializeFurniture` / `SerializeCharacters` calling the JSON-to-struct-to-binary path. Which means my original plan of "load the fixture, round-trip it, diff" doesn't have real binary fixtures to work against for those three formats. The *original* APK's binary versions exist (they can be extracted from the decompiled APK under `src/`), but they're not in the `data/` tree that the build tool consumes.

## The lossy reads

More interesting: even where both Read and Write exist, the Read side discards bytes in several places. Some examples I spotted while reading through the code:

In `cafe.go`, `ReadCafe` parses a `U8` count from the file and then reads `U8` trailing `int32`s in a loop that stores them nowhere. There's even a note-to-self comment on the line above the loop:

```go
// Tbh this might not be right
for i := 0; i < int(c.U8); i++ {
    ReadInt32(file)
}
```

In `save_game.go`, `readSaveStrings` is called twice from the save game reader, and its entire job is to read a length-prefixed array of strings and throw every one of them on the floor. Not stored, not returned, gone. The save game round-trip isn't just missing a writer — it would also be missing the *data* to write, because the reader never captured it in the first place.

In `cafe.go`, `readFoodStack` reads a byte into `f.U1`, then if `version > 24` reads *another* byte into `f.U1`, overwriting the first. The first byte is gone. That looks like either a latent bug (wrong field name) or an intentional discard of version-specific padding — but either way, the round-trip is lossy.

Also in `cafe.go`, `readFoodStack` reads two strings in a row and stores only the first. The second goes into the void.

None of this is Airyz doing anything wrong. These parsers were written to *inspect* the formats, not preserve them — "can we see what's in here" is a very different contract from "can we write this back byte-identically." The existing build pipeline never round-trips a save file or a cafe file through these parsers, so there's been no pressure to make them lossless. The build pipeline only round-trips Food/Furniture/Character/CharacterArt/ImageOffsets, and those reader/writer pairs *are* symmetric.

## The other thing: `ReadNextBytes` calls `log.Fatal`

Going to flag this because it's going to bite Phase 0b. `binary_reader.go` has this at the bottom:

```go
func ReadNextBytes(file io.Reader, number int) []byte {
    bytes := make([]byte, number)
    _, err := file.Read(bytes)
    if err != nil {
        log.Fatal(err)
    }
    return bytes
}
```

`log.Fatal` calls `os.Exit(1)`. From a test, that kills the entire test binary — you can't `recover()` from it because it's not a panic, it's a process exit. Any Phase 0b test that tries to parse a malformed or unexpectedly-truncated file will take the whole test run with it instead of failing cleanly. This needs to become an error return or a panic before we start writing fuzzier tests.

There's also a subtler issue: the code does a single `file.Read(bytes)` call instead of `io.ReadFull`, which means partial reads (legal under the `io.Reader` contract) would fail unpredictably. For `bytes.Reader` this is fine in practice, but for anything stream-like it's a bug.

## What Phase 0a actually delivered

Scoping accordingly. What I shipped in this session:

1. **Widened `WriteFoods` to take `io.Writer`.** It was the odd one out — every other `Write*` function took `io.Writer`, this one took `*os.File`. Widening doesn't break the existing caller in `serialization.go` because `*os.File` implements `io.Writer`. One-line change.

2. **Added `WriteAnimationData`.** Trivial, ten lines, mirrors `ReadAnimationData`. Enables a round-trip test for the one binary fixture in `src/assets/data/` that has a parser.

3. **Wrote `tool/file_types/roundtrip_test.go`.** In-memory round-trip tests for the six formats that now have a Read/Write pair: `Food`, `Furniture`, `Character`, `CharacterArt`, `ImageOffsets` at both `Type=1` and `Type=2`, and `AnimationData`. Plus one real-fixture test that loads `src/assets/data/animationData.bin.mid`, parses it, re-encodes it, and asserts the encoded bytes match the original prefix.

4. **Did not write tests for** `SaveGame`, `Cafe`, `FriendCafe`, `CharacterJP`. They can't round-trip in their current state.

The tests have not been run yet — there's no Go toolchain installed on this machine. I need to install Go before I can claim Phase 0a is actually green. This is a real gap in my verification and I'm flagging it here so future-me doesn't forget.

## What this means for the rewrite plan

The rewrite plan assumed Phase 0 was a one-pass tests-only phase. It isn't. Splitting it into **Phase 0a** (tests for what already has Read/Write symmetry, done in this session modulo actually running them) and **Phase 0b** (make the parsers lossless, add the missing writers, harden the reader primitives). I'm amending [`docs/rewrite-plan.md`](../rewrite-plan.md) to reflect this split.

Phase 0b is not small. It needs:

- `WriteSaveGame`, `WriteCafe`, `WriteFriendData`, `WriteCharactersJP` — each one mirroring a Read function that's currently lossy, so you can't just mechanically mirror the reader, you have to *first* add the missing struct fields for the discarded data, *then* teach the reader to populate them, *then* write the writer. Three steps per format, not one.
- `ReadNextBytes` fixed to return an error (or at minimum, panic instead of `log.Fatal`) so that test failures stay catchable.
- `io.ReadFull` used wherever a fixed-length read is needed, to close the partial-read hole.
- A real binary fixture for each format checked in under a `tool/file_types/testdata/` directory, so the round-trip tests aren't just in-memory constructions.

None of this blocks Phase 1 (the Godot-friendly asset export pipeline), which mostly goes from JSON to PNG/OGG/TTF and doesn't need `SaveGame` or `Cafe` round-tripping. But it does block Phase 3 (the save-load contract test), which is the whole point of having a validation harness in the first place. Phase 0b is on the critical path for Phase 3 and for anything touching player saves.

## The larger takeaway (the publishable one)

The thing I want to remember about this session is how fast the shape of Phase 0 changed once I actually read the code instead of planning around it. In the morning's rewrite plan, Phase 0 was a checkbox: "write round-trip tests, make them pass, done." By mid-afternoon it was two phases, the second of which requires going back and extending every lossy parser, which in turn requires understanding the original binary format well enough to know what the discarded bytes *mean*. That's not a warmup anymore. That's its own reverse engineering milestone.

This is exactly the kind of thing I expected the devlog to catch and the rewrite plan to miss. The rewrite plan is a scoping document written before the work starts; the devlog is the ground truth. When they disagree, the devlog wins and the plan gets amended. I'd rather have this discrepancy on day one than on week four.

The publishable framing of this: *"Day one of a reverse engineering rewrite: the validation harness is the thing that tells you your reverse engineering isn't done yet."* The existing parsers are good enough for the job they were written for — letting Airyz inspect the format and pipe food/furniture/character data through the build system — but they're not good enough to be a canonical ground truth for a new client. Finding that out on day one is the best possible outcome. Finding it out during Phase 3 would have been a disaster.

## Next

1. Install Go and actually run `go test ./tool/file_types/...` on this session's tests. Until I do that I cannot honestly claim Phase 0a is done.
2. Amend the rewrite plan to split Phase 0 into 0a/0b and move Phase 3's dependency to 0b.
3. Pick a concrete starting point for Phase 0b: probably `WriteCharactersJP` first, because `CharacterJP` has no version-conditional reads and no trailing-garbage reads, so it's the most mechanical of the missing writers and a good rehearsal before tackling `SaveGame`.
4. Before touching `SaveGame` and `Cafe`, read the original `.so` in Ghidra to understand what the currently-discarded fields *are*. The rewrite plan already lists the offsets anchored in `ZombieCafeExtension.cpp`; those should get us close enough to the save/cafe serializer entry points to answer the question.
