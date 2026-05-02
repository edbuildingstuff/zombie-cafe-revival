package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"tool/file_types"
)

type fixture struct {
	srcRel string // path relative to repo root
	outRel string // path relative to repo root
	parser string // "Cafe" | "SaveGame" | "FriendCafe"
}

var fixtures = []fixture{
	{"tool/file_types/testdata/playerCafe.caf", "godot/test/fixtures/save/playerCafe.caf.json", "Cafe"},
	{"tool/file_types/testdata/BACKUP1.caf", "godot/test/fixtures/save/BACKUP1.caf.json", "Cafe"},
	{"tool/file_types/testdata/globalData.dat", "godot/test/fixtures/save/globalData.dat.json", "SaveGame"},
	{"tool/file_types/testdata/BACKUP1.dat", "godot/test/fixtures/save/BACKUP1.dat.json", "SaveGame"},
	{"tool/file_types/testdata/ServerData.dat", "godot/test/fixtures/save/ServerData.dat.json", "FriendCafe"},
}

func main() {
	repoRoot, err := findRepoRoot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "cannot find repo root: %v\n", err)
		os.Exit(1)
	}

	for _, f := range fixtures {
		src := filepath.Join(repoRoot, f.srcRel)
		out := filepath.Join(repoRoot, f.outRel)

		raw, err := os.ReadFile(src)
		if err != nil {
			fmt.Fprintf(os.Stderr, "read %s: %v\n", src, err)
			os.Exit(1)
		}

		var parsed any
		switch f.parser {
		case "Cafe":
			parsed = file_types.ReadCafe(bytes.NewReader(raw))
		case "SaveGame":
			parsed = file_types.ReadSaveGame(bytes.NewReader(raw))
		case "FriendCafe":
			parsed = file_types.ReadFriendData(bytes.NewReader(raw))
		default:
			fmt.Fprintf(os.Stderr, "unknown parser %q\n", f.parser)
			os.Exit(1)
		}

		encoded, err := json.MarshalIndent(parsed, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "marshal %s: %v\n", f.parser, err)
			os.Exit(1)
		}

		if err := os.WriteFile(out, encoded, 0644); err != nil {
			fmt.Fprintf(os.Stderr, "write %s: %v\n", out, err)
			os.Exit(1)
		}

		fmt.Printf("wrote %s (%d bytes)\n", f.outRel, len(encoded))
	}
}

// findRepoRoot walks up from the current working directory until it finds
// a `go.work` file (the workspace root marker for this project).
func findRepoRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.work")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("go.work not found above %s", dir)
		}
		dir = parent
	}
}
