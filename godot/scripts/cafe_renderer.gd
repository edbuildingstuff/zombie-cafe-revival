class_name CafeRenderer
extends RefCounted

## Phase 4 Session 1: renders a Cafe Dict (Phase 3 LegacyLoader output)
## as Sprite2D children of a parent Node2D. Three passes:
##   1. Floor — one tile sprite per Cafe.Tiles[] entry
##   2. Walls — one wall sprite per Cafe.Tiles[*].U5/U7/U9 with Type=2
##   3. Furniture — one furniture sprite per Cafe.Tiles[*].U5/U7/U9 with Type=1
##
## All passes emit Sprite2D children with z_index set to enforce layering.
##
## Coordinate system: ISOMETRIC projection. Tile sprites are 164x105 diamond
## sprites with the diamond drawn at ~100x50 stride within the bounding box.
## Adjacent tiles must offset diagonally for the diamond edges to chain into
## continuous lines (continuous pavement, continuous walls, etc.).
##
##   screen_x = (tx - ty) * (TILE_W / 2)
##   screen_y = (tx + ty) * (TILE_H / 2)
##
## With TILE_W=100, TILE_H=50: tile (0,0) at (0,0); tile (1,0) at (50, 25);
## tile (0,1) at (-50, 25); tile (1,1) at (0, 50). The cafe spans
## (-2700..1864) × (0..2305) in pixels for a 35x55 grid.
##
## Phase 4 Session 1 used Cartesian (tx*50, ty*50) as a "best-effort coord fit"
## per spec §3.3. Session 1.5 corrected this to proper iso projection so
## diamond edges tessellate into continuous pavement/wall lines.
##
## Phase 4 Session 1 RE finding: cafe floor tiles, walls, AND furniture all
## share the existing `furniture` atlas — every observed U1 value (51, 68, 69,
## 70, 73, 113, 29, 38, 50, 30, 39, 49, 24, 25, 41, 32, 28, 31) resolves in
## furniture.offsets.json. Visual inspection of furniture/51.png, /68.png,
## /113.png confirmed these are isometric grass/floor diamond tiles.
## The mapTiles atlas is for Phase 5's world-map overview (city streets,
## enemy/friendly cafe buildings, UI buttons) — NOT for cafe interior rendering.

const TILE_W: int = 100  # full diamond width (legacy iso projection stride)
const TILE_H: int = 50   # full diamond height

const Z_FLOOR: int = 0
const Z_WALL: int = 10
const Z_FURNITURE: int = 20


# Public entry point. Returns the total sprite count for assertion.
# atlases: { "tiles": SpriteAtlas, "walls": SpriteAtlas|null, "furn": SpriteAtlas }
static func render(parent: Node2D, cafe_dict: Dictionary, atlases: Dictionary) -> int:
	var count: int = 0
	count += _render_floor(parent, cafe_dict, atlases.get("tiles"))
	count += _render_walls(parent, cafe_dict, atlases.get("walls"))
	count += _render_furniture(parent, cafe_dict, atlases.get("furn"))
	return count


static func _render_floor(parent: Node2D, cafe_dict: Dictionary, tiles_atlas) -> int:
	if tiles_atlas == null:
		push_error("CafeRenderer._render_floor: tiles_atlas is null")
		return 0
	var tiles: Array = cafe_dict.get("Tiles", [])
	var map_size_x: int = int(cafe_dict.get("MapSizeX", 0))
	if map_size_x <= 0 or tiles.is_empty():
		push_error("CafeRenderer._render_floor: invalid MapSizeX=%d or empty Tiles" % map_size_x)
		return 0

	var count: int = 0
	for i in range(tiles.size()):
		var tile: Dictionary = tiles[i]
		var u1: int = int(tile.get("U1", 0))
		var key := _atlas_region_for_tile_u1(u1)
		var region: AtlasTexture = tiles_atlas.get_region(key)
		if region == null:
			# Empty/unknown region — skip rather than placing a null sprite.
			# With the identity mapping (U1 == stem) any U1 not in the atlas
			# is skipped; defensive guard for unexpected values.
			continue

		var tx: int = i % map_size_x
		var ty: int = i / map_size_x

		var sprite := Sprite2D.new()
		sprite.name = "tile_%d" % i
		sprite.texture = region
		sprite.centered = false
		sprite.position = _iso_position(tx, ty)
		sprite.z_index = Z_FLOOR

		parent.add_child(sprite)
		count += 1

	return count


## Convert tile (tx, ty) to isometric screen position (top-left anchor).
## See module docstring §"Coordinate system".
static func _iso_position(tx: int, ty: int) -> Vector2:
	@warning_ignore("integer_division")
	var ix: int = (tx - ty) * (TILE_W / 2)
	@warning_ignore("integer_division")
	var iy: int = (tx + ty) * (TILE_H / 2)
	return Vector2(ix, iy)


