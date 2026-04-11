class_name SpriteAtlas
extends RefCounted

## Runtime wrapper around a packed sprite atlas produced by the Go
## build tool's `-target godot` flag.
##
## Keys the regions dict uniquely:
##   - For character atlases (with a character art manifest):
##     "<character_name>/<part_name>", e.g., "boxer-human/back_head1.png".
##     The offsets JSON lists entries in group-order, so entry i
##     belongs to character (i / pieces_per_character) and piece
##     (i % pieces_per_character).
##   - For non-character atlases: plain "<part_name>", e.g., "42.png".
##
## The distinction matters because a character atlas has roughly
## 3,000+ entries (113 characters × 27 pieces) with only ~27 unique
## part names — storing them under bare part names would silently
## collapse 99% of the atlas onto the last character's parts.
##
## The offsets JSON format is produced by
## tool/resource_manager/serialization/godot.go. Each entry has
## Name / X / Y / W / H plus XOffset / YOffset / XOffsetFlipped /
## YOffsetFlipped fields (the last four are per-image positioning
## overrides the legacy engine used; game code can apply them when
## drawing).

var source: Texture2D
var regions: Dictionary = {}  # composite key -> AtlasTexture
var draw_offsets: Dictionary = {}  # composite key -> Vector4(x, y, x_flipped, y_flipped)

# Only populated when a character art manifest is loaded
var character_names: PackedStringArray = PackedStringArray()
var pieces_per_character: int = 0

# Per-character precomputed piece list. Populated during _load_offsets
# so get_character_pieces() is O(1) dict lookup instead of an O(n)
# scan of the regions dict. Only built for character atlases; stays
# empty for plain texture atlases (furniture, recipes, etc).
var _character_pieces_index: Dictionary = {}  # character_name -> Array[AtlasTexture]


static func load_from(
	atlas_png_path: String,
	offsets_json_path: String,
	character_art_json_path: String = ""
) -> SpriteAtlas:
	var atlas := SpriteAtlas.new()

	if not ResourceLoader.exists(atlas_png_path):
		push_error("SpriteAtlas: atlas texture not found: " + atlas_png_path)
		return null

	atlas.source = load(atlas_png_path)
	if atlas.source == null:
		push_error("SpriteAtlas: failed to load atlas texture: " + atlas_png_path)
		return null

	# Character art loads first so _load_offsets can build composite keys.
	if character_art_json_path != "":
		if not atlas._load_character_art(character_art_json_path):
			return null

	if not atlas._load_offsets(offsets_json_path):
		return null

	return atlas


func get_region(key: String) -> AtlasTexture:
	return regions.get(key, null)


func has_region(key: String) -> bool:
	return regions.has(key)


func region_keys() -> Array:
	return regions.keys()


func get_draw_offset(key: String) -> Vector4:
	return draw_offsets.get(key, Vector4.ZERO)


## For character atlases: build the composite key for the given
## (character, part) pair, suitable for get_region lookup.
func character_key(character_name: String, part_name: String) -> String:
	return character_name + "/" + part_name


## For character atlases: returns an array of AtlasTexture covering
## every part for the named character, in pack order (back_head1,
## back_leftarm1, etc.). Empty array if character_name isn't in
## the manifest. O(1) dict lookup — the index is populated during
## _load_offsets so this method is safe to call in hot loops (e.g.,
## per-frame pose rebuilds once animated playback lands).
func get_character_pieces(character_name: String) -> Array:
	return _character_pieces_index.get(character_name, [])


func _load_offsets(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_error("SpriteAtlas: offsets JSON not found: " + path)
		return false

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("SpriteAtlas: cannot open offsets JSON: " + path)
		return false

	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		push_error("SpriteAtlas: offsets JSON is not an object: " + path)
		return false

	var root := parsed as Dictionary
	if not root.has("Offsets"):
		push_error("SpriteAtlas: offsets JSON missing 'Offsets' key: " + path)
		return false

	var entries := root["Offsets"] as Array
	var is_character_atlas := not character_names.is_empty() and pieces_per_character > 0

	for i in range(entries.size()):
		var entry := entries[i] as Dictionary
		var part_name := entry.get("Name", "") as String
		if part_name == "":
			continue

		var w := int(entry.get("W", 0))
		var h := int(entry.get("H", 0))
		if w <= 0 or h <= 0:
			# Some legacy entries have W=-1/H=-1 as placeholders. Store
			# them as zero-size so callers can detect and skip.
			w = 0
			h = 0

		var key := part_name
		var char_name := ""
		if is_character_atlas:
			var char_idx := i / pieces_per_character
			if char_idx < character_names.size():
				char_name = character_names[char_idx]
				key = char_name + "/" + part_name
			else:
				# More entries than character_names × pieces — extra
				# entries belong to no character. Fall back to a
				# synthetic key so they don't collide with real ones.
				key = "_unassigned/" + str(i) + "/" + part_name

		var region := AtlasTexture.new()
		region.atlas = source
		region.region = Rect2(entry.get("X", 0), entry.get("Y", 0), w, h)
		regions[key] = region

		draw_offsets[key] = Vector4(
			entry.get("XOffset", 0),
			entry.get("YOffset", 0),
			entry.get("XOffsetFlipped", 0),
			entry.get("YOffsetFlipped", 0)
		)

		# Populate the per-character index during the same pass.
		# char_name stays empty for non-character atlases and for
		# overflow entries that fell into the _unassigned namespace,
		# so those are naturally excluded from the index.
		if char_name != "":
			if not _character_pieces_index.has(char_name):
				_character_pieces_index[char_name] = []
			(_character_pieces_index[char_name] as Array).append(region)

	return true


func _load_character_art(path: String) -> bool:
	if not FileAccess.file_exists(path):
		push_error("SpriteAtlas: character art JSON not found: " + path)
		return false

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("SpriteAtlas: cannot open character art JSON: " + path)
		return false

	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		push_error("SpriteAtlas: character art JSON is not an object: " + path)
		return false

	var root := parsed as Dictionary
	pieces_per_character = int(root.get("PiecesPerString", 0))

	var strings_variant: Variant = root.get("Strings", [])
	if typeof(strings_variant) == TYPE_ARRAY:
		var strings_array := strings_variant as Array
		var packed := PackedStringArray()
		for s in strings_array:
			packed.append(s as String)
		character_names = packed

	return true
