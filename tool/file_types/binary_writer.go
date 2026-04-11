package file_types

import (
	"encoding/binary"
	"io"
	"math"
)

func WriteUint16(file io.Writer, value uint16) {
	b := make([]byte, 2)
	binary.BigEndian.PutUint16(b, value)
	file.Write(b)
}

func WriteUint32(file io.Writer, value uint32) {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, value)
	file.Write(b)
}

func WriteUint32LittleEndian(file io.Writer, value uint32) {
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, value)
	file.Write(b)
}

func WriteInt16(file io.Writer, value int16) {
	b := make([]byte, 2)
	binary.BigEndian.PutUint16(b, uint16(value))
	file.Write(b)
}

func WriteInt32(file io.Writer, value int32) {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, uint32(value))
	file.Write(b)
}

func WriteInt32LittleEndian(file io.Writer, value int32) {
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, uint32(value))
	file.Write(b)
}

func WriteInt64(file io.Writer, value int64) {
	b := make([]byte, 8)
	binary.BigEndian.PutUint64(b, uint64(value))
	file.Write(b)
}

func WriteFloat(file io.Writer, value float32) {
	b := make([]byte, 4)
	binary.LittleEndian.PutUint32(b, math.Float32bits(value))
	file.Write(b)
}

func WriteFloat64(file io.Writer, value float64) {
	b := make([]byte, 8)
	binary.LittleEndian.PutUint64(b, math.Float64bits(value))
	file.Write(b)
}

func WriteByte(file io.Writer, value byte) {
	file.Write([]byte{value})
}

func WriteBool(file io.Writer, value bool) {
	if value {
		file.Write([]byte{1})
	} else {
		file.Write([]byte{0})
	}
}

func WriteString(file io.Writer, value string) {
	WriteInt16(file, int16(len(value)))
	file.Write([]byte(value))
}

func WriteDate(file io.Writer, d Date) {
	WriteInt16(file, d.Year)
	WriteByte(file, d.Month)
	WriteByte(file, d.Day)
	WriteByte(file, d.Hour)
	WriteByte(file, d.Minute)
	WriteByte(file, d.Second)
}
