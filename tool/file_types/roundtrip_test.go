package file_types

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// Phase 0a validation harness for the Godot rewrite.
//
// These tests exercise the Read/Write pairs for every format in file_types
// that currently has both a deserializer and a serializer, using in-memory
// fixtures. The goal is to lock in Read/Write symmetry so that the Godot
// client's asset importer can trust this package as the canonical bridge
// between old game data and the new client.
//
// Formats still missing a Write function (and therefore untested here):
//   SaveGame, Cafe, FriendCafe, CharacterJP
//
// Those are called out in docs/rewrite-plan.md Phase 0b.

func assertRoundTrip[T any](t *testing.T, name string, original T,
	write func(w *bytes.Buffer, v T),
	read func(r *bytes.Buffer) T,
) {
	t.Helper()

	var buf bytes.Buffer
	write(&buf, original)

	if buf.Len() == 0 {
		t.Fatalf("%s: writer produced zero bytes", name)
	}

	decoded := read(&buf)

	if buf.Len() != 0 {
		t.Errorf("%s: %d unread bytes after decode", name, buf.Len())
	}

	if !reflect.DeepEqual(original, decoded) {
		t.Errorf("%s: round-trip mismatch\n  original: %#v\n  decoded:  %#v",
			name, original, decoded)
	}
}

func TestFoodRoundTrip(t *testing.T) {
	original := []Food{
		{
			Name:             "Mystery Meat",
			Price:            8,
			UnlockLevel:      1,
			CookTimeMinutes:  2,
			Servings:         12,
			PricePerSeving:   1,
			ExperiencePoints: 1,
			ImageID:          28,
			U7:               3,
			U8:               5,
			U9:               7,
			U10:              11,
			U11:              1337,
			U12:              42,
		},
		{
			Name:             "Zombie Pizza",
			Price:            500,
			UnlockLevel:      5,
			CookTimeMinutes:  15,
			Servings:         8,
			PricePerSeving:   62,
			ExperiencePoints: 10,
			ImageID:          42,
		},
		{
			Name: "",
		},
	}

	assertRoundTrip(t, "Food", original,
		func(w *bytes.Buffer, v []Food) { WriteFoods(w, v) },
		func(r *bytes.Buffer) []Food { return ReadFoods(r) },
	)
}

func TestFurnitureRoundTrip(t *testing.T) {
	original := []Furniture{
		{
			UnlockLevel:        1,
			Name:               "Zombie Table",
			Price:              250,
			PurchaseWithToxin:  false,
			SizeX:              2,
			SizeY:              2,
			ImageIndexNorth:    10,
			ImageIndexEast:     11,
			ImageIndexSouth:    12,
			ImageIndexWest:     13,
			Type:               3,
			Category:           1,
			Color:              []int{255, 0, 128, 255},
			MoneyPerHour:       5,
			MaximumMoney:       50,
			RatingBonus:        1.5,
			BuyMoneyAmount:     1000,
			ImagePackIndex:     2,
			StoveSpeedMult:     1.25,
			Description:        "A sturdy table for zombie patrons.",
			ExperiencePoints:   2.5,
			IsAvailableInStore: true,
			U21:                7,
			U22:                true,
			U23:                99,
		},
		{
			UnlockLevel:       15,
			Name:              "Toxin Lamp",
			Price:             999,
			PurchaseWithToxin: true,
			SizeX:             1,
			SizeY:             1,
			Color:             []int{0, 255, 0, 128},
			RatingBonus:       3.14,
			Description:       "",
		},
	}

	assertRoundTrip(t, "Furniture", original,
		func(w *bytes.Buffer, v []Furniture) { WriteFurnitureData(w, v) },
		func(r *bytes.Buffer) []Furniture { return ReadFurnitureData(r) },
	)
}

func TestCharacterRoundTrip(t *testing.T) {
	original := []Character{
		{
			CafeLevelRequired:      1,
			U2:                     2,
			U3:                     3,
			Name:                   "Generic Customer",
			CharacterArtStringHead: "head_generic",
			CharacterArtString:     "body_generic",
			U4:                     4,
			Energy:                 100,
			Speed:                  4,
			AttackStrength:         4,
			TipRating:              2,
			U8:                     5,
			U9:                     6,
			U10:                    7,
			IsFemale:               false,
			Cost:                   0,
			PurchaseWithToxin:      false,
			U14:                    8,
			CookSpeedBonus:         1.0,
			TipMultiplier:          1,
			RegenBoost:             0.5,
			CookXPBonus:            0.25,
			U19:                    true,
			U20:                    123,
			U21:                    9,
			HumanDescription:       "Just your average, hungry customer.",
			ZombieDescription:      "Just your average, hungry zombie.",
		},
		{
			CafeLevelRequired:  5,
			Name:               "Boxer",
			CharacterArtString: "body_boxer",
			Energy:             250,
			Speed:              6,
			AttackStrength:     8,
			IsFemale:           false,
			Cost:               1500,
			PurchaseWithToxin:  true,
			HumanDescription:   "A real knockout.",
			ZombieDescription:  "Still a real knockout.",
		},
	}

	assertRoundTrip(t, "Character", original,
		func(w *bytes.Buffer, v []Character) { WriteCharacters(w, v) },
		func(r *bytes.Buffer) []Character { return ReadCharacters(r) },
	)
}

