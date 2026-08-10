package archive

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"path"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
)

const (
	formatName    = "chronicle-archive"
	formatVersion = 2

	manifestPath    = "manifest.json"
	capturesPath    = "data/captures.ndjson"
	linksPath       = "data/links.ndjson"
	attachmentsPath = "data/attachments.ndjson"
	dismissalsPath  = "data/retrieval-dismissals.ndjson"
	notesPath       = "notes/captures.md"
	checksumsPath   = "checksums.sha256"
)

type Manifest struct {
	Format        string         `json:"format"`
	FormatVersion int            `json:"formatVersion"`
	ExportedAt    string         `json:"exportedAt"`
	IncludesTrash bool           `json:"includesTrash"`
	MediaComplete bool           `json:"mediaComplete"`
	Counts        ManifestCounts `json:"counts"`
}

type ManifestCounts struct {
	Captures    int `json:"captures"`
	Links       int `json:"links"`
	Attachments int `json:"attachments"`
	Media       int `json:"media"`
	Dismissals  int `json:"retrievalDismissals,omitempty"`
}

type CaptureRecord struct {
	ID                    string  `json:"id"`
	RawText               *string `json:"rawText"`
	MediaType             string  `json:"mediaType"`
	ClassifiedAs          string  `json:"classifiedAs"`
	CreatedAt             string  `json:"createdAt"`
	Source                string  `json:"source"`
	Transcript            *string `json:"transcript"`
	TranscriptionStatus   string  `json:"transcriptionStatus"`
	TranscriptionModel    *string `json:"transcriptionModel"`
	TranscriptionAttempts int32   `json:"transcriptionAttempts"`
	TranscribedAt         *string `json:"transcribedAt"`
	NextTranscriptionAt   *string `json:"nextTranscriptionAt"`
	AudioDurationSec      *int32  `json:"audioDurationSec"`
	RemindAt              *string `json:"remindAt"`
	DeletedAt             *string `json:"deletedAt"`
	RemindHide            bool    `json:"remindHide"`
	TodoAt                *string `json:"todoAt"`
	DoneAt                *string `json:"doneAt"`
	LinkURL               *string `json:"linkUrl"`
	MediaPath             *string `json:"mediaPath"`
	MediaSHA256           *string `json:"mediaSha256"`
	MediaContentType      *string `json:"mediaContentType"`
	LegacyMediaURL        *string `json:"legacyMediaUrl"`
}

type LinkRecord struct {
	AID       string `json:"aId"`
	BID       string `json:"bId"`
	CreatedAt string `json:"createdAt"`
}

type AttachmentRecord struct {
	ID             string  `json:"id"`
	CaptureID      string  `json:"captureId"`
	Provider       string  `json:"provider"`
	ProviderFileID string  `json:"providerFileId"`
	Name           string  `json:"name"`
	MimeType       *string `json:"mimeType"`
	SizeBytes      *int64  `json:"sizeBytes"`
	WebURL         string  `json:"webUrl"`
	CreatedAt      string  `json:"createdAt"`
	DeletedAt      *string `json:"deletedAt"`
}

type RetrievalDismissalRecord struct {
	Surface   string  `json:"surface"`
	Query     *string `json:"query,omitempty"`
	AnchorID  *string `json:"anchorId,omitempty"`
	TargetID  string  `json:"targetId"`
	CreatedAt string  `json:"createdAt"`
}

func captureRecord(c db.Capture) CaptureRecord {
	return CaptureRecord{
		ID:                    c.ID.String(),
		RawText:               textPointer(c.RawText),
		MediaType:             string(c.MediaType),
		ClassifiedAs:          string(c.ClassifiedAs),
		CreatedAt:             formatTime(c.CreatedAt.Time),
		Source:                c.Source,
		Transcript:            textPointer(c.Transcript),
		TranscriptionStatus:   string(c.TranscriptionStatus),
		TranscriptionModel:    textPointer(c.TranscriptionModel),
		TranscriptionAttempts: c.TranscriptionAttempts,
		TranscribedAt:         timePointer(c.TranscribedAt),
		NextTranscriptionAt:   timePointer(c.NextTranscriptionAt),
		AudioDurationSec:      int32Pointer(c.AudioDurationSec),
		RemindAt:              timePointer(c.RemindAt),
		DeletedAt:             timePointer(c.DeletedAt),
		RemindHide:            c.RemindHide,
		TodoAt:                timePointer(c.TodoAt),
		DoneAt:                timePointer(c.DoneAt),
		LinkURL:               textPointer(c.LinkUrl),
	}
}

