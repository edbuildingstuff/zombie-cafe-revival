# Session Handoff — Zombie Cafe Revival

**Last updated:** 2026-04-12 (after the megasession)
**Purpose:** quick orientation for a fresh session. Self-contained; read this plus `docs/devlog/2026-04-12-megasession-wrap.md` and `docs/rewrite-plan.md` and you should be able to continue without re-reading the full devlog history.

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

**Legacy APK on hardware works.** `libZombieCafeExtension.so` builds cleanly from source via NDK-bundled CMake+Ninja and includes a new runtime patch that NOPs out `Java_com_capcom_zombiecafeandroid_SoundManager_setEnabled` to dodge a modern-Android broadcast-receiver race. The game boots, plays music, and survives for several minutes before hitting `Scudo: corrupted chunk header` aborts (legacy heap bugs detected by modern Android's hardened allocator — not blocking fixture extraction).

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

### Option C — Fix the `Scudo` heap corruption crashes in the legacy APK

The game boots and runs, but hits `Scudo: corrupted chunk header` aborts after several minutes — legacy heap bugs in the native code that modern Android's hardened allocator detects during GC or finalization. The existing extension already NOPs out one known texture-destructor crash; the new crashes are in `MemMap::~MemMap` (ART GC path) and `Parcel::~Parcel` (Android framework IPC finalization). Identifying which allocation is being corrupted would need Ghidra or careful RE. Not blocking any other work — the game runs long enough for fixture extraction — but makes repeated device sessions painful.

**Recommendation:** **Option A**. Phase 3 is the biggest remaining arc of the rewrite and needs a design decision before any code ships. Option B is smaller scope and self-contained. Option C is only worth doing if repeated hardware sessions become a regular part of the workflow.

---

## Environment

Neither Go nor Godot is on `PATH` in Git Bash. Always invoke via full path.

| Tool | Full path |
|---|---|
| Go 1.26.2 | `/c/Program Files/Go/bin/go.exe` |
| Godot 4.6.2 (console) | `/c/Users/edwar/AppData/Local/Microsoft/WinGet/Packages/GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe/Godot_v4.6.2-stable_win64_console.exe` |
| Godot 4.6.2 (GUI) | same dir, `Godot_v4.6.2-stable_win64.exe` |

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

---

## Preferences recorded

One memory file at `memory/feedback_commit_style.md`:
- **Always produce one grouped commit message per session**, not split options. Don't offer "three commits or one" footers.

---

## Pointers for deeper reading

- `docs/rewrite-plan.md` — the phased checklist (start here for scope questions)
- `docs/devlog/2026-04-11-kickoff.md` — why Godot over the other rewrite paths
- `docs/devlog/2026-04-11-phase-0a-findings.md` — the lossy-reader surprise that shaped the morning
- `docs/devlog/2026-04-11-phase-2a-sprite-atlas.md` — latest, most relevant for continuing Phase 2b

Ten devlog entries total under `docs/devlog/` — read them chronologically for the full story, or jump to the latest two or three for context on the immediate next step.
