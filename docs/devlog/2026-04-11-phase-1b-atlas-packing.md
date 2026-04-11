# 2026-04-11 — Phase 1b step one: atlas packing for the Godot tree

**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))

Eighth devlog entry of the day. Phase 1a shipped a functional Godot asset tree that emitted every character part and furniture sprite as its own standalone PNG — 7,054 individual files adding up to 36 MB of the 41 MB total. That works, but it's wasteful for runtime rendering and for disk. This session adds the atlas-packing step that the legacy APK build uses, reusing the same `cct_file.WritePackedTexture` infrastructure, so the Godot tree now has both individual PNGs (for debugging and inspection) and packed atlas PNGs + JSON offset metadata (for runtime use).

## The mechanical mirror approach

I've done this same pattern three times now on this project: reader/writer symmetry in `file_types`, then the cafe writer family, then the save game writer, and now this. The shape is consistent — take an existing function that produces format A, write a twin that produces format B using the same underlying infrastructure, keep the twins structurally parallel. The "twin" framing is what keeps the parallel functions honest: if you find yourself making a design decision in the twin that the original didn't make, you're probably introducing a divergence that will bite later.

For this session that meant reading through `serialization.PackCharacters` and `serialization.PackTextures` line by line and producing `PackGodotCharacters` and `PackGodotTextures` that do the same work but serialize to different output formats at the end. Concretely:

- `PackCharacters` reads a character parts directory, groups files by subfolder (each subfolder being one character), validates that every character has the same number of parts, calls `cct_file.WritePackedTexture` to get back an `image.NRGBA` and a `file_types.ImageOffsets`, writes the offsets as binary via `file_types.WriteImageOffsets`, builds a `file_types.CharacterArt` struct, writes that as binary via `file_types.WriteCharacterArt`, and saves the image as a CCTX file via `cct_file.WriteCCTexture`.
- `PackGodotCharacters` reads the same directory with the same grouping logic and the same per-character invariant, calls the same `cct_file.WritePackedTexture` with identical parameters (`scale`, `sortByName=false`, `xOffset=0`, `padding=4`, `offset=2`), saves the image as a PNG via `imaging.Save`, and writes the `ImageOffsets` and `CharacterArt` as pretty-printed JSON.

The atlas geometry is bit-identical between the legacy and Godot outputs because both paths go through the exact same packer — the divergence is only in the final encoding step. This is exactly what the "mechanical mirror" framing wants.