func linkRecord(link db.CaptureLink) LinkRecord {
	return LinkRecord{
		AID:       link.AID.String(),
		BID:       link.BID.String(),
		CreatedAt: formatTime(link.CreatedAt.Time),
	}
}

func attachmentRecord(attachment db.CaptureAttachment) AttachmentRecord {
	return AttachmentRecord{
		ID:             attachment.ID.String(),
		CaptureID:      attachment.CaptureID.String(),
		Provider:       string(attachment.Provider),
		ProviderFileID: attachment.ProviderFileID,
		Name:           attachment.Name,
		MimeType:       textPointer(attachment.MimeType),
		SizeBytes:      int64Pointer(attachment.SizeBytes),
		WebURL:         attachment.WebUrl,
		CreatedAt:      formatTime(attachment.CreatedAt.Time),
		DeletedAt:      timePointer(attachment.DeletedAt),
	}
}

func retrievalDismissalRecord(row db.RetrievalDismissal) RetrievalDismissalRecord {
	record := RetrievalDismissalRecord{
		Surface: row.Surface, TargetID: row.TargetID.String(),
		CreatedAt: formatTime(row.CreatedAt.Time),
	}
	if row.QueryText.Valid {
		record.Query = &row.QueryText.String
	}
	if row.AnchorID.Valid {
		anchor := uuid.UUID(row.AnchorID.Bytes).String()
		record.AnchorID = &anchor
	}
	return record
}

func formatTime(value time.Time) string {
	return value.UTC().Format(time.RFC3339Nano)
}

func timePointer(value pgtype.Timestamptz) *string {
	if !value.Valid {
		return nil
	}
	formatted := formatTime(value.Time)
	return &formatted
}

func textPointer(value pgtype.Text) *string {
	if !value.Valid {
		return nil
	}
	text := value.String
	return &text
}

func int32Pointer(value pgtype.Int4) *int32 {
	if !value.Valid {
		return nil
	}
	number := value.Int32
	return &number
}

func int64Pointer(value pgtype.Int8) *int64 {
	if !value.Valid {
		return nil
	}
	number := value.Int64
	return &number
}

func nullableText(value *string) pgtype.Text {
	if value == nil {
		return pgtype.Text{}
	}
	return pgtype.Text{String: *value, Valid: true}
}

func nullableInt4(value *int32) pgtype.Int4 {
	if value == nil {
		return pgtype.Int4{}
	}
	return pgtype.Int4{Int32: *value, Valid: true}
}

func nullableInt8(value *int64) pgtype.Int8 {
	if value == nil {
		return pgtype.Int8{}
	}
	return pgtype.Int8{Int64: *value, Valid: true}
}

func parseTimestamp(value string) (pgtype.Timestamptz, error) {
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return pgtype.Timestamptz{}, err
	}
	return pgtype.Timestamptz{Time: parsed, Valid: true}, nil
}

func parseOptionalTimestamp(value *string) (pgtype.Timestamptz, error) {
	if value == nil {
		return pgtype.Timestamptz{}, nil
	}
	return parseTimestamp(*value)
}

