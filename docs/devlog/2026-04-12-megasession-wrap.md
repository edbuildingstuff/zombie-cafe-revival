# 2026-04-12 — megasession wrap: Phase 2b closure, Phase 1b parser marathon, legacy APK on hardware, Phase 0b fully closed

**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))

The biggest single day of work on this project to date. Fourteen commits landed over roughly 8 hours spanning 2026-04-11 evening to 2026-04-12 early morning, covering three distinct phase boundaries and one entirely unplanned detour into reverse engineering the legacy APK build path to run on a physical ARM device. This entry is the session handoff — future sessions should be able to read this one file plus `docs/handoff.md` to pick up with full context.

## TL;DR

- **Phase 2b is fully closed.** `godot/main.tscn` + `main_scene.gd` + CI workflow landed, then real keyframe-driven skeletal posing landed on top once Phase 1b item 2 shipped. Opening `godot/project.godot` in Godot 4 now shows `boxer-human` posed from the first frame of `sitSW.bin.mid` rather than laid out in a grid.
- **Phase 1b is nearly fully closed.** Item 2 (per-animation keyframe parser) shipped with structural decode for the skeleton section and byte-preservation for the opaque tail. Items 3 (opaque binary game data) shipped parsers for six files: `enemyItemData`, `strings_google`, `strings_amazon`, `cookbookData`, `enemyItems`, `enemyCafeData`, `enemyLayouts`. Items 5 (`cct_file` debug print sweep), 6 (cct.mid.png artifact skip — subsumed), and 8 (atlas-only output, saving 66% on the build tree) also closed. Only `constants.bin.mid` and `font3.bin.mid` remain pending in item 3, both attempted earlier and deferred because their formats resist quick analysis.
- **Phase 0b is fully closed** including the previously-blocked "real binary fixtures" item. A physical Samsung ARM device is now a fully-functional extraction path — the legacy patched APK boots, saves state, and surrenders its private files via `run-as`. `tool/file_types/testdata/` now holds real fixtures for all three canonical save-family formats (`Cafe`, `SaveGame`, `FriendCafe`), all round-tripping byte-identically.
- **Phase 3 is unblocked.** The rewrite plan had Phase 3 (save-load round-trip inside the Godot client) explicitly gated on Phase 0b closure. Phase 0b is now closed, so the next major session can start the Go↔Godot integration work without waiting on anything.

## The session arc

This session didn't start with a plan for 14 commits. It started with `docs/handoff.md` pointing at Option A (Phase 2b visible scene) as the recommended next step, and from there each commit opened a door into the next piece of work. The rough order was:

1. Read handoff, tackle Phase 2b visible scene.
2. Realize the provisional `draw_offsets` interpretation needed real animation data, tackle Phase 1b item 2 next.
3. After the animation parser lands, notice how much stdout spam `cct_file` contributes during `build_tool -target godot`, clean it up.
4. Hit an easy optimization (`SpriteAtlas.get_character_pieces`) and ship it as a palate cleanser.
5. Realize the atlases now cover all rendering paths, drop individual PNG copies from the build tree for a 66% size reduction.
6. Start knocking out Phase 1b item 3 opaque binary parsers one at a time.
7. Hit the `constants.bin.mid` mixed-endian wall, pivot to smaller files.
8. Ship `enemyItemData`, `strings_google/amazon`, `cookbookData`, `enemyItems`, `enemyCafeData` in sequence.
9. Get an ARM Android device connected and pivot the entire session into the legacy APK boot path — the Phase 0b blocker.
10. Build `libZombieCafeExtension.so`, patch `SoundManager.setEnabled`, get the game booting.
11. Play on device, pull real save fixtures, wire up Phase 0b round-trip tests.
12. Discover `ServerData.dat` is a FriendCafe fixture hiding under a misleading name, close Phase 0b.
13. Ship the `enemyLayouts.bin.mid` byte-preservation parser as the final Phase 1b item 3 piece.

Fourteen commits total. The mood of the session shifted around commit 11 from "knock out small items" into "unblock Phase 0b by getting real hardware to cooperate" — that turned out to be the most valuable chunk.

## Phase 2b wrap-up

