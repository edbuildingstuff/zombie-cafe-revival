# 2026-04-11 — Phase 1 kickoff: the Godot asset builder, MVP edition

**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))

Seventh entry of the day. Phase 0b isn't fully closed — the real-binary-fixture item is still blocked on getting an actual save file off a device or an emulator, which is a physical-world task with no code to write. Rather than sit on that blocker, I pivoted to Phase 1, which is independent: the Godot asset export pipeline doesn't touch save games at all, so nothing stops me from starting it now.

## What Phase 1 asks for

The rewrite plan's Phase 1 done criterion, verbatim:

> **Done when:** `go run ./tool/build_tool -target godot -o godot/assets/` produces a directory tree that Godot can import without manual intervention: PNGs for every texture, JSON for every data file, OGG for audio, TTF/BMFont for fonts.

The key phrase is *without manual intervention*. That rules out hand-editing files, running a conversion step in Godot's editor, or writing a custom Godot importer plugin for the legacy `CCTX` or `.bin.mid` formats. Whatever the build tool emits has to be readable by Godot 4's built-in importers directly.

Reading that criterion, there are three implied constraints:

1. **No CCTX textures** — Godot doesn't know how to read them, and a custom importer is manual intervention.
2. **No `.bin.mid` binary data files on the Godot side** — same reason. Either decode to JSON at build time, or treat them as opaque blobs Godot's game logic has to parse at runtime (which is manual intervention of a different kind).
3. **No bitmap font conversion this session** — Godot *does* have a native BMFont importer, but the legacy `.fnt.mid` format isn't BMFont-compatible. Converting it is a follow-up.

With those constraints, the MVP scope falls out naturally: copy the files Godot *can* import, decode the ones it can't, skip the ones that need custom work.

## What I built

One new file, one modified file, one gitignore update.

**`tool/resource_manager/serialization/godot.go`** is the new file. The top-level entry point is `BuildGodotAssets(in_directory, out_directory)`, which walks the source tree and produces four subdirectories under `<out>/assets/`:

- `data/` — editable JSON game data. The existing `*.bin.mid.json` sources in `src/assets/data/` (which are the human-editable forms of `characterData`, `foodData`, `furnitureData`) get copied and renamed with the `.bin.mid` suffix stripped, so they land as `characterData.json`, `foodData.json`, `furnitureData.json`. `animationData.bin.mid` gets decoded on the fly via the existing `ReadAnimationData` parser and written out as `animationData.json`. That's four data files total.
- `images/` — individual PNG files, subdirectory structure preserved. Walks `src/assets/images/` with `filepath.WalkDir`, filters to `*.png`, mirrors the path to the output. Atlas packing is deferred — each character part, food item, and furniture sprite is emitted as its own standalone PNG. Inefficient at runtime but trivially importable, which is the MVP tradeoff.
- `audio/` — the single OGG music track from `src/assets/Music/` lands at the top of `audio/`, and every OGG sound effect from `src/res/raw/` lands under `audio/sfx/`.
- `fonts/` — TTF files from wherever they live in the source tree (`src/assets/data/A Love of Thunder.ttf` and anything in `src/assets/fonts/` if there are other TTFs). Bitmap fonts are deliberately skipped for this session.

The function is intentionally stateless and side-effects-only: every file operation is `log.Fatalf` on error, there are no return values, and the function's entire contract is "produce the tree or crash trying." That's the right shape for a one-shot build tool — the process is expected to exit on error and the caller is expected to re-run from scratch after fixing whatever broke.

There are two small private helpers — `godotCopyFile` and `godotMkdir` — deliberately namespaced with a `godot` prefix so they don't collide with any future helpers in the rest of the `serialization` package. This is the kind of tiny defensive choice that doesn't matter in a single session but prevents the kind of merge conflict that eats a future session.

**`tool/build_tool/main.go`** gains a `-target` flag (defaults to `android`, accepts `godot`). The main function now dispatches on the target: `android` runs the existing APK build pipeline (refactored into a new `buildAndroid` helper function so the main function stays short), `godot` calls `serialization.BuildGodotAssets`, and anything else is a fatal error with a helpful message. The APK build path is completely untouched — I moved the existing orchestration into `buildAndroid` without changing any of its behavior, which means the legacy build should produce byte-identical output to the pre-refactor version.

