class_name SaveV1
extends RefCounted

## Phase 3 Session 3: going-forward JSON save format envelope.
##
## Schema:
##   { "version": 1,
##     "savedAt": "2026-04-25T15:18:00Z",
##     "playerSave": <SaveGame Dict>,
##     "playerCafe": <Cafe Dict>,
##     "friendCafes": [<FriendCafe Dict>, ...] }
##
## load_save() reads JSON, runs the migration dispatcher, returns the
## envelope Dict. save_save() stamps savedAt and writes pretty JSON.
##
## PackedByteArray fields (CharacterInstance.Name, SaveStrings.Strings[],
## SaveGame.Trailing_b64-equivalents) are encoded via the _to_json_safe
## walker:
##   - clean UTF-8 bytes (no NULs, valid roundtrip)  -> plain JSON String
##   - everything else                                -> {"_b64": "<base64>"}
## _from_json_safe is the inverse (only the {"_b64": ...} tag converts back
## to PackedByteArray; plain Strings stay as Strings — LegacyWriter accepts
## both via Variant).

const CURRENT_VERSION: int = 1
const DEFAULT_PATH: String = "user://save.json"


static func save_save(envelope: Dictionary, path: String = DEFAULT_PATH) -> Error:
	var stamped: Dictionary = envelope.duplicate(true)
	stamped["savedAt"] = Time.get_datetime_string_from_system(true) + "Z"
	if not stamped.has("version"):
		stamped["version"] = CURRENT_VERSION

	var serializable: Variant = _to_json_safe(stamped)
	var text: String = JSON.stringify(serializable, "\t")

	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("save_save: cannot open %s for write (err=%d)" % [path, FileAccess.get_open_error()])
		return FileAccess.get_open_error()
	f.store_string(text)
	f.close()
	return OK


static func load_save(path: String = DEFAULT_PATH) -> Dictionary:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("load_save: cannot open %s for read (err=%d)" % [path, FileAccess.get_open_error()])
		return {}
	var text: String = f.get_as_text()
	f.close()

	var raw: Variant = JSON.parse_string(text)
	if not raw is Dictionary:
		push_error("load_save: top-level JSON is not an object (got %s)" % typeof(raw))
		return {}

	var converted: Variant = _from_json_safe(raw)
	var envelope: Dictionary = converted as Dictionary

	# Dispatcher: validate and migrate version.
	if not envelope.has("version"):
		push_error("load_save: envelope missing required field 'version'")
		return {}
	var version: int = int(envelope["version"])
	if version > CURRENT_VERSION:
		push_error("load_save: envelope version %d is newer than CURRENT_VERSION %d (forward-only)" % [version, CURRENT_VERSION])
		return {}
	# Migration loop: while version < CURRENT_VERSION, apply migration step.
	# At v1 with CURRENT_VERSION=1 the loop is a no-op. Migration files land
	# in `migrations/` when a real format change requires one.
	while int(envelope["version"]) < CURRENT_VERSION:
		push_error("load_save: no migration step defined for v%d" % int(envelope["version"]))
		return {}

	return envelope


# === Walker helpers ===


static func _to_json_safe(value: Variant) -> Variant:
	if value is PackedByteArray:
		var bytes: PackedByteArray = value
		# Detect NULs: Godot's String can't reliably hold NULs, so any
		# byte sequence containing NUL must be base64-tagged.
		for b in bytes:
			if b == 0:
				return {"_b64": Marshalls.raw_to_base64(bytes)}
		# Try a UTF-8 round-trip. If it survives, emit as plain String.
		var s: String = bytes.get_string_from_utf8()
		if s.to_utf8_buffer() == bytes:
			return s
		# Bytes are not clean UTF-8 — fall back to base64.
		return {"_b64": Marshalls.raw_to_base64(bytes)}
	if value is Dictionary:
		var d: Dictionary = {}
		for k in value:
			d[k] = _to_json_safe(value[k])
		return d
	if value is Array:
		var a: Array = []
		for v in value:
			a.append(_to_json_safe(v))
		return a
	# Primitives (int, float, bool, String, null) pass through.
	return value


static func _from_json_safe(value: Variant) -> Variant:
	if value is Dictionary:
		var d: Dictionary = value
		# Tagged base64 representation of a byte slice.
		if d.size() == 1 and d.has("_b64"):
			return Marshalls.base64_to_raw(String(d["_b64"]))
		var out: Dictionary = {}
		for k in d:
			out[k] = _from_json_safe(d[k])
		return out
	if value is Array:
		var a: Array = []
		for v in value:
			a.append(_from_json_safe(v))
		return a
	# Primitives (including String, which represents a clean UTF-8 byte slice
	# from _to_json_safe — LegacyWriter.write_string accepts Variant so the
	# downstream consumer doesn't care that we left it as String).
	return value
