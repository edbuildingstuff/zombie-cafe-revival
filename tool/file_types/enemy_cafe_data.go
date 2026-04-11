package file_types

import (
	"encoding/binary"
	"io"
)


// EnemyCafeData is the decoded form of src/assets/data/enemyCafeData.bin.mid.
// The file holds the "enemy cafe" definitions for the raid/friend system —
// each entry pairs a cafe display name ("Cafe", "Diner", "Italian Eatery",
// "Asian Restaurant", ...) with an ID list, a location/franchise name
// ("Frankenstein's", "Leprechaun's", etc.), and several flag int16 fields
// whose per-slot meaning hasn't been fully decoded.
//
// File layout:
//
//	int32 LE: Count (= 14 in the real file)
//	int16 BE: HeaderFlag (= 0x0130 = 304)
//	Count × Entry
//
// Per-entry layout (all int16 fields are big-endian):
//
//	int16: name length
//	[]byte: Name
//	int16: SubType (= 0 for most entries, = 1 for some)
//	int16: SequenceID
//	int16: CafeID
//	int16: data length
//	[]byte: Data (underscore-delimited item id list)
//	int16: Flag1
//	int16: Flag2
//	int16: Flag3
//	[if HasTail] int16: Flag4
//	[if HasTail] int16: LocationName length
//	[if HasTail] []byte: LocationName
//
// The last entry in the real file ("Villain", SubType=1, SequenceID=14) is
// truncated: it ends after Flag3 with no Flag4 and no LocationName. This
// isn't a parser bug — the file literally has exactly 26 bytes of space
// left for that entry which is only enough for everything up through
// Flag3. HasTail on the entry distinguishes the two shapes so the writer
// can faithfully reproduce the original byte layout.
type EnemyCafeData struct {
	Count      int32
	HeaderFlag int16
	Entries    []EnemyCafeEntry
}

type EnemyCafeEntry struct {
	Name         string
	SubType      int16
	SequenceID   int16
	CafeID       int16
	Data         string
	Flag1        int16
	Flag2        int16
	Flag3        int16
	HasTail      bool
	Flag4        int16
	LocationName string
}

func ReadEnemyCafeData(file io.Reader) EnemyCafeData {
	all, err := io.ReadAll(file)
	if err != nil {
		panic(err)
	}

	data := EnemyCafeData{}
	pos := 0

	if pos+4 > len(all) {
		panic("enemyCafeData: too short for count header")
	}
	data.Count = int32(binary.LittleEndian.Uint32(all[pos : pos+4]))
	pos += 4

	if pos+2 > len(all) {
		panic("enemyCafeData: too short for header flag")
	}
	data.HeaderFlag = int16(binary.BigEndian.Uint16(all[pos : pos+2]))
	pos += 2

	data.Entries = make([]EnemyCafeEntry, data.Count)
	for i := int32(0); i < data.Count; i++ {
		e := EnemyCafeEntry{}

		nameLen := int(readBEUint16At(all, pos))
		pos += 2
		e.Name = string(all[pos : pos+nameLen])
		pos += nameLen

		e.SubType = int16(readBEUint16At(all, pos))
		pos += 2
		e.SequenceID = int16(readBEUint16At(all, pos))
		pos += 2
		e.CafeID = int16(readBEUint16At(all, pos))
		pos += 2

		dataLen := int(readBEUint16At(all, pos))
		pos += 2
		e.Data = string(all[pos : pos+dataLen])
		pos += dataLen

		e.Flag1 = int16(readBEUint16At(all, pos))
		pos += 2
		e.Flag2 = int16(readBEUint16At(all, pos))
		pos += 2
		e.Flag3 = int16(readBEUint16At(all, pos))
		pos += 2

		// Tail: Flag4 + LocationName. Present when there are enough
		// bytes left for at least Flag4 + a zero-length LocationName.
		// The last entry in the real file is truncated after Flag3.
		if pos+4 <= len(all) {
			e.HasTail = true
			e.Flag4 = int16(readBEUint16At(all, pos))
			pos += 2
			locLen := int(readBEUint16At(all, pos))
			pos += 2
			e.LocationName = string(all[pos : pos+locLen])
			pos += locLen
		}

		data.Entries[i] = e
	}

	return data
}

func readBEUint16At(buf []byte, pos int) uint16 {
	if pos+2 > len(buf) {
		panic("enemyCafeData: short read inside entry")
	}
	return binary.BigEndian.Uint16(buf[pos : pos+2])
}

func WriteEnemyCafeData(file io.Writer, data EnemyCafeData) {
	WriteInt32LittleEndian(file, data.Count)
	WriteInt16(file, data.HeaderFlag)
	for _, e := range data.Entries {
		writeEnemyCafeEntry(file, e)
	}
}

func writeEnemyCafeEntry(file io.Writer, e EnemyCafeEntry) {
	WriteString(file, e.Name)
	WriteInt16(file, e.SubType)
	WriteInt16(file, e.SequenceID)
	WriteInt16(file, e.CafeID)
	WriteString(file, e.Data)
	WriteInt16(file, e.Flag1)
	WriteInt16(file, e.Flag2)
	WriteInt16(file, e.Flag3)
	if e.HasTail {
		WriteInt16(file, e.Flag4)
		WriteString(file, e.LocationName)
	}
}
