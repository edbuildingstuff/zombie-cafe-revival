package file_types

import (
	"io"
)

// EnemyLayouts is the decoded form of src/assets/data/enemyLayouts.bin.mid.
// The file is 2847 bytes and contains the NPC/enemy cafe layouts the game
// uses when the player raids an in-map NPC cafe (distinct from the friend
// raid system, which uses the FriendCafe format in ServerData.dat). The
// content includes repeating patterns of (int16 prefixes + 1-byte ASCII
// type codes + trailing ints) that look like per-tile or per-furniture
// records — the observed single-byte codes `H T W L A S C D G B E P`
// are almost certainly initials of cafe element types (Hole, Table,
// Wall, Lamp, Aisle/Apparatus, Stove, Chair, Door, Grill, Bin, Eating,
// Prep — best guesses) but a full hex-dump analysis couldn't lock
// down the exact record boundaries: the gaps between consecutive `H`
// occurrences in the file are 29 and 30 bytes (inconsistent), which
// means records are either variable-size or the header encoding
// includes per-record alignment that isn't obvious from the byte
// patterns alone.
//
// Rather than commit to a wrong struct interpretation that would need
// to be retrofitted later, the parser preserves the whole file as an
// opaque Data []byte slice. This still satisfies the Phase 0b-style
// round-trip contract — ReadEnemyLayouts + WriteEnemyLayouts produces
// byte-identical output — and the Godot build tool can emit the file
// as JSON (base64-encoded because of Go's default []byte marshaling)
// while the schema work is deferred. A future session with more
// investigation budget, or one that can reference libZombieCafeAndroid
// via Ghidra for symbol anchors, can upgrade the struct without any
// wire-format change.
type EnemyLayouts struct {
	Data []byte
}

func ReadEnemyLayouts(file io.Reader) EnemyLayouts {
	raw, err := io.ReadAll(file)
	if err != nil {
		panic(err)
	}
	return EnemyLayouts{Data: raw}
}

func WriteEnemyLayouts(file io.Writer, data EnemyLayouts) {
	if len(data.Data) == 0 {
		return
	}
	if _, err := file.Write(data.Data); err != nil {
		panic(err)
	}
}
