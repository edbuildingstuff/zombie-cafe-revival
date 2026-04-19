# Session Handoff — Zombie Cafe Revival

**Last updated:** 2026-04-19 (after the Scudo crash hunt; previous: 2026-04-12 IAP bypass)
**Purpose:** quick orientation for a fresh session. Self-contained; read this plus `docs/devlog/2026-04-19-scudo-crash-hunt.md`, `docs/devlog/2026-04-12-megasession-wrap.md`, and `docs/rewrite-plan.md` and you should be able to continue without re-reading the full devlog history.

---

## The project in one paragraph

**Zombie Cafe Revival** is a reverse engineering + rewrite project for Capcom's 2011 mobile game *Zombie Cafe*. Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff)) is continuing from Airyz's original Android APK patching work (see `README.md`) by rewriting the client as a **Godot 4 game** that reuses the existing Go asset pipeline and the Cloudflare Workers backend. The Go tooling decodes/encodes every binary format the game uses; the Godot client will render and simulate on top of that. Goal is cross-platform (Windows/Mac/Linux/Android/iOS/web) via Godot's export targets. The original ARMv7 `libZombieCafeAndroid.so` is used only as reference documentation, not as runtime code.

---

## Where we are

Eleven devlog entries from 2026-04-11 plus one megasession entry from 2026-04-12 (`docs/devlog/2026-04-12-megasession-wrap.md`) which captures 14 commits across three phase boundaries. Tracked in `docs/rewrite-plan.md` with checklist substeps. Short summary:

- **Phase 0a (done):** file_types validation harness. Round-trip tests for every format passing.
- **Phase 0b (done, including real fixtures):** lossless parsers and symmetric writers for every binary format. **Real device fixtures now live under `tool/file_types/testdata/`** — `playerCafe.caf` + `BACKUP1.caf` (Cafe), `globalData.dat` + `BACKUP1.dat` (SaveGame, with a new `Trailing []byte` preservation field), `ServerData.dat` (FriendCafe). All round-trip byte-identically. Extraction path is a physical ARM Samsung device via `adb shell run-as com.capcom.zombiecafeandroid`, requires rebuilding the APK with `android:debuggable="true"` and installing to user 0 to bypass Samsung Secure Folder permissions.
- **Phase 1a (done):** `-target godot` flag on `build_tool`.
- **Phase 1b (almost fully done):** atlas packing, animation parser (skeleton section decoded, opaque tail preserved), six opaque binary parsers (`enemyItemData`, `strings_google`, `strings_amazon`, `cookbookData`, `enemyItems`, `enemyCafeData`, `enemyLayouts`), `cct_file` debug print sweep, atlas-only output (66% size reduction). Still pending: `constants.bin.mid` (mixed endian), `font3.bin.mid` (custom bitmap format). Bitmap font conversion (item 4) and social icon copy (item 7) also pending but low-priority.
- **Phase 1 validation (done):** 15/15 validation checks passing via `godot/validate_assets.gd` + GitHub Actions CI.
- **Phase 2a (done):** `SpriteAtlas` with O(1) per-character piece lookup via precomputed index (was linear scan of 3,051 regions, now a single dict lookup).
- **Phase 2b (done):** `godot/main.tscn` + `main_scene.gd` + the pose function that reads `sitSW.json` and positions 13 bone-backed Sprite2Ds from real keyframe data. Open `godot/project.godot` in Godot 4 → Run → shows boxer-human posed. Cafe background still pending (blocked on mapTiles packer re-enablement).
- **Phase 3 (unblocked, not started):** save-load round-trip inside the Godot client. Was gated on Phase 0b closure; now possible.