func TestCharacterArtRoundTrip(t *testing.T) {
	original := CharacterArt{
		PiecesPerString: 4,
		Strings: []string{
			"head_1,body_1,arm_1,leg_1",
			"head_2,body_2,arm_2,leg_2",
			"head_3,body_3,arm_3,leg_3",
		},
	}

	assertRoundTrip(t, "CharacterArt", original,
		func(w *bytes.Buffer, v CharacterArt) { WriteCharacterArt(w, v) },
		func(r *bytes.Buffer) CharacterArt { return ReadCharacterArt(r) },
	)
}

func TestImageOffsetsType2RoundTrip(t *testing.T) {
	original := ImageOffsets{
		Type: 2,
		Offsets: []Offset{
			{
				Name: "sprite_1",
				X:    0, Y: 0, W: 64, H: 64,
				XOffset: 10, YOffset: 20,
				XOffsetFlipped: -10, YOffsetFlipped: 20,
			},
			{
				Name: "sprite_2",
				X:    64, Y: 0, W: 32, H: 48,
				XOffset: 5, YOffset: 15,
				XOffsetFlipped: -5, YOffsetFlipped: 15,
			},
		},
	}

	assertRoundTrip(t, "ImageOffsets(type=2)", original,
		func(w *bytes.Buffer, v ImageOffsets) { WriteImageOffsets(w, v) },
		func(r *bytes.Buffer) ImageOffsets { return ReadImageOffsets(r) },
	)
}

func TestImageOffsetsType1RoundTrip(t *testing.T) {
	original := ImageOffsets{
		Type: 1,
		Offsets: []Offset{
			{X: 0, Y: 0, W: 128, H: 128},
			{X: 128, Y: 0, W: 64, H: 64},
			{X: 192, Y: 0, W: 32, H: 32},
		},
	}

	assertRoundTrip(t, "ImageOffsets(type=1)", original,
		func(w *bytes.Buffer, v ImageOffsets) { WriteImageOffsets(w, v) },
		func(r *bytes.Buffer) ImageOffsets { return ReadImageOffsets(r) },
	)
}

func TestCharacterJPRoundTrip(t *testing.T) {
	original := []CharacterJP{
		{
			CafeLevelRequired:  1,
			U2:                 2,
			U3:                 3,
			Name:                "ゾンビ",
			Category:            "客",
			CharacterArtString:  "char_jp_01",
			U4:                  4,
			Energy:              150,
			Speed:               5,
			AttackStrength:      6,
			TipRating:           3,
			U9:                  7,
			U10:                 8,
			U11:                 9,
			U12:                 10,
			IsFemale:            true,
			Cost:                2000,
			U15:                 11,
			U16:                 12,
			CookSpeedBonus:      1.5,
			TipMultiplier:       2,
			U19:                 0.75,
			U20:                 1.25,
			U21:                 13,
			U22:                 14,
			U23:                 2.5,
			HumanDescription:    "A hungry customer.",
			ZombieDescription:   "A ravenous zombie.",
		},
		{
			CafeLevelRequired: 10,
			Name:              "Boss",
			Category:          "ボス",
			Energy:            500,
			Speed:             8,
			AttackStrength:    12,
			IsFemale:          false,
			Cost:              5000,
			HumanDescription:  "",
			ZombieDescription: "",
		},
	}

	assertRoundTrip(t, "CharacterJP", original,
		func(w *bytes.Buffer, v []CharacterJP) { WriteCharactersJP(w, v) },
		func(r *bytes.Buffer) []CharacterJP { return ReadCharactersJP(r) },
	)
}

func TestAnimationDataRoundTrip(t *testing.T) {
	original := []AnimationData{
		{Form: 1, Type: 1, Direction: 0, AnimationFile: "idleNW.bin.mid"},
		{Form: 1, Type: 1, Direction: 1, AnimationFile: "idleSW.bin.mid"},
		{Form: 2, Type: 3, Direction: 0, AnimationFile: "attackHumanNW.bin.mid"},
		{Form: 2, Type: 3, Direction: 1, AnimationFile: "attackHumanSW.bin.mid"},
	}

	assertRoundTrip(t, "AnimationData", original,
		func(w *bytes.Buffer, v []AnimationData) { WriteAnimationData(w, v) },
		func(r *bytes.Buffer) []AnimationData { return ReadAnimationData(r) },
	)
}