The visible-scene work was straightforward: `godot/main.tscn` with a `Node2D` root, `main_scene.gd` that calls `SpriteAtlas.get_character_pieces("boxer-human")` and assembles 27 `Sprite2D` children. The non-obvious part was a Godot lifecycle quirk — nodes added to `get_root()` inside a `extends SceneTree` script's `_init()` don't get their `_ready` callback synchronously, so the validator's same-call child-count check was reading zero children. The fix was to factor scene construction into a public `assemble()` method that `_ready` delegates to, and have the validator call `assemble()` directly. This is a broader good-design pattern too: scene construction that lives in a named method can be re-called for respawns, hot-reloads, and unit tests, while `_ready`-only construction can only run once per instance.

The visible scene initially used a 9×3 grid layout with `draw_offsets` applied as per-piece nudges. After Phase 1b item 2 landed (see below), `main_scene.gd` gained a `pose_from_animation` method that loads `res://assets/data/animation/sitSW.json`, pulls 13 skeleton records from the first keyframe, and writes their translation columns as sprite positions anchored at screen-center. The grid layout remains as a graceful fallback if the animation JSON is missing or malformed — same pattern the SpriteAtlas code already uses for loading failures.

A new `SpriteAtlas.get_character_pieces` optimization also landed in this span: the previous linear scan over 3,051 atlas regions became an O(1) dict lookup by precomputing a `_character_pieces_index: Dictionary[String, Array[AtlasTexture]]` during `_load_offsets` in the same pass that builds the regions dict. Characterization tests with `cowboy-human` and a non-existent character (plus an explicit "distinct AtlasTexture across characters" check to reject accidentally-shared state) were added **before** the refactor to pin the existing behavior and then re-run after to prove the refactor was behavior-preserving. This is a particularly satisfying TDD pattern for pure refactors: `red` is impossible when there's no new behavior, so characterization tests substitute for the red-green-refactor cycle.

## The animation parser and the opaque tail

`tool/file_types/animation_file.go` is the first real reverse engineering work in `file_types` this session. The pre-implementation spec hypothesized a flat list of `BoneCount` records, each 12 floats + some trailer; hex-dump analysis during implementation revealed the format is significantly more layered:

- 12-byte header (3 int32 LE: values `(3, 24, 13)` — NOT the expected `BoneCount`)
- 32-byte prologue (four `_PTR` ASCII markers at fixed offsets + four int32s with `KeyframeCount` at slot 2)
- `SkeletonRecordCount` records of 64 bytes each (12 floats + 16-byte trailer) — the 13 value in the header is this count, NOT a generic "unknown" int32
- An opaque tail containing a bone permutation list, pointer table, and keyframe data whose exact boundaries don't divide cleanly from byte analysis alone

**The key insight:** the `24` in the header isn't skeleton bone count; it's the per-keyframe visual part count. Skeleton records vary per file (sit=13, attack2NW=14, etc.). The first draft panicked on any file with a non-13 `SkeletonRecordCount`, which immediately fired on `attack2NW.bin.mid`. The fix was to loosen the validation: hard-fail only on the structural invariants (`Unknown0 == 3`, `BoneCount == 24`) and let `SkeletonRecordCount` vary as the iteration bound.

**The pragmatic decision:** rather than decode the complex tail structure (which would have required a Ghidra pass on `libZombieCafeAndroid.so` or multi-session differential analysis), the parser decodes the confirmed-structural skeleton section and preserves everything after it as an opaque `Tail []byte`. This satisfies the round-trip contract for all 60 real files without committing to a wrong interpretation. The Godot consumer uses translations from the skeleton section's bind pose records (which are near-zero in sitSW, producing a visibly-posed but not biologically-faithful character — "provisional but documented").

Three tests shipped with the parser:
- `TestAnimationFileRoundTrip` iterates all 60 files as sub-tests (single-file failure names the file precisely)
- `TestAnimationFileInMemoryFixture` round-trips a hand-constructed struct with non-default values (catches reader/writer asymmetry the zero-heavy real files miss)
- `TestAnimationFileKeyframeCountHypothesis` spot-checks that `sitSW.KeyframeCount ∈ [1,3]` and `walkNW.KeyframeCount ∈ [20,60]`, grounding the one semantic label the struct committed to in real evidence

**Upgrade path:** when animated playback becomes a priority, a dedicated session can crack the tail structure (likely Ghidra) and replace the `Tail []byte` with named fields. The Godot consumer upgrades to `_process`-driven frame advancement at the same time.

