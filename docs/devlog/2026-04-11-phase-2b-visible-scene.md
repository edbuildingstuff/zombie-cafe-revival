# 2026-04-11 — Phase 2b: first rendered scene, the `_ready` lifecycle gotcha, and CI

**Author:** Edward Yang ([@edbuildingstuff](https://github.com/edbuildingstuff))

Eleventh devlog entry of the day, and the session that turns `SpriteAtlas` into actual on-screen pixels. Goal: close Phase 2b by shipping `godot/main.tscn` + a startup script that assembles the 27 pieces of `boxer-human` into visible `Sprite2D` children, extend the headless validator to instantiate the scene, and wire up a GitHub Actions workflow so every push runs the validation on ubuntu-latest. All three landed. Along the way I tripped on a `SceneTree` lifecycle quirk that the prior `validate_assets.gd` code never exercised, and made a deliberate-but-provisional choice about how to interpret the per-piece `draw_offsets`.

## What shipped

**`godot/main.tscn`** — a minimal packed scene with a `Node2D` root and the new startup script attached. No baked children; the script constructs them at runtime. It's now wired as the project's main scene via `run/main_scene="res://main.tscn"` in `project.godot`, so opening `project.godot` in the Godot 4 editor and hitting Run launches straight into the rendered scene. No `.tscn.import` or UID metadata needed at this phase — Godot generates those during the first editor pass.

**`godot/scripts/main_scene.gd`** — loads `characterParts.png` + offsets JSON + character art JSON via `SpriteAtlas.load_from`, walks the regions dict filtering for keys that start with `"boxer-human/"`, and for each matching piece constructs a `Sprite2D` child with the `AtlasTexture` assigned to `.texture`. The sprites are laid out in a 9×3 grid with 140-pixel cells starting at `(80, 80)`, and the per-piece `draw_offsets` are applied as a small positional nudge from each cell's origin. Assembly lives in a public `assemble()` method that returns the sprite count; `_ready` calls it for the normal in-editor runtime path, and the validator calls it directly (see "The lifecycle gotcha" below).

**`godot/validate_assets.gd`** — one new check, `_validate_main_scene`, which brings the validator up to 15 total checks. It loads `main.tscn` as a `PackedScene`, instantiates it, asserts the root is a `Node2D`, calls `assemble()` on the instance, then walks the children and confirms there are exactly 27 `Sprite2D` nodes and that every one of them has a valid `AtlasTexture` with a non-null atlas source and a non-zero region rect. Same pattern as the Phase 2a `_validate_character_atlas` / `_validate_texture_atlas` checks — asserts structure and prints a one-line summary with counts so a silent correctness bug (like the name-collision one from Phase 2a) would show up in the log output.

**`.github/workflows/godot-validation.yml`** — triggers on every `push` and `pull_request`, runs on `ubuntu-latest`, downloads the official Godot 4.6.2 Linux x86_64 binary from the GitHub releases mirror (`Godot_v4.6.2-stable_linux.x86_64.zip`), runs the `--editor --quit` pass to build the `.godot/` class cache on the cold CI filesystem, then runs `validate_assets.gd` via `--headless --script`. The cache pass is non-optional in CI because `.godot/` is gitignored and the `SpriteAtlas` `class_name` lookup fails without a populated `global_script_class_cache.cfg`.

## The lifecycle gotcha

First draft of `main_scene.gd` put the entire sprite-assembly path in `_ready()`, which is the conventional Godot entry point. The first validator run promptly failed with **`expected 27 Sprite2D children, got 0`** — the scene instantiated fine, the root was the right type, and yet there were no children. A debug `print("main_scene: _ready() firing")` revealed the root cause: that print appeared **after** the validation-failed message, not before. `_ready` was running, but on a later frame than the validator's synchronous child-count assertion.

The mechanism: `validate_assets.gd` uses `extends SceneTree` and runs its work inside `_init()`, which is the very earliest lifecycle phase — the SceneTree exists but its main loop hasn't started ticking yet. When `_init` calls `get_root().add_child(instance)`, the node enters the tree, but `_ready()` is deferred to the first frame the SceneTree processes. Since `_init` then immediately inspects the instance's children and calls `quit(1)` on failure, the deferred `_ready` fires only just before the process exits — far too late to matter.

This is specific to `SceneTree`-derived scripts running in `_init`. In a normal game (main loop running, scenes loaded via `change_scene_to_packed`), `_ready` fires synchronously when the node enters the tree, and this whole problem doesn't exist.

**The fix:** factor assembly out of `_ready()` into a public `assemble()` method, have `_ready()` call it (so the in-editor runtime path is unchanged), and have the validator call it directly by name via `instance.call("assemble")`. The validator now exercises the same assembly code the in-editor runtime does, but bypasses the lifecycle quirk by invoking it synchronously. A `get_child_count() == 0` guard inside `_ready()` prevents double-assembly if both paths end up running in the same instance.

I spent a couple of minutes deciding whether to lean on `await get_tree().process_frame` in the validator instead — it would let the `_ready` path stay canonical — but that approach requires turning `_init` into an async function, and an async validator is a meaningfully bigger change than an `assemble()` method. The `assemble()` extraction is also arguably better design: it gives the scene a testable, re-callable "build my content" entry point that doesn't depend on `_ready` lifecycle assumptions. Game code later on is going to want exactly this shape anyway (think "respawn the character" or "load a different character without reloading the scene").

Adding to the running list of Godot-specific gotchas this project has collected:

1. `--path` makes subsequent `--script` arguments resolve via `res://`, not system paths.
2. Newly-added `class_name` scripts require a `--editor --quit` pass to register in the global class cache.
3. The `_console` Godot variant writes to stdout in-process; the plain variant pops a separate window.
4. **New:** Nodes added to `get_root()` inside a `extends SceneTree` script's `_init` don't get their `_ready` callback synchronously. Use explicit public methods for construction logic, or switch to an async `await` pattern.

## The draw_offsets interpretation

The handoff for this session flagged this as a "check in before coding" point: the per-piece `XOffset` / `YOffset` / `XOffsetFlipped` / `YOffsetFlipped` fields in the atlas offsets JSON don't document their semantics anywhere in the rewrite project, and the field names alone don't tell you which axis is up, whether "flipped" means horizontal mirroring, or what coordinate space they're anchored to. I investigated before committing to an interpretation, and ended up making a pragmatic-but-provisional choice rather than blocking the session.

What I found:

- The values are authored per-image, not computed by the packer. The per-image `.json` files under `src/assets/images/characterParts*/` contain `XOffset` / `YOffset` / `XOffset2` / `YOffset2` fields on every piece, and `cct_file.WritePackedTexture` in the Go pipeline copies them verbatim into the output offsets JSON. `XOffset2` is renamed to `XOffsetFlipped` at the Go `file_types.Offset` boundary.
- The range is small but non-uniform. For `boxer-human`, most pieces have `XOffset`/`YOffset` in the 0–5 pixel range. For `conquistador-human/head1.png`, `XOffset` is 22 and `XOffset2` is 14 — still small, but an order of magnitude bigger than the leg pieces on the same character.
- That range is much too small to be primary positioning. The character pieces themselves are 25–113 pixels tall; if `XOffset`/`YOffset` were the primary layout coordinates, every part of every character would cluster inside a ~25×25 pixel blob. Whatever these values are, they're a fine-tuning nudge on top of some larger primary positioning source.
- The most likely meaning is a per-piece anchor offset: the coordinate inside the piece rectangle where a skeleton bone attaches. The "flipped" variant would then be the anchor coordinate when the same piece is drawn horizontally mirrored (because mirroring swaps which side of the piece the anchor lands on).
- But without the per-animation keyframe parser (Phase 1b pending), we don't have the primary positioning source. The `.bin.mid` animation files under `src/assets/data/animation/` presumably contain the frame-by-frame positions and rotations of each bone; until we parse those, we can't place the pieces into a posed skeleton.

Given all that, I decided to **not** try to render `boxer-human` as a posed character this session. Instead, `main_scene.gd` lays the 27 pieces out in a 9×3 grid — one piece per cell, origin-anchored, uniform 140×140 cells — and applies `(XOffset, YOffset)` as a per-sprite position nudge on top of each cell origin. The visible result is the sprite sheet for `boxer-human`, not a posed character. The nudge from `draw_offsets` is typically only 0–5 pixels so its visual effect is subtle, but the code path is exercised end-to-end, and the validator confirms every `Sprite2D` ends up with a valid `AtlasTexture`.

This choice is documented in the script header so future me doesn't mistake the grid for an intentional layout. When the animation parser lands (Option B from the handoff — the highest-value Phase 1b item), the grid code goes away and `assemble()` will instead walk animation keyframes, position pieces relative to a root anchor, and use `draw_offsets` as the per-piece anchor offset it appears to be.

## Verification

Final run of the full validator against the real assets:

```
Godot Engine v4.6.2.stable.official.71f334935 - https://godotengine.org

  OK json(array, 216 items): res://assets/data/foodData.json
  OK json(array, 219 items): res://assets/data/characterData.json
  OK json(array, 60 items):  res://assets/data/animationData.json
  OK json(object, 2 keys):   res://assets/atlases/characterParts.offsets.json
  OK json(object, 2 keys):   res://assets/atlases/characterParts.characterArt.json
  OK json(object, 2 keys):   res://assets/atlases/furniture.offsets.json
  OK texture(2048.0x2048.0): res://assets/atlases/characterParts.png
  OK texture(2048.0x2048.0): res://assets/atlases/furniture.png
  OK texture(62.0x65.0):     res://assets/images/boxer-human/back_head1.png
  OK font:                   res://assets/fonts/A Love of Thunder.ttf
  OK audio(130.69s):         res://assets/audio/Zombie Theme V1.ogg
  OK audio(9.87s):           res://assets/audio/sfx/blender.ogg
  OK SpriteAtlas(chars):     3051 regions, 113 characters, 27 pieces each
    first non-degenerate key 'BrideOfFrankenstein-human/0-spacer.png' at [P: (2360.0, 7.0), S: (3.0, 3.0)]
    get_character_pieces('boxer-human') -> 27 AtlasTextures
  OK SpriteAtlas(furn):      256 regions (no character art)
    first non-degenerate key '1.png' at [P: (671.0, 807.0), S: (62.0, 123.0)]
  OK main.tscn:              27 Sprite2D children, 27 with valid AtlasTextures

========== VALIDATION PASSED ==========
```

15/15 checks pass, including the new `main.tscn` end-to-end scene check. The full workspace Go build (`file_types`, `build_tool`, `resource_manager`, `cctpacker` native; `server` under `GOOS=js GOARCH=wasm`) still builds clean — nothing in this session touched Go code.

Not verified locally: **the CI workflow itself**. I can't run GitHub Actions from this machine, so the workflow is best-effort based on the standard Godot 4.6.2 Linux download URL pattern. The first `push` will confirm whether the download path, `--editor --quit` pre-pass, and `--script` invocation all work on ubuntu-latest. If the URL 404s or the editor pass hits an X11 dependency wall on the runner, I'll fix it in a follow-up — all three are easy to diagnose from the Actions log.

## What Phase 2b leaves open

From the rewrite plan's Phase 2b item list, this session closed the two core deliverables (`main.tscn` + CI workflow). Remaining as `(pending)`:

- **Per-character index in `SpriteAtlas.get_character_pieces`.** Current impl is O(n) per call, scanning all 3,051 regions. Fine for one-off lookups; waste for hot loops. Precompute a `Dictionary[String, Array[AtlasTexture]]` once during load. Not worth a dedicated session — a future session that adds a second character render can do it as part of its setup.
- **Cafe background.** Blocked on the `mapTiles` texture packer being re-enabled in `build_tool/main.go` (currently commented out). Separate from the character rendering path.
- **Optional headless screenshot.** The handoff listed this as "optional" and I didn't pursue it this session — scene-tree instantiation + child-count + texture-validity assertions give us the coverage we need without the complexity of a pixel-level comparison. If we want visual regression testing later, the cleanest path is a `get_viewport().get_texture().get_image().save_png(...)` at the end of `_validate_main_scene` followed by an image-diff step in the CI workflow. Noting for whenever the "visual regression" itch actually shows up.

## What I want to remember from this session

Three things.

First, **`extends SceneTree` + `_init` + `add_child` does NOT fire `_ready` synchronously**. This is a lifecycle corner case the prior `validate_assets.gd` code never hit because it only loaded resources, never instantiated scenes. If a future test or tool script needs to exercise a scene inside `_init`, it either needs an explicit construction method (what I did), an `await` on a frame tick (what I didn't do), or to switch from `SceneTree` to a normal Node-based main scene. This is now gotcha #4 in the running CLI gotchas list.

Second, **making assembly a public method instead of relying on `_ready` is better design anyway**, not just a workaround for the lifecycle quirk. Scene construction logic that lives in `_ready` can only run once per instance; scene construction logic in a named method can be re-called (re-render for a new character, rebuild after an asset hot-reload, run from a unit test). The validator is the first consumer but it will not be the last. I'm going to default to this pattern for the foreseeable future: `_ready` is a *delegator*, not a *constructor*.

Third, **"provisional-but-documented" is a valid answer to semantic ambiguity**. The `draw_offsets` interpretation is not firmly grounded — I don't know for sure they're bone anchor offsets, I haven't ghidra'd the `.so` to confirm, and the first real character pose might demonstrate the interpretation is wrong. But I can make a reasonable guess, apply it consistently, document the guess as provisional in the script header AND the devlog, and move forward. The alternative — blocking on certainty — would burn a whole session on Ghidra work that isn't actually the highest-value thing to do right now (the per-animation parser is). The devlog itself is the safety rail: six months from now I can find this entry and know exactly which piece of positioning code was a guess versus which was verified.

## Next

Phase 2b is structurally done. The two remaining Phase 2b items (`get_character_pieces` optimization and cafe background) are either trivial or blocked on unrelated work. Phase 2c is implicitly "pose the character correctly," which is gated on the per-animation keyframe parser, which is Option B from the handoff.

So the natural next session is **Option B — Phase 1b per-animation keyframe parser**. It's real byte-level reverse engineering: hex-dump a sample `.bin.mid` animation file, infer the structure (probably a keyframe count followed by per-frame (part_index, x, y, rotation, scale) tuples, though that's a guess), write `ReadAnimationFile` / `WriteAnimationFile` in `file_types` with round-trip tests, and plumb the decoded JSON through `build_tool`. Once that lands, a follow-up session can rip out the grid layout in `main_scene.gd` and replace it with real skeletal posing driven by the first keyframe of the character's idle animation.

The step after that is the actual game tick work. But that's two sessions away, not one.