// makeCafeFixture builds a Cafe at version 63 that touches every branch
// in the reader: all three CafeFurniture variants (Food, Stove,
// ServingCounter, plain), decorated and undecorated walls, tiles with
// every combination of U4/U6/U8 pointer slots, non-empty TrailingInts1,
// non-empty TrailingInts2, a FoodStack in a Stove, multiple FoodStacks
// in a ServingCounter, and a Food with its own inner Object=nil case.
func makeCafeFixture() Cafe {
	date1 := Date{Year: 2024, Month: 1, Day: 15, Hour: 12, Minute: 30, Second: 45}
	date2 := Date{Year: 2025, Month: 6, Day: 30, Hour: 8, Minute: 15, Second: 0}
	date3 := Date{Year: 2026, Month: 4, Day: 11, Hour: 23, Minute: 59, Second: 59}

	stoveObj := CafeObject{
		Type: 1,
		Furniture: &CafeFurniture{
			FurnitureType: 1,
			Stove: &Stove{
				U1:        100,
				U2:        5,
				HasObject: false,
				U5:        1,
				U6:        2,
				U7:        date1,
				HasFoodStack: true,
				FoodStack: &FoodStack{
					U0: 1, U1: 2, U3: 500, U5: 3,
					U6: "meat_stew", U6Alt: "stew_icon",
					U7: date2,
				},
				U8: 1234567890,
				U9: 9876543210,
			},
		},
		U1: 10, U2: 20, U3: 30, U4: true,
	}

	counterObj := CafeObject{
		Type: 1,
		Furniture: &CafeFurniture{
			FurnitureType: 2,
			ServingCounter: &ServingCounter{
				U1:        200,
				U2:        4,
				HasObject: false,
				U3:        2,
				U4:        5,
				U5:        date1,
				U6:        50,
				NumFoodStacks: 2,
				FoodStacks: []FoodStack{
					{U0: 0, U1: 1, U3: 150, U5: 2, U6: "pizza", U6Alt: "pizza_icon", U7: date2},
					{U0: 3, U1: 4, U3: 175, U5: 5, U6: "burger", U6Alt: "", U7: date3},
				},
			},
		},
		U1: 11, U2: 21, U3: 31, U4: false,
	}

	plainObj := CafeObject{
		Type: 1,
		Furniture: &CafeFurniture{
			FurnitureType: 7, // neither 0 nor 1 nor 2 — plain furniture byte preserved
			U2:            500,
			Orientation:   1,
			HasObject:     false,
			U3:            6,
			U4:            7,
			U5:            date1,
		},
		U1: 12, U2: 22, U3: 32, U4: true,
	}

	foodObj := CafeObject{
		Type: 1,
		Furniture: &CafeFurniture{
			U1: 99,
			Food: &CafeFoodData{
				U1: 1000,
				U2: 10,
				U3: false,
				U4: 20,
				U5: 30,
				U6: date2,
				U7: FoodStack{
					U0: 5, U1: 6, U3: 800, U5: 7,
					U6: "soup", U6Alt: "soup_alt",
					U7: date3,
				},
			},
		},
		U1: 13, U2: 23, U3: 33, U4: false,
	}

	wallObj := CafeObject{
		Type: 2,
		Wall: &CafeWall{
			U1: 42,
			U2: true, U3: false, U4: true,
			U5:            1000,
			HasDecoration: false,
		},
		U1: 14, U2: 24, U3: 34, U4: true,
	}

	decoratedWallObj := CafeObject{
		Type: 2,
		Wall: &CafeWall{
			U1: 77,
			U2: false, U3: true, U4: false,
			U5:            2000,
			HasDecoration: true,
			DecorationObject: &CafeObject{
				Type: 1,
				Furniture: &CafeFurniture{
					FurnitureType: 9,
					U2:            123,
					Orientation:   2,
					U3:            8,
					U4:            9,
					U5:            date1,
				},
				U1: 15, U2: 25, U3: 35, U4: false,
			},
		},
		U1: 16, U2: 26, U3: 36, U4: true,
	}

	tiles := []CafeTile{
		// tile 0: only U5 slot filled with stove
		{U1: 1, U2: 100, U3: true, U4: true, U5: &stoveObj, U6: false, U8: false},
		// tile 1: U5 and U7 filled (counter + plain)
		{U1: 2, U2: 200, U3: false, U4: true, U5: &counterObj, U6: true, U7: &plainObj, U8: false},
		// tile 2: only U9 filled (decorated wall)
		{U1: 3, U2: 300, U3: true, U4: false, U6: false, U8: true, U9: &decoratedWallObj},
		// tile 3: U5 food + U7 wall (undecorated) + U9 nil
		{U1: 4, U2: 400, U3: false, U4: true, U5: &foodObj, U6: true, U7: &wallObj, U8: false},
	}

	return Cafe{
		Version:       63,
		U0:            12345.6789,
		SizeX:         2, SizeY: 2,
		U3:            10, U4: 20,
		MapSizeX:      2, MapSizeY: 2,
		U7:            true,
		Tiles:         tiles,
		U8:            3,
		TrailingInts1: []int32{111, 222, 333},
		TrailingInts2: []int32{444, 555},
	}
}