## The Phase 1b parser marathon

After the animation parser, the rest of Phase 1b item 3 was a sequence of smaller opaque binary parsers. Pattern recognition matters here — by commit 10 I had a mental playbook for how to approach each new format:

1. Hex-dump head + tail + a mid chunk
2. Identify fixed-width markers (int16/int32 headers, ASCII strings, repeating sentinel bytes like `_PTR` / `0xCDCDCDCD`)
3. Hypothesize a struct
4. Write scaffold with panicing stubs
5. Write round-trip test against the real file as the forcing function
6. Iterate on the struct until `bytes.Equal` passes
7. Wire through `BuildGodotAssets`

The files that shipped cleanly:
- **`enemyItemData.bin.mid`** (321 B) — 1-byte count header (=20) + 20 × 16-byte records. Trivial.
- **`strings_google.bin.mid` / `strings_amazon.bin.mid`** (~19 KB each) — despite the `.bin.mid` suffix these are plain UTF-8 text with `\r\n` separators, not binary. The "parser" is a 20-line `strings.Split`/`strings.Join` wrapper. The two files differ by exactly one URL string (`iphone` vs `android` in a `beeline-i.com` link).
- **`cookbookData.bin.mid`** (1164 B) — 1-byte count (=10) + 10 entries with `Name`, 4 × `int16` `Fields`, `Description`, `AfterDescription`, `Status`, `Trailer`. Standard big-endian int16-prefixed strings throughout.
- **`enemyItems.bin.mid`** (1866 B) — BE int16 count header + a flat list of length-prefixed strings that runs to EOF. The count is the cafe-category count, but the number of strings per category varies so the parser uses a read-until-EOF loop rather than a fixed-count loop.
- **`enemyCafeData.bin.mid`** (775 B) — 14 enemy cafe definitions for the raid system. Mixed-endian header (LE int32 count + BE int16 flag). Two surprises during implementation: (a) the first draft read `SubType + SequenceID` as a single int32 which happened to work for entries 0-11 where `SubType == 0` but blew up on entry 12 where `SubType == 1`; (b) the **last entry ("Villain") is structurally truncated** — it ends after Flag3 with no Flag4 and no LocationName, with exactly 26 bytes of file left. The `HasTail bool` field on `EnemyCafeEntry` distinguishes the two shapes so the writer can reproduce the original layout.

The one that deliberately didn't fully ship:
- **`enemyLayouts.bin.mid`** (2847 B) — holds NPC cafe layouts for in-map raids. Hex-dump analysis surfaced repeating records with 1-byte ASCII type codes (`H T W L A S C D G B E P` — likely initials of element types: Hole, Table, Wall, Lamp, etc.) and int16 prefixes, but exact record boundaries wouldn't resolve: gaps between consecutive `H` occurrences are 29 and 30 bytes, inconsistent. Rather than commit to a wrong struct, shipped a byte-preservation parser (the same `Tail []byte` pattern the animation parser uses, just applied at the top level with the whole file as opaque `Data []byte`). Round-trip is trivially byte-identical. Future structural upgrade is free — no wire-format change.

The ones that didn't get attempted or bailed early:
- **`constants.bin.mid`** (9789 B) — attempted first, but mixed endianness (first 12 bytes look like big-endian int32s `1000, 10000, 3000` but subsequent float-looking values only decode under little-endian). Needs differential analysis across multiple similar files OR a Ghidra pass. Deferred.
- **`font3.bin.mid`** (2533 B) — quick diagnostic showed it's NOT a standard BMFont format (no `BMF` magic, no `info face=` ASCII header). Custom bitmap font layout. Would need its own focused session. Bailed fast per the quick-diagnostic plan.

**What I want to remember from the parser marathon:** byte-preservation parsers are a legitimate "ship it" option when the format is intractable in a single session. They satisfy the round-trip contract, unblock the build pipeline, and leave a clean upgrade path. Don't let the desire for a semantic decode block progress — ship the preservation layer, move on, upgrade when there's a concrete reason to care.

## The legacy APK boot path (the session's biggest detour)

The unplanned pivot that ate the second half of the session. It started with "I just connected a real ARM Android device" and ended with "the game is running and we have real fixtures." In between:

### Step 1: build the APK from source