**`.gitignore`** gains `build_godot` so the 41 MB generated asset tree doesn't show up in `git status`. Worth noting: `build` was already ignored (catching the legacy APK build directory), so I added `build_godot` as a sibling rather than trying to generalize the pattern. Being specific is clearer than being clever in a `.gitignore`.

## Test run

Ran `go run ./tool/build_tool -i src/ -o build_godot/ -target godot` against the real source tree:

```
2026/04/11 16:40:57 BuildGodotAssets: src/ -> build_godot/
2026/04/11 16:41:02 BuildGodotAssets: done
```

Five seconds. Output tree summary:

```
build_godot/assets/
├── data/                      4 JSON files (668 KB)
│   ├── animationData.json     decoded from binary
│   ├── characterData.json     copied from .bin.mid.json
│   ├── foodData.json
│   └── furnitureData.json
├── fonts/                     200 KB
│   └── A Love of Thunder.ttf
├── audio/                     5.0 MB
│   ├── Zombie Theme V1.ogg    from src/assets/Music/
│   └── sfx/                   204 OGG files from src/res/raw/
└── images/                    36 MB, 7054 PNG files total
    ├── characterParts/        subdirectories per character name preserved
    ├── characterParts2/
    ├── furniture/             plus furniture2/, furniture3/
    ├── recipeImages/          plus recipeImages2/
    ├── mapTiles/
    └── <a bunch of standalone PNGs at the top level>
```

Spot-checked `animationData.json` — it's a well-formed array of objects with `Form`, `Type`, `Direction`, and `AnimationFile` fields, which is exactly what the `file_types.AnimationData` struct produces when marshaled by `encoding/json`. Spot-checked `foodData.json` — first entry is `"Mystery Meat"` with the expected `Price`, `CookTimeMinutes`, `Servings` and the `U7`-`U12` placeholder fields, which is what I expected since those JSON files are just copies of Airyz's editable sources.

Total output size is 41 MB. The bulk is `images/` at 36 MB because every character part and furniture sprite is its own PNG file. A future atlas-packing session will cut this significantly — packing the character parts alone into a few atlases per pack would probably halve the image footprint and also improve runtime load performance by orders of magnitude once it's running in Godot.

I did *not* run the legacy `-target android` build end-to-end, because that path needs the Android NDK toolchain, `apktool`, and `jarsigner`, none of which are set up on this machine. But I did verify that `go build` and `go run ./tool/build_tool -help` both succeed against the refactored main function, which is sufficient evidence that my changes haven't broken the `buildAndroid` code path's compilation. The orchestration inside `buildAndroid` is a verbatim move of the original `main` function body, so behavioral regression is extremely unlikely without a compile error to catch it.

## Things I noticed but deliberately didn't fix

**Leftover CCTX-to-PNG artifacts in the source tree.** While inspecting the output I saw `ingameUiImages.cct.mid.png` and `loading.cct.mid.png` in `build_godot/assets/images/` — files with a `.cct.mid.png` extension. These are detritus from a previous legacy build run where the `imaging.Save(img, out_cct_path+".png")` line in `PackTextures` dropped a PNG next to the CCTX. They got picked up by my `WalkDir` because they end in `.png`. Not wrong — the images *are* valid PNGs, Godot can import them — just slightly weird naming. A future cleanup pass can either skip files with `.cct.mid.png` extension or rename them during copy. For now they're harmless.

**Social icons and standalone `.html` files.** `src/assets/data/` has `FacebooK.png` (sic), `Twitter.png`, `Youtube.png`, `about.html`, `help_amazon.html`, `help_google.html`. None of them got copied — my `copyGodotDataFiles` only matches `*.bin.mid.json`, and `copyGodotImages` only walks `src/assets/images/` so the PNGs in `src/assets/data/` are invisible to it. Whether this matters depends on what the Godot client wants to do with them. The social icons and EULA text are UI assets that the game probably displays somewhere; a future session can either add them to `copyGodotDataFiles` explicitly or walk `src/assets/data/` with a broader filter.

