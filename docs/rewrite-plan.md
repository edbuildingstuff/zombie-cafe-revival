# Godot 4 Rewrite Plan

**Status:** Active — adopted 2026-04-11
**Owner:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))
**Inherits from:** Airyz's reverse engineering work (see [README.md](../README.md))

## TL;DR

We are rewriting the *Zombie Cafe* client as a **Godot 4** project that consumes the existing Go asset pipeline and Cloudflare Workers backend. The original `libZombieCafeAndroid.so` becomes *reference material*, not a runtime dependency. The smali shell and `LibZombieCafeExtension` runtime patcher are retired the moment a Godot boot path can load a save file and render a cafe.

## Goals

1. **Cross-platform.** One codebase, exports to Windows, macOS, Linux, Android, iOS, and the web. No per-platform forks.
2. **Preserve the data.** Save games, cafe layouts, characters, food, furniture, and textures round-trip through the existing Go tooling without loss. Old saves from the patched Android build remain loadable.
3. **Own the game loop.** Gameplay logic lives in GDScript (or C# where it matters), not in a reverse-engineered binary. Any future balance change, new character, or new mode is a normal code edit.
4. **Keep the server.** `tool/server/` stays as-is. The Godot client talks to the same `/v1/zca/*` endpoints the legacy APK talks to today.
5. **Document as we go.** Every non-trivial decision and every reversed piece of behavior gets a devlog entry so it can become a blog post later.

## Non-goals

- **Bit-perfect behavioral fidelity with the 2011 binary.** We'll match the original where it matters (economy, pacing, character stats), but we will not chase every undocumented edge case in the original `libZombieCafeAndroid.so`.
- **Shipping on the Play Store / App Store under the original name.** This is preservation, not commercial distribution.
- **Supporting the legacy patched-APK build in parallel forever.** It stays buildable during the transition and gets archived once the Godot client reaches feature parity.
- **Rewriting the Go tooling.** `tool/file_types/`, `tool/cctpacker/`, `tool/resource_manager/`, and `tool/build_tool/` are already well-factored for this use case. They may get a new entry point for exporting Godot-native assets, but the binary format code is untouched.

## What we keep vs. what we replace

| Component                                             | Status       | Notes                                                                                       |
| ----------------------------------------------------- | ------------ | ------------------------------------------------------------------------------------------- |
| `tool/file_types/` (Go binary format definitions)     | **Keep**     | Canonical source of truth for `SaveGame`, `Cafe`, `Character`, `Food`, `Furniture`, etc.    |
| `tool/cctpacker/` (CCTX codec)                        | **Keep**     | Used to decode the original texture atlases into PNGs the Godot importer can consume.       |
| `tool/resource_manager/` (JSON ↔ binary)              | **Keep**     | Human-readable editing workflow for game data.                                              |
| `tool/build_tool/` (APK build orchestrator)           | **Keep (legacy)** | Kept runnable during transition; retired once Godot client is at parity.              |
| `tool/server/` (Cloudflare Workers backend)           | **Keep & extend** | Fill in the currently-stubbed endpoints (`getgamestate`, proper friend metadata).      |
| `src/assets/` (extracted game assets)                 | **Keep as source** | Feed into the Godot import pipeline via the Go tooling.                                |
| `src/smali/` (decompiled Dalvik bytecode)             | **Reference, then delete** | Kept until the Godot client boots; then archived on a branch and removed from main. |
| `src/lib/armeabi/libZombieCafeAndroid.so`             | **Reference** | Not shipped with the Godot client. Used as an oracle for behavior we're unsure about.     |
| `src/lib/cpp/` (LibZombieCafeExtension)               | **Retire**   | Every patch it applies becomes unnecessary once the game is running in Godot.               |
| `src/AndroidManifest.xml`, `apktool.yml`, `debug.keystore` | **Retire** | Godot handles Android export directly.                                                |

## Phased plan

Each phase has a concrete "done" criterion. We do not start phase N+1 until phase N's criterion is met.

### Phase 0a — Validation harness for symmetric formats *(in progress)*

**Done when:** `go test ./tool/file_types/...` passes on the round-trip tests in `tool/file_types/roundtrip_test.go` for every format that currently has both a `Read*` and `Write*` function.

Why first: the Go binary format code had zero tests. Before we trust any part of it as the bridge between old saves and the Godot client, we need to lock in Read/Write symmetry where it already exists — so any future refactor of `file_types` can be validated against a regression baseline.

Scope: six formats. `Food`, `Furniture`, `Character`, `CharacterArt`, `ImageOffsets` (both `Type=1` and `Type=2`), and `AnimationData` (after adding the missing `WriteAnimationData` in this phase). All tested with in-memory fixtures. One real-file smoke test against `src/assets/data/animationData.bin.mid`.

Deliverables:
- `tool/file_types/roundtrip_test.go` with in-memory round-trip tests.
- `WriteAnimationData` added to `animation_data.go`.
- `WriteFoods` signature widened from `*os.File` to `io.Writer` for consistency with every other writer in the package.
- A `go test` invocation documented in the README once the tests have been verified green.

### Phase 0b — Lossless parsers and missing writers *(blocks Phase 3)*

**Done when:** `SaveGame`, `Cafe`, `FriendCafe`, and `CharacterJP` all round-trip byte-identically through Read → Write on real fixture files extracted from the decompiled APK.

Why this is its own phase: the existing readers for these formats are *lossy*. `readSaveStrings` in `save_game.go` reads length-prefixed string arrays and throws every string away. `ReadCafe` reads a trailing `int32` count followed by that many `int32`s into nowhere (with a note-to-self comment conceding the author wasn't sure it was right). `readFoodStack` in `cafe.go` reads a byte into `f.U1`, then on `version > 24` overwrites it with a second byte — losing the first. The same function reads two consecutive strings and stores only the first. None of this is a bug in the sense of "the build pipeline is broken" — the build pipeline never round-trips these formats, so there's been no pressure to be lossless. It *is* a bug in the sense of "we cannot use this as the source of truth for the Godot client's save/load path."

Fixing it means:

1. For each lossy read site, add struct fields that capture the currently-discarded data.
2. Update the reader to populate those fields instead of dropping them.
3. Write the corresponding writer.
4. Harden `ReadNextBytes` in `binary_reader.go` to return an error (or panic) instead of calling `log.Fatal`, so that malformed fixtures in tests fail cleanly instead of killing the test binary.
5. Use `io.ReadFull` wherever a fixed-length read happens, to close the partial-read gap in the `io.Reader` contract.
6. Check in binary fixtures under `tool/file_types/testdata/` — real files extracted from the decompiled APK, one per format.
7. Extend `roundtrip_test.go` (or add per-format `*_test.go` files) to assert byte-level equality for each format against its checked-in fixture.

Some of this requires going back to Ghidra and understanding what the currently-discarded fields *mean* — specifically for `SaveGame` and `Cafe`. The anchors labelled in `src/lib/cpp/ZombieCafeExtension.cpp` should put us close enough to the save/cafe serialization entry points in the original `.so` to answer that.

Recommended starting point: `CharacterJP`. It has no version-conditional reads and no trailing-garbage reads, so adding `WriteCharactersJP` is the most mechanical of the four missing writers and a good rehearsal before tackling `SaveGame`.

Deliverables:
- `WriteSaveGame`, `WriteCafe`, `WriteFriendData`, `WriteCharactersJP`.
- Additional struct fields on `SaveGame`, `Cafe`, and their sub-types to preserve data that is currently discarded.
- `ReadNextBytes` returns an error instead of `log.Fatal`; callers updated to propagate.
- `tool/file_types/testdata/` with one binary fixture per format.
- Round-trip tests for all four formats passing against real fixtures.

### Phase 1 — Asset export pipeline for Godot

**Done when:** `go run ./tool/build_tool -target godot -o godot/assets/` produces a directory tree that Godot can import without manual intervention: PNGs for every texture, JSON for every data file, OGG for audio, TTF/BMFont for fonts.

Why: Godot's importer wants friendly formats. We already have the Go code that can unpack CCTX → PNG and binary game data → JSON; we just need a new build-tool target that emits a Godot-friendly layout instead of an APK-friendly one.

Deliverables:
- A new `-target` flag on `build_tool` selecting `android` (default, legacy) or `godot`.
- `godot/assets/` tree populated with importable files.
- A short doc in `docs/` explaining the asset flow.

### Phase 2 — Godot project scaffold

**Done when:** opening `godot/project.godot` in Godot 4 shows the cafe background, a player character sprite, and a rendered test UI, with nothing hardcoded beyond a "hello world" scene. No gameplay yet.

Deliverables:
- `godot/project.godot` with import settings tuned for the exported assets.
- One scene showing a static cafe tile with the character sprite overlaid.
- CI entry (GitHub Actions) that runs `godot --headless --check-only` on every push.

### Phase 3 — Save-load round-trip *(blocked on Phase 0b)*

**Done when:** the Godot client can load a real save file produced by the legacy Android build, render the cafe layout described by it, and write it back out byte-identically. No tick simulation yet — this is purely a data path.

Why this before gameplay: if the Godot client can't agree with the Go tooling on what a save file means, there's no point implementing a tick loop. This is the fidelity contract.

**Blocked on Phase 0b:** byte-identical round-tripping requires `SaveGame`, `Cafe`, and `FriendCafe` to have lossless parsers and matching writers. The current readers discard bytes in several places (see Phase 0b), so this phase cannot start until Phase 0b is complete.

Deliverables:
- A GDScript/C# wrapper that calls into the Go `file_types` package (via a compiled shared library, or by round-tripping through JSON).
- A test save file checked in under `godot/test/fixtures/`.
- A unit test in Godot that loads it, re-saves it, and diffs against the original bytes.

### Phase 4 — Game tick loop

**Done when:** customers spawn, walk to tables, order food, wait for the stove, eat, pay, and leave. XP and money update. The player can place furniture and buy characters. No online features, no billing, no Facebook.

This is where the bulk of the reverse engineering effort goes. For each behavior, the order of operations is:

1. Check the original `libZombieCafeAndroid.so` in Ghidra, using the offsets already labelled in `src/lib/cpp/ZombieCafeExtension.cpp` as anchors.
2. Write a devlog entry describing the behavior in plain English.
3. Implement it in Godot.
4. If the behavior is exposed in a save file field (e.g., a timer, a cooldown), verify by loading a legacy save and confirming the values match expectations.

### Phase 5 — Online features

**Done when:** the Godot client authenticates (or stubs auth), uploads its save state to `tool/server/`, fetches a random friend cafe via `getrandomgamestate`, and lets the player raid it. Friend metadata is no longer hardcoded.

This phase also drives the remaining server work: implementing `getgamestate` properly, replacing the placeholder timestamp, and removing the 90% save-drop throttle (which was a cost-control hack and should not survive the rewrite).

### Phase 6 — Platform exports

**Done when:** clean builds for Windows, Linux, macOS, Android, and web are attached to a GitHub release, each one smoke-tested to boot into the menu and load a save.

iOS is listed separately: it requires a macOS build host and an Apple developer account, so it's a stretch goal for this phase rather than a blocker.

### Phase 7 — Retire the legacy build

**Done when:** `src/smali/`, `src/lib/cpp/`, `src/AndroidManifest.xml`, `apktool.yml`, and `debug.keystore` are removed from `main` and preserved on a `legacy-android-apk` branch. The README's "Building the legacy Android APK" section is replaced with a "Building in Godot" section.

## Validation strategy

Three layers of test coverage, in order of how much they're worth:

1. **Phase 0 Go round-trip tests.** Canary for any binary format regression. Fast, deterministic, runs on every push.
2. **Godot ↔ Go contract tests.** Load a real save in Godot, serialize it back, diff against the Go tooling's output. Catches divergence between the two consumers of the format.
3. **Behavioral smoke tests.** A small Godot test scene that runs a headless tick loop for N simulated minutes and asserts that a starting save reaches an expected end state. Catches gameplay regressions.

Performance tests are explicitly skipped. Zombie Cafe's peak entity count is low enough that Godot 4 can run it at several thousand FPS on any modern machine. If we ever hit a hot loop, GDExtension exists.

## Why Godot over the alternatives

We considered three paths before committing:

### Path A — Emulate `libZombieCafeAndroid.so` on non-Android hosts

Wrap the existing ARM binary in a user-mode emulator (unidbg, QEMU user-mode) plus a JNI stub layer and a GL ES 1.0 translator. Would run on desktop in weeks.

**Rejected because:** every existing limitation (memory leak, ARMv7 lock-in, 2-character-sheet ceiling, NOPed destructors) carries forward. We'd never own the code. iOS and web remain hard.

### Path B — Static decompilation of the `.so` into portable C++

Use Ghidra to lift the entire 1.9 MB binary into readable C++, then port it to SDL2 + modern GL. The existing offset labels in `ZombieCafeExtension.cpp` would seed the symbol table.

**Rejected because:** even in the best case, this is months of work on deeply hostile decompiler output, and the end state is a codebase that only ARM reverse engineers can maintain. Every future feature — new characters, new modes, modding, real-time friends — fights the port instead of building on it. Bit-perfect fidelity is the only advantage, and this project has already diverged from the original in deliberate ways (toxin buy swap, disabled cafe-size upgrade, server throttling), so fidelity is not a meaningful goal.

### Path C — Godot remake using the existing assets and server *(chosen)*

Rewrite the client in Godot 4. Keep the Go tooling, the server, and the assets. Use the original `.so` as reference documentation, not as runtime code.

**Chosen because:**

- **Maintainability:** idiomatic Godot code any 2D game developer can contribute to, versus decompiled C++ that has a talent pool measured in dozens of people worldwide.
- **Flexibility:** every improvement the project wants — JP character roster, new modes, modding, real-time multiplayer, modern graphics — is a normal Godot feature instead of a patch to reverse-engineered logic.
- **Platform reach:** Godot exports to all six target platforms from a single button.
- **Performance is a non-issue at this scale**, so the theoretical advantage of native C++ doesn't matter.
- **The existing Go tooling is already perfectly suited to this path.** It was written to pack/unpack game data — exactly what a Godot asset pipeline needs.

The trade-off we're accepting: we give up bit-perfect behavioral fidelity with the 2011 binary in exchange for a codebase that's still alive in 2030.

## Open questions and known risks

- **Save format v63 is not the only version.** There may be older save formats in the wild. Phase 3 needs to decide whether to support them or require a one-way upgrade.
- **The animation format is decoded but not re-packed.** We'll need to finish that work in Phase 1 or Phase 4, depending on whether Godot consumes the original atlases or a re-exported form.
- **Go ↔ Godot integration path is undecided.** Three candidates: (a) compile `file_types` to a shared library via `c-shared` buildmode and call it from GDExtension; (b) run the Go tooling as a subprocess during asset import only, and never at runtime; (c) port `file_types` to GDScript/C# and accept the maintenance duplication. Option (b) is the leading candidate because it keeps runtime and tooling concerns cleanly separated.
- **Legal posture.** The project has always operated in the reverse engineering preservation grey zone. A Godot rewrite doesn't change that, but it's worth re-reading the position stated in the README before any public release.
- **Japanese version support.** Phase 4 should decide early whether to target EN-only, JP-only, or both. Both is cheap if the rewrite is designed for it from the start, expensive if bolted on later.

## Decision log pointer

This document *is* the decision log for the Godot rewrite. Future major decisions (e.g., GDScript vs. C#, the Go ↔ Godot integration path, save format migration strategy) will be captured here as amendments with dates, not in separate files. Small decisions and exploration notes go in `docs/devlog/` instead.
