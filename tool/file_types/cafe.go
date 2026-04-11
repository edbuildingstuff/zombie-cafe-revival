package file_types

import (
	"io"
)

type Cafe struct {
	Version       byte
	U0            float64 // header float64 immediately following version byte
	SizeX         byte
	SizeY         byte
	U3            int16
	U4            int16
	MapSizeX      int32
	MapSizeY      int32
	U7            bool
	Tiles         []CafeTile
	U8            int32
	TrailingInts1 []int32 // len must equal U8; populated on read, consumed on write
	TrailingInts2 []int32 // only present when Version > 61
}

type CafeWall struct {
	U1               int16
	U2               bool
	U3               bool
	U4               bool
	U5               int32
	HasDecoration    bool
	DecorationObject *CafeObject
}

type CafeFurniture struct {
	U1             byte
	Food           *CafeFoodData
	FurnitureType  byte // 0 when Food != nil; 1 for Stove; 2 for ServingCounter; else plain furniture
	Stove          *Stove
	ServingCounter *ServingCounter
	U2             int32
	Orientation    byte
	HasObject      bool
	Object         *CafeObject
	U3             byte
	U4             int16
	U5             Date
}

type CafeObject struct {
	Type      byte
	Wall      *CafeWall
	Furniture *CafeFurniture
	U1        int32
	U2        int16
	U3        int16
	U4        bool
}

type CafeTile struct {
	U1 int16
	U2 int32
	U3 bool
	U4 bool
	U5 *CafeObject
	U6 bool
	U7 *CafeObject
	U8 bool
	U9 *CafeObject
}

type FoodStack struct {
	U0    byte   // only present when version > 24; previously overwritten by U1 and lost
	U1    byte
	U2    byte   // vestigial — never read or written, kept for backwards compatibility
	U3    int32  // only present when version > 48
	U4    int16  // only present when version <= 48
	U5    byte
	U6    string
	U6Alt string // always present; previously discarded by the reader
	U7    Date   // only present when version > 51
}

type CafeFoodData struct {
	U1     int32
	U2     byte
	U3     bool
	Object *CafeObject
	U4     byte
	U5     int16
	U6     Date
	U7     FoodStack
}

type Stove struct {
	U1           int32
	U2           byte
	HasObject    bool
	Object       *CafeObject
	U5           byte
	U6           int16
	U7           Date
	HasFoodStack bool
	FoodStack    *FoodStack
	U8           int64
	U9           int64
}

type ServingCounter struct {
	U1        int32
	U2        byte
	HasObject bool
	Object    *CafeObject
	U3        byte
	U4        int16
	U5        Date

	U6 int32

	NumFoodStacks int16
	FoodStacks    []FoodStack
}

func readStove(file io.Reader, version int) Stove {
	var s Stove

	if version <= 48 {
		s.U1 = int32(ReadByte(file))
	} else {
		s.U1 = ReadInt32(file)
	}

	s.U2 = ReadByte(file)
	s.HasObject = ReadBool(file)

	if s.HasObject {
		o := readCafeObject(file, version)
		s.Object = &o
	}

	s.U5 = ReadByte(file)
	if version > 23 {
		s.U6 = ReadInt16(file)
	}

	if version > 47 {
		s.U7 = ReadDate(file)
	}

	s.HasFoodStack = ReadBool(file)
	if s.HasFoodStack {
		food := readFoodStack(file, version)
		s.FoodStack = &food
	}

	s.U8 = ReadInt64(file)
	s.U9 = ReadInt64(file)

	return s
}

func readServingCounter(file io.Reader, version int) ServingCounter {
	var s ServingCounter

	if version > 48 {
		s.U1 = ReadInt32(file)
	} else {
		s.U1 = int32(ReadByte(file))
	}

	s.U2 = ReadByte(file)
	s.HasObject = ReadBool(file)
	if s.HasObject {
		o := readCafeObject(file, version)
		s.Object = &o
	}

	s.U3 = ReadByte(file)

	if version > 23 {
		s.U4 = ReadInt16(file)
	}

	if version > 47 {
		s.U5 = ReadDate(file)
	}

	if version > 25 {
		s.U6 = ReadInt32(file)
	} else {
		s.U6 = int32(ReadInt16(file))
	}

	s.NumFoodStacks = ReadInt16(file)
	s.FoodStacks = make([]FoodStack, s.NumFoodStacks)
	for i := 0; i < int(s.NumFoodStacks); i++ {
		s.FoodStacks[i] = readFoodStack(file, version)
	}

	return s
}

func readFoodStack(file io.Reader, version int) FoodStack {
	var f FoodStack

	if version > 24 {
		f.U0 = ReadByte(file)
	}
	f.U1 = ReadByte(file)

	if version > 48 {
		f.U3 = ReadInt32(file)
	}

	if version <= 48 {
		f.U4 = ReadInt16(file)
	}

	f.U5 = ReadByte(file)
	f.U6 = ReadString(file)
	f.U6Alt = ReadString(file)

	if version > 51 {
		f.U7 = ReadDate(file)
	}

	return f
}

