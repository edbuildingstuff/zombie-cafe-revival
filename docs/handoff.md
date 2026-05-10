# Session Handoff — Zombie Cafe Revival

**Last updated:** 2026-05-10 (after Phase 3 close-out; previous: 2026-04-25 Phase 3 Session 1, 2026-04-19 Scudo crash hunt, 2026-04-12 IAP bypass)
**Purpose:** quick orientation for a fresh session. Self-contained; read this plus `docs/devlog/2026-05-10-phase-3-save-format.md` and `docs/rewrite-plan.md` and you should be able to continue without re-reading the full devlog history.

---

## The project in one paragraph

**Zombie Cafe Revival** is a reverse engineering + rewrite project for Capcom's 2011 mobile game *Zombie Cafe*. Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff)) is continuing from Airyz's original Android APK patching work (see `README.md`) by rewriting the client as a **Godot 4 game** that reuses the existing Go asset pipeline and the Cloudflare Workers backend. The Go tooling decodes/encodes every binary format the game uses; the Godot client renders and simulates on top of that. Goal is cross-platform (Windows/Mac/Linux/Android/iOS/web) via Godot's export targets. The original ARMv7 `libZombieCafeAndroid.so` is used only as reference documentation, not as runtime code.

---

## Where we are

**Phase 3 is closed.** The Godot client owns the save format end-to-end — five real device fixtures across three formats round-trip byte-identically through pure GDScript, a JSON envelope at `user://save.json` is the going-forward save format, and CI runs the test runner on every push (**207 PASS / 0 FAIL**). The longest-standing open question in the rewrite plan ("Go ↔ Godot integration path is undecided") is settled in favor of **option 3: GDScript port** — over GDExtension's per-platform native matrix or a subprocess at asset-import time only — because cross-platform reach (web, iOS) makes options 1 and 2 untenable. See `docs/devlog/2026-05-10-phase-3-save-format.md` for the full story.

**Phase status by phase:**

- **Phase 0a (done):** file_types validation harness. Round-trip tests for every format passing.
- **Phase 0b (done, including real fixtures):** lossless parsers and symmetric writers for every binary format. Real device fixtures live under `tool/file_types/testdata/` — `playerCafe.caf` + `BACKUP1.caf` (Cafe), `globalData.dat` + `BACKUP1.dat` (SaveGame, with `Trailing []byte` preservation field), `ServerData.dat` (FriendCafe). All round-trip byte-identically.
- **Phase 1a (done):** `-target godot` flag on `build_tool`.
- **Phase 1b (almost fully done):** atlas packing, animation parser, six opaque binary parsers, debug print sweep, atlas-only output (66% size reduction). Pending: `constants.bin.mid` (mixed endian), `font3.bin.mid` (custom bitmap format). Bitmap font conversion (item 4) and social icon copy (item 7) also pending but low-priority cosmetic.
- **Phase 1 validation (done):** 15/15 validation checks passing via `godot/validate_assets.gd` + GitHub Actions CI.
- **Phase 2a (done):** `SpriteAtlas` with O(1) per-character piece lookup.
- **Phase 2b (done):** `godot/main.tscn` + `main_scene.gd` + the pose function reading `sitSW.json`. Open `godot/project.godot` in Godot 4 → Run → shows boxer-human posed. Cafe background still pending (blocked on `mapTiles` packer re-enablement).
- **Phase 3 (done, 2026-04-25 → 2026-05-10):** Pure GDScript port of the Go save-family parsers and writers. `godot/scripts/save/{binary_reader,binary_writer,legacy_loader,legacy_writer,save_v1}.gd` plus `godot/test/test_save_round_trip.gd` plus `tool/dump_legacy_fixtures/`. Three test layers green: Layer 1 byte-identical round-trip on all 5 real fixtures, Layer 2 Go-Dict ↔ GDScript-Dict cross-validation against committed JSON oracles, Layer 3 envelope round-trip. CI runs the test runner on every push. **207 PASS / 0 FAIL.** Sessions: 1 (`d02a00de`, primitives + Cafe), 2 (`0b059166`, SaveGame + FriendCafe), 3 (`c3f90174`, oracle + envelope + CI), 4 (this handoff + devlog).
- **Phase 4 (next):** game tick loop. Customers spawn, walk to tables, order food, wait for the stove, eat, pay, and leave. XP and money update.
- **Phase 5 (unblocked):** online features. Server upload of binary saves now plumbable against the GDScript writer (`write_save_game(dict) -> PackedByteArray`).