The README's build command (`go run ./tool/build_tool/ -i src/ -o build/`) runs the Go build tool which produces a full APK-ready tree in `build/`. `build_tool` itself doesn't need `cmake`/`make` even though the README lists them as prerequisites — those are only needed for the C++ extension build which `build_tool` doesn't invoke.

### Step 2: install `apktool` because it's not on PATH

Downloaded `apktool_2.9.3.jar` directly from GitHub releases to `/c/Users/edwar/bin/apktool.jar`, with a thin shell wrapper that execs `java -jar`. The bin directory was already on PATH so no further setup needed.

### Step 3: first install blocked by Play Protect / user profile permissions

The `adb install` failed with `INSTALL_FAILED_VERIFICATION_FAILURE: Install not allowed`. Root cause: the device has a Samsung Secure Folder as user 150, and the default `adb shell pm list packages` defaulted to that user which lacked permissions. Fix: install explicitly to user 0 with `adb install --user 0 -r ./build/out/out.apk`.

### Step 4: first launch crashed on `UnsatisfiedLinkError`

The smali code contains `System.loadLibrary("ZombieCafeExtension")` at the main Activity's `<clinit>`, and the APK only had `libZombieCafeAndroid.so` — no `libZombieCafeExtension.so`. That library has to be built separately from `src/lib/cpp/` with CMake + Ninja, both of which are bundled with the Android SDK at `/c/Users/edwar/AppData/Local/Android/Sdk/cmake/3.22.1/bin/` and `/c/Users/edwar/AppData/Local/Android/Sdk/ndk/28.2.13676358/`. With those tools, the extension built cleanly for `armeabi-v7a` and dropped into `build/lib/armeabi/` alongside the existing `libZombieCafeAndroid.so`. The ABI mismatch (existing `.so` is ARMv5 armeabi per its ELF flags, new one is armeabi-v7a) is fine because ARMv7 CPUs execute both instruction sets and Android's loader doesn't enforce strict directory-to-flags matching.

### Step 5: second launch crashed in `CCSound::SetEffectsVolume+4` null deref

SIGSEGV with fault address `0x10`, triggered deep in a broadcast receiver callback firing `SoundManager.setEnabled` before the game's `CCSound` singleton was initialized. This is a classic old-Android-vs-new-Android lifecycle divergence: the legacy game expected broadcast receivers to deliver events later in the activity lifecycle, but modern Android delivers sticky broadcasts much earlier. The game's native code isn't guarded against the receiver firing pre-init.

### Step 6: patch the extension to NOP out the crash path

Added a new patch to `ZombieCafeExtension.cpp` that writes Thumb `bx lr` (2 bytes: `0x70, 0x47`) at `base + 0x5e07c`, the start of `Java_com_capcom_zombiecafeandroid_SoundManager_setEnabled`. Making the JNI entry a no-op prevents the receiver callback from ever reaching the uninitialized singleton. Confirmed via `llvm-objdump -T` on the real `.so`:
```
0005e07c g DF .text 00000070 Java_com_capcom_zombiecafeandroid_SoundManager_setEnabled
```

