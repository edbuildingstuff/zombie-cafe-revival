package serialization

import (
	"cctpacker/cct_file"
	"encoding/json"
	"file_types"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/disintegration/imaging"
)

// BuildGodotAssets produces a Godot 4-friendly asset tree from the
// extracted APK source at in_directory. The output layout is:
//
//	<out>/assets/data/     — JSON data files (decoded from binary where needed)
//	<out>/assets/atlases/  — packed atlas PNGs + offsets JSON (the only image source)
//	<out>/assets/audio/    — OGG files (music at the top, sfx under sfx/)
//	<out>/assets/fonts/    — TTF files
//
// The Godot client reads sprites exclusively through SpriteAtlas, so
// individual PNG files are not copied into the output tree — atlases
// + offsets JSON are the canonical image source. This saves ~36 MB
// on the build output versus copying every per-character part as its
// own PNG file.
func BuildGodotAssets(in_directory string, out_directory string) {
	log.Printf("BuildGodotAssets: %s -> %s", in_directory, out_directory)

	if err := os.RemoveAll(out_directory); err != nil {
		log.Fatalf("removing old output: %v", err)
	}

	assetsOut := filepath.Join(out_directory, "assets")
	godotMkdir(assetsOut)

	copyGodotDataFiles(in_directory, filepath.Join(assetsOut, "data"))
	deserializeAnimationDataForGodot(in_directory, filepath.Join(assetsOut, "data"))
	deserializeEnemyItemDataForGodot(in_directory, filepath.Join(assetsOut, "data"))
	deserializeStringsFilesForGodot(in_directory, filepath.Join(assetsOut, "data"))
	copyGodotAudio(in_directory, filepath.Join(assetsOut, "audio"))
	copyGodotFonts(in_directory, filepath.Join(assetsOut, "fonts"))
	packGodotAtlases(in_directory, filepath.Join(assetsOut, "atlases"))
	packGodotAnimations(in_directory, filepath.Join(assetsOut, "data", "animation"))

	log.Printf("BuildGodotAssets: done")
}

// packGodotAtlases runs the atlas packers for every sprite category
// the legacy APK build packs, writing a PNG + JSON offsets pair (and
// for character atlases, a JSON character-art manifest as well) into
// <out>/assets/atlases/. Scale factors match the values the legacy
// PackCharacters / PackTextures functions use internally — see the
// hardcoded scale maps in serialization.go for the source of truth.
func packGodotAtlases(in_directory string, out_directory string) {
	imagesIn := filepath.Join(in_directory, "assets", "images")
	godotMkdir(out_directory)

	PackGodotCharacters(filepath.Join(imagesIn, "characterParts"), out_directory, 0.75)
	PackGodotCharacters(filepath.Join(imagesIn, "characterParts2"), out_directory, 0.75)

	PackGodotTextures(filepath.Join(imagesIn, "recipeImages"), out_directory, 0.5)
	PackGodotTextures(filepath.Join(imagesIn, "recipeImages2"), out_directory, 0.5)
	PackGodotTextures(filepath.Join(imagesIn, "furniture"), out_directory, 1.0)
	PackGodotTextures(filepath.Join(imagesIn, "furniture2"), out_directory, 0.75)
	PackGodotTextures(filepath.Join(imagesIn, "furniture3"), out_directory, 1.0)
}

// PackGodotCharacters mirrors serialization.PackCharacters but emits
// a PNG + JSON offsets + JSON character-art triple instead of the
// legacy CCTX + binary offsets + binary character-art. Reuses
// cct_file.WritePackedTexture for the layout work so atlas geometry
// stays identical to the legacy pipeline.
func PackGodotCharacters(in_directory string, out_directory string, scale float32) {
	entries, err := os.ReadDir(in_directory)
	if err != nil {
		log.Printf("PackGodotCharacters: skipping %s: %v", in_directory, err)
		return
	}

	var files []string
	var folders []string
	piecesPerPack := -1

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		folders = append(folders, entry.Name())

		folderPath := filepath.Join(in_directory, entry.Name())
		dirFiles, err := os.ReadDir(folderPath)
		if err != nil {
			log.Fatalf("PackGodotCharacters: reading %s: %v", folderPath, err)
		}

		numImages := 0
		for _, file := range dirFiles {
			if file.IsDir() {
				continue
			}
			if !strings.HasSuffix(strings.ToLower(file.Name()), ".png") {
				continue
			}
			numImages++
			files = append(files, filepath.Join(folderPath, file.Name()))
		}

		if piecesPerPack == -1 {
			piecesPerPack = numImages
		} else if numImages != piecesPerPack {
			log.Fatalf("PackGodotCharacters: inconsistent pieces per pack in %s (expected %d, got %d)",
				folderPath, piecesPerPack, numImages)
		}
	}

	if len(files) == 0 {
		log.Printf("PackGodotCharacters: no images found in %s, skipping", in_directory)
		return
	}

	img, offsets := cct_file.WritePackedTexture(files, scale, false, 0, 4, 2)
	offsets.Type = 2

	folderName := filepath.Base(in_directory)
	godotMkdir(out_directory)

	pngPath := filepath.Join(out_directory, folderName+".png")
	if err := imaging.Save(img, pngPath); err != nil {
		log.Fatalf("PackGodotCharacters: saving %s: %v", pngPath, err)
	}

	offsetsPath := filepath.Join(out_directory, folderName+".offsets.json")
	writeJSONFile(offsetsPath, offsets)

	characterArt := file_types.CharacterArt{
		PiecesPerString: byte(piecesPerPack),
		Strings:         folders,
	}
	artPath := filepath.Join(out_directory, folderName+".characterArt.json")
	writeJSONFile(artPath, characterArt)
}

