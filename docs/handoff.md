# Session Handoff — Zombie Cafe Revival

**Last updated:** 2026-04-25 (after Phase 3 Session 1; previous: 2026-04-19 Scudo crash hunt, 2026-04-12 IAP bypass)
**Purpose:** quick orientation for a fresh session. Self-contained; read this plus `docs/superpowers/specs/2026-04-25-godot-save-format-bridge-design.md`, `docs/superpowers/plans/2026-04-25-phase-3-session-1-cafe-round-trip.md`, and `docs/rewrite-plan.md` and you should be able to continue without re-reading the full devlog history.

---

## The project in one paragraph

**Zombie Cafe Revival** is a reverse engineering + rewrite project for Capcom's 2011 mobile game *Zombie Cafe*. Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff)) is continuing from Airyz's original Android APK patching work (see `README.md`) by rewriting the client as a **Godot 4 game** that reuses the existing Go asset pipeline and the Cloudflare Workers backend. The Go tooling decodes/encodes every binary format the game uses; the Godot client will render and simulate on top of that. Goal is cross-platform (Windows/Mac/Linux/Android/iOS/web) via Godot's export targets. The original ARMv7 `libZombieCafeAndroid.so` is used only as reference documentation, not as runtime code.

---

## Where we are

Eleven devlog entries from 2026-04-11 plus one megasession entry from 2026-04-12 (`docs/devlog/2026-04-12-megasession-wrap.md`) capturing 14 commits across three phase boundaries, one devlog entry from 2026-04-19 covering the Scudo crash hunt, and now Phase 3 Session 1 (2026-04-25) which landed the GDScript foundation for the save format bridge. Tracked in `docs/rewrite-plan.md` with checklist substeps. Short summary:

- **Phase 0a (done):** file_types validation harness. Round-trip tests for every format passing.
- **Phase 0b (done, including real fixtures):** lossless parsers and symmetric writers for every binary format. Real device fixtures live under `tool/file_types/testdata/` — `playerCafe.caf` + `BACKUP1.caf` (Cafe), `globalData.dat` + `BACKUP1.dat` (SaveGame, with `Trailing []byte` preservation field), `ServerData.dat` (FriendCafe). All round-trip byte-identically.
- **Phase 1a (done):** `-target godot` flag on `build_tool`.
- **Phase 1b (almost fully done):** atlas packing, animation parser, six opaque binary parsers, debug print sweep, atlas-only output (66% size reduction). Pending: `constants.bin.mid` (mixed endian), `font3.bin.mid` (custom bitmap format). Bitmap font conversion (item 4) and social icon copy (item 7) also pending but low-priority.
- **Phase 1 validation (done):** 15/15 validation checks passing via `godot/validate_assets.gd` + GitHub Actions CI.
- **Phase 2a (done):** `SpriteAtlas` with O(1) per-character piece lookup.
- **Phase 2b (done):** `godot/main.tscn` + `main_scene.gd` + the pose function reading `sitSW.json`. Open `godot/project.godot` in Godot 4 → Run → shows boxer-human posed. Cafe background still pending (blocked on mapTiles packer re-enablement).
- **Phase 3 (Session 1 of 4 done, 2026-04-25):** Pure GDScript port of the Go `Cafe` family. `godot/scripts/save/{binary_reader,binary_writer,legacy_loader,legacy_writer}.gd` plus `godot/test/test_save_round_trip.gd`. Real fixtures `playerCafe.caf` (20,129 B) and `BACKUP1.caf` (20,017 B) round-trip byte-identically. 87 PASS / 0 FAIL on the headless test runner. Commit: `d02a00de`. The integration-path question that had been open since 2026-04-11 is closed: GDScript port (option 3 from `rewrite-plan.md`) over GDExtension or runtime subprocess, because cross-platform reach (web/iOS) makes options 1 and 2 untenable. **Sessions 2-4 remain:** SaveGame + FriendCafe round-trip (Session 2), cross-validation oracle + JSON envelope + CI wiring (Session 3), devlog/handoff close-out (Session 4). See spec/plan for details. Plans for Sessions 2-4 will be written when this session lands.