**Legacy APK on hardware is believed stable** (validation pending — see "What to do next"). The 2026-04-19 session tracked down the `Scudo: corrupted chunk header` crashes that had been firing every few minutes. Root cause turned out to be two sibling off-by-one bugs in the game's JNI MD5 wrappers: `javaMD5String+102` (`+0x17f31a` strb) and `javaMD5Data+126` (`+0x17f7de` strb). Both allocate `new char[32]` for the MD5 hex output, fill 32 bytes via `GetStringUTFRegion`, then write a C-string null terminator at offset 32 — one byte past the end. Since `GameStateCafe::uninit` runs a save on every cafe transition, the OOB accumulated into scattered one-byte corruption of unrelated chunks, which the GC/finalizer/driver threads then tripped over at free time. Fix is a 1-byte patch at each site flipping `movs r3, #0x20` → `movs r3, #0x1F` so the terminator lands at `buf[31]` in-bounds; last hex char of the MD5 becomes `\0`, server's hash validation rejects the truncated hash, but Airyz's backend already drops 90% of saves and the game never reads the hash back. A separate Bug 1 (`SoundManager.playSound → MediaPlayer.release → RefBase::decStrong → scudo_free` on every character SFX) was also fixed by NOPing `javaStartEffect+50` at `+0x17e186`; character SFX are now silent but background music still plays. See `docs/devlog/2026-04-19-scudo-crash-hunt.md` for the full diagnostic trail, including the GWP-ASan setup that caught Bug 2, the runtime-memory verification workflow, and the static scan that found the `javaMD5Data` sibling.

**Legacy APK toxin IAP is bypassed for unlimited late-game access.** `src/smali/com/capcom/billing/SmurfsBilling.smali` has been patched so that any triggered-by-low-toxin slot pick fakes a successful purchase — `onCreate` reads the `ItemName0` Intent extra, calls `ZombieCafeAndroid.boughtToxin(productID)` to fire the normal success callback path (which credits toxin via `PurchaseAndroidToxin`), and immediately `finish()`s. `doFinish` and `onDestroy` are also null-safe-ified since the `BillingService` fields they normally touch are no longer initialized. `ZombieCafeAndroid.BuyToxin` is unchanged so the full startActivity → onPause → Activity → onResume cycle fires cleanly and the native game's "waiting for purchase" dim state clears on its own. The HUD toxin icon ("store page" entry point) still does nothing — confirmed via smali probe instrumentation that the native `BUTTON_ADDTOXIN` handler is pure native code with zero JNI calls, so Java patching can't fix that path; future work there requires Ghidra on `libZombieCafeAndroid.so`. See `docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md` for the full design, Findings section, and follow-up notes.

**Nothing is broken.** Full workspace builds clean (`file_types`, `resource_manager`, `build_tool`, `cctpacker` native; `server` under `GOOS=js GOARCH=wasm`). All tests green. Headless Godot validation passes.

---

## What to do next (three options, pick one)

### Option A — Phase 3 kickoff: Go ↔ Godot integration path *(recommended)*

Phase 3 was gated on Phase 0b closure and is now unblocked. Kickoff is a brainstorming + design doc session, not an immediate code session — the rewrite plan's open question is which integration path to use. Three candidates:

