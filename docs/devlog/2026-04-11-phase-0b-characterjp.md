# 2026-04-11 — Phase 0b step one: `CharacterJP` writer and `ReadNextBytes` hardening

**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))

Third devlog entry of the day. After the [Phase 0a findings](./2026-04-11-phase-0a-findings.md) entry committed, I installed Go 1.26.2, the Phase 0a round-trip tests went green, and then the natural next step per the rewrite plan was to pick the most mechanical of the four missing writers — `WriteCharactersJP` — and use it as a rehearsal for the harder ones that are still outstanding (`WriteSaveGame`, `WriteCafe`, `WriteFriendData`). This entry is about that rehearsal and a small tooling fix that came with it.

## What I changed this session

Three files, all in `tool/file_types/`.

### `binary_reader.go` — hardening

The Phase 0a entry flagged two problems with `ReadNextBytes`: it called `log.Fatal` on error (which is `os.Exit(1)`, unrecoverable from a test), and it used a single `file.Read(buf)` call instead of `io.ReadFull`, which violates the `io.Reader` contract's allowance of partial reads. Both are closed in one shot:

```go
func ReadNextBytes(file io.Reader, number int) []byte {
    bytes := make([]byte, number)
    _, err := io.ReadFull(file, bytes)
    if err != nil {
        panic(fmt.Sprintf("ReadNextBytes: wanted %d bytes, got %v", number, err))
    }
    return bytes
}
```

`io.ReadFull` returns `io.ErrUnexpectedEOF` on a short read and `io.EOF` only when nothing was read, which is exactly the semantics I want. `panic` instead of `log.Fatal` means tests can `defer recover()` if they need to, and it keeps the existing contract for the build pipeline (still errors out loudly on bad data, just via panic instead of process exit).

While I was in the file, `ReadBool` also used `log.Panicln` for the "byte was not 0 or 1" case. Same treatment — converted to `panic(fmt.Sprintf(...))` and dropped the `log` import entirely. Not load-bearing, just tidying while the file was open.

Important thing I did not do: **I did not change `ReadNextBytes` to return an error.** Doing that would force every caller in every `Read*` function across the package to check and propagate errors, which is a six-file mechanical refactor with nothing to show for it in terms of behavior. Panic-based error handling is idiomatic enough for a parser that fundamentally can't recover from a malformed file midway through, and it's enough to let tests catch failures cleanly. If we ever need Result-style error propagation — for example, if we start accepting untrusted user-uploaded saves at runtime — that becomes a real refactor. Not today.

### `character_jp.go` — added writer, stripped debug prints

The interesting thing about the JP character format, relative to the EN format, is how mechanical it is:

- The array length is prefixed as a big-endian `int16` rather than a single byte, which makes sense because the JP version ships five character sheets of 20+ characters each, well past the 256 cap that a single-byte length would impose.
- There are no version-conditional reads anywhere in `readSingleCharacterJP`. Every field unconditionally reads and assigns to a struct field.
- There are no trailing-garbage reads — nothing gets read into the void.

That's why the rewrite plan recommended starting here. `writeSingleCharacterJP` and `WriteCharactersJP` are literally a mirror of the reader, field for field. No design decisions, no Ghidra, no reverse engineering. Good rehearsal for the muscle memory I'll need when I get to `SaveGame` and `Cafe`.

While I was there I also removed three debug prints: an `fmt.Println("---")` inside `readSingleCharacterJP`, an `fmt.Printf("Reading character: %d\n", i)` in the read loop, and a `json.MarshalIndent(character, ...)` that was dumping every parsed character to stdout. All of them were fine during interactive exploration but they pollute test output. Removed them and dropped the `encoding/json` import that was only there to serve them.

### `roundtrip_test.go` — added `TestCharacterJPRoundTrip`

Followed the same pattern as the other seven round-trip tests. Two fixture characters, one with every field populated and one with minimal values, wrapped in the generic `assertRoundTrip` helper. The first fixture uses Japanese strings — `"ゾンビ"`, `"客"`, `"ボス"` — partly because that's what this format actually holds in the wild and partly because it's an implicit test that `ReadString`/`WriteString` handle multi-byte UTF-8 correctly. They do, which is reassuring: the string length is byte-prefixed, not rune-prefixed, and both sides agree on that.

## Test run

```
=== RUN   TestFoodRoundTrip              --- PASS (0.00s)
=== RUN   TestFurnitureRoundTrip         --- PASS (0.00s)
=== RUN   TestCharacterRoundTrip         --- PASS (0.00s)
=== RUN   TestCharacterArtRoundTrip      --- PASS (0.00s)
=== RUN   TestImageOffsetsType2RoundTrip --- PASS (0.00s)
=== RUN   TestImageOffsetsType1RoundTrip --- PASS (0.00s)
=== RUN   TestCharacterJPRoundTrip       --- PASS (0.00s)
=== RUN   TestAnimationDataRoundTrip     --- PASS (0.00s)
=== RUN   TestAnimationDataFixture       --- PASS (0.00s)
PASS
ok      file_types      2.402s
```