**Legacy APK on hardware is stable.** The 2026-04-19 session tracked down the `Scudo: corrupted chunk header` crashes that had been firing every few minutes. Root cause: two sibling off-by-one bugs in the game's JNI MD5 wrappers (`javaMD5String+102` and `javaMD5Data+126`), both writing `\0` one byte past their `new char[32]` allocation. Fix is a 1-byte patch at each site flipping `movs r3, #0x20` → `movs r3, #0x1F` so the terminator lands at `buf[31]` in-bounds. A separate Bug 1 (`SoundManager.playSound → MediaPlayer.release → RefBase::decStrong → scudo_free` on every character SFX) was initially worked around by NOPing `javaStartEffect+50`, but with the source corruption from javaMD5 fixed the SFX path was provably clean — the NOP was reverted in `2ebcfc35` to restore character SFX. See `docs/devlog/2026-04-19-scudo-crash-hunt.md` for the diagnostic trail. Validated stable on a Samsung Note 20 Ultra (Android 13) for multi-minute raid sessions.

**Legacy APK toxin IAP is bypassed for unlimited late-game access.** `src/smali/com/capcom/billing/SmurfsBilling.smali` patched so that triggered-by-low-toxin slot picks fake successful purchases by reading `ItemName0` from the Intent and calling `ZombieCafeAndroid.boughtToxin(productID)`. The Activity-swap cycle stays intact so the native shopping state machine clears cleanly. The HUD toxin icon ("store page" entry) still does nothing — confirmed via smali probe instrumentation that the native handler has zero JNI calls; future work there requires Ghidra on `libZombieCafeAndroid.so`. See `docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md` Findings section.

**Facebook invite-friends rebrand (`f23cef1a`)** points the dialog at `https://github.com/edbuildingstuff` and adds a back-button-dismissable WebView fix (was unkillable due to a threading bug in the original FB SDK).

**Nothing is broken.** Full workspace builds clean (`file_types`, `resource_manager`, `build_tool`, `cctpacker` native; `server` under `GOOS=js GOARCH=wasm`). All Go tests green. Headless Godot validation passes 15/15. Phase 3 Session 1 test runner passes 87/0.

---

## What to do next

### Option A — Phase 3 Session 2: SaveGame + FriendCafe round-trip *(recommended)*

Direct continuation of Session 1. Extends `legacy_loader.gd` / `legacy_writer.gd` with:

- `parse_save_game` / `write_save_game` — the trickier of the two formats because of the `SaveStrings` count-1 quirk (`RawCount=0` and `RawCount=1` both decode to zero strings; `RawCount` must be preserved separately) and the ~1 KB `Trailing []byte` preservation field that becomes `Trailing_b64` in the Dictionary.
- `parse_friend_cafe` / `write_friend_cafe` — mostly orchestration on top of Session 1's `parse_cafe`. Three lines of plumbing: leading byte version + CafeState + Cafe.
- Sub-records: `parse_character_instance`, `parse_cafe_state`, `parse_save_strings`.

Three more fixtures to copy into `godot/test/fixtures/save/`: `globalData.dat`, `BACKUP1.dat`, `ServerData.dat`.

Acceptance: `OK 5/5` on real device fixtures (all five round-trip byte-identically in pure GDScript). The test runner already exists; just extend `_init` with three more `_test_*_fixture` calls.

**First step:** write the Session 2 plan at `docs/superpowers/plans/2026-04-25-phase-3-session-2-savegame-friendcafe.md` following the same pattern as Session 1's plan. Then execute via subagent-driven-development. Estimate: ~8-10 implementer tasks (about half the size of Session 1 because primitives + cafe sub-records are already done).

### Option B — Phase 1b stragglers: `constants.bin.mid` or `font3.bin.mid`

Both deferred during the megasession because their formats resist quick analysis. Each would be its own focused session.