func readFood(file io.Reader, version int) CafeFoodData {
	var f CafeFoodData
	if version <= 48 {
		f.U1 = int32(ReadByte(file))
	} else {
		f.U1 = ReadInt32(file)
	}

	f.U2 = ReadByte(file)
	f.U3 = ReadBool(file)
	if f.U3 {
		o := readCafeObject(file, version)
		f.Object = &o
	}

	f.U4 = ReadByte(file)

	if version > 23 {
		f.U5 = ReadInt16(file)
		if version > 47 {
			f.U6 = ReadDate(file)
		}
	}

	f.U7 = readFoodStack(file, version)
	return f
}

func readCafeFurniture(file io.Reader, version int) CafeFurniture {
	var c CafeFurniture

	isFood := ReadBool(file)
	if isFood {
		c.U1 = ReadByte(file)
		food := readFood(file, version)
		c.Food = &food
	} else {
		c.FurnitureType = ReadByte(file)
		if c.FurnitureType == 1 {
			stove := readStove(file, version)
			c.Stove = &stove
		} else if c.FurnitureType == 2 {
			s := readServingCounter(file, version)
			c.ServingCounter = &s
		} else {
			if version > 48 {
				c.U2 = ReadInt32(file)
			} else {
				c.U2 = int32(ReadByte(file))
			}

			c.Orientation = ReadByte(file)
			c.HasObject = ReadBool(file)
			if c.HasObject {
				o := readCafeObject(file, version)
				c.Object = &o
			}

			c.U3 = ReadByte(file)

			if version > 23 {
				c.U4 = ReadInt16(file)
			}

			if version > 47 {
				c.U5 = ReadDate(file)
			}
		}

	}

	return c
}

func readCafeWall(file io.Reader, version int) CafeWall {
	var c CafeWall

	if version > 58 {
		c.U1 = ReadInt16(file)
	} else {
		c.U1 = int16(ReadByte(file))
	}

	c.U2 = ReadBool(file)
	c.U3 = ReadBool(file)
	c.U4 = ReadBool(file)
	c.U5 = ReadInt32(file)
	c.HasDecoration = ReadBool(file)

	if c.HasDecoration {
		var obj CafeObject
		obj = readCafeObject(file, version)
		c.DecorationObject = &obj
	}

	return c
}

func readCafeObject(file io.Reader, version int) CafeObject {
	var o CafeObject

	o.Type = ReadByte(file)

	if o.Type == 1 {
		furniture := readCafeFurniture(file, version)
		o.Furniture = &furniture
	}

	if o.Type == 2 {
		wall := readCafeWall(file, version)
		o.Wall = &wall
	}

	if o.Type == 2 || o.Type == 1 {
		o.U1 = ReadInt32(file)
		o.U2 = ReadInt16(file)
		o.U3 = ReadInt16(file)
		o.U4 = ReadBool(file)
	}

	return o
}

func readCafeTile(file io.Reader, version int) CafeTile {
	var t CafeTile

	if version <= 58 {
		t.U1 = int16(ReadByte(file))
	} else {
		t.U1 = ReadInt16(file)
	}

	t.U2 = ReadInt32(file)
	t.U3 = ReadBool(file)
	t.U4 = ReadBool(file)
	if t.U4 {
		o := readCafeObject(file, version)
		t.U5 = &o
	}

	t.U6 = ReadBool(file)
	if t.U6 {
		o := readCafeObject(file, version)
		t.U7 = &o
	}

	t.U8 = ReadBool(file)
	if t.U8 {
		o := readCafeObject(file, version)
		t.U9 = &o
	}

	return t
}

func ReadCafe(file io.Reader) Cafe {
	var c Cafe

	c.Version = ReadByte(file)
	c.U0 = ReadFloat64(file)
	c.SizeX = ReadByte(file)
	c.SizeY = ReadByte(file)
	c.U3 = ReadInt16(file)
	c.U4 = ReadInt16(file)

	if c.Version > 48 {
		c.MapSizeX = ReadInt32(file)
		c.MapSizeY = ReadInt32(file)
	}

	c.U7 = ReadBool(file)

	numTiles := int(c.MapSizeX * c.MapSizeY)
	c.Tiles = make([]CafeTile, numTiles)

	for i := 0; i < numTiles; i++ {
		c.Tiles[i] = readCafeTile(file, int(c.Version))
	}

	c.U8 = ReadInt32(file)
	c.TrailingInts1 = make([]int32, c.U8)
	for i := 0; i < int(c.U8); i++ {
		c.TrailingInts1[i] = ReadInt32(file)
	}

	if c.Version > 61 {
		num := ReadInt32(file)
		c.TrailingInts2 = make([]int32, num)
		for i := 0; i < int(num); i++ {
			c.TrailingInts2[i] = ReadInt32(file)
		}
	}

	return c
}
