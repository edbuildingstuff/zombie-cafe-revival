package file_types

import (
	"io"
)

type AnimationData struct {
	Form          byte
	Type          byte
	Direction     byte
	AnimationFile string
}

func readSingleAnimationData(file io.Reader) AnimationData {
	data := AnimationData{}
	data.Form = ReadByte(file)
	data.Type = ReadByte(file)
	data.Direction = ReadByte(file)
	data.AnimationFile = ReadString(file)
	return data
}

func ReadAnimationData(file io.Reader) []AnimationData {
	data := []AnimationData{}

	length := ReadByte(file)

	for i := 0; i < int(length); i++ {
		data = append(data, readSingleAnimationData(file))
	}

	return data
}

func writeSingleAnimationData(file io.Writer, data AnimationData) {
	WriteByte(file, data.Form)
	WriteByte(file, data.Type)
	WriteByte(file, data.Direction)
	WriteString(file, data.AnimationFile)
}

func WriteAnimationData(file io.Writer, data []AnimationData) {
	WriteByte(file, byte(len(data)))
	for _, entry := range data {
		writeSingleAnimationData(file, entry)
	}
}
