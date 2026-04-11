# 2026-04-11 — Phase 1 validation: opening the asset tree in real Godot

**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))

Ninth devlog entry of the day. This session's question was the one I kept deferring: *does the Phase 1 asset tree I've been building all day actually work when Godot 4 touches it?* The answer is **yes — every category validated on first run, zero failures, zero warnings.**

## What I was testing

Phase 1a produced a Godot-friendly asset tree. Phase 1b added atlas packing. I shipped two devlog entries claiming "Godot can import this" without having Godot installed anywhere on the machine. That's a lot of claim surface to leave unchecked, and I wanted to either validate it or discover the bugs before layering the per-animation keyframe parser and remaining Phase 1b work on top.

The specific claims being tested:

1. The 4 JSON data files (`foodData.json`, `characterData.json`, `animationData.json`, plus the 3 atlas offset/manifest JSONs) are valid JSON that Godot's `JSON.parse_string()` accepts and produces the expected shapes.
2. The atlas PNG files load as `Texture2D` resources.
3. The individual character-part PNGs load as `Texture2D` resources.
4. The TTF font loads as a `FontFile` resource.
5. The OGG audio files load as `AudioStream` resources with valid durations.

If any of these failed, the Phase 1 work had a bug that would compound with every additional category I added.

## What I built for the validation

**`godot/project.godot`** — a minimal Godot 4 project file. Config version 5, a project name, a description noting it's the validation scaffold. No scenes, no scripts wired into the startup flow, no assets listed directly. Just enough for Godot to recognize the directory as a project and run its filesystem scanner against it.

**`godot/assets/`** — 5.5 MB of representative samples copied from the full 52 MB `build_godot/assets/` tree. The selection was deliberate: one file from each asset category, enough to hit every importer Godot has for the file types I care about.

- `data/foodData.json`, `data/characterData.json`, `data/animationData.json` — the three JSON data files.
- `images/boxer-human/1x1.png`, `back_head1.png`, `back_leftarm1.png` — three individual character parts.
- `atlases/characterParts.png` + `characterParts.offsets.json` + `characterParts.characterArt.json` — the full triple the atlas packer emits for character sprites.
- `atlases/furniture.png` + `furniture.offsets.json` — the atlas pair the packer emits for texture categories without character grouping.
- `fonts/A Love of Thunder.ttf` — the TTF.
- `audio/Zombie Theme V1.ogg` — the music track.
- `audio/sfx/blender.ogg` — one sound effect from the 204-file sfx set.

Fourteen files, covering every Phase 1 output category. If any of these failed to import or parse, the whole asset pipeline would need a fix.

**`godot/validate_assets.gd`** — a headless GDScript that exercises each category explicitly. Extends `SceneTree` so it runs standalone via `godot --headless --script res://validate_assets.gd --path godot/` without needing a main scene. For each JSON file, it opens the file via `FileAccess.open()`, reads the text, parses it with `JSON.parse_string()`, and asserts the result is the expected shape (array with N+ elements for the data files, non-empty object for the offset/manifest files). For each texture, it checks `ResourceLoader.exists()`, loads as `Texture2D`, and confirms the size is non-zero. For the font, it loads as `FontFile`. For audio, it loads as `AudioStream` and queries the duration. Any failure gets appended to a list and printed at the end; success prints a summary and exits with code 0, failure exits with code 1.

The script is worth keeping as a regression test for future asset-builder changes — it's a known-good checkpoint, and if I add a new category or change an existing one, I can re-run it and see immediately whether Godot still consumes the output.

## Install and first run

Installed Godot Engine 4.6.2 via winget (`GodotEngine.GodotEngine`) — background job, finished in about a minute while I was writing the project file. The binary landed at `C:\Users\edwar\AppData\Local\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.6.2-stable_win64_console.exe` — the `_console` variant is important because it writes log output to stdout instead of a separate Windows console window, which is what I need for headless operation in Git Bash.

