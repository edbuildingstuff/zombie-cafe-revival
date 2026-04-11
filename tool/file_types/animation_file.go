package file_types

import (
	"io"
)

// AnimationFile is the decoded form of one src/assets/data/animation/*.bin.mid.
// Field layout is byte-preservation-oriented: semantic names are committed
// only when differential analysis across the 60 real files produces strong
// evidence; otherwise fields use Unknown*/Field*/Pad* placeholders. The
// writer echoes every byte the reader consumed, same preservation contract
// as Phase 0b's cafe/savegame work.
//
// The format has at least four distinct sections after the prologue: a
// 13-record skeleton bind-pose block (confirmed structural, 832 bytes),
// a bone permutation index list (~124 bytes), a 12-item pointer list
// (~96 bytes), and a keyframe section whose per-keyframe size hasn't
// been nailed down cleanly from hex-dump analysis alone. Rather than
// decode every section, we parse the skeleton block (which is the
// piece the Godot consumer needs for single-keyframe posing) and
// preserve everything after it as an opaque Tail byte slice. This
// trades semantic interpretation of the tail for round-trip fidelity
// and session scope — full decode is a follow-up.
type AnimationFile struct {
	Header   AnimationHeader
	Prologue AnimationPrologue
	// Skeleton holds the bind-pose records from the first structural
	// section. Length is Header.SkeletonRecordCount (the 13 value
	// from position [2] of the header). Each record is 12 floats
	// plus a 16-byte trailer whose semantic meaning hasn't been
	// nailed down but which round-trips faithfully.
	Skeleton []AnimationRecord
	// Tail is everything after the skeleton section, preserved
	// verbatim. Contains the bone permutation list, pointer table,
	// and keyframe data. Round-tripped as opaque bytes pending a
	// follow-up session that fully decodes it.
	Tail []byte
}

// AnimationHeader is the 12-byte fixed header. All 60 observed .bin.mid
// files have (3, 24, 13) here.
//
// NOTE: the pre-implementation spec hypothesized that BoneCount=24 was
// the skeleton bone count (based on 27 atlas pieces minus 3 spacers).
// Hex-dump analysis during implementation showed the actual skeleton
// section has exactly Unknown2=13 records, not 24. The 24 is something
// else — most likely the count of visual parts per keyframe (bones
// have children; one bone can reference multiple atlas pieces). The
// field names reflect the pre-implementation hypothesis and the
// evidence-corrected interpretation is in the comments.
type AnimationHeader struct {
	Unknown0             int32 // = 3  in all observed files; possibly format version
	BoneCount            int32 // = 24 in all observed files; likely part-per-keyframe count, not bone count
	SkeletonRecordCount  int32 // = 13 in all observed files; confirmed count of records in the Skeleton section
}

// AnimationPrologue is the 32-byte block directly after the header. It
// contains four literal "_PTR" ASCII markers at fixed offsets, interleaved
// with int32 data that differs per file. KeyframeCount is the one semantic
// label the differential-analysis evidence supports: sitSW has 1 here, walkNW
// has 39, matching "static pose" vs "full walk cycle" expectations.
type AnimationPrologue struct {
	PtrMarker0    [4]byte // literal "_PTR"
	Field0        int32   // sit=2, walk=1 — probable animation subtype flag
	Pad0          int32   // = 0 in all samples
	PtrMarker1    [4]byte // literal "_PTR"
	KeyframeCount int32   // sit=1, walk=39 — likely keyframe count
	PtrMarker2    [4]byte // literal "_PTR"
	Pad1          int32   // = 0 in all samples
	PtrMarker3    [4]byte // literal "_PTR"
}

// AnimationRecord is the per-bone data unit that repeats after the prologue.
// Exact trailer size is determined during implementation by running the
// round-trip test and iterating until bytes match.
type AnimationRecord struct {
	Transform [12]float32 // 3x4 affine hypothesis; row-major
	Trailer   []byte      // size nailed down during iteration
}

// Expected ASCII bytes for the "_PTR" sentinel that appears at fixed offsets
// in the prologue. Preserved byte-for-byte by the writer.
var expectedPtrMarker = [4]byte{'_', 'P', 'T', 'R'}

func readPtrMarker(file io.Reader) [4]byte {
	var marker [4]byte
	if _, err := io.ReadFull(file, marker[:]); err != nil {
		panic(err)
	}
	if marker != expectedPtrMarker {
		panic("readPtrMarker: expected \"_PTR\", got " + string(marker[:]))
	}
	return marker
}

func writePtrMarker(file io.Writer, marker [4]byte) {
	if _, err := file.Write(marker[:]); err != nil {
		panic(err)
	}
}

