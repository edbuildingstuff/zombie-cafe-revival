package file_types

import (
	"io"
)

type FriendCafe struct {
	Version byte // leading version byte, independent of the embedded Cafe.Version
	State   CafeState
	Cafe    Cafe
}

func ReadFriendData(file io.Reader) FriendCafe {
	var s FriendCafe
	s.Version = ReadByte(file)

	if s.Version != 63 {
		panic("Unable to handle this cafe version")
	}

	s.State = readCafeState(file, int(s.Version))
	s.Cafe = ReadCafe(file)

	return s
}

func WriteFriendData(file io.Writer, f FriendCafe) {
	WriteByte(file, f.Version)
	writeCafeState(file, f.State, int(f.Version))
	WriteCafe(file, f.Cafe)
}