Nine tests green. The entire workspace also builds cleanly — `file_types`, `resource_manager`, `build_tool`, `cctpacker` all compile for the host target, and `server` compiles for its intended `GOOS=js GOARCH=wasm` target (the Cloudflare Workers runtime). So the `ReadNextBytes` hardening did not break any of the reader call sites in the rest of the tooling.

## What's still outstanding in Phase 0b

The three writers I deliberately did not attempt this session, each for a specific reason:

**`WriteCharacters`** *(already exists — not missing)*. Noting this so future-me doesn't waste a pass looking.

**`WriteSaveGame`**. This one is blocked on understanding what `readSaveStrings` is throwing away. The function reads an `int16` length, then reads that many strings, and discards all of them. That data is almost certainly *something* — maybe a list of string IDs for in-progress orders, maybe localization keys, maybe achievement flags. The rewrite plan's Phase 3 contract ("round-trip a real save byte-identically") cannot be satisfied until we know what those strings are and where they should live on the `SaveGame` struct. The answer is most likely in Ghidra, using the `0x1ac` currency offset in `ZombieCafeExtension.cpp` as a starting anchor for the save game serializer entry point in `libZombieCafeAndroid.so`.

**`WriteCafe`**. Blocked on two different lossy sites. First, the trailing `int32` reads at the bottom of `ReadCafe` (the ones with the "Tbh this might not be right" comment) are consumed into nowhere — they might be a tile index map, or path-finding data, or per-object state. Second, `readFoodStack` reads two strings and keeps only the first; the second one could be a food type name, an image key, or who knows. Same Ghidra answer applies.

**`WriteFriendData`**. Trivially derivable from `WriteCafe` + `WriteCafeState` once those exist, since `FriendCafe = CafeState + Cafe`. Not separately blocked.

The pattern in all three cases is the same: the rewrite plan needs me to do one pass of static reverse engineering against the original `.so` before I can finish the validation harness against real fixtures. I suspected this was the shape of Phase 0b when I wrote the plan this morning — see the second paragraph of its Phase 0b description — but it's more concrete now that I've stared at the lossy read sites directly.

## Smaller stuff I noticed but did not fix

While reading `cafe.go` and `save_game.go` side by side I collected a small to-do list of things that aren't bugs exactly, just incidental cleanup that a future Phase 0b pass should sweep up:

- `cafe.go` has `fmt.Println`/`fmt.Printf` debug prints in `ReadCafe`, `readServingCounter`, and `readFoodStack`. Test output from any future `Cafe` round-trip test will be extremely noisy until these go.
- `character.go` has `fmt.Println(fmt.Sprintf("Num characters: %d", num))` in `ReadCharacters`. It's already spamming test output on every run of `TestCharacterRoundTrip`, just harmlessly redirected by `go test`'s stdout capture.
- `furniture.go` has `fmt.Println(furniture.Name)` inside `readSingleFurnitureData`, which prints every furniture name during a parse.
- `file_types.go`'s `ValidateSave` and `ValidateCafe` open a file and then silently return on open error with no action. The function name says "Validate," but there's no return value and no error reporting — it's more like "attempt to parse, discard all signal." Should either be deleted or rewritten.

None of these block anything. I'm noting them so they don't get lost.

## What I want to remember from this session

Two things.

First, the rehearsal hypothesis was right. Writing `WriteCharactersJP` took maybe fifteen minutes and the round-trip test caught zero bugs because there were zero bugs to catch — the reader and my writer agreed on the first try. That's exactly what a rehearsal should feel like: boring. When `SaveGame` comes around and it's *not* boring, I'll have a baseline for what "easy" feels like in this codebase and I'll know the difficulty is real, not manufactured.

Second, I ran into the Go version / `go vet` issue again this morning (the `%d` format specifier on a `bool` that Go 1.20 let slide and Go 1.26 didn't). That's a small thing by itself, but it's a preview of the kind of friction I'm going to hit if I try to keep the existing `go.mod` files on Go 1.20 while my local toolchain is 1.26. At some point I should bump every module's `go.mod` to 1.23 (matching `go.work`) and let `go vet` do its job. Not this session.

## Next

Realistically the next productive session is not more file_types writing — it's a Ghidra pass on `src/lib/armeabi/libZombieCafeAndroid.so` to chase the save game serializer and the cafe serializer entry points. The offsets in `src/lib/cpp/ZombieCafeExtension.cpp` are the starting anchors. The goal is a devlog entry, not code: "here are the function addresses, here is what each currently-discarded byte actually means, here is how to extend the `SaveGame` and `Cafe` struct definitions to capture them." *Then* I can come back and write `WriteSaveGame`/`WriteCafe` in a single mechanical pass.

That's the point where Phase 0b stops being an internal plumbing job and starts being recognizable as the reverse engineering work the project is actually about. Looking forward to it.
