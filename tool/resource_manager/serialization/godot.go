package serialization

import (
	"encoding/json"
	"file_types"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
)

// BuildGodotAssets produces a Godot 4-friendly asset tree from the
// extracted APK source at in_directory. The output layout is:
//
//	<out>/assets/data/   — JSON data files (decoded from binary where needed)
//	<out>/assets/images/ — individual PNG files, subdirectory structure preserved
//	<out>/assets/audio/  — OGG files (music at the top, sfx under sfx/)
//	<out>/assets/fonts/  — TTF files
//
// Atlas packing, opaque binary file parsing (constants, enemy data,
// per-animation keyframes, bitmap fonts), and any Godot-specific
// import metadata emission are explicitly deferred to follow-up
// sessions. The goal of this first pass is to produce a directory
// Godot 4 can import without manual intervention, not to produce a
// feature-complete runtime.
func BuildGodotAssets(in_directory string, out_directory string) {
	log.Printf("BuildGodotAssets: %s -> %s", in_directory, out_directory)

	if err := os.RemoveAll(out_directory); err != nil {
		log.Fatalf("removing old output: %v", err)
	}

	assetsOut := filepath.Join(out_directory, "assets")
	godotMkdir(assetsOut)

	copyGodotDataFiles(in_directory, filepath.Join(assetsOut, "data"))
	deserializeAnimationDataForGodot(in_directory, filepath.Join(assetsOut, "data"))
	copyGodotImages(in_directory, filepath.Join(assetsOut, "images"))
	copyGodotAudio(in_directory, filepath.Join(assetsOut, "audio"))
	copyGodotFonts(in_directory, filepath.Join(assetsOut, "fonts"))

	log.Printf("BuildGodotAssets: done")
}

// copyGodotDataFiles copies the *.bin.mid.json editable data sources
// from src/assets/data/ into the Godot tree with the .bin.mid suffix
// stripped so filenames read as normal .json files.
func copyGodotDataFiles(in_directory string, out_directory string) {
	in_data := filepath.Join(in_directory, "assets", "data")
	godotMkdir(out_directory)

	entries, err := os.ReadDir(in_data)
	if err != nil {
		log.Fatalf("reading %s: %v", in_data, err)
	}

	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasSuffix(name, ".bin.mid.json") {
			continue
		}
		friendly := strings.TrimSuffix(name, ".bin.mid.json") + ".json"
		src := filepath.Join(in_data, name)
		dst := filepath.Join(out_directory, friendly)
		godotCopyFile(src, dst)
	}
}

// deserializeAnimationDataForGodot decodes src/assets/data/animationData.bin.mid
// using the existing ReadAnimationData parser and writes a pretty-printed JSON
// version to <out>/assets/data/animationData.json. If the source file is
// missing, the function logs and returns — it does not fail the build.
func deserializeAnimationDataForGodot(in_directory string, out_data_directory string) {
	src := filepath.Join(in_directory, "assets", "data", "animationData.bin.mid")
	dst := filepath.Join(out_data_directory, "animationData.json")

	f, err := os.Open(src)
	if err != nil {
		log.Printf("animationData not present at %s: %v (skipping)", src, err)
		return
	}
	defer f.Close()

	data := file_types.ReadAnimationData(f)
	b, err := json.MarshalIndent(data, "", "    ")
	if err != nil {
		log.Fatalf("marshaling animationData: %v", err)
	}

	godotMkdir(filepath.Dir(dst))
	if err := os.WriteFile(dst, b, 0644); err != nil {
		log.Fatalf("writing %s: %v", dst, err)
	}
}

// copyGodotImages walks src/assets/images/ and copies every *.png file
// into the Godot images/ tree, preserving the subdirectory structure.
// No atlas packing is performed in this first pass — each character part,
// food item, and furniture sprite is emitted as its own PNG, which Godot
// imports natively via its built-in PNG importer.
func copyGodotImages(in_directory string, out_directory string) {
	in_images := filepath.Join(in_directory, "assets", "images")
	godotMkdir(out_directory)

	err := filepath.WalkDir(in_images, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		if !strings.HasSuffix(strings.ToLower(d.Name()), ".png") {
			return nil
		}

		rel, err := filepath.Rel(in_images, path)
		if err != nil {
			return err
		}
		dst := filepath.Join(out_directory, rel)
		godotMkdir(filepath.Dir(dst))
		godotCopyFile(path, dst)
		return nil
	})
	if err != nil {
		log.Fatalf("walking images: %v", err)
	}
}

// copyGodotAudio copies the OGG music track from src/assets/Music/ and
// every OGG sound effect from src/res/raw/ into the Godot audio/ tree.
// Music lives at the top of audio/, sfx lives under audio/sfx/.
func copyGodotAudio(in_directory string, out_directory string) {
	godotMkdir(out_directory)

	musicIn := filepath.Join(in_directory, "assets", "Music")
	if entries, err := os.ReadDir(musicIn); err == nil {
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(strings.ToLower(e.Name()), ".ogg") {
				continue
			}
			godotCopyFile(
				filepath.Join(musicIn, e.Name()),
				filepath.Join(out_directory, e.Name()),
			)
		}
	}

	sfxIn := filepath.Join(in_directory, "res", "raw")
	if entries, err := os.ReadDir(sfxIn); err == nil {
		sfxOut := filepath.Join(out_directory, "sfx")
		godotMkdir(sfxOut)
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(strings.ToLower(e.Name()), ".ogg") {
				continue
			}
			godotCopyFile(
				filepath.Join(sfxIn, e.Name()),
				filepath.Join(sfxOut, e.Name()),
			)
		}
	}
}

// copyGodotFonts copies TTF files out of src/assets/data/ and
// src/assets/fonts/ into the Godot fonts/ tree. Bitmap fonts
// (the thunder_*.fnt.mid + PNG sheet pairs) are not converted in
// this first pass — a follow-up session can target Godot's native
// BMFont or sprite-font import paths.
func copyGodotFonts(in_directory string, out_directory string) {
	godotMkdir(out_directory)

	candidates := []string{
		filepath.Join(in_directory, "assets", "data"),
		filepath.Join(in_directory, "assets", "fonts"),
	}

	for _, dir := range candidates {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			if !strings.HasSuffix(strings.ToLower(e.Name()), ".ttf") {
				continue
			}
			godotCopyFile(
				filepath.Join(dir, e.Name()),
				filepath.Join(out_directory, e.Name()),
			)
		}
	}
}

// godotCopyFile reads src and writes it to dst. Any error is fatal.
func godotCopyFile(src string, dst string) {
	b, err := os.ReadFile(src)
	if err != nil {
		log.Fatalf("reading %s: %v", src, err)
	}
	if err := os.WriteFile(dst, b, 0644); err != nil {
		log.Fatalf("writing %s: %v", dst, err)
	}
}

// godotMkdir creates dir and all parents, failing the process on error.
func godotMkdir(dir string) {
	if err := os.MkdirAll(dir, 0755); err != nil {
		log.Fatalf("creating %s: %v", dir, err)
	}
}
