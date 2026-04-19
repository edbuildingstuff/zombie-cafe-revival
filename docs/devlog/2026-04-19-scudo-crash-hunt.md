# 2026-04-19 — Scudo crash hunt

Phase-0-plus session. Started with the goal of eliminating the `Scudo: corrupted chunk header` aborts that were making repeated device sessions painful (Option C from the 2026-04-12 handoff). Ended with a root-cause fix shipped into `src/lib/cpp/ZombieCafeExtension.cpp`, pending one last validation round.

---

## The handoff's attribution was wrong

The 2026-04-12 handoff said the crashes lived in `MemMap::~MemMap` (ART GC) and `Parcel::~Parcel` (framework IPC), guessed from partial evidence. Today's first job was reproducing — the user triggered a crash during raid while I was connected via `adb`.

An `adb bugreport` preserved **32 tombstones** from 2026-04-13 through today. (Samsung's dropbox rotates tombstone content within a few hours — the timestamps survive as `(contents lost)`, the stacks do not. `adb bugreport` reads `/data/tombstones/*` directly and is the only reliable capture mechanism.)

Thread-class distribution: HeapTaskDaemon 13, FinalizerDaemon 6, ReferenceQueueDaemon 5, GLThread 32 5, mali-cmar-backe 1, other 2. Every one ended in `scudo_free → Chunk::loadHeader → reportHeaderCorruption → abort`. Only the 5 GLThread tombstones caught the game itself mid-corruption; the other 27 were system threads tripping over neighbor chunks the game had clobbered earlier (ART GC sweeping large Java objects, Finalizer freeing conscrypt SSL buffers, ReferenceQueue freeing ICU regex patterns, Mali driver freeing sync objects, etc.). `MemMap` and `Parcel` were downstream symptoms, not the bug sites.

The five GLThread stacks collapsed to three distinct `libZombieCafeAndroid.so` sites:

| Site | RVA | Trigger |
|---|---|---|
| `Cafe::~Cafe()+300` | `+0x679e4` | `GameStateCafe::uninit` during cafe transitions |
| `PathTween::~PathTween()+30` → reached via `MoveTask::~MoveTask()+26` | `+0x149c56` / `+0xe0a02` | customer pathfind completion |
| `javaStartEffect+50` → `_JNIEnv::CallStaticBooleanMethod+20` | `+0x17e186` / `+0x17cccd` | sound effect in `GameStateRaid::tick` (3 of 5) |

Saved as memory `project_crash_sites_from_tombstones.md` and full crash corpus archived under `.claude/crash_logs_2026-04-19/` (not committed, ~80 MB).

---

## Plan A: NOP the three manifestation sites

Theory: symptom-patch every site where Scudo trips, empirically test whether the sites were planting the corruption or just catching it.

Patched `Cafe::~Cafe+300` (`bl operator delete` at `+0x679e4`, 4-byte NOP), `PathTween::~PathTween+30` (`bl operator delete` at `+0x149c56`, 4-byte NOP), `MoveTask::~MoveTask+26` (`blx r3` at `+0xe0a02`, 2-byte NOP). Same pattern as Airyz's existing texture-destructor NOPs.

**Result: crash at 353s uptime, `HeapTaskDaemon` / `MemMap::~MemMap` / `LargeObjectSpace::Free` — zero game frames.** The three NOPs killed their respective GLThread paths (5 tombstones' worth, ~16% of the corpus) but the upstream heap overwrite was still being planted somewhere else and still tripping GC-collateral trips on 27+ other tombstones.

Kept the three NOPs as defense in depth. They're harmless now that the real bug is found.

---

## Plan B: GWP-ASan

Needed per-allocation provenance to find the overwrite source. Android's GWP-ASan samples allocations onto guarded pages and produces enhanced tombstones with allocation/deallocation call stacks when a bad access hits a guard.

### First attempt failed silently

Set `libc.debug.gwp_asan.sample_rate.com.capcom.zombiecafeandroid=1000`, `process_sampling=1`, `max_allocs=40000`. `getprop` read them back. Game crashed; no `Cause: [GWP-ASan]:` section in the tombstone.

**Turns out Samsung user builds silently refuse GWP-ASan via setprop-only.** The `libc.debug.gwp_asan.*` namespace only takes effect if the app is also `android:debuggable="true"` OR has `android:gwpAsanMode="always"` set in the manifest. Not documented prominently anywhere.

### Second attempt: manifest opt-in + debuggable

Added `android:gwpAsanMode="always"` and `android:debuggable="true"` to the manifest, rebuilt. Verified GWP-ASan was actually mapped in-process:

```
adb shell run-as com.capcom.zombiecafeandroid cat /proc/$PID/maps | grep GWP-ASan
```

showed the signature `[anon:GWP-ASan Guard Page]` / `[anon:GWP-ASan Alive Slot]` page pairs. Good.

### Tuning sample rate

Default 2500, ramped to 50 (25× tighter), then 10. At `sample_rate=10` GWP-ASan hit:

```
Cause: [GWP-ASan]: Buffer Overflow, 0 bytes right of a 32-byte allocation at 0xb7c70fe0
#00 pc 0017f31a  libZombieCafeAndroid.so (javaMD5String+102)
#01 pc 0018b0c5  libZombieCafeAndroid.so (CCMd5+8)
#02 pc 0018b1f3  libZombieCafeAndroid.so (CCServer::SaveMyGameState+286)
#03 pc 0012ee05  libZombieCafeAndroid.so (ZombieCafe::saveGameState+592)
#04 pc 0009fa09  libZombieCafeAndroid.so (GameStateCafe::uninit+1376)
```

Caveat: at `sample_rate=10` GWP-ASan occasionally self-aborts with `Failed to allocate in guarded pool allocator memory` when Mali's memory-purge thread churns too many frees. Safe range is 50-500; rate=10 only briefly for targeted hunting.

---

## Bug 2: `javaMD5String+102` off-by-one null terminator

Disassembly of `javaMD5String` revealed the textbook mistake:

```asm
17f2fc: blx   .plt+0x17c         ; operator new[](length)   — length from GetStringUTFLength = 32
17f300: adds  r4, r0, #0          ; r4 = buf, 32 bytes
...
17f314: blx   r7                  ; GetStringUTFRegion copies 32 chars into buf[0..31]
17f316: movs  r2, #0              ; null byte
17f318: movs  r3, #0x20           ; offset 32
17f31a: strb  r2, [r4, r3]        ; buf[32] = 0   ← OOB by 1 byte
17f31c: add   sp, #0x14
```

Classic bug: allocates exactly the string length, then writes a C-string null terminator one byte past the end. Every call clobbers one byte of whatever Scudo chunk happens to sit immediately after the buffer. Because `GameStateCafe::uninit` runs a save on every cafe transition (map-tap, raid-entry, raid-exit) the OOB accumulates into scattered one-byte corruption across unrelated chunks. All the thread-class variance in the original 32-tombstone corpus was GC, finalizers, and drivers tripping over chunks the game had clobbered hours earlier.

### Fix iteration 1: NOP the `strb` at `+0x17f31a`

Killed the OOB cleanly. But downstream `CCUrlConnection::NewRequest` does strlen-based concat on the MD5 buffer to build the save URL, and with no null terminator `strlen` reads past the buffer into heap garbage until it finds a zero. Bytes like `0x81` poison the URL — CheckJNI (on in debuggable builds) aborts in `NewStringUTF` with "illegal start byte 0x81"; release builds would silently pass the garbage through and cascade into conscrypt/SSL finalizer Scudo trips.

**The CheckJNI abort message contains the actual offending URL string** including hex-dumped garbage, which is how I knew exactly what the downstream path was doing. Extremely useful diagnostic when it triggers.

### Fix iteration 2: 1-byte offset patch at `+0x17f318`

Kept the `strb` instruction, changed the offset constant:

```
movs r3, #0x20    ; encoding 0x2320, byte0=0x20
  →
movs r3, #0x1F    ; encoding 0x231F, byte0=0x1F
```

One byte flipped at `+0x17f318` (`20 23` → `1F 23`). Null terminator now lands at `buf[31]` in-bounds; the last hex character of the MD5 gets overwritten with `\0`; `strlen` returns 31; URL is clean ASCII. Server's hash validation rejects the truncated hash, but Airyz's backend drops 90% of saves anyway and the game never reads the hash back. No behaviour change worth caring about.

### Runtime verification

For the first time this session, I verified the patch actually landed in memory rather than trusting the `memcpyProtected` return value:

```
PID=$(adb shell pidof com.capcom.zombiecafeandroid)
# Find the mapping containing file offset 0x17f318 in maps; here it was the
# rwxp segment covering file offsets 0x17e000-0x180000 at VA d960b000-d960d000,
# so runtime VA = 0xd960b000 + (0x17f318 - 0x17e000) = 0xd960c318.
adb shell "run-as com.capcom.zombiecafeandroid dd if=/proc/$PID/mem bs=1 skip=3646997272 count=8 2>/dev/null | od -An -tx1"
# → 00 22 1f 23 e2 54 05 b0
#    movs r2,#0 | movs r3,#0x1F | strb r2,[r4,r3] | add sp,#0x14
```

That's the exact three-instruction sequence we wanted.

---

## Bug 2 sibling: `javaMD5Data+126`

After the `javaMD5String` fix the GC-collateral crashes **kept coming** with the same pattern. Either the fix wasn't live (ruled out by the runtime read above) or another function had the same bug.

Static scan — every symbol matching `java[A-Z]*` in `libZombieCafeAndroid.so` disassembled, grepped for the instruction pair `movs r3, #0x20 ; strb r2, [r4, r3]`:

```
llvm-objdump -T libZombieCafeAndroid.so | awk '/ java[A-Z]/{...}' | while read sym; do
  llvm-objdump -d --start-address=$(...) --stop-address=$(...) \
    --triple=thumbv7-linux-androideabi libZombieCafeAndroid.so \
  | grep -E 'movs\s+r3, #0x20|strb\s+r2, \[r4, r3\]'
done
```

Exactly two hits: `javaMD5String+102` (already patched) and **`javaMD5Data+126` at `+0x17f7de`**. `javaMD5Data` is the binary-data variant — called by the 4-arg overload `CCMd5(out, 32, bytes, len)` (at `0x18b0a4`) used for hashing raw byte sequences rather than null-terminated strings. Same 32-byte buffer, same gratuitous null-terminator-past-the-end, just a different JNI entrypoint.

Applied the same 1-byte `1F 23` patch. Installed at 23:43:22.

**This install is not yet validated.** Session wrap happened before a retest cycle. See "pending" below.

---

## Bug 1 (separate): SoundManager → MediaPlayer.release ref-count trip

During the javaMD5String hunt, an unrelated crash broke through the JNI barrier and gave us the Java side of the stack:

```
#06 scudo_free
#07 android::RefBase::decStrong+68
#08 android::sp<MediaPlayerListener>::operator=+106
#09 android::MediaPlayer::setListener+42
#10 android_media_MediaPlayer_release+66
#12 android.media.MediaPlayer.release+404
#13 com.capcom.zombiecafeandroid.SoundManager.playSound+312
#14 com.capcom.zombiecafeandroid.CC_Android.fromNative_startEffect+126
#22 _JNIEnv::CallStaticBooleanMethod+20
#23 javaStartEffect+50
#27 ZombieCafe::playEffect
#28 CharacterInstance::groan+52
#29 GameStateRaid::tick+1734
```

`SoundManager.playSound` is the game's Java SFX code. It calls `MediaPlayer.release()` whose `setListener(null)` drops the last `sp<MediaPlayerListener>` strong ref; `RefBase::decStrong` triggers `delete` on a listener whose chunk header is in a bad state. This is what was causing the ~7-min mid-raid crashes: every zombie groan / attack / damage SFX hit this path.

This was also the 3 of 5 GLThread tombstones in the original corpus that had `javaStartEffect` in their stack — the tombstones were just truncated before reaching Java.

Fix: 4-byte NOP over the `bl CallStaticBooleanMethod` at `+0x17e186` (javaStartEffect+50). The native sound-effect path now returns without invoking the buggy Java method. Side effect: character SFX are silent; background music is on a separate path and still plays. Same tradeoff `SoundManager.setEnabled → bx lr` already made for the bootup audio race.

User confirmed after: "during the raid there are no more sound effects from the characters" — yes, that's expected.

---

## Current extension patch list (end of session)

Order matters for readability; all live simultaneously in `src/lib/cpp/ZombieCafeExtension.cpp`:

1. **Airyz originals** — server URL redirects (ZCR info, updater, x, zca endpoints); texture destructor NOPs at `+0x9dee8`, `+0x13d530/550/9e8/9ee`, `+0x13d3ae/b4`; money → toxin button swap at `+0xab018`.
2. **Prior session** — `SoundManager.setEnabled` JNI entry → `bx lr` at `+0x5e07c` (dodges boot-time audio receiver null-deref).
3. **Plan A defensive NOPs (today, redundant but harmless)** — `Cafe::~Cafe+300` at `+0x679e4`, `PathTween::~PathTween+30` at `+0x149c56`, `MoveTask::~MoveTask+26` at `+0xe0a02`. These would only fire if `javaMD5*` corruption reached their specific destructors; with MD5 fixed they never will. Leaving as belt-and-suspenders; delete if you prefer clean diffs.
4. **Bug 1 (today)** — `javaStartEffect+50` NOP (4 bytes) at `+0x17e186`. Silent SFX, no crash.
5. **Bug 2 (today)** — `javaMD5String+100` 1-byte offset patch at `+0x17f318` (`20 23` → `1F 23`).
6. **Bug 2 sibling (today, unvalidated)** — `javaMD5Data+124` 1-byte offset patch at `+0x17f7de` (same encoding change).

Manifest changes:
- `android:gwpAsanMode="always"` — currently in manifest for diagnostics. Safe to remove for final builds; harmless to keep.
- `android:debuggable="true"` — currently in. Required for GWP-ASan activation on Samsung user builds and for `run-as` access to `/proc/$PID/*`. Removing it breaks the verification workflow. Recommend keeping until the rewrite obsoletes the legacy APK entirely; it's not a shipping binary.

Live setprops on the device (will be cleared on reboot):
- `libc.debug.gwp_asan.sample_rate.com.capcom.zombiecafeandroid=100`
- `libc.debug.gwp_asan.process_sampling.com.capcom.zombiecafeandroid=1`
- `libc.debug.gwp_asan.max_allocs.com.capcom.zombiecafeandroid=10000`

---

## Pending for next session

1. **Validate the 23:43:22 build.** User hasn't test-played the build with the `javaMD5Data` sibling fix. Expected result: no more `Scudo: corrupted chunk header` crashes in any thread class. Raid, map-tap, cafe transitions, multi-hour session — should all be clean. If similar GC-collateral pattern returns, there's a Bug #5 and the static signature scan needs widening (or we accept a malloc-instrumentation shim is needed).
2. **Once validated, decide the final build shape.** Options to tidy:
   - Remove the three Plan A defensive NOPs (empirically unnecessary).
   - Remove `gwpAsanMode="always"` from manifest (diagnostics only).
   - Keep `debuggable="true"` (required for verification + fixture extraction).
3. **Commit the `ZombieCafeExtension.cpp` changes.** The file has been rebuilt many times today locally; it's still uncommitted. One grouped commit covering: Plan A NOPs, `javaStartEffect` NOP, both `javaMD5*` offset patches, the inline comment documentation. Manifest changes in a separate concern — `debuggable=true` + `gwpAsanMode=always` should probably be its own commit because it affects the reproducibility of every future build.
4. **Update `project_crash_sites_from_tombstones.md`** (memory) if the 23:43:22 build reveals a fifth bug — it already has the `javaMD5Data` finding and the debugging-workflow lessons captured.

---

## Workflow lessons (captured so we don't re-derive)

- **Tombstone capture:** `adb bugreport` reads `/data/tombstones/*` directly. Samsung dropbox rotates content within hours; `dumpsys dropbox --print` will show entries as `(contents lost)` almost immediately. The timestamps are still useful as an index of when crashes happened — the content is not.
- **GWP-ASan on Samsung user builds:** requires `android:debuggable="true"`. `gwpAsanMode="always"` + `libc.debug.gwp_asan.*` setprop alone is silently ignored. Verify live with `run-as cat /proc/$PID/maps | grep GWP-ASan` — if you don't see `[anon:GWP-ASan Guard Page]` / `[anon:GWP-ASan Alive Slot]` pairs, it's not actually running.
- **Sample rate tuning:** default 2500 is too coarse for rare-allocation bugs; 50–500 is safe; 10 is aggressive and will occasionally self-abort on GPU-heavy workloads (Mali's memory purger churns the pool).
- **Runtime patch verification:** `adb shell run-as PKG dd if=/proc/$PID/mem bs=1 skip=$VA count=N | od -An -tx1`. Compute `$VA` from the `r-xp` / `rwxp` mapping whose file-offset range contains your target file offset; the library is split into multiple segments when text relocations force per-page rwx mappings. Trusting `memcpyProtected`'s return value silently is a footgun — verify.
- **Off-by-one hunting:** when GWP-ASan catches one site, grep the binary for the same instruction signature. Sibling bugs are common — `javaMD5String` and `javaMD5Data` share the same code-gen pattern, and one fix alone was insufficient because callers split across the two.
- **CheckJNI abort messages are gold:** they dump the exact offending string with a hex tail. If you ever see `JNI DETECTED ERROR IN APPLICATION: input is not valid Modified UTF-8`, read the `string:` and `input:` fields carefully — they frequently reveal adjacent heap content.