func captureContentDigest(record CaptureRecord) (string, error) {
	// Conflict identity intentionally excludes the archive ID and processing
	// state. IDs are remapped when another user already owns them, while
	// transcripts, classification, todo timestamps, and link metadata can all
	// change asynchronously or be derived again from raw text after restore.
	// Only user-owned content and durable presentation state decide whether an
	// imported Capture is the same logical record.
	identity := struct {
		RawText          *string `json:"rawText"`
		Transcript       *string `json:"transcript"`
		MediaType        string  `json:"mediaType"`
		CreatedAt        string  `json:"createdAt"`
		Source           string  `json:"source"`
		RemindAt         *string `json:"remindAt"`
		DeletedAt        *string `json:"deletedAt"`
		RemindHide       bool    `json:"remindHide"`
		MediaSHA256      *string `json:"mediaSha256"`
		MediaContentType *string `json:"mediaContentType"`
		LegacyMediaURL   *string `json:"legacyMediaUrl"`
	}{
		RawText:          record.RawText,
		MediaType:        record.MediaType,
		CreatedAt:        record.CreatedAt,
		Source:           record.Source,
		RemindAt:         record.RemindAt,
		DeletedAt:        record.DeletedAt,
		RemindHide:       record.RemindHide,
		MediaSHA256:      record.MediaSHA256,
		MediaContentType: record.MediaContentType,
		LegacyMediaURL:   record.LegacyMediaURL,
	}
	if record.MediaType != string(db.CaptureMediaTypeText) {
		// Media transcripts can be corrected by the user, so a difference is a
		// real merge conflict. Text-capture transcripts are fetched link content
		// and remain derived processing state.
		identity.Transcript = record.Transcript
	}
	encoded, err := json.Marshal(identity)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(encoded)
	return hex.EncodeToString(sum[:]), nil
}

func renderNote(record CaptureRecord) []byte {
	var body strings.Builder
	body.WriteString("---\n")
	body.WriteString("id: ")
	body.WriteString(record.ID)
	body.WriteString("\ncreatedAt: ")
	body.WriteString(strconv.Quote(record.CreatedAt))
	body.WriteString("\nsource: ")
	body.WriteString(strconv.Quote(record.Source))
	if record.DeletedAt != nil {
		body.WriteString("\ndeletedAt: ")
		body.WriteString(strconv.Quote(*record.DeletedAt))
	}
	body.WriteString("\n---\n\n")
	if record.RawText != nil {
		body.WriteString(*record.RawText)
		body.WriteString("\n")
	}
	if record.MediaPath != nil {
		body.WriteString("\nMedia: [")
		body.WriteString(*record.MediaPath)
		body.WriteString("](../")
		body.WriteString(*record.MediaPath)
		body.WriteString(")\n")
	}
	if record.Transcript != nil {
		body.WriteString("\n## Transcript\n\n")
		body.WriteString(*record.Transcript)
		body.WriteString("\n")
	}
	return []byte(body.String())
}

func renderChecksums(checksums map[string]string) []byte {
	names := make([]string, 0, len(checksums))
	for name := range checksums {
		names = append(names, name)
	}
	sort.Strings(names)
	var body strings.Builder
	for _, name := range names {
		body.WriteString(checksums[name])
		body.WriteString("  ")
		body.WriteString(name)
		body.WriteByte('\n')
	}
	return []byte(body.String())
}

func parseChecksums(data []byte) (map[string]string, error) {
	result := make(map[string]string)
	for lineNumber, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		parts := strings.SplitN(line, "  ", 2)
		if len(parts) != 2 {
			return nil, fmt.Errorf("checksum line %d is malformed", lineNumber+1)
		}
		sum := strings.ToLower(strings.TrimSpace(parts[0]))
		if len(sum) != sha256.Size*2 {
			return nil, fmt.Errorf("checksum line %d has an invalid digest", lineNumber+1)
		}
		if _, err := hex.DecodeString(sum); err != nil {
			return nil, fmt.Errorf("checksum line %d has an invalid digest", lineNumber+1)
		}
		name := parts[1]
		if !validEntryName(name) || name == checksumsPath {
			return nil, fmt.Errorf("checksum line %d has an invalid path", lineNumber+1)
		}
		if _, exists := result[name]; exists {
			return nil, fmt.Errorf("checksum path %q is duplicated", name)
		}
		result[name] = sum
	}
	return result, nil
}

func validEntryName(name string) bool {
	return name != "" &&
		!strings.HasPrefix(name, "/") &&
		!strings.Contains(name, "\\") &&
		path.Clean(name) == name &&
		name != "." &&
		!strings.HasPrefix(name, "../")
}

func validateUUID(value, field string) (uuid.UUID, error) {
	parsed, err := uuid.Parse(value)
	if err != nil {
		return uuid.Nil, fmt.Errorf("%s must be a UUID", field)
	}
	return parsed, nil
}