// PackGodotTextures mirrors serialization.PackTextures but emits
// a PNG + JSON offsets pair instead of the legacy CCTX + binary
// offsets. Reuses cct_file.WritePackedTexture for the layout work.
func PackGodotTextures(in_directory string, out_directory string, scale float32) {
	entries, err := os.ReadDir(in_directory)
	if err != nil {
		log.Printf("PackGodotTextures: skipping %s: %v", in_directory, err)
		return
	}

	var files []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if !strings.HasSuffix(strings.ToLower(entry.Name()), ".png") {
			continue
		}
		files = append(files, filepath.Join(in_directory, entry.Name()))
	}

	if len(files) == 0 {
		log.Printf("PackGodotTextures: no images found in %s, skipping", in_directory)
		return
	}

	img, offsets := cct_file.WritePackedTexture(files, scale, true, -1, 2, 0)
	offsets.Type = 2

	folderName := filepath.Base(in_directory)
	godotMkdir(out_directory)

	pngPath := filepath.Join(out_directory, folderName+".png")
	if err := imaging.Save(img, pngPath); err != nil {
		log.Fatalf("PackGodotTextures: saving %s: %v", pngPath, err)
	}

	offsetsPath := filepath.Join(out_directory, folderName+".offsets.json")
	writeJSONFile(offsetsPath, offsets)
}

// writeJSONFile marshals v as pretty-printed JSON and writes it to
// path. Any error is fatal.
func writeJSONFile(path string, v interface{}) {
	b, err := json.MarshalIndent(v, "", "    ")
	if err != nil {
		log.Fatalf("marshaling JSON for %s: %v", path, err)
	}
	if err := os.WriteFile(path, b, 0644); err != nil {
		log.Fatalf("writing %s: %v", path, err)
	}
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

// deserializeStringsFilesForGodot decodes both strings_google.bin.mid and
// strings_amazon.bin.mid from src/assets/data/ and emits one JSON per
// input to <out>/<name>.json (e.g., strings_google.json). The two files
// are nearly identical — they differ by a single URL string — but we
// emit both so the Godot client can pick whichever one matches its
// build target at runtime, same as the legacy build. Missing source
// files are skipped with a log line rather than failing the build.
func deserializeStringsFilesForGodot(in_directory string, out_data_directory string) {
	names := []string{"strings_google.bin.mid", "strings_amazon.bin.mid"}
	for _, name := range names {
		src := filepath.Join(in_directory, "assets", "data", name)
		dstName := strings.TrimSuffix(name, ".bin.mid") + ".json"
		dst := filepath.Join(out_data_directory, dstName)

		f, err := os.Open(src)
		if err != nil {
			log.Printf("strings file not present at %s: %v (skipping)", src, err)
			continue
		}
		data := file_types.ReadStringsFile(f)
		f.Close()

		godotMkdir(filepath.Dir(dst))
		writeJSONFile(dst, data)
	}
}

// deserializeEnemyItemDataForGodot decodes src/assets/data/enemyItemData.bin.mid
// using ReadEnemyItemData and writes a pretty-printed JSON version to
// <out>/assets/data/enemyItemData.json. Missing source logs and returns
// rather than failing the build — matches the tolerance pattern of
// deserializeAnimationDataForGodot.
func deserializeEnemyItemDataForGodot(in_directory string, out_data_directory string) {
	src := filepath.Join(in_directory, "assets", "data", "enemyItemData.bin.mid")
	dst := filepath.Join(out_data_directory, "enemyItemData.json")

	f, err := os.Open(src)
	if err != nil {
		log.Printf("enemyItemData not present at %s: %v (skipping)", src, err)
		return
	}
	defer f.Close()

	data := file_types.ReadEnemyItemData(f)

	godotMkdir(filepath.Dir(dst))
	writeJSONFile(dst, data)
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

// packGodotAnimations decodes every per-animation .bin.mid file under
// src/assets/data/animation/ using file_types.ReadAnimationFile and
// writes a pretty-printed JSON version to <out>/*.json (one per file).
// Missing source directory is logged and skipped, matching the
// tolerance pattern of packGodotAtlases.
func packGodotAnimations(in_directory string, out_directory string) {
	in_dir := filepath.Join(in_directory, "assets", "data", "animation")
	entries, err := os.ReadDir(in_dir)
	if err != nil {
		log.Printf("packGodotAnimations: skipping %s: %v", in_dir, err)
		return
	}

	godotMkdir(out_directory)

	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if !strings.HasSuffix(strings.ToLower(e.Name()), ".bin.mid") {
			continue
		}
		src := filepath.Join(in_dir, e.Name())
		dstName := strings.TrimSuffix(e.Name(), ".bin.mid") + ".json"
		dst := filepath.Join(out_directory, dstName)

		f, err := os.Open(src)
		if err != nil {
			log.Fatalf("opening %s: %v", src, err)
		}
		data := file_types.ReadAnimationFile(f)
		f.Close()

		writeJSONFile(dst, data)
	}
}