static func _render_walls(parent: Node2D, cafe_dict: Dictionary, walls_atlas) -> int:
	if walls_atlas == null:
		# Acceptable: caller may pass null to skip walls. Render nothing.
		return 0
	var tiles: Array = cafe_dict.get("Tiles", [])
	var map_size_x: int = int(cafe_dict.get("MapSizeX", 0))
	if map_size_x <= 0 or tiles.is_empty():
		return 0

	var count: int = 0
	for i in range(tiles.size()):
		var tile: Dictionary = tiles[i]
		for slot in ["U5", "U7", "U9"]:
			var obj = tile.get(slot)
			if obj == null or not (obj is Dictionary):
				continue
			var t: int = int(obj.get("Type", 0))
			if t != 2:  # 2 = Wall
				continue
			var wall = obj.get("Wall")
			if wall == null or not (wall is Dictionary):
				continue
			var u1: int = int(wall.get("U1", 0))

			var sprite := Sprite2D.new()
			sprite.name = "wall_tile%d_%s" % [i, slot]
			sprite.centered = false
			sprite.z_index = Z_WALL

			var key := "%d.png" % u1
			var region: AtlasTexture = walls_atlas.get_region(key)
			if region != null:
				sprite.texture = region
			else:
				# Fallback: small colored rectangle so the wall slot
				# is visually identifiable. Sprite2D needs a non-null
				# texture for the validator's assertion.
				sprite.texture = _placeholder_texture(Color(0.6, 0.4, 0.2))

			var tx: int = i % map_size_x
			var ty: int = i / map_size_x
			sprite.position = _iso_position(tx, ty)

			parent.add_child(sprite)
			count += 1

	return count


static func _placeholder_texture(color: Color) -> ImageTexture:
	var img := Image.create(TILE_W, TILE_H, false, Image.FORMAT_RGBA8)
	img.fill(color)
	return ImageTexture.create_from_image(img)


static func _render_furniture(parent: Node2D, cafe_dict: Dictionary, furn_atlas) -> int:
	if furn_atlas == null:
		push_error("CafeRenderer._render_furniture: furn_atlas is null")
		return 0
	var tiles: Array = cafe_dict.get("Tiles", [])
	var map_size_x: int = int(cafe_dict.get("MapSizeX", 0))
	if map_size_x <= 0 or tiles.is_empty():
		return 0

	var count: int = 0
	for i in range(tiles.size()):
		var tile: Dictionary = tiles[i]
		# Direct furniture-in-slot
		for slot in ["U5", "U7", "U9"]:
			count += _emit_furniture_in_slot(parent, tile, slot, i, map_size_x, furn_atlas)
		# Furniture nested inside Wall.DecorationObject (recursive CafeObject).
		for slot in ["U5", "U7", "U9"]:
			var obj = tile.get(slot)
			if obj == null or not (obj is Dictionary):
				continue
			var wall = obj.get("Wall")
			if wall == null or not (wall is Dictionary):
				continue
			var deco = wall.get("DecorationObject")
			if deco == null or not (deco is Dictionary):
				continue
			count += _emit_furniture_object(parent, deco, i, map_size_x, furn_atlas, "deco_%d_%s" % [i, slot])

	return count


static func _emit_furniture_in_slot(
	parent: Node2D, tile: Dictionary, slot: String, tile_idx: int,
	map_size_x: int, furn_atlas) -> int:
	var obj = tile.get(slot)
	if obj == null or not (obj is Dictionary):
		return 0
	var t: int = int(obj.get("Type", 0))
	if t != 1:  # 1 = Furniture
		return 0
	return _emit_furniture_object(parent, obj, tile_idx, map_size_x, furn_atlas, "furn_tile%d_%s" % [tile_idx, slot])


static func _emit_furniture_object(
	parent: Node2D, cafe_object: Dictionary, tile_idx: int,
	map_size_x: int, furn_atlas, name: String) -> int:
	var furn = cafe_object.get("Furniture")
	if furn == null or not (furn is Dictionary):
		return 0
	var u2: int = int(furn.get("U2", 0))
	var key := "%d.png" % u2
	var region: AtlasTexture = furn_atlas.get_region(key)

	var sprite := Sprite2D.new()
	sprite.name = name
	sprite.centered = false
	sprite.z_index = Z_FURNITURE
	if region != null:
		sprite.texture = region
	else:
		sprite.texture = _placeholder_texture(Color(0.2, 0.6, 0.4))

	var tx: int = tile_idx % map_size_x
	var ty: int = tile_idx / map_size_x
	sprite.position = _iso_position(tx, ty)

	parent.add_child(sprite)
	return 1


## Tiles[].U1 -> furniture-atlas region key. Phase 4 Session 1 RE finding:
## the cafe floor tiles, walls, and furniture all live in the existing
## `furniture` atlas (verified by matching all observed U1 values against
## furniture.offsets.json AND visual inspection of furniture/51.png,
## /68.png, /113.png — all isometric grass/floor diamond tiles). The
## mapTiles atlas is for the Phase 5 world-map overview, not cafe interior.
## So the lookup is a direct identity: U1 == filename stem.
static func _atlas_region_for_tile_u1(u1: int) -> String:
	return "%d.png" % u1