- **`constants.bin.mid`** (9789 bytes): mixed-endian, first 12 bytes look like BE int32s (`1000, 10000, 3000`), subsequent floats only decode under LE. Differential analysis across similar files OR a Ghidra pass would help.
- **`font3.bin.mid`** (2533 bytes): custom bitmap font format — NOT standard BMFont. Would need its own RE investigation.

Medium-value. Closes the Phase 1b item 3 list entirely.

### Option C — Phase 1b polish: bitmap font conversion (item 4) + social icon copy (item 7)

Lower-value cosmetic items deferred from Phase 1b. `A Love of Thunder.ttf` already rasterizes via Godot's built-in TTF renderer, so the bitmap font work only matters if the original look needs preserving. Social icons might be needed if the Phase 5 friend-raid UI calls for them.

**Recommendation:** **Option A (Phase 3 Session 2)**. Session 1 just landed and the architecture is fresh in mind; Sessions 2-4 build sequentially on it and were estimated at decreasing size. The sooner Phase 3 closes, the sooner Phase 4 (game tick) is unblocked.

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

**Multi-device note:** Edward works on this project across at least two computers. The paths above are canonical — if a tool is missing on a machine, install it at the matching path (e.g. `winget install -e --id GodotEngine.GodotEngine` brings Godot to the WinGet location above) rather than localizing to a divergent path. See `memory/project_multi_device.md`.