func makeCafeStateFixture() CafeState {
	mainChar := CharacterInstance{
		Type: 1, Name: "MainZombie",
		U2: 1, U3: 2, U4: 3.5, U5: 4,
		U6: 1000000000, U7: 5, U8: 2000000000, U9: 3000000000,
		U10: 10, U11: 20, U12: 30, U13: 40,
		U14: 50, U15: 60, U16: 70,
	}
	zombie := CharacterInstance{
		Type: 2, Name: "Z1",
		U2: 3, U3: 4, U4: 5.5, U5: 6,
		U6: 1500000000, U7: 7, U8: 2500000000, U9: 3500000000,
		U10: 11, U11: 21, U12: 31, U13: 41,
		U14: 51, U15: 61, U16: 71,
	}
	return CafeState{
		U1:               123.456,
		ExperiencePoints: 999.5,
		Toxin:            50,
		Money:            500,
		Level:            5,
		U6:               1, U7: 2,
		U8:  3.0, U9: 4,
		U10:        true,
		Character:  mainChar,
		NumZombies: 1,
		Zombies:    []CharacterInstance{zombie},
		U11:        3,
		U12:        []int8{1, 2, 3},
		U13:        true,
	}
}

func TestCafeRoundTrip(t *testing.T) {
	original := makeCafeFixture()

	assertRoundTrip(t, "Cafe", original,
		func(w *bytes.Buffer, v Cafe) { WriteCafe(w, v) },
		func(r *bytes.Buffer) Cafe { return ReadCafe(r) },
	)
}

func TestFriendCafeRoundTrip(t *testing.T) {
	original := FriendCafe{
		Version: 63,
		State:   makeCafeStateFixture(),
		Cafe:    makeCafeFixture(),
	}

	assertRoundTrip(t, "FriendCafe", original,
		func(w *bytes.Buffer, v FriendCafe) { WriteFriendData(w, v) },
		func(r *bytes.Buffer) FriendCafe { return ReadFriendData(r) },
	)
}

// TestSaveStringsEncoding exercises the subtract-one count boundary in
// readSaveStrings / writeSaveStrings. The on-disk prefix N decodes to
// max(0, N-1) strings, so N=0 and N=1 both decode to zero strings — the
// raw count must survive the round-trip even when the string list is
// empty, or the two cases become indistinguishable.
func TestSaveStringsEncoding(t *testing.T) {
	cases := []struct {
		name     string
		rawCount int16
		strings  []string
	}{
		{"raw count 0, zero strings", 0, nil},
		{"raw count 1, zero strings (boundary)", 1, nil},
		{"raw count 2, one string", 2, []string{"first"}},
		{"raw count 5, four strings", 5, []string{"a", "b", "c", "d"}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			original := SaveStrings{
				RawCount: tc.rawCount,
				Strings:  tc.strings,
			}

			var buf bytes.Buffer
			writeSaveStrings(&buf, original)

			decoded := readSaveStrings(&buf)

			if buf.Len() != 0 {
				t.Errorf("%d unread bytes after decode", buf.Len())
			}

			if decoded.RawCount != original.RawCount {
				t.Errorf("RawCount mismatch: got %d, want %d",
					decoded.RawCount, original.RawCount)
			}

			if !reflect.DeepEqual(decoded.Strings, original.Strings) {
				t.Errorf("Strings mismatch: got %#v, want %#v",
					decoded.Strings, original.Strings)
			}
		})
	}
}

func TestSaveGameRoundTrip(t *testing.T) {
	original := SaveGame{
		Version: 63,
		State:   makeCafeStateFixture(),
		PreStrings: SaveStrings{
			RawCount: 3,
			Strings:  []string{"pre_alpha", "pre_beta"},
		},
		U15: Date{Year: 2026, Month: 4, Day: 11, Hour: 14, Minute: 0, Second: 0},
		PostStrings: SaveStrings{
			RawCount: 2,
			Strings:  []string{"post_solo"},
		},
		U17:       Date{Year: 2026, Month: 4, Day: 11, Hour: 14, Minute: 30, Second: 30},
		NumOrders: 0,
		U18:       7,
		U19:       42,
		U20:       true,
	}

	assertRoundTrip(t, "SaveGame", original,
		func(w *bytes.Buffer, v SaveGame) { WriteSaveGame(w, v) },
		func(r *bytes.Buffer) SaveGame { return ReadSaveGame(r) },
	)
}

