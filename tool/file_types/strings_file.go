package file_types

import (
	"io"
	"strings"
)

// StringsFile is the decoded form of src/assets/data/strings_*.bin.mid
// (strings_google.bin.mid and strings_amazon.bin.mid). Despite the
// .bin.mid suffix, these files are NOT binary — they're plain UTF-8
// text with Windows-style \r\n line separators, carrying the game's
// localized English strings (dialog, button labels, tutorial text,
// item names, etc.). The two files differ by exactly one URL string
// (iphone/android in a beeline-i.com link); everything else is
// byte-identical between them.
//
// The "parser" just splits the raw bytes on \r\n and the writer
// joins with \r\n. Round-trip is byte-identical because strings.Split
// and strings.Join are perfect inverses for files that use a
// separator (not a terminator) convention.
type StringsFile struct {
	Strings []string
}

func ReadStringsFile(file io.Reader) StringsFile {
	raw, err := io.ReadAll(file)
	if err != nil {
		panic(err)
	}
	return StringsFile{
		Strings: strings.Split(string(raw), "\r\n"),
	}
}

func WriteStringsFile(file io.Writer, data StringsFile) {
	joined := strings.Join(data.Strings, "\r\n")
	if _, err := file.Write([]byte(joined)); err != nil {
		panic(err)
	}
}