Git user: **Edward Yang**. Main branch: **main**. Repo root: `/c/Users/edwar/Documents/edbuildingstuff/zombie-cafe-revival` (path may vary by device — different from the 2026-04-19 doc's `/c/Users/edwar/edbuildingstuff/...`; both are valid on their respective machines).

---

## Key commands

### Build the Godot asset tree
```bash
"/c/Program Files/Go/bin/go.exe" run ./tool/build_tool -i src/ -o build_godot/ -target godot
```

### Run file_types tests
```bash
"/c/Program Files/Go/bin/go.exe" test ./tool/file_types/...
```

### Run Phase 3 GDScript save round-trip tests
```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --path godot/ --script res://test/test_save_round_trip.gd
```

Expected (post-Session-1): `=== Session 1 results: 87 passed, 0 failed ===`, exit 0.

### Run Godot headless asset validation
```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --path godot/ --script res://validate_assets.gd
```

Expected: 15/15 checks pass.

### If adding new `class_name` scripts, rebuild Godot class cache first
```bash
"/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe" --headless --editor --quit --path godot/
```

### Build every workspace module
```bash
for m in file_types build_tool resource_manager cctpacker; do
  (cd tool/$m && "/c/Program Files/Go/bin/go.exe" build ./...) || echo "$m FAILED"
done
(cd tool/server && GOOS=js GOARCH=wasm "/c/Program Files/Go/bin/go.exe" build ./...) || echo "server FAILED"
```

---

## Key files

| Path | What it is |
|---|---|
| `README.md` | Project overview, heritage, legacy APK build instructions |
| `docs/rewrite-plan.md` | Phased implementation plan, source of truth for done/pending substeps |
| `docs/devlog/` | 14 narrative entries spanning Phase 0a through 2026-04-19 Scudo hunt |
| `docs/superpowers/specs/` | Design specs — `2026-04-12-iap-debug-bypass-design.md`, `2026-04-11-animation-keyframe-parser-design.md`, `2026-04-25-godot-save-format-bridge-design.md` |
| `docs/superpowers/plans/` | Implementation plans — `2026-04-12-iap-debug-bypass.md`, `2026-04-11-animation-keyframe-parser.md`, `2026-04-25-phase-3-session-1-cafe-round-trip.md` |
| `tool/file_types/` | Go binary format parsers and writers. Every format has round-trip tests. |
| `tool/file_types/testdata/` | Real device fixtures pulled from the legacy APK |
| `tool/file_types/roundtrip_test.go` | Go round-trip tests, ~1306 lines |
| `tool/resource_manager/serialization/godot.go` | Godot asset build functions |
| `tool/build_tool/main.go` | Entry point with `-target` flag dispatch (android/godot) |
| `godot/project.godot` | Godot 4 project config |
| `godot/scripts/sprite_atlas.gd` | `SpriteAtlas` class — atlas + offsets JSON loader |
| `godot/scripts/main_scene.gd` | Main scene with `assemble()` + `pose_from_animation()` |
| `godot/scripts/save/binary_reader.gd`, `binary_writer.gd` | **NEW (Session 1):** GDScript primitives mirroring Go's binary_reader.go / binary_writer.go |
| `godot/scripts/save/legacy_loader.gd`, `legacy_writer.gd` | **NEW (Session 1):** GDScript port of the Go Cafe-family parsers/writers |
| `godot/test/test_save_round_trip.gd` | **NEW (Session 1):** Phase 3 Layer-1 round-trip test runner. 87 PASS / 0 FAIL. |
| `godot/test/fixtures/save/` | **NEW (Session 1):** Cafe fixtures `playerCafe.caf` + `BACKUP1.caf`, copied from `tool/file_types/testdata/`. Sessions 2 will add `globalData.dat`, `BACKUP1.dat`, `ServerData.dat`. |
| `godot/validate_assets.gd` | Headless asset validator, 15 checks |
| `godot/assets/` | 5.5 MB sample assets for the validation script |
| `build_godot/` | Gitignored. Full 18 MB Godot tree produced by `-target godot`. Regenerate with the build command above. |
| `godot/.godot/` | Gitignored Godot class cache. Regenerate with `--editor --quit` if a `class_name` import fails. |

---

## Gotchas

- **Godot CLI `--path` is sticky.** After `--path godot/`, any `--script` argument is resolved via `res://` from that project root. Always use `res://<path>`, never a system path.
- **`class_name` registry is lazy.** New scripts with `class_name` directives are invisible to other scripts until a project filesystem scan has run. After adding a new `class_name`, run `godot --headless --editor --quit --path godot/` once. Symptom: `Identifier "FooClass" not declared`.
- **Use the `_console` Godot variant for headless runs.** The plain `.exe` spawns a separate Windows console window that's hard to capture; the `_console` variant writes to stdout in-process.
- **GDScript has no exceptions** — no try/catch. The `BinaryReader` in `godot/scripts/save/binary_reader.gd` uses a `failed: bool` flag pattern: short reads call `push_error` and set `failed = true`; subsequent reads short-circuit. Top-level callers check `reader.failed` after parsing. New primitive readers should follow the same pattern.
- **GDScript `JSON.parse_string` returns floats for all numbers.** Layer 1 doesn't go through JSON, but Sessions 2-3 cross-validation will — `legacy_writer.gd` already casts every numeric field via `int(...)` so it tolerates JSON-sourced floats.
- **GDScript only allows one `class_name` per file.** `binary_reader.gd` and `binary_writer.gd` were intentionally split for this reason. New parser/writer modules should follow.
- **`PackedByteArray.encode_float`/`decode_float` are little-endian** in Godot 4 — matches the Go save format's float encoding. No translation needed.
- **`.uid` files for `class_name` scripts are tracked.** Convention from existing `main_scene.gd.uid`, `sprite_atlas.gd.uid`, `validate_assets.gd.uid`. When adding a new `class_name`, commit the auto-generated `.uid` sidecar alongside.
- **Windows autocrlf produces benign `.import` modifications.** `git status` may show every `*.import` file as modified after running Godot, with `git diff` only printing line-ending warnings. `git diff --ignore-all-space` confirms no real content change. Don't restage them; they'll resolve on the next genuine update.
- **Working directory drift.** Multi-step bash commands with `cd` can leave the shell in `tool/<module>/` from a previous build step. Always prefer absolute paths or `cd` back to repo root.
- **Go 1.26 `go vet` is stricter than 1.20.** The `go.mod` files declare Go 1.20 but the installed toolchain is 1.26. Format-string bugs that 1.20 let slide (like `%d` on a `bool`) fail `go test` under 1.26 because `go test` runs `go vet` first.
- **`server` module only builds for wasm.** It targets Cloudflare Workers and imports `syscall/js`. Native build fails with "build constraints exclude all Go files in syscall/js" — expected. Use `GOOS=js GOARCH=wasm`.
- **The pre-existing `cct_file.WritePackedTexture` had ~15 debug prints** — removed in Phase 1b polish. `build_tool -target godot` now produces two lines of output instead of dozens.
- **`adb install -r` does not restart a running game instance.** Always `adb shell am force-stop com.capcom.zombiecafeandroid` before `am start` when testing a smali patch. Confirm the process is dead with `adb shell pidof com.capcom.zombiecafeandroid` (exit code 1 = dead).
- **The `SmurfsBilling` IAP bypass depends on `BuyToxin` staying unchanged.** Don't patch `BuyToxin` directly — see `docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md` Findings section.
- **Samsung dropbox rotates tombstone content within hours.** `dumpsys dropbox --print` will show entries as `(contents lost)` almost immediately. Always capture via `adb bugreport`.
- **Samsung user builds silently refuse GWP-ASan unless `android:debuggable="true"`.** Verify via `adb shell run-as PKG cat /proc/$PID/maps | grep GWP-ASan`.
- **Verify runtime patches landed via `/proc/$PID/mem`, not by trusting `memcpyProtected`.** From a debuggable build: `adb shell run-as PKG dd if=/proc/$PID/mem bs=1 skip=$VA count=N | od -An -tx1`.

---

## Preferences and durable findings recorded

Memory files under `~/.claude/projects/<project-slug>/memory/` (auto memory location, separate from the repo):

- **`feedback_commit_style.md`** — always produce one grouped commit message per session, not split options. Don't offer "three commits or one" footers.
- **`feedback_no_coauthor_trailer.md`** — omit the `Co-Authored-By: Claude` trailer from commit messages on this repo.
- **`project_iap_bypass_findings.md`** — full story of what works and what doesn't for legacy APK IAP bypassing. Read before any future IAP-related smali patching.
- **`project_crash_sites_from_tombstones.md`** — root-cause story of the 2026-04-19 Scudo crash hunt. Read before any future crash investigation in the legacy APK.
- **`project_multi_device.md`** — handoff doc tool paths reflect what was installed on the authoring device. Missing tool on a new device → install at the same path, don't localize. Added 2026-04-25 after the Godot 4.6.2 install dance.

---

## Pointers for deeper reading

- `docs/rewrite-plan.md` — the phased checklist (start here for scope questions)
- `docs/superpowers/specs/2026-04-25-godot-save-format-bridge-design.md` — Phase 3 design: GDScript port choice + JSON envelope schema + 4-session sequencing
- `docs/superpowers/plans/2026-04-25-phase-3-session-1-cafe-round-trip.md` — Session 1 implementation plan (executed; useful as reference pattern for Session 2's plan)
- `docs/devlog/2026-04-19-scudo-crash-hunt.md` — root cause of the Scudo crashes, GWP-ASan setup, runtime memory verification.
- `docs/devlog/2026-04-12-megasession-wrap.md` — IAP bypass session + 14 commits across three phase boundaries.
- `docs/devlog/2026-04-11-kickoff.md` — why Godot over the other rewrite paths.
- `docs/devlog/2026-04-11-phase-2a-sprite-atlas.md` — most relevant for continuing Phase 2b.
- `docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md` + `docs/superpowers/plans/2026-04-12-iap-debug-bypass.md` — IAP bypass design, Findings, and implementation plan. Only relevant if touching the legacy APK's billing path.

Fourteen devlog entries total under `docs/devlog/` — read them chronologically for the full story, or jump to the latest two or three for context on the immediate next step. **Note:** Phase 3 Session 1 (2026-04-25) has not yet produced a devlog entry; that's deferred to Session 4's close-out.
