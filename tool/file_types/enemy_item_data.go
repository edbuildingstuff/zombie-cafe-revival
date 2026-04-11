package file_types

import (
	"io"
)

// EnemyItemData is the decoded form of src/assets/data/enemyItemData.bin.mid.
// The real file is exactly 321 bytes, laid out as one leading count byte
// followed by Count × 16 bytes of per-item attribute data. Byte 0 is 0x14
// (= 20), and 1 + 20 × 16 = 321, which is the cleanest possible structural
// hypothesis. The 16 per-item bytes are small integers (0-14 in the real
// data) that plausibly represent item stats, tiers, or level-up thresholds,
// but the specific meaning of each column isn't decoded yet — preservation
// semantics only, same philosophy as Phase 0b and the animation parser.
type EnemyItemData struct {
	Count byte

	// Records holds Count entries, each 16 bytes long. Each entry is a
	// slice (not a fixed-size array) so the writer can round-trip a
	// fixture where a test deliberately uses a non-16 record width —
	// though no real file has been observed with anything other than 16.
	Records [][]byte
}

// The fixed per-record byte width observed in the real enemyItemData.bin.mid
// file. Declared as a constant so the writer and the in-memory fixture test
// agree without having to hardcode the number in multiple places.
const EnemyItemRecordWidth = 16

func ReadEnemyItemData(file io.Reader) EnemyItemData {
	data := EnemyItemData{}
	data.Count = ReadByte(file)
	data.Records = make([][]byte, data.Count)
	for i := 0; i < int(data.Count); i++ {
		data.Records[i] = make([]byte, EnemyItemRecordWidth)
		if _, err := io.ReadFull(file, data.Records[i]); err != nil {
			panic(err)
		}
	}
	return data
}

func WriteEnemyItemData(file io.Writer, data EnemyItemData) {
	WriteByte(file, data.Count)
	for _, record := range data.Records {
		if _, err := file.Write(record); err != nil {
			panic(err)
		}
	}
}
