package file_types

import (
	"io"
)

type CharacterInstance struct {
	Type byte
	Name string
	U2   byte
	U3   byte
	U4   float32
	U5   byte
	U6   int64
	U7   byte
	U8   int64
	U9   int64
	U10  int32
	U11  int32
	U12  int32
	U13  int32
	U14  byte
	U15  int32
	U16  int32
}

type CafeState struct {
	U1               float64
	ExperiencePoints float32
	Toxin            int32
	Money            int32
	Level            int32
	U6               int32
	U7               int32
	U8               float32
	U9               int32
	U10              bool
	Character        CharacterInstance
	NumZombies       byte
	Zombies          []CharacterInstance
	U11              int32
	U12              []int8
	U13              bool
}

// SaveStrings captures a length-prefixed string block in the save game
// format. The encoding is unusual: the raw int16 prefix holds a value N,
// and the block contains max(0, N-1) strings. Because both N=0 and N=1
// decode to zero strings, the raw count must be stored explicitly — it
// cannot be derived from len(Strings).
type SaveStrings struct {
	RawCount int16
	Strings  []string
}

type SaveGame struct {
	Version     byte // leading version byte, previously read into a local and lost
	State       CafeState
	PreStrings  SaveStrings // read between State and U15
	U15         Date
	PostStrings SaveStrings // read between U15 and U17
	U17         Date
	NumOrders   int16
	U18         byte
	U19         byte
	U20         bool

	// Trailing preserves any bytes that appear after the known struct
	// fields. The real binary save files pulled from the legacy Android
	// build (see tool/file_types/testdata/globalData.dat) contain ~1 KB
	// of additional data past U20 — probably an extended character /
	// friend list — that the current parser can't decode structurally.
	// Storing the remainder as opaque bytes keeps the Phase 0b round-trip
	// contract intact while the schema work is deferred. In-memory fixture
	// tests leave this empty and the writer skips the emission when it is.
	// JSON tag aligns with the GDScript Dictionary's "Trailing_b64" key.
	Trailing []byte `json:"Trailing_b64"`
}

func readSaveStrings(file io.Reader) SaveStrings {
	var s SaveStrings
	s.RawCount = ReadInt16(file)
	num := int(s.RawCount) - 1
	if num >= 0 {
		for i := num; i >= 1; i-- {
			s.Strings = append(s.Strings, ReadString(file))
		}
	}
	return s
}

func writeSaveStrings(file io.Writer, s SaveStrings) {
	WriteInt16(file, s.RawCount)
	for _, str := range s.Strings {
		WriteString(file, str)
	}
}

func readCharacter(file io.Reader, fileVersion int) CharacterInstance {
	var c CharacterInstance
	c.Type = ReadByte(file)
	c.Name = ReadString(file)
	c.U2 = ReadByte(file)
	c.U3 = ReadByte(file)
	c.U4 = ReadFloat(file)
	c.U5 = ReadByte(file)
	c.U6 = ReadInt64(file)
	c.U7 = ReadByte(file)
	c.U8 = ReadInt64(file)
	c.U9 = ReadInt64(file)
	c.U10 = ReadInt32(file)
	c.U11 = ReadInt32(file)
	c.U12 = ReadInt32(file)
	c.U13 = ReadInt32(file)

	if fileVersion > 29 {
		c.U14 = ReadByte(file)
		if fileVersion > 46 {
			c.U15 = ReadInt32(file)
			c.U16 = ReadInt32(file)
		}
	}

	return c
}

func readCafeState(file io.Reader, version int) CafeState {
	var save CafeState
	save.U1 = ReadFloat64(file)
	save.ExperiencePoints = ReadFloat(file)
	save.Toxin = ReadInt32(file)
	save.Money = ReadInt32(file)
	save.Level = ReadInt32(file)
	save.U6 = ReadInt32(file)
	save.U7 = ReadInt32(file)
	save.U8 = ReadFloat(file)
	save.U9 = ReadInt32(file)
	save.U10 = ReadBool(file)
	save.Character = readCharacter(file, version)
	save.NumZombies = ReadByte(file)
	save.Zombies = make([]CharacterInstance, save.NumZombies)

	for i := 0; i < int(save.NumZombies); i++ {
		save.Zombies[i] = readCharacter(file, version)
	}

	if version > 62 {
		save.U11 = ReadInt32(file)
	} else {
		save.U11 = int32(ReadByte(file))
	}

	save.U12 = make([]int8, save.U11)
	for i := 0; i < int(save.U11); i++ {
		save.U12[i] = int8(ReadByte(file))
	}

	if version > 33 {
		save.U13 = ReadBool(file)
	}

	return save
}

