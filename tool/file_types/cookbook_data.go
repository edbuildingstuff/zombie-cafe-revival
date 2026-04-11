package file_types

import (
	"io"
)

// CookbookData is the decoded form of src/assets/data/cookbookData.bin.mid.
// The file holds the game's cookbook/recipe-category index. Each entry
// describes one "cookbook" (a category like "The Mafia Cookbook" or
// "The General Cookbook") with a display name, four integer fields whose
// meaning is inferred but not fully confirmed, an unlock-hint description
// string, an unknown trailing int16, a short status string ("Not Used",
// etc.), and a trailer flag int16.
//
// File layout (all int16 fields are big-endian, matching the ReadString
// convention shared by every other format in file_types):
//
//	byte: Count
//	repeat Count times:
//	  int16: name length
//	  []byte: name
//	  int16×4: Fields — observed non-zero values for record 3 are
//	           (5000, 20, 3, 3) which plausibly decode as
//	           (price, servings, unlock_level, bonus_stars) but the
//	           meaning is not confirmed; preserved as raw int16 slots.
//	  int16: description length
//	  []byte: description
//	  int16: AfterDescription (= 0 in every observed record)
//	  int16: status length
//	  []byte: status
//	  int16: Trailer
//
// Preservation semantics: the four Fields are exposed as an int16 array
// rather than named struct fields so we can round-trip the data without
// committing to a semantic interpretation that might turn out wrong. A
// future session that actually uses the cookbook system in the game tick
// can rename once the meanings are confirmed.
type CookbookData struct {
	Count   byte
	Entries []CookbookEntry
}

type CookbookEntry struct {
	Name             string
	Fields           [4]int16
	Description      string
	AfterDescription int16
	Status           string
	Trailer          int16
}

func ReadCookbookData(file io.Reader) CookbookData {
	data := CookbookData{}
	data.Count = ReadByte(file)
	data.Entries = make([]CookbookEntry, data.Count)
	for i := byte(0); i < data.Count; i++ {
		data.Entries[i] = readCookbookEntry(file)
	}
	return data
}

func readCookbookEntry(file io.Reader) CookbookEntry {
	e := CookbookEntry{}
	e.Name = ReadString(file)
	for i := 0; i < 4; i++ {
		e.Fields[i] = ReadInt16(file)
	}
	e.Description = ReadString(file)
	e.AfterDescription = ReadInt16(file)
	e.Status = ReadString(file)
	e.Trailer = ReadInt16(file)
	return e
}

func WriteCookbookData(file io.Writer, data CookbookData) {
	WriteByte(file, data.Count)
	for _, entry := range data.Entries {
		writeCookbookEntry(file, entry)
	}
}

func writeCookbookEntry(file io.Writer, e CookbookEntry) {
	WriteString(file, e.Name)
	for i := 0; i < 4; i++ {
		WriteInt16(file, e.Fields[i])
	}
	WriteString(file, e.Description)
	WriteInt16(file, e.AfterDescription)
	WriteString(file, e.Status)
	WriteInt16(file, e.Trailer)
}
