package file_types

import (
	"encoding/binary"
	"io"
)

// EnemyItems is the decoded form of src/assets/data/enemyItems.bin.mid.
// The file is a 2-byte big-endian Count header followed by a flat list
// of length-prefixed strings that runs to EOF. Count is observed to be
// 14 in the real file, but the number of strings is much larger than
// 14 — the count is a cafe category count, while the strings include
// category names ("Cafe", "Diner", "Italian", "Asian", ...) interleaved
// with underscore-delimited item-id lists like "34_35_36_37_38_39" that
// plausibly encode which items each category's enemy drops when raided.
// Semantic interpretation of which string belongs to which cafe in
// which slot isn't committed yet — same preservation philosophy as the
// other Phase 1b opaque parsers.
type EnemyItems struct {
	Count   int16
	Strings []string
}

func ReadEnemyItems(file io.Reader) EnemyItems {
	data := EnemyItems{}
	data.Count = ReadInt16(file)

	remaining, err := io.ReadAll(file)
	if err != nil {
		panic(err)
	}

	pos := 0
	for pos+2 <= len(remaining) {
		strLen := int(binary.BigEndian.Uint16(remaining[pos : pos+2]))
		pos += 2
		if pos+strLen > len(remaining) {
			panic("ReadEnemyItems: short read inside string payload")
		}
		data.Strings = append(data.Strings, string(remaining[pos:pos+strLen]))
		pos += strLen
	}

	if pos != len(remaining) {
		panic("ReadEnemyItems: trailing bytes after last string (not a clean flat-string-list layout)")
	}

	return data
}

func WriteEnemyItems(file io.Writer, data EnemyItems) {
	WriteInt16(file, data.Count)
	for _, s := range data.Strings {
		WriteString(file, s)
	}
}