// TestAnimationDataFixture parses the real animationData.bin.mid fixture
// from src/assets/data/ and confirms the parser consumes it cleanly and
// produces a non-empty slice. This is the one binary fixture in the tree
// that has a matching Read function, so it's the only meaningful real-file
// smoke test we can write today.
func TestAnimationDataFixture(t *testing.T) {
	repoRoot := findRepoRoot(t)
	path := filepath.Join(repoRoot, "src", "assets", "data", "animationData.bin.mid")

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("fixture not present at %s: %v", path, err)
	}

	data := ReadAnimationData(bytes.NewReader(raw))

	if len(data) == 0 {
		t.Fatalf("ReadAnimationData returned empty slice for %s", path)
	}

	// Round-trip the parsed data and confirm the re-encoded bytes match
	// the relevant prefix of the original file. Any trailing bytes beyond
	// what the parser understood are reported but don't fail the test —
	// that's useful Phase 0b signal, not a regression.
	var buf bytes.Buffer
	WriteAnimationData(&buf, data)

	encoded := buf.Bytes()
	if len(encoded) > len(raw) {
		t.Errorf("re-encoded output (%d bytes) is longer than source (%d bytes)",
			len(encoded), len(raw))
		return
	}

	if !bytes.Equal(encoded, raw[:len(encoded)]) {
		t.Errorf("re-encoded bytes do not match source prefix (first %d bytes)",
			len(encoded))
		return
	}

	trailing := len(raw) - len(encoded)
	if trailing > 0 {
		t.Logf("note: %d trailing bytes in source file not accounted for by ReadAnimationData (expected: trailing bytes may be padding or format extensions)", trailing)
	}
}

// findRepoRoot walks up from the test file location until it finds the
// repository root, identified by the presence of go.work.
func findRepoRoot(t *testing.T) string {
	t.Helper()

	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("os.Getwd: %v", err)
	}

	dir := wd
	for i := 0; i < 8; i++ {
		if _, err := os.Stat(filepath.Join(dir, "go.work")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}

	t.Fatalf("could not find repo root (no go.work) starting from %s", wd)
	return ""
}

func TestEnemyCafeDataRoundTrip(t *testing.T) {
	repoRoot := findRepoRoot(t)
	path := filepath.Join(repoRoot, "src", "assets", "data", "enemyCafeData.bin.mid")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("fixture not present at %s: %v", path, err)
	}

	parsed := ReadEnemyCafeData(bytes.NewReader(raw))

	var buf bytes.Buffer
	WriteEnemyCafeData(&buf, parsed)

	if !bytes.Equal(raw, buf.Bytes()) {
		t.Fatalf("enemyCafeData round-trip bytes differ (orig %d, got %d)",
			len(raw), buf.Len())
	}

	if parsed.Count != 14 {
		t.Errorf("Count = %d, expected 14", parsed.Count)
	}
	if len(parsed.Entries) != 14 {
		t.Errorf("Entries len = %d, expected 14", len(parsed.Entries))
	}
	if len(parsed.Entries) >= 1 && parsed.Entries[0].Name != "Cafe" {
		t.Errorf("Entries[0].Name = %q, expected \"Cafe\"", parsed.Entries[0].Name)
	}
	// First 13 entries have the tail (Flag4 + LocationName); the last
	// entry ("Villain") is truncated after Flag3.
	if len(parsed.Entries) >= 14 {
		for i := 0; i < 13; i++ {
			if !parsed.Entries[i].HasTail {
				t.Errorf("Entries[%d].HasTail = false, expected true", i)
			}
		}
		if parsed.Entries[13].HasTail {
			t.Errorf("Entries[13].HasTail = true, expected false (last entry is truncated)")
		}
		if parsed.Entries[13].Name != "Villain" {
			t.Errorf("Entries[13].Name = %q, expected \"Villain\"", parsed.Entries[13].Name)
		}
	}
}

func TestEnemyCafeDataInMemoryFixture(t *testing.T) {
	fixture := EnemyCafeData{
		Count:      2,
		HeaderFlag: 304,
		Entries: []EnemyCafeEntry{
			{
				Name:         "First",
				SubType:      0,
				SequenceID:   5,
				CafeID:       100,
				Data:         "1_2_3",
				Flag1:        10,
				Flag2:        -1,
				Flag3:        20,
				HasTail:      true,
				Flag4:        30,
				LocationName: "Some Place",
			},
			{
				Name:       "Last",
				SubType:    1,
				SequenceID: 6,
				CafeID:     200,
				Data:       "4_5",
				Flag1:      40,
				Flag2:      50,
				Flag3:      60,
				HasTail:    false,
			},
		},
	}

	var buf bytes.Buffer
	WriteEnemyCafeData(&buf, fixture)

	parsed := ReadEnemyCafeData(bytes.NewReader(buf.Bytes()))

	if !reflect.DeepEqual(parsed, fixture) {
		t.Errorf("fixture mismatch:\n  got %#v\n  want %#v", parsed, fixture)
	}
}

// TestEnemyItemsRoundTrip exercises ReadEnemyItems/WriteEnemyItems
// against the real enemyItems.bin.mid file. Flat string-list format
// with a 2-byte count header.
func TestEnemyItemsRoundTrip(t *testing.T) {
	repoRoot := findRepoRoot(t)
	path := filepath.Join(repoRoot, "src", "assets", "data", "enemyItems.bin.mid")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("fixture not present at %s: %v", path, err)
	}

	parsed := ReadEnemyItems(bytes.NewReader(raw))

	var buf bytes.Buffer
	WriteEnemyItems(&buf, parsed)

	if !bytes.Equal(raw, buf.Bytes()) {
		t.Fatalf("enemyItems round-trip bytes differ (orig %d, got %d)",
			len(raw), buf.Len())
	}

	if parsed.Count != 14 {
		t.Errorf("Count = %d, expected 14", parsed.Count)
	}
	if len(parsed.Strings) < 14 {
		t.Errorf("Strings len = %d, expected many more than Count (14)",
			len(parsed.Strings))
	}
	// First string should be "Cafe" based on hex dump.
	if len(parsed.Strings) >= 1 && parsed.Strings[0] != "Cafe" {
		t.Errorf("Strings[0] = %q, expected \"Cafe\"", parsed.Strings[0])
	}
}