**Opaque binary data files.** `constants.bin.mid`, `cookbookData.bin.mid`, `enemyCafeData.bin.mid`, `enemyItemData.bin.mid`, `enemyItems.bin.mid`, `enemyLayouts.bin.mid`, `font3.bin.mid`, `strings_amazon.bin.mid`, `strings_google.bin.mid`, and every file under `src/assets/data/animation/` (the per-animation keyframe blobs). None of these have parsers in the Go `file_types` package, so I can't decode them to JSON. None of them got copied to the Godot tree either — they'd be useless there without a parser. The Godot client will need some subset of these eventually (the per-animation keyframes are the obvious one — you can't animate characters without them), but that's going to require writing new parsers in `file_types`, which is its own session's worth of reverse engineering work. Deferring.

**Atlas packing.** As discussed above. The legacy `PackCharacters` / `PackTextures` functions in `serialization.go` already know how to produce an `image.NRGBA` + `file_types.ImageOffsets` pair via `cct_file.WritePackedTexture`; they then save it as CCTX. A Godot-targeted version would save the `image.NRGBA` as a PNG (via the existing `imaging.Save` call which is already imported) and the `ImageOffsets` as JSON. That's a small amount of new code but it's non-trivial to get right, and it's a clear follow-up rather than MVP scope.

**Per-asset Godot import metadata.** Godot generates `.import` files alongside each asset the first time the project opens in the editor. For a purely build-tool-emitted tree, we could either let Godot's first-open pass generate them (slower, requires the editor) or emit them ourselves (faster, more complicated). For MVP I'm letting Godot handle it.

## Phase 1 status

The done criterion says the tree has to be importable by Godot without manual intervention. My MVP build produces such a tree for the asset categories I chose to handle (data, images, audio, fonts). It does *not* handle every file in the source tree — specifically the opaque binary game-logic files and the per-animation keyframes are missing, and the atlas-packing optimization isn't done. Whether to call that "Phase 1 done" or "Phase 1 in progress" is a judgment call.

I'm going to call it in progress, because the opaque binary files are non-negotiable for a functional game (animations can't render without them) and the done criterion implicitly assumes "a tree Godot can import" means "a tree that lets Godot actually run the game," not "a tree with zero unreadable files." Phase 1 closes when there's a parser for every binary data file that the runtime needs, and the atlas-packing at least gets started so the image tree isn't embarrassingly large.

The rewrite plan is getting amended to track this distinction: Phase 1a (this session — the MVP skeleton) is done, Phase 1b is the atlas packing + remaining binary parsers.

## Next

1. **Phase 1b, atlas packing.** Add `PackTexturesForGodot` / `PackCharactersForGodot` that reuse `cct_file.WritePackedTexture` to get the `image.NRGBA` and then save as PNG + JSON offsets instead of CCTX + binary offsets. Smallest useful increment.
2. **Phase 1b, opaque binary parsers.** The per-animation `.bin.mid` files under `src/assets/data/animation/` are the most game-critical. Figure out their format — probably a keyframe list with per-frame positions, rotations, and part references — and add `ReadAnimationFile` / `WriteAnimationFile` in `file_types`. Follow-up sessions can tackle `constants.bin.mid` and the enemy data files.
3. **Phase 0b, fixture sourcing.** Still outstanding. Independent of Phase 1. Decide whether to set up an Android emulator pipeline or source existing Airyz-era save files.
4. **Phase 2, Godot project scaffold.** Once the asset tree is functional enough, this is the first time actual Godot code gets written — a `project.godot` file, a minimal scene, a CI entry that runs `godot --headless --check-only`. Unlocks the ability to actually *see* whether the asset tree imports cleanly.

Two to three more focused sessions and the rewrite starts producing a visible Godot client. That's the point where the project shifts from "improving Airyz's Go tooling" to "building something new on top of it."