For `PackGodotTextures` vs `PackTextures` the story is even simpler: one directory, one flat list of PNGs, the same packer call (`sortByName=true`, `xOffset=-1`, `padding=2`, `offset=0`), and the same two-file output (PNG + JSON offsets, no character-art manifest because there's no per-character grouping for furniture and recipe sprites).

## What got wired up

**`tool/resource_manager/serialization/godot.go`** gained three new functions plus some imports. The entry point from `BuildGodotAssets` is a new helper `packGodotAtlases` that calls `PackGodotCharacters` for the two character-parts directories with scale `0.75`, and `PackGodotTextures` for `recipeImages` / `recipeImages2` at `0.5`, `furniture` at `1.0`, `furniture2` at `0.75`, `furniture3` at `1.0`. Those scale factors are lifted directly from the hardcoded `file_map` tables inside `serialization.PackCharacters` / `serialization.PackTextures`, because that's the legacy source of truth for "what scale does this particular input directory get packed at." I chose to centralize them in `packGodotAtlases` rather than duplicate the map-lookup pattern, so that if the scales ever need to change there's exactly one place to change them on the Godot side.

A small shared helper `writeJSONFile` got added alongside the pack functions — takes a path and any JSON-marshalable value, pretty-prints with four-space indentation, writes with `os.WriteFile`, fatal on error. Mirrors the style of the existing `writeJson` helper in `serialization.go` but without the newline-normalization behavior, since the atlas JSON is generated fresh rather than being passed through from an external source.

The `BuildGodotAssets` function grew by one line — a call to `packGodotAtlases` after the existing `copyGodotFonts` call, pointed at a new `<out>/assets/atlases/` subdirectory. No other changes to the MVP path; individual PNGs still get copied under `<out>/assets/images/` as before, so the atlases are additive rather than replacing.

## Test run

Ran the build against the real source tree:

```
$ go run ./tool/build_tool -i src/ -o build_godot/ -target godot
BuildGodotAssets: src/ -> build_godot/
[... much noise from cct_file.WritePackedTexture debug prints ...]
Num rects not packed: 0
BuildGodotAssets: done
```

The output tree now includes `build_godot/assets/atlases/` with 16 files (7 PNG atlases, 7 offsets JSON files, and 2 character-art JSON manifests for the two character-parts packs):

```
characterParts.png                1.5 MB
characterParts.offsets.json       797 KB
characterParts.characterArt.json  3.2 KB
characterParts2.png               1.8 MB
characterParts2.offsets.json      827 KB
characterParts2.characterArt.json 3.3 KB
recipeImages.png                  1.3 MB
recipeImages.offsets.json         40 KB
recipeImages2.png                 723 KB
recipeImages2.offsets.json        22 KB
furniture.png                     1.3 MB
furniture.offsets.json            65 KB
furniture2.png                    1.5 MB
furniture2.offsets.json           51 KB
furniture3.png                    892 KB
furniture3.offsets.json           25 KB
```

11 MB for the atlases directory, bringing the total output tree from 41 MB to 52 MB. That's additive because the individual PNGs are still there — if I remove them in a future pass the total will drop to around 16 MB (4 MB data/audio/fonts + 12 MB atlases).

Spot-checked the JSON output. The offsets file for characterParts looks like:

```json
{
    "Type": 2,
    "Offsets": [
        {
            "Name": "0-spacer.png",
            "X": 2360,
            "Y": 7,
            "W": 3,
            "H": 3,
            "XOffset": 0,
            "YOffset": 0,
            "XOffsetFlipped": 0,
            "YOffsetFlipped": 0
        },
        ...
    ]
}
```

And the character art manifest has `PiecesPerString: 27` with 118-plus character names in the `Strings` array — matching the 0.75 scale factor and the per-character grouping logic. The first character listed alphabetically is `BrideOfFrankenstein-human`, which tells me the directory walk is ordered alphabetically and picks up Halloween costume variants correctly.

`go test ./tool/file_types/...` still passes (13 tests + 4 sub-tests, no regressions). Full workspace still builds clean under the native targets and under `GOOS=js GOARCH=wasm` for the server module.

## Noise in the build output

The `cct_file.WritePackedTexture` function has a pile of `fmt.Println("Initial rect: ...")` and `fmt.Printf("Could not find json file: ...")` debug prints that spam the build output any time the packer runs. They're harmless — the "Could not find json file" messages are the packer looking for per-image sidecar offset metadata that doesn't exist for these inputs, and the fallback path is correct. But the noise was fine for the legacy APK build (which runs maybe once a week) and isn't fine for a build tool that's going to run every time someone regenerates the Godot tree.

Stripping those prints is the same category of work as the `cafe.go` / `furniture.go` / `character.go` debug-print sweep from earlier today, just in a different package. I deliberately didn't do it in this session — `cct_file.WritePackedTexture` is the shared legacy function used by both the APK build and the Godot build, so touching it risks breaking the legacy path in ways that are hard to catch without running the full APK build. Better to do that sweep in its own focused session where the only change is removing prints, with a clean before/after diff.

Adding to the "noticed but deliberately not fixed" list for Phase 1b polish.

## Phase 1b status

One of the four pending items from the Phase 1a devlog is now done: **atlas packing** lands. The remaining three are still open:

- **Per-animation keyframe parser** — no progress. Still needs reverse engineering of `src/assets/data/animation/*.bin.mid`. Real Ghidra-or-hex-editor work. Highest remaining Phase 1b risk.
- **Opaque binary game data** — no progress. `constants.bin.mid`, `enemyCafeData.bin.mid`, `cookbookData.bin.mid`, and friends. Each its own small reverse engineering session.
- **Bitmap font conversion** — no progress. Lowest priority since Godot's TTF renderer can substitute.

Plus some polish items:

- **`cct_file` debug print sweep** — new item added this session, same category as the earlier `cafe.go` sweep.
- **Replace individual PNG copies with atlas-only output** — once Phase 2 confirms the atlases are the format the Godot client actually consumes, the individual copies become dead weight and can be removed for a ~30 MB tree-size win.
- **Skip leftover `*.cct.mid.png` artifacts** in `copyGodotImages` — Phase 1a's known-issue list, unchanged.

## The real decision point is Phase 2

Phase 1b is feeling done-ish at this point. Atlas packing was the highest-value remaining item because it directly changes what Godot can consume, and the other items either need reverse engineering (per-animation + opaque data) or are low priority (fonts, cleanup).

The more productive next session might be **Phase 2 — Godot project scaffold**. That's the first time actual Godot code gets written for this project: a `project.godot` file, a minimal scene, a CI entry that runs `godot --headless --check-only` on every push. The reason that might be the right next step: it's the first chance to *actually test* whether the asset tree I've been producing all day is importable. Right now the claim is "Godot 4 can import this without manual intervention" — but I haven't opened Godot once. There could be an encoding detail, a `.import` file convention, or a texture format mismatch that only surfaces the moment the editor actually touches the tree.

I don't want to keep shipping Phase 1 polish if there's a latent "Godot rejects the whole tree" bug waiting. A one-session Phase 2 scaffold would validate (or invalidate) all the Phase 1 work so far in a way that further Phase 1b work can't.

The tradeoff: Phase 2 requires Godot 4 to be installed, which is another system dependency to add (like Go was this morning). But that's a one-time setup, and Godot's installation story is quite good — single executable, downloadable from godotengine.org, no package manager required. I could install it and verify the asset tree in one session.

Going to raise that as the next-session question rather than commit to it now. The rewrite plan's Phase 2 section is already written; I just need to decide whether the remaining Phase 1b items come first or second.

## Next

1. **Option A:** Continue Phase 1b — sweep `cct_file` debug prints, tackle the per-animation keyframe parser. Real reverse engineering work, no new tool installs.
2. **Option B:** Jump to Phase 2 — install Godot 4, write a minimal `project.godot`, import the asset tree, see if any of the Phase 1 work breaks on contact with the actual editor. New tool install but high-value validation.
3. **Phase 0b fixture sourcing** still outstanding, still independent, still blocked on physical-world work.

My current preference is Option B, for the validation argument above. Option A ships more code but doesn't tell me whether the code from the last three hours actually works in the target environment.