1. **`c-shared` buildmode + GDExtension.** Compile `file_types` as a native shared library and call it from GDScript via a GDExtension wrapper. Highest performance, highest complexity, platform-specific `.so`/`.dll` build matrix.
2. **Subprocess at asset-import time only.** `build_tool` already decodes binary formats to JSON; extend the pipeline to also decode save files, ship the JSON alongside the Godot tree, and let the Godot client read JSON exclusively at runtime. No runtime Go dependency. Leading candidate per the rewrite plan.
3. **Port `file_types` to GDScript (or C#).** Duplicate-maintenance cost but no cross-language boundary. Simplest to reason about, slowest to ship.

First session under Option A should brainstorm the three, write a spec for the chosen path at `docs/superpowers/specs/`, and leave implementation for the session after.

### Option B — Remaining Phase 1b item 3 stragglers: `constants.bin.mid` or `font3.bin.mid`

Both were attempted during the megasession and deferred because their formats resist quick analysis. Each would be its own focused session.

- **`constants.bin.mid`** (9789 bytes): mixed-endian layout, first 12 bytes look like BE int32s (`1000, 10000, 3000`) but subsequent float values only decode under LE. Differential analysis across similar files OR a Ghidra pass would help.
- **`font3.bin.mid`** (2533 bytes): custom bitmap font format — NOT standard BMFont (no `BMF` magic, no `info face=` ASCII). Would need its own RE investigation.

Medium-value. Closes the Phase 1b item 3 list entirely if both succeed.

### Option C — Close out the Scudo crash fix: validate + commit

The 2026-04-19 session tracked the crashes to two sibling off-by-one null-terminator bugs in `javaMD5String` / `javaMD5Data` and shipped a 1-byte patch for each (see the 2026-04-19 devlog). Four things remain:

1. **Validate the 23:43:22 install.** Session wrapped before a retest cycle of the build that includes the `javaMD5Data` sibling fix. Expected: no more `Scudo: corrupted chunk header` aborts in any thread class, for a multi-hour session with raids, map-taps, and cafe transitions. If a GC-collateral crash returns, static-scan the binary for other off-by-one signatures or commit to a malloc-instrumentation shim.
2. **Decide final build shape.** Currently the extension also carries three "Plan A" defensive NOPs (`Cafe::~Cafe+300`, `PathTween::~PathTween+30`, `MoveTask::~MoveTask+26`) from the earlier hypothesis that those sites were planting the corruption; they turned out to be bystanders. Harmless but redundant — delete if clean diffs matter, leave if belt-and-suspenders matters. Also decide whether `android:gwpAsanMode="always"` should stay in the manifest (diagnostics only) and whether `android:debuggable="true"` should be kept (enables `run-as` for runtime memory reads + future GWP-ASan activation; not a shipping binary).
3. **Commit the changes.** `src/lib/cpp/ZombieCafeExtension.cpp` has been rebuilt many times locally and is uncommitted. Manifest is also dirty (`debuggable` and `gwpAsanMode` attributes added). Recommend one grouped commit for the extension changes and a separate one for the manifest changes since they have different implications for future builds. See `memory/feedback_commit_style.md` and `feedback_no_coauthor_trailer.md` for the commit-message conventions.
4. **Update the memory file** if validation reveals more bugs; otherwise it's accurate as of session end.

### Options A and B (unchanged from 2026-04-12)

- **Option A — Phase 3 kickoff: Go ↔ Godot integration path.** Phase 3 is unblocked; first session should be brainstorm + spec for the integration path (c-shared GDExtension vs. asset-import subprocess vs. GDScript port). Original recommendation; still the biggest remaining arc of the rewrite.
- **Option B — Phase 1b stragglers: `constants.bin.mid` (mixed-endian) or `font3.bin.mid` (custom bitmap format).** Smaller scope, self-contained.

**Recommendation:** **Option C step 1 (validate the 23:43:22 install)** first — it's 10-20 minutes of playtest that determines whether the crash fix is actually done. If yes, commit and proceed to Option A for the strategic arc. If no, continue Option C until stable.

---

## Environment

Neither Go, Godot, nor `adb` is on `PATH` in Git Bash. Always invoke via full path.

| Tool | Full path |
|---|---|
| Go 1.26.2 | `/c/Program Files/Go/bin/go.exe` |
| Godot 4.6.2 (console) | `/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe` |
| Godot 4.6.2 (GUI) | same dir, `Godot_v4.6.2-stable_win64.exe` |
| `adb` (Android Platform Tools) | `/c/Users/edwar/AppData/Local/Android/Sdk/platform-tools/adb.exe` |

`apktool` and `jarsigner` **are** on `PATH` in Git Bash and can be invoked directly.

Git user: **Edward Yang**. Main branch: **main**. Repo root: `/c/Users/edwar/edbuildingstuff/zombie-cafe-revival`.

---

## Key commands

### Build the Godot asset tree
```bash
cd /c/Users/edwar/edbuildingstuff/zombie-cafe-revival
"/c/Program Files/Go/bin/go.exe" run ./tool/build_tool -i src/ -o build_godot/ -target godot
```

### Run file_types tests
```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/...
```

### Build every workspace module (check nothing regressed)
```bash
for m in file_types build_tool resource_manager cctpacker; do
  (cd tool/$m && "/c/Program Files/Go/bin/go.exe" build ./...) || echo "$m FAILED"
done
(cd tool/server && GOOS=js GOARCH=wasm "/c/Program Files/Go/bin/go.exe" build ./...) || echo "server FAILED"
```

### Run Godot headless validation
```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --path godot/ --script res://validate_assets.gd
```

### If adding new `class_name` scripts, rebuild Godot class cache first
```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --editor --quit --path godot/
```

---

## Key files

| Path | What it is |
|---|---|
| `README.md` | Project overview, heritage, legacy APK build instructions |
| `docs/rewrite-plan.md` | Phased implementation plan, source of truth for done/pending substeps |
| `docs/devlog/` | 10 narrative entries from today, one per session/decision |
| `tool/file_types/` | Binary format parsers and writers. Every format has round-trip tests. |
| `tool/file_types/roundtrip_test.go` | 13 tests + 4 sub-tests exercising Read/Write symmetry |
| `tool/resource_manager/serialization/godot.go` | Godot asset build functions (`BuildGodotAssets`, `PackGodotCharacters`, `PackGodotTextures`) |
| `tool/build_tool/main.go` | Entry point with `-target` flag dispatch (android/godot) |
| `godot/project.godot` | Godot 4 project config |
| `godot/scripts/sprite_atlas.gd` | `SpriteAtlas` class — first reusable Godot client code |
| `godot/validate_assets.gd` | Headless validation script (14 checks) |
| `godot/assets/` | 5.5 MB sample assets for the validation script |
| `build_godot/` | Gitignored. Full 52 MB Godot tree produced by `-target godot`. |

---

## Gotchas

- **Godot CLI `--path` is sticky.** After `--path godot/`, any `--script` argument is resolved via `res://` from that project root. Always use `res://<path>` for the script argument, never a system path.
- **`class_name` registry is lazy.** New scripts with `class_name` directives are invisible to other scripts until a project filesystem scan has run. If you add a new `class_name` and a dependent script fails with `Identifier "Foo" not declared`, run `godot --headless --editor --quit --path godot/` once to rebuild the class cache.
- **Use the `_console` Godot variant for headless runs.** The plain `.exe` spawns a separate Windows console window that's hard to capture; the `_console` variant writes to stdout in-process.
- **Working directory drift.** Multi-step bash commands with `cd` can leave the shell in `tool/<module>/` from a previous build step. Always prefer absolute paths or `cd` back to repo root.
- **Go 1.26 `go vet` is stricter than 1.20.** The `go.mod` files declare Go 1.20 but the installed toolchain is 1.26. Format-string bugs that 1.20 let slide (like `%d` on a `bool`) fail `go test` under 1.26 because `go test` runs `go vet` first. One such bug already fixed in `cafe.go`.
- **`server` module only builds for wasm.** It targets Cloudflare Workers and imports `syscall/js`, which has `//go:build js` guards. Native build fails with "build constraints exclude all Go files in syscall/js" — this is expected, build with `GOOS=js GOARCH=wasm` instead.
- **No fixture files for `Cafe`/`FriendCafe`/`SaveGame`.** All their round-trip tests use in-memory constructed fixtures. Real binary fixtures are a pending Phase 0b item.
- **The pre-existing `cct_file.WritePackedTexture` has ~15 debug prints** that spam stdout whenever the atlas packer runs. Marked as a Phase 1b polish item; not touched yet because it's shared between legacy APK and Godot build paths.
- **`adb install -r` does not restart a running game instance.** The APK on disk is replaced but the running process keeps running the old dex bytes. Always `adb shell am force-stop com.capcom.zombiecafeandroid` before `adb shell am start -n com.capcom.zombiecafeandroid/.ZombieCafeAndroid` when testing a new smali patch — otherwise you'll think your edit didn't apply. Confirm the process is actually dead with `adb shell pidof com.capcom.zombiecafeandroid` (exit code 1 = dead).
- **The `SmurfsBilling` IAP bypass depends on `BuyToxin` staying unchanged.** Don't patch `BuyToxin` directly — the native game's shopping state machine requires the full startActivity → onPause → SmurfsBilling Activity → onResume cycle to clear its dim "waiting for purchase" overlay, and shortcutting that path credits toxin but leaves the game frozen until the user hits the Android back button. The SmurfsBilling-only patch avoids this by letting the Activity swap happen cleanly and just short-circuiting the Activity's body. See `docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md` Findings section for the full story of why the obvious approach is wrong.
- **Samsung dropbox rotates tombstone content within hours.** `dumpsys dropbox --print` will show entries as `(contents lost)` almost immediately after they're written. Always capture via `adb bugreport` which reads `/data/tombstones/*` directly. The dropbox timestamps are still a valid index of when crashes happened; the content is not.
- **Samsung user builds silently refuse GWP-ASan unless the app is `android:debuggable="true"`.** `gwpAsanMode="always"` + `libc.debug.gwp_asan.*` setprops on their own are ignored — no error, just no diagnostics. Verify live with `adb shell run-as PKG cat /proc/$PID/maps | grep GWP-ASan`; must show `[anon:GWP-ASan Guard Page]` / `[anon:GWP-ASan Alive Slot]` page pairs. Safe sample_rate range is 50-500; `sample_rate=10` will occasionally self-abort with `Failed to allocate in guarded pool allocator memory` when Mali's purge thread churns the pool.
- **Verify runtime patches from the extension actually land in memory, don't trust `memcpyProtected`'s silent return.** From a debuggable build: `adb shell run-as PKG dd if=/proc/$PID/mem bs=1 skip=$VA count=N | od -An -tx1`. Compute `$VA` from the `r-xp`/`rwxp` mapping in `/proc/$PID/maps` whose file-offset range contains your target file offset — the library is split into many tiny segments because text relocations force per-page rwx mappings.

---

## Preferences and durable findings recorded

Memory files under `memory/`:
- **`feedback_commit_style.md`** — always produce one grouped commit message per session, not split options. Don't offer "three commits or one" footers.
- **`feedback_no_coauthor_trailer.md`** — omit the `Co-Authored-By: Claude` trailer from commit messages on this repo.
- **`project_iap_bypass_findings.md`** — the full story of what works and what doesn't for legacy APK IAP bypassing. Read before any future IAP-related smali patching or any attempt to fix the HUD toxin icon. Covers both the `SmurfsBilling.onCreate` approach (chosen, shipped) and the `BuyToxin` direct-call alternative (confirmed working with a back-button-dismissible dim wart; documented for revert), plus the probe experiment that conclusively rules out Java-side fixes for the HUD store icon.
- **`project_crash_sites_from_tombstones.md`** — the root-cause story of the 2026-04-19 Scudo crash hunt. Two off-by-one null terminators in `javaMD5String` and `javaMD5Data` account for ~every `Scudo: corrupted chunk header` tombstone in the 2026-04-13..19 corpus. Separate `SoundManager → MediaPlayer.release` ref-count bug also documented. Includes the debugging workflow lessons (GWP-ASan needs debuggable, static scan for sibling bugs, runtime memory verification). Read before any future crash investigation in the legacy APK.

---

## Pointers for deeper reading

- `docs/rewrite-plan.md` — the phased checklist (start here for scope questions)
- `docs/devlog/2026-04-19-scudo-crash-hunt.md` — today's session: root cause of the `Scudo: corrupted chunk header` crashes, Plan A/B narrative, GWP-ASan setup, runtime memory verification. Read first if touching the legacy APK extension.
- `docs/devlog/2026-04-12-megasession-wrap.md` — IAP bypass session + 14 commits across three phase boundaries.
- `docs/devlog/2026-04-11-kickoff.md` — why Godot over the other rewrite paths.
- `docs/devlog/2026-04-11-phase-0a-findings.md` — the lossy-reader surprise that shaped the morning.
- `docs/devlog/2026-04-11-phase-2a-sprite-atlas.md` — most relevant for continuing Phase 2b.
- `docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md` + `docs/superpowers/plans/2026-04-12-iap-debug-bypass.md` — the IAP bypass design, Findings, and implementation plan. Only relevant if you need to touch the legacy APK's billing path or revisit the HUD store icon.

Fourteen devlog entries total under `docs/devlog/` — read them chronologically for the full story, or jump to the latest two or three for context on the immediate next step.