func TestEnemyItemsInMemoryFixture(t *testing.T) {
	fixture := EnemyItems{
		Count: 3,
		Strings: []string{
			"Alpha",
			"",
			"1_2_3_4",
			"Beta — with UTF-8 é",
			"",
		},
	}

	var buf bytes.Buffer
	WriteEnemyItems(&buf, fixture)

	parsed := ReadEnemyItems(bytes.NewReader(buf.Bytes()))

	if parsed.Count != fixture.Count {
		t.Errorf("Count: got %d, want %d", parsed.Count, fixture.Count)
	}
	if !reflect.DeepEqual(parsed.Strings, fixture.Strings) {
		t.Errorf("Strings mismatch:\n  got %#v\n  want %#v",
			parsed.Strings, fixture.Strings)
	}
}

// TestCookbookDataRoundTrip exercises ReadCookbookData/WriteCookbookData
// against the real src/assets/data/cookbookData.bin.mid file. The file
// is 1164 bytes holding 10 cookbook entries with length-prefixed
// strings and integer fields.
func TestCookbookDataRoundTrip(t *testing.T) {
	repoRoot := findRepoRoot(t)
	path := filepath.Join(repoRoot, "src", "assets", "data", "cookbookData.bin.mid")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("fixture not present at %s: %v", path, err)
	}

	parsed := ReadCookbookData(bytes.NewReader(raw))

	var buf bytes.Buffer
	WriteCookbookData(&buf, parsed)

	if !bytes.Equal(raw, buf.Bytes()) {
		t.Fatalf("cookbookData round-trip bytes differ (orig %d, got %d)",
			len(raw), buf.Len())
	}

	if parsed.Count != 10 {
		t.Errorf("Count = %d, expected 10", parsed.Count)
	}
	if len(parsed.Entries) != 10 {
		t.Errorf("Entries len = %d, expected 10", len(parsed.Entries))
	}
	if len(parsed.Entries) >= 1 && parsed.Entries[0].Name != "Your Favorite Recipes" {
		t.Errorf("Entries[0].Name = %q, expected \"Your Favorite Recipes\"",
			parsed.Entries[0].Name)
	}
}

func TestCookbookDataInMemoryFixture(t *testing.T) {
	fixture := CookbookData{
		Count: 2,
		Entries: []CookbookEntry{
			{
				Name:             "Test Cookbook A",
				Fields:           [4]int16{100, 200, 300, 400},
				Description:      "First description.",
				AfterDescription: 5,
				Status:           "Active",
				Trailer:          7,
			},
			{
				Name:             "Test Cookbook B — with UTF-8 café",
				Fields:           [4]int16{-1, 0, 32767, -32768},
				Description:      "Second.",
				AfterDescription: 0,
				Status:           "",
				Trailer:          1,
			},
		},
	}

	var buf bytes.Buffer
	WriteCookbookData(&buf, fixture)

	parsed := ReadCookbookData(bytes.NewReader(buf.Bytes()))

	if parsed.Count != fixture.Count {
		t.Errorf("Count: got %d, want %d", parsed.Count, fixture.Count)
	}
	if !reflect.DeepEqual(parsed.Entries, fixture.Entries) {
		t.Errorf("entries mismatch:\n  got %#v\n  want %#v",
			parsed.Entries, fixture.Entries)
	}
}

// TestStringsFileRoundTrip exercises ReadStringsFile / WriteStringsFile
// against both src/assets/data/strings_google.bin.mid and
// src/assets/data/strings_amazon.bin.mid. Despite the .bin.mid suffix
// these files are plain UTF-8 text with \r\n separators; a round-trip
// should be byte-identical via strings.Split + strings.Join.
func TestStringsFileRoundTrip(t *testing.T) {
	repoRoot := findRepoRoot(t)

	fixtures := []string{
		"strings_google.bin.mid",
		"strings_amazon.bin.mid",
	}

	for _, name := range fixtures {
		name := name
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(repoRoot, "src", "assets", "data", name)
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Skipf("fixture not present at %s: %v", path, err)
			}

			parsed := ReadStringsFile(bytes.NewReader(raw))

			var buf bytes.Buffer
			WriteStringsFile(&buf, parsed)

			if !bytes.Equal(raw, buf.Bytes()) {
				t.Fatalf("%s: round-trip bytes differ (orig %d, got %d)",
					name, len(raw), buf.Len())
			}

			// Sanity: the files have hundreds of strings. A parse
			// that produces zero or one string is probably wrong
			// (single-string would mean the separator split failed).
			if len(parsed.Strings) < 10 {
				t.Errorf("%s: only %d strings decoded, expected many more",
					name, len(parsed.Strings))
			}
		})
	}
}