First run was `godot --headless --editor --quit --path godot/` to trigger the import pipeline. The filesystem scanner found all 8 importable assets (JSON files don't appear here because they're not a Godot resource type — they're raw data Godot loads at runtime), and the reimport step ran through them all with no errors. Godot's import cache under `godot/.godot/imported/` got populated with:

- `.ctex` files for every PNG (Godot's `CompressedTexture2D` format)
- `.fontdata` for the TTF (`FontFile` resource)
- `.oggvorbisstr` for each OGG (`AudioStreamOggVorbis` resource)
- `.md5` files alongside each for change detection

This is exactly the metadata Godot produces when it's happy. If any of the files had been unrecognized or malformed, the import step would have logged errors or left the cache incomplete. It didn't, on any of them.

## The actual validation run

After confirming the import pipeline ate the files cleanly, I ran the GDScript validator. Initially typed the wrong path — passed `--script godot/validate_assets.gd` along with `--path godot/`, and Godot tried to resolve `res://godot/validate_assets.gd` (the `--path` flag makes the subsequent `res://` root). Fixed it by using `res://validate_assets.gd` directly.

Second run succeeded:

```
Godot Engine v4.6.2.stable.official.71f334935 - https://godotengine.org

  OK json(array, 216 items): res://assets/data/foodData.json
  OK json(array, 219 items): res://assets/data/characterData.json
  OK json(array, 60 items):  res://assets/data/animationData.json
  OK json(object, 2 keys):   res://assets/atlases/characterParts.offsets.json
  OK json(object, 2 keys):   res://assets/atlases/characterParts.characterArt.json
  OK json(object, 2 keys):   res://assets/atlases/furniture.offsets.json
  OK texture(2048x2048):     res://assets/atlases/characterParts.png
  OK texture(2048x2048):     res://assets/atlases/furniture.png
  OK texture(62x65):         res://assets/images/boxer-human/back_head1.png
  OK font:                   res://assets/fonts/A Love of Thunder.ttf
  OK audio(130.69s):         res://assets/audio/Zombie Theme V1.ogg
  OK audio(9.87s):           res://assets/audio/sfx/blender.ogg

========== VALIDATION PASSED ==========
All asset categories load and parse as expected.
```

Twelve checks, twelve passes. The interesting numbers:

- **216 food items** parsed out of `foodData.json`. That's the entire cookbook.
- **219 characters** parsed out of `characterData.json`. That's more than I expected — Airyz's JSON must include every character variant (human + zombie forms), not just the base roster.
- **60 animation entries** parsed out of `animationData.json` — matches the ~30 animations-per-direction count I'd expect for a 2D character with NW and SW variants.
- **2048×2048** atlases for both `characterParts` and `furniture`. That's sitting at the edge of older mobile hardware's max texture size (some Android GPUs cap at 2048 or even 1024), which is worth filing away for later. Godot 4 will handle it fine on any modern machine.
- **130.69 seconds** for "Zombie Theme V1.ogg" — a two-and-a-bit-minute loop, which sounds right for an ambient cafe BGM.
- **9.87 seconds** for the blender sfx, which is quite long for a sound effect — probably a multi-cycle whir.

## What this validates

Every claim I shipped today about "the Godot tree is importable" now has evidence. Specifically:

1. **Phase 1a's MVP output is valid.** The JSON data files (both the direct copies of Airyz's editable sources and the decoded `animationData.json`) are parseable. The individual PNGs import. The TTF imports. The OGGs import.
2. **Phase 1b's atlas packing is valid.** The packed PNG atlases load at full 2048×2048 resolution with no corruption. The atlas offset JSON files and the character art manifest JSON parse as dictionaries. The shape Go's `encoding/json` produces via `MarshalIndent` is directly consumable by Godot's `JSON.parse_string()` — no escaping or encoding mismatches.
3. **The combined Phase 1 pipeline is end-to-end green.** Running the builder against the real source tree, copying a representative subset into a Godot project, and validating with a real Godot 4.6.2 install all work on first run after fixing one path-argument confusion.

Nothing in the Phase 1 work needs fixing before continuing.

## What this doesn't validate

Important distinctions, because I don't want to overclaim:

- **Phase 2 is not done.** Phase 2's done criterion is "opening `godot/project.godot` in Godot 4 shows the cafe background, a player character sprite, and a rendered test UI." I haven't rendered anything visually yet. All I've done is prove the asset import pipeline works — the actual scene composition, sprite display, UI scaffold, and headless CI entry all remain.
- **Runtime integration isn't tested.** The JSON files parse, but I haven't written any game code that actually *uses* them to, say, look up a food item by ID or assemble a character from parts. That's Phase 3/4 territory and requires the animation keyframe parser first.
- **AtlasTexture indexing isn't tested.** I confirmed the atlas PNGs load as `Texture2D`, but I haven't exercised `AtlasTexture` — the Godot resource that takes a source texture and a region rectangle to crop a sub-image. The atlas offsets JSON gives me the region rectangles, but wiring that up into a working `AtlasTexture`-per-character-part pipeline is a future session.
- **Cross-platform behavior isn't tested.** I ran on Windows with Godot's Windows binary. Linux/Mac imports might behave identically or might surface file-encoding issues (the font filename `A Love of Thunder.ttf` with the space works on Windows, needs verification elsewhere).

These are all fine as deferred questions. The point of this session was to verify Phase 1's foundation, not to finish Phase 2.

## Project structure decisions

Committed (or will be committed):

- `godot/project.godot` — the scaffold project file. Tracked.
- `godot/validate_assets.gd` — the headless validation script. Tracked.
- `godot/assets/` — 5.5 MB of representative samples. **This is the interesting call.** Arguments for tracking them: the validation script references them by path, so committing makes the validation reproducible for anyone who clones the repo and runs the script. Arguments against: 5.5 MB of binary assets in git isn't great, and they're regeneratable from `build_godot/` via the copy commands I ran in this session. I'm going to track them anyway because reproducibility of the validation script is more valuable than the 5.5 MB git weight.
- `godot/**/*.import` — Godot's per-asset import settings. Per Godot convention these should be committed; they capture import parameters (texture filtering, compression quality, font antialiasing, etc.) that affect runtime behavior.

Gitignored:

- `godot/.godot/` — Godot's internal cache directory (`imported/`, `editor/`, misc state). Per Godot convention this is local-only; it's regenerated on first project open.

`.gitignore` gained `godot/.godot/` this session. That's the minimal Godot-related ignore needed.

## Phase 1 status

**Phase 1a: done (confirmed valid).**

**Phase 1b:**
- *(done)* Atlas packing.
- *(done, this session)* **Validation that the asset tree imports in real Godot** — new implicit item, would have been the smart thing to schedule before Phase 1b but I only figured that out the hard way.
- *(pending)* Per-animation keyframe parser.
- *(pending)* Opaque binary game data parsers.
- *(pending)* `cct_file` debug print sweep.
- *(pending, lower priority)* Bitmap font conversion.
- *(pending, cosmetic)* Skip `*.cct.mid.png` artifacts, copy social icons.
- *(pending, size)* Remove individual PNG copies once atlas-only rendering is confirmed.

Phase 1 is functionally validated even though Phase 1b has unfinished items. The unfinished items are additive improvements to an already-working pipeline, not bug fixes to a broken one, which is a much better position than I was in before this session.

## What I want to remember

Two things.

First, **the project-file path argument in Godot's CLI is sticky**. `--path` sets the `res://` root for everything that follows, including `--script`. The first failed run was me typing `--script godot/validate_assets.gd` as if it were a system path, when Godot was interpreting it relative to the `res://` root I'd just set. The fix is always `res://<path-relative-to-project-root>`. Future sessions doing headless Godot work should default to using `res://` prefixes for any resource path passed on the command line.

Second, **install-then-validate is cheaper than I expected**. I was worried about adding Godot as another system dependency, and it turned out to take about two minutes: one winget call, one binary path lookup, one correction of a CLI argument, one successful validation run. That's cheaper than any of the three Phase 1b items I was contemplating doing instead. The general lesson: when a validation blocker is "install one tool and run one script," the install is almost always worth it over "spend a session building more code on an unvalidated foundation." I should apply this heuristic more often.

## Next

1. **Continue Phase 1b polish.** The per-animation keyframe parser is the highest-value next item — it's game-critical (characters can't animate without it) and it's real reverse engineering work, not mechanical mirroring. This is also the first session where I'd need to open actual binary files and stare at bytes, which is a different kind of work from the rest of today.
2. **Or jump to Phase 2 proper.** Build a minimal scene that displays one character atlas, use `AtlasTexture` to crop a single character part, confirm it renders in a headless screenshot. This is a small amount of GDScript and would surface any runtime integration issues that pure import validation missed.
3. **Phase 0b fixture sourcing** still independent and still blocked on physical-world work.

Leaning toward option 1 because it's unblocked and the per-animation parser is a Phase 1b completion item. Option 2 is also good and would give the first visual artifact of the rewrite. Open to either. Either way, today's validation session closed the biggest risk I had walking into this afternoon.