**Legacy APK on hardware is stable.** The 2026-04-19 session tracked down the `Scudo: corrupted chunk header` crashes that had been firing every few minutes. Root cause: two sibling off-by-one bugs in the game's JNI MD5 wrappers (`javaMD5String+102` and `javaMD5Data+126`), both writing `\0` one byte past their `new char[32]` allocation. Fix is a 1-byte patch at each site flipping `movs r3, #0x20` → `movs r3, #0x1F` so the terminator lands at `buf[31]` in-bounds. A separate Bug 1 (`SoundManager.playSound → MediaPlayer.release → RefBase::decStrong → scudo_free` on every character SFX) was initially worked around by NOPing `javaStartEffect+50`, but with the source corruption from javaMD5 fixed the SFX path was provably clean — the NOP was reverted in `2ebcfc35` to restore character SFX. See `docs/devlog/2026-04-19-scudo-crash-hunt.md` for the diagnostic trail. Validated stable on a Samsung Note 20 Ultra (Android 13) for multi-minute raid sessions.

**Legacy APK toxin IAP is bypassed for unlimited late-game access.** `src/smali/com/capcom/billing/SmurfsBilling.smali` patched so that triggered-by-low-toxin slot picks fake successful purchases by reading `ItemName0` from the Intent and calling `ZombieCafeAndroid.boughtToxin(productID)`. The Activity-swap cycle stays intact so the native shopping state machine clears cleanly. The HUD toxin icon ("store page" entry) still does nothing — confirmed via smali probe instrumentation that the native handler has zero JNI calls; future work there requires Ghidra on `libZombieCafeAndroid.so`. See `docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md` Findings section.

**Facebook invite-friends rebrand (`f23cef1a`)** points the dialog at `https://github.com/edbuildingstuff` and adds a back-button-dismissable WebView fix (was unkillable due to a threading bug in the original FB SDK).

**Nothing is broken.** Full workspace builds clean (`file_types`, `resource_manager`, `build_tool`, `cctpacker`, `dump_legacy_fixtures` native; `server` under `GOOS=js GOARCH=wasm`). All Go tests green. Headless Godot validation passes 15/15. Phase 3 save round-trip runner passes 207/0.

---

## What to do next

### Option A — Phase 4: game tick loop *(recommended)*

Phase 3 closed the save-load fidelity contract; Phase 4 is now the next active phase. Customers spawn, walk to tables, order food, wait for the stove, eat, pay, and leave. XP and money update. The player can place furniture and buy characters. No online features, no billing, no Facebook.

This is where the bulk of the reverse engineering effort goes. For each behavior, the order of operations is:

1. Check the original `libZombieCafeAndroid.so` in Ghidra, using the offsets already labelled in `src/lib/cpp/ZombieCafeExtension.cpp` as anchors.
2. Write a devlog entry describing the behavior in plain English.
3. Implement it in Godot.
4. If the behavior is exposed in a save file field (e.g., a timer, a cooldown), verify by loading a legacy save and confirming the values match expectations.

**First step:** write a Phase 4 design spec at `docs/superpowers/specs/2026-05-XX-phase-4-game-tick-design.md` covering the sub-system breakdown (customer spawning, pathfinding, food orders, kitchen state, payment/XP, furniture placement, character purchasing) and the per-sub-system reverse engineering anchor points. Then break Phase 4 into sessions like Phase 3 was — each session a vertical slice (e.g., "customer spawn + walk to seat" as Session 1).

### Option B — Phase 1b stragglers: `constants.bin.mid` or `font3.bin.mid`

Both deferred during the Phase 1b megasession because their formats resist quick analysis. Each would be its own focused session.

- **`constants.bin.mid`** (9789 bytes): mixed-endian, first 12 bytes look like BE int32s (`1000, 10000, 3000`), subsequent floats only decode under LE. Differential analysis across similar files OR a Ghidra pass would help.
- **`font3.bin.mid`** (2533 bytes): custom bitmap font format — NOT standard BMFont. Would need its own RE investigation.

Medium-value. Closes the Phase 1b item 3 list entirely.

### Option C — Phase 1b polish: bitmap font conversion (item 4) + social icon copy (item 7)

Lower-value cosmetic items deferred from Phase 1b. `A Love of Thunder.ttf` already rasterizes via Godot's built-in TTF renderer, so the bitmap font work only matters if the original look needs preserving. Social icons might be needed if the Phase 5 friend-raid UI calls for them.

**Recommendation:** **Option A (Phase 4)**. Phase 3 just closed and the architecture is fresh in mind; Phase 4's tick loop reads and writes saves continuously, so building it on top of the Phase 3 foundation is the natural next step. The two Phase 1b stragglers and the cosmetic items can be picked up any time, none of them block gameplay.

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