func TestStringsFileInMemoryFixture(t *testing.T) {
	fixture := StringsFile{
		Strings: []string{
			"First string",
			"Second string",
			"Third with UTF-8 — café",
			"",
			"After an empty string",
		},
	}

	var buf bytes.Buffer
	WriteStringsFile(&buf, fixture)

	parsed := ReadStringsFile(bytes.NewReader(buf.Bytes()))

	if !reflect.DeepEqual(parsed.Strings, fixture.Strings) {
		t.Errorf("strings mismatch:\n  got %#v\n  want %#v",
			parsed.Strings, fixture.Strings)
	}
}

// TestEnemyItemDataRoundTrip exercises the ReadEnemyItemData /
// WriteEnemyItemData pair against the real src/assets/data/
// enemyItemData.bin.mid file. The file is 321 bytes with a clean
// (1-byte count + count × 16 bytes) layout — the parser should
// round-trip it byte-identically, and a fixture test with
// non-default values catches reader-writer asymmetry.
func TestEnemyItemDataRoundTrip(t *testing.T) {
	repoRoot := findRepoRoot(t)
	path := filepath.Join(repoRoot, "src", "assets", "data", "enemyItemData.bin.mid")

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("fixture not present at %s: %v", path, err)
	}

	parsed := ReadEnemyItemData(bytes.NewReader(raw))

	var buf bytes.Buffer
	WriteEnemyItemData(&buf, parsed)

	if !bytes.Equal(raw, buf.Bytes()) {
		t.Fatalf("enemyItemData round-trip differs (orig %d bytes, got %d)",
			len(raw), buf.Len())
	}

	// Sanity: the structural invariant we committed to at implementation
	// time. If this fires, it means either the count byte was misread
	// or a real file was dropped in that doesn't match the 20-item layout.
	if parsed.Count != 20 {
		t.Errorf("enemyItemData.Count = %d, expected 20", parsed.Count)
	}
	if len(parsed.Records) != 20 {
		t.Errorf("enemyItemData.Records len = %d, expected 20", len(parsed.Records))
	}
	for i, r := range parsed.Records {
		if len(r) != EnemyItemRecordWidth {
			t.Errorf("record[%d] width = %d, expected %d",
				i, len(r), EnemyItemRecordWidth)
		}
	}
}

func TestEnemyItemDataInMemoryFixture(t *testing.T) {
	fixture := EnemyItemData{
		Count: 3,
		Records: [][]byte{
			{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10},
			{0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20},
			{0xff, 0xfe, 0xfd, 0xfc, 0xfb, 0xfa, 0xf9, 0xf8, 0xf7, 0xf6, 0xf5, 0xf4, 0xf3, 0xf2, 0xf1, 0xf0},
		},
	}

	var buf bytes.Buffer
	WriteEnemyItemData(&buf, fixture)

	parsed := ReadEnemyItemData(bytes.NewReader(buf.Bytes()))

	if parsed.Count != fixture.Count {
		t.Errorf("Count mismatch: got %d, want %d", parsed.Count, fixture.Count)
	}
	if len(parsed.Records) != len(fixture.Records) {
		t.Fatalf("record count: got %d, want %d",
			len(parsed.Records), len(fixture.Records))
	}
	for i := range fixture.Records {
		if !bytes.Equal(parsed.Records[i], fixture.Records[i]) {
			t.Errorf("record[%d] mismatch:\n  got %x\n  want %x",
				i, parsed.Records[i], fixture.Records[i])
		}
	}
}

// TestAnimationFileKeyframeCountHypothesis spot-checks the semantic
// label committed at design time: Prologue.KeyframeCount should be
// small for static poses (sit) and in the 20-60 range for full
// animation cycles (walk). If this fails, the field name should be
// demoted back to a placeholder and the hypothesis revisited.
func TestAnimationFileKeyframeCountHypothesis(t *testing.T) {
	repoRoot := findRepoRoot(t)

	cases := []struct {
		file     string
		minFrame int32
		maxFrame int32
		why      string
	}{
		{"sitSW.bin.mid", 1, 3, "sit is a static pose, expect 1-3 frames"},
		{"walkNW.bin.mid", 20, 60, "walk is a full cycle, expect 20-60 frames"},
	}

	for _, tc := range cases {
		t.Run(tc.file, func(t *testing.T) {
			path := filepath.Join(repoRoot, "src", "assets", "data", "animation", tc.file)
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Skipf("%s not found: %v", tc.file, err)
			}
			parsed := ReadAnimationFile(bytes.NewReader(raw))
			got := parsed.Prologue.KeyframeCount
			if got < tc.minFrame || got > tc.maxFrame {
				t.Errorf("%s.KeyframeCount = %d, expected [%d, %d] (%s)",
					tc.file, got, tc.minFrame, tc.maxFrame, tc.why)
			}
		})
	}
}

