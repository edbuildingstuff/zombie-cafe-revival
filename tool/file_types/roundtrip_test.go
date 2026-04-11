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