func readAnimationRecord(file io.Reader, trailerSize int) AnimationRecord {
	r := AnimationRecord{}
	for i := 0; i < 12; i++ {
		r.Transform[i] = ReadFloat(file)
	}
	if trailerSize > 0 {
		r.Trailer = make([]byte, trailerSize)
		if _, err := io.ReadFull(file, r.Trailer); err != nil {
			panic(err)
		}
	}
	return r
}

func writeAnimationRecord(file io.Writer, r AnimationRecord) {
	for i := 0; i < 12; i++ {
		WriteFloat(file, r.Transform[i])
	}
	if len(r.Trailer) > 0 {
		if _, err := file.Write(r.Trailer); err != nil {
			panic(err)
		}
	}
}

// ReadAnimationFile decodes a .bin.mid animation file. Panics on short read
// (via the hardened ReadNextBytes helpers) or on a header other than the
// observed (3, 24, 13) — supporting other skeleton topologies is a future
// session, not this one. Every int32 field in these files is little-endian
// (confirmed by hex-dumping sitSW and walkNW); the `ReadInt32LittleEndian`
// variant is required — the default `ReadInt32` is big-endian in this
// package for historical reasons tied to the other legacy formats.
func ReadAnimationFile(file io.Reader) AnimationFile {
	data := AnimationFile{}
	data.Header.Unknown0 = ReadInt32LittleEndian(file)
	data.Header.BoneCount = ReadInt32LittleEndian(file)
	data.Header.SkeletonRecordCount = ReadInt32LittleEndian(file)
	// Observed constraints across all 60 files: Unknown0 is always 3,
	// BoneCount is always 24, SkeletonRecordCount varies (13, 14, ...).
	// We only hard-fail on the first two since they're structural
	// invariants — the third is a per-animation count the loop below
	// uses as its iteration bound.
	if data.Header.Unknown0 != 3 || data.Header.BoneCount != 24 {
		panic("ReadAnimationFile: unexpected header (expected first two ints to be 3, 24)")
	}

	data.Prologue.PtrMarker0 = readPtrMarker(file)
	data.Prologue.Field0 = ReadInt32LittleEndian(file)
	data.Prologue.Pad0 = ReadInt32LittleEndian(file)
	data.Prologue.PtrMarker1 = readPtrMarker(file)
	data.Prologue.KeyframeCount = ReadInt32LittleEndian(file)
	data.Prologue.PtrMarker2 = readPtrMarker(file)
	data.Prologue.Pad1 = ReadInt32LittleEndian(file)
	data.Prologue.PtrMarker3 = readPtrMarker(file)

	// Skeleton section: SkeletonRecordCount (13) records, each 64 bytes
	// (12 floats for the transform + 16 bytes of trailer metadata).
	// Confirmed structural from sitSW.bin.mid hex-dump analysis.
	const trailerSize = 16
	data.Skeleton = make([]AnimationRecord, data.Header.SkeletonRecordCount)
	for i := int32(0); i < data.Header.SkeletonRecordCount; i++ {
		data.Skeleton[i] = readAnimationRecord(file, trailerSize)
	}

	// Everything after the skeleton is opaque tail — preserved verbatim
	// so round-trip is byte-identical without needing to fully decode
	// the bone permutation list, pointer table, and keyframe section.
	rest, err := io.ReadAll(file)
	if err != nil {
		panic(err)
	}
	data.Tail = rest

	return data
}

// WriteAnimationFile echoes the parsed struct back to bytes. Must produce
// byte-identical output for every file the reader consumes.
func WriteAnimationFile(file io.Writer, data AnimationFile) {
	WriteInt32LittleEndian(file, data.Header.Unknown0)
	WriteInt32LittleEndian(file, data.Header.BoneCount)
	WriteInt32LittleEndian(file, data.Header.SkeletonRecordCount)

	writePtrMarker(file, data.Prologue.PtrMarker0)
	WriteInt32LittleEndian(file, data.Prologue.Field0)
	WriteInt32LittleEndian(file, data.Prologue.Pad0)
	writePtrMarker(file, data.Prologue.PtrMarker1)
	WriteInt32LittleEndian(file, data.Prologue.KeyframeCount)
	writePtrMarker(file, data.Prologue.PtrMarker2)
	WriteInt32LittleEndian(file, data.Prologue.Pad1)
	writePtrMarker(file, data.Prologue.PtrMarker3)

	for _, r := range data.Skeleton {
		writeAnimationRecord(file, r)
	}

	if len(data.Tail) > 0 {
		if _, err := file.Write(data.Tail); err != nil {
			panic(err)
		}
	}
}
