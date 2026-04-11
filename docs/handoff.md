# Session Handoff — Zombie Cafe Revival

**Last updated:** 2026-04-11 (end of day, ~49% context used before handoff)
**Purpose:** quick orientation for a fresh session. Self-contained; read this plus `docs/rewrite-plan.md` and you should be able to continue without re-reading the 10 devlog entries.

---

## The project in one paragraph

**Zombie Cafe Revival** is a reverse engineering + rewrite project for Capcom's 2011 mobile game *Zombie Cafe*. Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff)) is continuing from Airyz's original Android APK patching work (see `README.md`) by rewriting the client as a **Godot 4 game** that reuses the existing Go asset pipeline and the Cloudflare Workers backend. The Go tooling decodes/encodes every binary format the game uses; the Godot client will render and simulate on top of that. Goal is cross-platform (Windows/Mac/Linux/Android/iOS/web) via Godot's export targets. The original ARMv7 `libZombieCafeAndroid.so` is used only as reference documentation, not as runtime code.

---

## Where we are

Ten devlog entries of work today. Tracked in `docs/rewrite-plan.md` with checklist substeps. Short summary:

- **Phase 0a (done):** file_types validation harness. 13 round-trip tests + 4 sub-tests passing.
- **Phase 0b (one item pending):** lossless parsers and symmetric writers for every binary format — `Food`, `Furniture`, `Character`, `CharacterArt`, `ImageOffsets`, `AnimationData`, `CharacterJP`, `FoodStack`, `Cafe`, `CafeState`, `CharacterInstance`, `FriendCafe`, `SaveGame`. Preservation-field approach (no semantic naming, just byte preservation). The one remaining item is **check in real binary fixtures under `tool/file_types/testdata/`** — blocked on physical-world save file extraction from a device/emulator.
- **Phase 1a (done):** `-target godot` flag on `build_tool`. Produces a 52 MB importable tree: JSON data files, individual PNGs, OGG audio, TTF fonts.
- **Phase 1b (atlas packing done, 5 items pending):** atlas packing landed (`PackGodotCharacters`/`PackGodotTextures` writing PNG + JSON offsets). Pending: per-animation keyframe parser, opaque binary game data parsers, `cct_file` debug print sweep, bitmap font conversion, cosmetic cleanup.
- **Phase 1 validation (done):** Godot 4.6.2 installed, 14/14 validation checks passing against real assets. Manually verified in the editor by Edward.
- **Phase 2a (done):** first real Godot client code. `SpriteAtlas` class handles both character atlases (composite `"<char>/<part>"` keys) and texture atlases (bare part name keys). Validated end-to-end: 3,051 character-atlas regions, 27 pieces returned by `get_character_pieces('boxer-human')`.

**Nothing is broken.** Full workspace builds clean (`file_types`, `resource_manager`, `build_tool`, `cctpacker` native; `server` under `GOOS=js GOARCH=wasm`). All tests green.

---

## What to do next (three options, pick one)

### Option A — Phase 2b: visible rendered scene *(recommended)*

Smallest scope, highest symbolic value, continues the momentum from Phase 2a.

- Create `godot/main.tscn` with a `Node2D` root containing 27 layered `Sprite2D` children.
- Write a GDScript that calls `SpriteAtlas.get_character_pieces("boxer-human")` and assigns each `AtlasTexture` to one sprite, applying the stored `draw_offsets` for positioning.
- Set `main.tscn` as the project's main scene in `project.godot`.
- Add a GitHub Actions workflow running `godot --headless --path godot/ --script res://validate_assets.gd` on every push.
- Optionally: headless screenshot of the rendered character.

Value: first visible artifact, shakes out any remaining `AtlasTexture`/`Sprite2D` integration gotchas, closes Phase 2b.

### Option B — Per-animation keyframe parser *(highest-value Phase 1b item)*

The first real byte-level reverse engineering task of the project. Higher risk, higher reward.

- `src/assets/data/animation/*.bin.mid` (~60 files) have no Go parser today.
- Each file likely contains a keyframe list — per-frame positions, rotations, part references.
- Deliverable: `ReadAnimationFile`/`WriteAnimationFile` in `file_types` with round-trip tests, plus a deserializer path in `godot.go` so the Godot tree gets JSON keyframes.
- Game-critical — characters can't animate without this data.
- Unknown scope: requires hex-dumping sample files, inferring structure, possibly ghidra'ing the original `.so` for anchors.

### Option C — Phase 0b fixture sourcing *(blocked on physical-world work)*

Closes Phase 0b entirely. Not a code task.

- Install Android emulator (Android Studio or Waydroid), build the legacy APK via the existing `-target android` path, install, play a few minutes, extract save data via `adb pull /data/data/com.capcom.zombiecafeandroid/files/`.
- Check in one `Cafe`, one `FriendCafe`, one `SaveGame` under `tool/file_types/testdata/`.
- Add fixture tests that round-trip real files byte-identically.

Alternatively: ask around for existing Airyz-era save files and skip the emulator pipeline.

**Recommendation:** **Option A first**, then Option B. Option A is one focused session with immediate visible payoff; Option B is a bigger chunk of reverse engineering work that deserves its own fresh session with full context budget.

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