// TestAnimationFileInMemoryFixture builds an AnimationFile with
// non-default values across every field and asserts round-trip
// symmetry. The real .bin.mid files are full of zeros and identity
// transforms — they catch structural bugs but can miss reader-writer
// asymmetry on non-default numeric values. This fixture fills that
// gap.
func TestAnimationFileInMemoryFixture(t *testing.T) {
	ptr := [4]byte{'_', 'P', 'T', 'R'}
	fixture := AnimationFile{
		Header: AnimationHeader{
			Unknown0:            3,
			BoneCount:           24,
			SkeletonRecordCount: 2,
		},
		Prologue: AnimationPrologue{
			PtrMarker0:    ptr,
			Field0:        7,
			Pad0:          0,
			PtrMarker1:    ptr,
			KeyframeCount: 5,
			PtrMarker2:    ptr,
			Pad1:          0,
			PtrMarker3:    ptr,
		},
		Skeleton: []AnimationRecord{
			{
				Transform: [12]float32{
					0.866, 0.5, 0,
					-0.5, 0.866, 0,
					0, 0, 1,
					10.5, 20.25, 0,
				},
				Trailer: []byte{
					0x01, 0x02, 0x03, 0x04,
					0x05, 0x06, 0x07, 0x08,
					0x09, 0x0a, 0x0b, 0x0c,
					0x0d, 0x0e, 0x0f, 0x10,
				},
			},
			{
				Transform: [12]float32{
					1, 0, 0,
					0, 1, 0,
					0, 0, 1,
					-5.75, 100.125, 3.5,
				},
				Trailer: []byte{
					0xcd, 0xcd, 0xcd, 0xcd,
					0x00, 0x00, 0x00, 0x00,
					0x00, 0x00, 0x00, 0x00,
					0xff, 0xff, 0xff, 0xff,
				},
			},
		},
		Tail: []byte{0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe},
	}

	var buf bytes.Buffer
	WriteAnimationFile(&buf, fixture)

	parsed := ReadAnimationFile(bytes.NewReader(buf.Bytes()))

	if parsed.Header != fixture.Header {
		t.Errorf("header mismatch: got %+v, want %+v",
			parsed.Header, fixture.Header)
	}
	if parsed.Prologue != fixture.Prologue {
		t.Errorf("prologue mismatch: got %+v, want %+v",
			parsed.Prologue, fixture.Prologue)
	}
	if len(parsed.Skeleton) != len(fixture.Skeleton) {
		t.Fatalf("skeleton count: got %d, want %d",
			len(parsed.Skeleton), len(fixture.Skeleton))
	}
	for i := range fixture.Skeleton {
		if parsed.Skeleton[i].Transform != fixture.Skeleton[i].Transform {
			t.Errorf("skeleton[%d] transform mismatch:\n  got %+v\n  want %+v",
				i, parsed.Skeleton[i].Transform, fixture.Skeleton[i].Transform)
		}
		if !bytes.Equal(parsed.Skeleton[i].Trailer, fixture.Skeleton[i].Trailer) {
			t.Errorf("skeleton[%d] trailer mismatch:\n  got %x\n  want %x",
				i, parsed.Skeleton[i].Trailer, fixture.Skeleton[i].Trailer)
		}
	}
	if !bytes.Equal(parsed.Tail, fixture.Tail) {
		t.Errorf("tail mismatch: got %x, want %x", parsed.Tail, fixture.Tail)
	}
}

// TestAnimationFileRoundTrip iterates every .bin.mid file under
// src/assets/data/animation/ as a sub-test and asserts Read → Write
// produces byte-identical output. Each file is its own sub-test so
// a single-file failure names the file precisely. This is the forcing
// function for the preservation-field contract in animation_file.go:
// if the writer drops or synthesizes a single byte, one of the 60
// sub-tests fires and points at the culprit.
func TestAnimationFileRoundTrip(t *testing.T) {
	repoRoot := findRepoRoot(t)
	globPath := filepath.Join(repoRoot, "src", "assets", "data", "animation", "*.bin.mid")
	files, err := filepath.Glob(globPath)
	if err != nil {
		t.Fatalf("glob %s: %v", globPath, err)
	}
	if len(files) == 0 {
		t.Skipf("no animation files found at %s", globPath)
	}

	for _, path := range files {
		path := path
		name := filepath.Base(path)
		t.Run(name, func(t *testing.T) {
			original, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read %s: %v", name, err)
			}

			parsed := ReadAnimationFile(bytes.NewReader(original))

			var roundtrip bytes.Buffer
			WriteAnimationFile(&roundtrip, parsed)

			got := roundtrip.Bytes()
			if !bytes.Equal(original, got) {
				t.Fatalf("%s: round-trip bytes differ (orig %d, got %d)",
					name, len(original), len(got))
			}
		})
	}
}