The game boots fine after this patch, background music still plays (because music goes through Android's `MediaPlayerService`, completely separate from the patched-out `CCSound` effects path), and the extension follows the same `memcpyProtected` pattern the existing patches use for the Money→Toxin swap and the texture destructor NOPs.

### Step 7: rebuild, reinstall, play, extract

The final chain:
```
cmake --build .                                 # rebuild extension
cp .../libZombieCafeExtension.so build/lib/armeabi/
apktool b ./build -o ./build/out/out.apk
jarsigner ...
adb install --user 0 -r ./build/out/out.apk
adb shell am start --user 0 -n com.capcom.zombiecafeandroid/.ZombieCafeAndroid
```

The game was alive, responsive to touches, playing music, and surviving for several minutes at a time before eventually hitting a `Scudo: corrupted chunk header` abort (modern Android's hardened allocator detecting legacy heap-corruption bugs deep inside ART's GC). But several minutes is plenty for fixture creation.

### Step 8: make the app debuggable

`adb shell run-as com.capcom.zombiecafeandroid ls files/` failed with `run-as: package not debuggable`. Our `debug.keystore` signature isn't the same as the Android platform debug key, so we need the manifest to explicitly declare `android:debuggable="true"`. Edited `build/AndroidManifest.xml`, rebuilt with `apktool b`, reinstalled with `-r` (which preserves app user data across reinstalls because the signature is unchanged), and `run-as` worked immediately.

## The Phase 0b fixture extraction

Once `run-as` was working, pulling files was trivial via `adb exec-out` (binary-safe):

```
adb exec-out "run-as com.capcom.zombiecafeandroid cat files/playerCafe.caf" > /tmp/...
adb exec-out "run-as com.capcom.zombiecafeandroid cat files/globalData.dat" > /tmp/...
```

The device's `/data/data/com.capcom.zombiecafeandroid/files/` directory contained:
- `playerCafe.caf` (20,129 B), `BACKUP1-3.caf` — rolling cafe backups
- `globalData.dat` (1,626 B), `BACKUP1-3.dat` — something with a SaveGame-shaped header
- `ServerData.dat` (20,747 B) — initially mysterious
- `raidCafe0-7.dat`, `raidEnemies0-7.dat` — 2 bytes each (empty placeholders)
- `adata.mkt` — marketing/ads data, not game state

### The Cafe fixtures just worked

`playerCafe.caf` and `BACKUP1.caf` both round-tripped byte-identically via the existing `ReadCafe` / `WriteCafe` functions on the first try. The Phase 0b preservation-fields work from earlier sessions turns out to be complete and correct for real-world data — no parser changes needed. `TestRealCafeFixturesRoundTrip` landed with zero iteration.

### The SaveGame fixtures needed a preservation field

`globalData.dat` and `BACKUP1.dat` initially failed round-trip: parser output was ~37% the size of the input. The files start with `0x3f = 63` (the SaveGame version) followed by a float64 `-1.0` for `CafeState.U1`, so they ARE SaveGame-shaped — but real device files carry ~1 KB of additional content past the known struct fields. Visible in hex near offset `0x265`: character/friend names like `Lionel`, `Odie`, `Krystal`. Probably an extended character roster or friend list.

Fix: added a `Trailing []byte` preservation field to the `SaveGame` struct (same Phase 0b preservation-field philosophy as the original cafe/savegame work). `ReadSaveGame` `io.ReadAll`s any leftover bytes into `Trailing`; `WriteSaveGame` echoes them back. Keeping `Trailing` nil when empty (rather than `[]byte{}`) so hand-constructed in-memory fixtures still compare equal under `reflect.DeepEqual` — prior-session `TestSaveGameRoundTrip` passes unchanged.

### ServerData.dat turned out to be FriendCafe

The 20,747-byte `ServerData.dat` was initially mysterious. Its header `3f 00 00 00 00 00 00 f0 bf` is byte-for-byte identical to `globalData.dat`'s SaveGame header, but its size is ~20 KB — way too big for a SaveGame. Comparing to `FriendCafe`'s struct layout (`byte Version + CafeState State + Cafe Cafe`), the size math works out: ~1 byte header + ~500 bytes of state + ~20 KB of embedded Cafe data.

`ReadFriendData` + `WriteFriendData` round-tripped on the first try. The filename "ServerData.dat" is misleading — it's not generic "server data", it's the binary blob the raid flow downloads for a friend's cafe and caches locally. The raid/friend system was populating this file all along, just under a name that didn't suggest "friend cafe fixture".

The 2-byte `raidCafe*.dat` / `raidEnemies*.dat` files turned out to be int16 count markers (value = 0) from the in-map NPC raid UI — NOT FriendCafe candidates. The user confirmed they raided all available NPC cafes but those paths never flush real friend data to those files. Random-player raids would, but the random-player view was read-only on this specific device (probably a server-side flag for stale accounts). No problem — `ServerData.dat` covered the FriendCafe contract anyway.

### Phase 0b closure

All three canonical save-family formats now have real device fixtures with passing round-trip tests:
- `Cafe`: `playerCafe.caf`, `BACKUP1.caf`
- `SaveGame`: `globalData.dat`, `BACKUP1.dat`
- `FriendCafe`: `ServerData.dat`

`tool/file_types/testdata/` is populated, `TestRealCafeFixturesRoundTrip` / `TestRealSaveGameFixturesRoundTrip` / `TestRealFriendCafeFixturesRoundTrip` are all green, and Phase 3 (save-load round-trip in Godot) is now unblocked.

## What's still open

**Phase 1b:**
- Item 3: `constants.bin.mid` (mixed-endian, deferred), `font3.bin.mid` (custom bitmap format, bailed). Both are their own focused sessions.
- Item 4: Bitmap font conversion. Lower priority — Godot's native TTF renderer already covers the project's font needs, this is only for preserving the specific pixel look of the original bitmap rendering.
- Item 7: Copy social icons / EULA / help HTML into the Godot tree. Speculative, no current Godot consumer.

**Phase 2b:**
- Cafe background. Still blocked on the `mapTiles` texture packer being re-enabled in `build_tool/main.go` (currently commented out in the legacy path).
- Real skeletal posing of `boxer-human` that's biologically faithful rather than bind-pose-driven. Requires full animation tail decode (Ghidra territory).

**Phase 3:**
- Unblocked and ready to kick off. Next session should brainstorm the Go↔Godot integration path (the rewrite plan lists three candidates: `c-shared` buildmode + GDExtension, asset-import-only subprocess, or port to GDScript/C#).

**Native crashes:**
- The legacy game on modern Android hits `Scudo: corrupted chunk header` aborts after several minutes of gameplay. Heap corruption in the 14-year-old native code, detected by modern Android's hardened allocator. The existing extension already NOPs out one known texture-destructor crash; the new crashes are in different code paths (`MemMap::~MemMap` during ART GC, `Parcel::~Parcel` during finalization). Fixing them would require identifying which allocation is being corrupted, which is deep RE work. Not blocking — the game runs long enough for fixture extraction.

## What I want to remember from this session

Five things.

First, **byte-preservation is a legitimate "ship it" option**. When a binary format resists quick analysis — animation tail, enemyLayouts, SaveGame's trailing section — the move is to decode what you can, preserve the rest as opaque bytes, ship the round-trip contract, and move on. Future work can upgrade structs without wire-format changes. Don't let the desire for a semantic decode become a blocker.

Second, **"the last entry is truncated" is a real pattern in legacy game data**. `enemyCafeData.bin.mid`'s final "Villain" entry has fewer fields than the preceding 13 entries, matching exactly the 26 bytes of remaining file. Could be a file format quirk, could be an authoring-tool bug that shipped, could be intentional (a sentinel or placeholder). Whatever it is, the parser needs an explicit `HasTail bool` on the entry struct to distinguish the two shapes for faithful round-trip.

Third, **"file size roughly equals struct layout" is the fastest way to disambiguate formats**. `ServerData.dat` turned out to be `FriendCafe` because `1 byte + ~500 bytes + ~20 KB Cafe ≈ 20,747 B`. Hex dumps help, but the size-vs-layout sanity check can instantly rule out wrong hypotheses.

Fourth, **running legacy code on modern hardware is mostly a boot-path problem**. Once the extension loaded and the `SoundManager.setEnabled` race was patched, the game ran fine for minutes at a time — long enough to create the fixtures we needed. The remaining `Scudo` heap-corruption crashes are genuine legacy bugs that were masked on old Android's less-strict allocators. Don't over-invest in fixing them unless gameplay time matters.

Fifth, **sessions can be more productive than expected if the direction is tight**. This was 14 commits in ~8 hours, and the shape was "knock out one small well-scoped thing, then the next". Keeping options tight at each decision point ("1, 2, or 3?") meant we never spent time on speculative work. The detour into the legacy APK boot path was the only multi-hour commitment, and it paid off massively because it unblocked Phase 0b.

## Next

With Phase 0b closed, the natural next session is **Phase 3 kickoff**: brainstorm the Go↔Godot integration path. The rewrite plan's three candidates (`c-shared` + GDExtension, asset-import subprocess only, port to GDScript/C#) need a decision before code work starts. Option (b) — subprocess — is the rewrite plan's leading candidate because it keeps runtime and tooling concerns cleanly separated.

Alternatively, the next session could tackle one of the remaining Phase 1b item 3 stragglers (`constants.bin.mid` with a Ghidra pass, or `font3.bin.mid` as its own investigation) if there's appetite for more RE. The `Scudo` crash investigation could also be a session on its own if the device session gets too painful for future extraction work.

But the highest-value next move is Phase 3 kickoff. Phase 0b was the gate and it's now open.