Git user: **Edward Yang**. Main branch: **main**. Repo root: `/c/Users/edwar/edbuildingstuff/zombie-cafe-revival` on the current authoring device (path may vary by device — different from the 2026-04-19 doc's `/c/Users/edwar/Documents/edbuildingstuff/...`; both are valid on their respective machines).

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

Expected: `=== Save round-trip results: 207 passed, 0 failed ===`, exit 0.

### Regenerate Layer 2 JSON oracles after Go parser changes
```bash
"/c/Program Files/Go/bin/go.exe" run ./tool/dump_legacy_fixtures
```

Reads `tool/file_types/testdata/*.{caf,dat}`, writes PascalCase JSON to `godot/test/fixtures/save/<name>.json` for the 5 real fixtures. Re-run the GDScript test runner afterwards to confirm Layer 2 still passes.

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
for m in file_types build_tool resource_manager cctpacker dump_legacy_fixtures; do
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
| `docs/devlog/` | Narrative entries spanning Phase 0a through Phase 3 close-out (2026-05-10) |
| `docs/superpowers/specs/` | Design specs — `2026-04-12-iap-debug-bypass-design.md`, `2026-04-11-animation-keyframe-parser-design.md`, `2026-04-25-godot-save-format-bridge-design.md` |
| `docs/superpowers/plans/` | Implementation plans — IAP bypass, animation keyframe parser, Phase 3 Sessions 1/2/3 |
| `tool/file_types/` | Go binary format parsers and writers. Every format has round-trip tests. |
| `tool/file_types/testdata/` | Real device fixtures pulled from the legacy APK |
| `tool/file_types/roundtrip_test.go` | Go round-trip tests, ~1306 lines |
| `tool/dump_legacy_fixtures/` | Standalone Go CLI emitting Layer 2 JSON oracles for the GDScript test runner |
| `tool/resource_manager/serialization/godot.go` | Godot asset build functions |
| `tool/build_tool/main.go` | Entry point with `-target` flag dispatch (android/godot) |
| `godot/project.godot` | Godot 4 project config |
| `godot/scripts/sprite_atlas.gd` | `SpriteAtlas` class — atlas + offsets JSON loader |
| `godot/scripts/main_scene.gd` | Main scene with `assemble()` + `pose_from_animation()` |
| `godot/scripts/save/binary_reader.gd`, `binary_writer.gd` | GDScript primitives mirroring Go's `binary_reader.go` / `binary_writer.go`. Note: `read_string` returns `PackedByteArray`, not `String` (see Gotchas) |
| `godot/scripts/save/legacy_loader.gd`, `legacy_writer.gd` | GDScript port of the Go Cafe / SaveGame / FriendCafe parsers and writers |
| `godot/scripts/save/save_v1.gd` | Going-forward JSON envelope. `save_save` / `load_save` + `_to_json_safe` / `_from_json_safe` walker |
| `godot/test/test_save_round_trip.gd` | Phase 3 three-layer test runner. **207 PASS / 0 FAIL.** |
| `godot/test/fixtures/save/` | Real device fixtures (`.caf`/`.dat`) plus committed JSON oracles for Layer 2 |
| `godot/validate_assets.gd` | Headless asset validator, 15 checks |
| `godot/assets/` | 5.5 MB sample assets for the validation script |
| `build_godot/` | Gitignored. Full 18 MB Godot tree produced by `-target godot`. Regenerate with the build command above. |
| `godot/.godot/` | Gitignored Godot class cache. Regenerate with `--editor --quit` if a `class_name` import fails. |
| `.github/workflows/godot-validation.yml` | CI: Godot 4.6.2 download + class cache build + asset validator + save round-trip tests, all on every push |

---

## Gotchas

- **`read_string` returns `PackedByteArray`, not `String`.** The legacy `globalData.dat` carries `\r\0` byte suffixes inside `CharacterInstance.Name` strings. Godot's `String` cannot hold a NUL codepoint, so byte-faithful round-trip requires keeping bytes rather than decoding through `String`. `write_string` accepts both `PackedByteArray` and `String` via `Variant`. The JSON envelope (`save_v1.gd`) walks Dictionary trees and serializes each `PackedByteArray` as either a plain JSON string (clean UTF-8, no NULs) or `{"_b64": "<base64>"}` (anything else). When adding new string-bearing parsers, follow this convention. See `binary_reader.gd:125-132`.
- **Layer 2 cross-validation is lossy on string fields by design.** `_deep_equal` UTF-8-decodes the `PackedByteArray` side and compares to the JSON-parsed `String`. Layer 1 already proves byte-faithfulness; Layer 2's job is structural agreement. The diagnostic stderr "Unicode parsing error, some characters were replaced with � (U+FFFD)" during Layer 2 is expected — Godot's JSON parser substitutes embedded NULs with U+FFFD, and `_bytes_eq_string` compensates.
- **`JSON.parse_string` returns `float` for every number.** The `_deep_equal` helper coerces both sides to float-with-tolerance. Tolerance is both absolute and relative (`max(1e-6, max(abs(a), abs(b)) * 1e-6)`) because Go's `json.Marshal` of float32 emits the shortest decimal representation; reconstructed float64 differs from the original float32 by up to half a ULP at float32 precision (~1e-7 relative).
- **Migration dispatcher is scaffold-only at v1.** `CURRENT_VERSION = 1`. The negative-path tests cover v2 rejection (forward-only), missing-version rejection, missing-file rejection, non-object root rejection. Real migration files (`migrations/v1_to_v2.gd`) land when a real format change requires one — Phase 4+.
- **Godot CLI `--path` is sticky.** After `--path godot/`, any `--script` argument is resolved via `res://` from that project root. Always use `res://<path>`, never a system path.
- **`class_name` registry is lazy.** New scripts with `class_name` directives are invisible to other scripts until a project filesystem scan has run. After adding a new `class_name`, run `godot --headless --editor --quit --path godot/` once. Symptom: `Identifier "FooClass" not declared`.
- **Use the `_console` Godot variant for headless runs.** The plain `.exe` spawns a separate Windows console window that's hard to capture; the `_console` variant writes to stdout in-process.
- **GDScript has no exceptions** — no try/catch. The `BinaryReader` in `godot/scripts/save/binary_reader.gd` uses a `failed: bool` flag pattern: short reads call `push_error` and set `failed = true`; subsequent reads short-circuit. Top-level callers check `reader.failed` after parsing.
- **GDScript only allows one `class_name` per file.** `binary_reader.gd` and `binary_writer.gd` were intentionally split for this reason. New parser/writer modules should follow.
- **`PackedByteArray.encode_float` / `decode_float` are little-endian** in Godot 4 — matches the Go save format's float encoding. No translation needed.
- **`.uid` files for `class_name` scripts are tracked.** Convention from existing `main_scene.gd.uid`, `sprite_atlas.gd.uid`, `validate_assets.gd.uid`, the save scripts. When adding a new `class_name`, commit the auto-generated `.uid` sidecar alongside.
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

- `docs/rewrite-plan.md` — the phased checklist (start here for scope questions). Phase 3 is now marked done; Phase 4 is the next active phase.
- `docs/devlog/2026-05-10-phase-3-save-format.md` — Phase 3 close-out: architecture decision, four-session arc, GDScript-specific surprises (`PackedByteArray` strings, `_b64` hybrid, `JSON.parse_string` floats), CI-as-done-signal.
- `docs/superpowers/specs/2026-04-25-godot-save-format-bridge-design.md` — Phase 3 design: GDScript port choice + JSON envelope schema + 4-session sequencing.
- `docs/superpowers/plans/2026-04-25-phase-3-session-1-cafe-round-trip.md` — Session 1 implementation plan (executed; useful as reference pattern for future session-scoped plans).
- `docs/superpowers/plans/2026-04-25-phase-3-session-2-savegame-friendcafe.md` — Session 2 plan + the architectural deviation discovery for `read_string`.
- `docs/superpowers/plans/2026-04-25-phase-3-session-3-oracle-envelope-ci.md` — Session 3 plan: oracle CLI, envelope walker, three-layer test integration, CI wiring.
- `docs/devlog/2026-04-19-scudo-crash-hunt.md` — root cause of the Scudo crashes, GWP-ASan setup, runtime memory verification.
- `docs/devlog/2026-04-12-megasession-wrap.md` — IAP bypass session + 14 commits across three phase boundaries.
- `docs/devlog/2026-04-11-kickoff.md` — why Godot over the other rewrite paths.
- `docs/devlog/2026-04-11-phase-2a-sprite-atlas.md` — most relevant for continuing Phase 2b.
- `docs/superpowers/specs/2026-04-12-iap-debug-bypass-design.md` + `docs/superpowers/plans/2026-04-12-iap-debug-bypass.md` — IAP bypass design, Findings, and implementation plan. Only relevant if touching the legacy APK's billing path.

Fifteen devlog entries total under `docs/devlog/` — read them chronologically for the full story, or jump to the latest two or three for context on the immediate next step.