func readSaveGameVersion63(file io.Reader, save SaveGame) SaveGame {
	const version = 63
	save.State = readCafeState(file, version)

	save.PreStrings = readSaveStrings(file)

	save.U15 = ReadDate(file)

	save.PostStrings = readSaveStrings(file)

	save.U17 = ReadDate(file)

	save.NumOrders = ReadInt16(file)

	if save.NumOrders > 0 {
		panic("Have not implemented a way to handle deserialization of orders yet")
	}

	save.U18 = ReadByte(file)
	save.U19 = ReadByte(file)
	save.U20 = ReadBool(file)

	// Preserve any trailing bytes the struct doesn't know about.
	// Keep Trailing nil (rather than empty slice) when there are none
	// so hand-constructed in-memory fixtures whose Trailing is unset
	// still compare equal after round-trip via reflect.DeepEqual.
	trailing, err := io.ReadAll(file)
	if err != nil {
		panic(err)
	}
	if len(trailing) > 0 {
		save.Trailing = trailing
	}

	return save
}

func ReadSaveGame(file io.Reader) SaveGame {
	var s SaveGame
	s.Version = ReadByte(file)

	if s.Version == 63 {
		return readSaveGameVersion63(file, s)
	}

	return s
}

func writeCharacter(file io.Writer, c CharacterInstance, fileVersion int) {
	WriteByte(file, c.Type)
	WriteString(file, c.Name)
	WriteByte(file, c.U2)
	WriteByte(file, c.U3)
	WriteFloat(file, c.U4)
	WriteByte(file, c.U5)
	WriteInt64(file, c.U6)
	WriteByte(file, c.U7)
	WriteInt64(file, c.U8)
	WriteInt64(file, c.U9)
	WriteInt32(file, c.U10)
	WriteInt32(file, c.U11)
	WriteInt32(file, c.U12)
	WriteInt32(file, c.U13)

	if fileVersion > 29 {
		WriteByte(file, c.U14)
		if fileVersion > 46 {
			WriteInt32(file, c.U15)
			WriteInt32(file, c.U16)
		}
	}
}

func writeCafeState(file io.Writer, save CafeState, version int) {
	WriteFloat64(file, save.U1)
	WriteFloat(file, save.ExperiencePoints)
	WriteInt32(file, save.Toxin)
	WriteInt32(file, save.Money)
	WriteInt32(file, save.Level)
	WriteInt32(file, save.U6)
	WriteInt32(file, save.U7)
	WriteFloat(file, save.U8)
	WriteInt32(file, save.U9)
	WriteBool(file, save.U10)

	writeCharacter(file, save.Character, version)

	WriteByte(file, save.NumZombies)
	for i := 0; i < int(save.NumZombies); i++ {
		writeCharacter(file, save.Zombies[i], version)
	}

	if version > 62 {
		WriteInt32(file, save.U11)
	} else {
		WriteByte(file, byte(save.U11))
	}

	for i := 0; i < int(save.U11); i++ {
		WriteByte(file, byte(save.U12[i]))
	}

	if version > 33 {
		WriteBool(file, save.U13)
	}
}

func writeSaveGameVersion63(file io.Writer, save SaveGame) {
	const version = 63
	writeCafeState(file, save.State, version)

	writeSaveStrings(file, save.PreStrings)

	WriteDate(file, save.U15)

	writeSaveStrings(file, save.PostStrings)

	WriteDate(file, save.U17)

	WriteInt16(file, save.NumOrders)

	if save.NumOrders > 0 {
		panic("WriteSaveGame: orders serialization not implemented")
	}

	WriteByte(file, save.U18)
	WriteByte(file, save.U19)
	WriteBool(file, save.U20)

	if len(save.Trailing) > 0 {
		if _, err := file.Write(save.Trailing); err != nil {
			panic(err)
		}
	}
}

func WriteSaveGame(file io.Writer, save SaveGame) {
	WriteByte(file, save.Version)

	if save.Version == 63 {
		writeSaveGameVersion63(file, save)
	}
}
