package upload

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/capture"
	"github.com/sikaoshenmi/chronicle/internal/objectstore"
)

const maxUploadSize = 20 << 20 // 20 MB

type Config struct {
	BucketName    string
	PublicBaseURL string
	// Deprecated compatibility fields for focused tests and older embedders.
	// Production wiring resolves both R2 and generic S3 into the fields above.
	R2BucketName      string
	R2AccountID       string
	OpenAIKey         string
	OpenAIBaseURL     string
	OpenAIModel       string
	OpenAIVisionModel string
	VisionEnabled     bool
}

func (cfg Config) bucketName() string {
	if cfg.BucketName != "" {
		return cfg.BucketName
	}
	return cfg.R2BucketName
}

func (cfg Config) publicURL(key string) (string, error) {
	if cfg.PublicBaseURL != "" {
		return url.JoinPath(strings.TrimRight(cfg.PublicBaseURL, "/"), key)
	}
	if cfg.R2BucketName == "" || cfg.R2AccountID == "" {
		return "", errors.New("object storage public URL is not configured")
	}
	return fmt.Sprintf(
		"https://%s.%s.r2.cloudflarestorage.com/%s",
		cfg.R2BucketName,
		cfg.R2AccountID,
		key,
	), nil
}

type handler struct {
	s3       objectstore.Client
	q        *db.Queries
	cfg      Config
	validate func(raw string) (string, error)
	kick     func()
}

// Register mounts POST /captures/upload on the chi router as a plain http.Handler.
// Multipart parsing requires direct *http.Request access, so huma is bypassed here.
// kick wakes the transcription worker after an upload enqueues a pending job
// (see StartTranscriptionWorker); pass a no-op when transcription is disabled.
func Register(r chi.Router, pool *pgxpool.Pool, s3c objectstore.Client, cfg Config, validate func(raw string) (string, error), kick func()) {
	if kick == nil {
		kick = func() {}
	}
	h := &handler{s3: s3c, q: db.New(pool), cfg: cfg, validate: validate, kick: kick}
	r.Post("/captures/upload", h.upload)
}

type uploadResponse struct {
	ID                  string  `json:"id,omitempty"`
	MediaUrl            string  `json:"mediaUrl"`
	MediaType           string  `json:"mediaType"`
	Source              string  `json:"source,omitempty"`
	Transcript          *string `json:"transcript,omitempty"`
	TranscriptionStatus string  `json:"transcriptionStatus,omitempty"`
	AudioDurationSec    *int32  `json:"audioDurationSec,omitempty"`
	CreatedAt           string  `json:"createdAt,omitempty"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"status": status, "title": msg})
}

func (h *handler) upload(w http.ResponseWriter, r *http.Request) {
	raw := ""
	if auth := r.Header.Get("Authorization"); strings.HasPrefix(auth, "Bearer ") {
		raw = strings.TrimPrefix(auth, "Bearer ")
	} else if c, err := r.Cookie("access_token"); err == nil {
		raw = c.Value
	}
	if raw == "" {
		writeErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	userID, err := h.validate(raw)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	uid, err := uuid.Parse(userID)
	if err != nil {
		writeErr(w, http.StatusUnauthorized, "unauthorized")
		return
	}

	if h.s3 == nil || h.cfg.bucketName() == "" {
		writeErr(w, http.StatusServiceUnavailable, "file upload not configured")
		return
	}
	captureID := uuid.New()
	var operationID uuid.UUID
	idempotent := false
	if rawKey := strings.TrimSpace(r.Header.Get("Idempotency-Key")); rawKey != "" {
		operationID, err = uuid.Parse(rawKey)
		if err != nil {
			writeErr(w, http.StatusUnprocessableEntity, "Idempotency-Key must be a UUID")
			return
		}
		idempotent = true
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxUploadSize+1024)
	if err := r.ParseMultipartForm(maxUploadSize); err != nil {
		writeErr(w, http.StatusRequestEntityTooLarge, "file too large (max 20 MB)")
		return
	}

	f, fh, err := r.FormFile("file")
	if err != nil {
		writeErr(w, http.StatusUnprocessableEntity, "field 'file' is required")
		return
	}
	defer f.Close()

	data, err := io.ReadAll(f)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not read upload")
		return
	}

	contentType, mediaType := DetectMedia(data)
	if mediaType == "" {
		writeErr(w, http.StatusUnprocessableEntity, "unsupported file type (image or audio only)")
		return
	}
	if declared := ClassifyMediaType(fh.Header.Get("Content-Type")); declared != "" && declared != mediaType {
		writeErr(w, http.StatusUnprocessableEntity, "file content does not match Content-Type")
		return
	}

	var duration *int32
	if rawDuration := r.FormValue("durationSec"); rawDuration != "" {
		parsed, parseErr := strconv.ParseInt(rawDuration, 10, 32)
		if parseErr != nil || parsed <= 0 {
			writeErr(w, http.StatusUnprocessableEntity, "durationSec must be a positive integer")
			return
		}
		value := int32(parsed)
		duration = &value
	}
	createCapture := false
	if rawCreateCapture := r.FormValue("createCapture"); rawCreateCapture != "" {
		createCapture, err = strconv.ParseBool(rawCreateCapture)
		if err != nil {
			writeErr(w, http.StatusUnprocessableEntity, "createCapture must be a boolean")
			return
		}
	}
	var remindAt pgtype.Timestamptz
	if rawRemindAt := strings.TrimSpace(r.FormValue("remindAt")); rawRemindAt != "" {
		parsed, parseErr := time.Parse(time.RFC3339, rawRemindAt)
		if parseErr != nil {
			writeErr(w, http.StatusUnprocessableEntity, "remindAt must be RFC3339")
			return
		}
		remindAt = pgtype.Timestamptz{Time: parsed, Valid: true}
	}
	remindHide := true
	if rawRemindHide := strings.TrimSpace(r.FormValue("remindHide")); rawRemindHide != "" {
		remindHide, err = strconv.ParseBool(rawRemindHide)
		if err != nil {
			writeErr(w, http.StatusUnprocessableEntity, "remindHide must be a boolean")
			return
		}
	}
	source := strings.TrimSpace(r.FormValue("source"))
	if source == "" {
		source = "web"
	}
	if source != "web" && source != "desktop_quick_capture" {
		writeErr(w, http.StatusUnprocessableEntity, "invalid capture source")
		return
	}
	if !createCapture {
		writeErr(w, http.StatusUnprocessableEntity, "createCapture=true is required")
		return
	}

	rawText := strings.TrimSpace(r.FormValue("text"))
	contentHash := sha256.Sum256(data)
	requestHash := uploadRequestFingerprint(
		contentHash,
		mediaType,
		source,
		duration,
		rawText,
		remindAt,
		remindHide,
	)
	reserved := false
	defer func() {
		if !reserved {
			return
		}
		releaseCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_, _ = h.q.ReleaseCaptureUploadOperation(releaseCtx, db.ReleaseCaptureUploadOperationParams{
			ID:          operationID,
			UserID:      uid,
			RequestHash: requestHash,
		})
	}()

	if idempotent {
		operation, operationErr := h.q.GetCaptureUploadOperation(r.Context(), operationID)
		if operationErr == nil {
			if operation.UserID != uid || operation.RequestHash != requestHash {
				writeErr(w, http.StatusConflict, "Idempotency-Key was already used with another upload")
				return
			}
			captureID = operation.CaptureID
			key := uploadObjectKey(userID, captureID, contentHash, contentType)
			existing, getErr := h.q.GetCaptureAnyState(
				r.Context(),
				db.GetCaptureAnyStateParams{ID: captureID, UserID: uid},
			)
			switch {
			case getErr == nil:
				if !uploadedCaptureMatches(
					existing,
					key,
					mediaType,
					source,
					duration,
					rawText,
					remindAt,
					remindHide,
				) {
					writeErr(w, http.StatusConflict, "Idempotency-Key was already used with another upload")
					return
				}
				_, _ = h.q.CompleteCaptureUploadOperation(
					r.Context(),
					db.CompleteCaptureUploadOperationParams{
						ID: operationID, UserID: uid, RequestHash: requestHash,
					},
				)
				writeJSON(w, http.StatusOK, uploadedCaptureResponse(existing))
				return
			case !errors.Is(getErr, pgx.ErrNoRows):
				writeErr(w, http.StatusInternalServerError, "could not check upload operation")
				return
			}
			if operation.CompletedAt.Valid {
				writeErr(w, http.StatusConflict, "completed upload no longer owns a capture")
				return
			}
			if operation.LeaseUntil.Valid && operation.LeaseUntil.Time.After(time.Now()) {
				writeErr(w, http.StatusConflict, "upload operation is already in progress")
				return
			}
		} else if !errors.Is(operationErr, pgx.ErrNoRows) {
			writeErr(w, http.StatusInternalServerError, "could not check upload operation")
			return
		}

		operation, reserveErr := h.q.ReserveCaptureUploadOperation(
			r.Context(),
			db.ReserveCaptureUploadOperationParams{
				ID:          operationID,
				CaptureID:   captureID,
				UserID:      uid,
				RequestHash: requestHash,
			},
		)
		if errors.Is(reserveErr, pgx.ErrNoRows) {
			operation, operationErr := h.q.GetCaptureUploadOperation(r.Context(), operationID)
			switch {
			case operationErr == nil &&
				operation.UserID == uid &&
				operation.RequestHash == requestHash &&
				!operation.CompletedAt.Valid:
				writeErr(w, http.StatusConflict, "upload operation is already in progress")
			case operationErr == nil:
				writeErr(w, http.StatusConflict, "Idempotency-Key was already used with another upload")
			case errors.Is(operationErr, pgx.ErrNoRows):
				writeErr(w, http.StatusConflict, "Idempotency-Key was already used by another capture")
			default:
				writeErr(w, http.StatusInternalServerError, "could not check upload operation")
			}
			return
		}
		if reserveErr != nil {
			writeErr(w, http.StatusInternalServerError, "could not reserve upload operation")
			return
		}
		captureID = operation.CaptureID
		reserved = true
	}

	key := uploadObjectKey(userID, captureID, contentHash, contentType)
	publicURL, err := h.cfg.publicURL(key)
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "file upload not configured")
		return
	}
	uploadCtx, cancelUpload := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancelUpload()
	_, err = h.s3.PutObject(uploadCtx, &s3.PutObjectInput{
		Bucket:      aws.String(h.cfg.bucketName()),
		Key:         aws.String(key),
		Body:        bytes.NewReader(data),
		ContentType: aws.String(contentType),
	})
	if err != nil {
		writeErr(w, http.StatusBadGateway, "storage upload failed")
		return
	}
	// The composer draft sent along with the upload becomes the capture's
	// text. Like the create/update endpoints, the text decides the todo facet
	// (#todo tag; see internal/capture/todotag.go).
	todoAt, doneAt := capture.DeriveTodoStamps(rawText, time.Now())
	c, err := h.q.CreateUploadedCapture(r.Context(), db.CreateUploadedCaptureParams{
		ID:                   captureID,
		UserID:               uid,
		MediaUrl:             publicURL,
		MediaType:            db.CaptureMediaType(mediaType),
		Source:               source,
		MediaKey:             key,
		AudioDurationSec:     nullableInt4(duration),
		RawText:              nullableText(rawText),
		TodoAt:               todoAt,
		DoneAt:               doneAt,
		RemindAt:             remindAt,
		RemindHide:           remindHide,
		TranscriptionEnabled: h.cfg.OpenAIKey != "",
		VisionEnabled:        h.cfg.OpenAIKey != "" && h.cfg.VisionEnabled,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		c, err = h.q.GetCaptureAnyState(
			r.Context(),
			db.GetCaptureAnyStateParams{ID: captureID, UserID: uid},
		)
		if err == nil && !uploadedCaptureMatches(
			c,
			key,
			mediaType,
			source,
			duration,
			rawText,
			remindAt,
			remindHide,
		) {
			writeErr(w, http.StatusConflict, "capture identity was claimed by another operation")
			return
		}
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not create capture")
		return
	}
	if c.TranscriptionStatus == db.TranscriptionStatusPending {
		h.kick()
	}
	if idempotent {
		// The capture is the durable replay record, so a bookkeeping failure
		// must not turn a committed upload into an ambiguous client failure.
		_, _ = h.q.CompleteCaptureUploadOperation(
			r.Context(),
			db.CompleteCaptureUploadOperationParams{
				ID:          operationID,
				UserID:      uid,
				RequestHash: requestHash,
			},
		)
		reserved = false
	}
	writeJSON(w, http.StatusOK, uploadedCaptureResponse(c))
}

func uploadObjectKey(
	userID string,
	captureID uuid.UUID,
	contentHash [sha256.Size]byte,
	contentType string,
) string {
	return fmt.Sprintf(
		"captures/%s/%s-%x%s",
		userID,
		captureID.String(),
		contentHash[:8],
		extensionFor(contentType),
	)
}

func uploadRequestFingerprint(
	contentHash [sha256.Size]byte,
	mediaType string,
	source string,
	duration *int32,
	rawText string,
	remindAt pgtype.Timestamptz,
	remindHide bool,
) string {
	var remindAtUTC *string
	if remindAt.Valid {
		value := remindAt.Time.UTC().Format(time.RFC3339Nano)
		remindAtUTC = &value
	}
	payload, _ := json.Marshal(struct {
		ContentHash string  `json:"contentHash"`
		MediaType   string  `json:"mediaType"`
		Source      string  `json:"source"`
		Duration    *int32  `json:"durationSec"`
		RawText     string  `json:"rawText"`
		RemindAt    *string `json:"remindAt"`
		RemindHide  bool    `json:"remindHide"`
	}{
		ContentHash: fmt.Sprintf("%x", contentHash[:]),
		MediaType:   mediaType,
		Source:      source,
		Duration:    duration,
		RawText:     rawText,
		RemindAt:    remindAtUTC,
		RemindHide:  remindHide,
	})
	sum := sha256.Sum256(payload)
	return fmt.Sprintf("%x", sum[:])
}

func uploadedCaptureMatches(
	existing db.Capture,
	mediaKey string,
	mediaType string,
	source string,
	duration *int32,
	rawText string,
	remindAt pgtype.Timestamptz,
	remindHide bool,
) bool {
	expectedText := nullableText(rawText)
	expectedDuration := nullableInt4(duration)
	return !existing.DeletedAt.Valid &&
		existing.MediaKey.Valid && existing.MediaKey.String == mediaKey &&
		existing.MediaUrl.Valid &&
		string(existing.MediaType) == mediaType &&
		existing.Source == source &&
		existing.RawText.Valid == expectedText.Valid &&
		(!expectedText.Valid || existing.RawText.String == expectedText.String) &&
		existing.AudioDurationSec.Valid == expectedDuration.Valid &&
		(!expectedDuration.Valid || existing.AudioDurationSec.Int32 == expectedDuration.Int32) &&
		existing.RemindAt.Valid == remindAt.Valid &&
		(!remindAt.Valid || existing.RemindAt.Time.Equal(remindAt.Time)) &&
		existing.RemindHide == remindHide
}

func uploadedCaptureResponse(c db.Capture) uploadResponse {
	resp := uploadResponse{
		ID:                  c.ID.String(),
		MediaUrl:            c.MediaUrl.String,
		MediaType:           string(c.MediaType),
		Source:              c.Source,
		TranscriptionStatus: string(c.TranscriptionStatus),
		CreatedAt:           c.CreatedAt.Time.UTC().Format(time.RFC3339),
	}
	if c.AudioDurationSec.Valid {
		resp.AudioDurationSec = &c.AudioDurationSec.Int32
	}
	return resp
}

// DetectMedia identifies the canonical content type and Chronicle media type
// from file bytes. Callers must not trust a client-provided content type.
func DetectMedia(data []byte) (string, string) {
	detected := http.DetectContentType(data)
	if kind := ClassifyMediaType(detected); kind != "" {
		return detected, kind
	}
	if len(data) >= 12 {
		prefix4 := string(data[:4])
		kind4 := string(data[8:12])
		switch {
		case prefix4 == "RIFF" && kind4 == "WEBP":
			return "image/webp", "image"
		case prefix4 == "RIFF" && kind4 == "WAVE":
			return "audio/wav", "audio"
		case prefix4 == "FORM" && (kind4 == "AIFF" || kind4 == "AIFC"):
			return "audio/aiff", "audio"
		case string(data[4:8]) == "ftyp":
			brand := string(data[8:12])
			if slices.Contains([]string{"heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif"}, brand) {
				if brand == "avif" {
					return "image/avif", "image"
				}
				return "image/heic", "image"
			}
			if slices.Contains([]string{"M4A ", "M4B ", "mp41", "mp42", "isom"}, brand) {
				return "audio/mp4", "audio"
			}
		}
	}
	if len(data) >= 4 {
		switch {
		case string(data[:4]) == "fLaC":
			return "audio/flac", "audio"
		case string(data[:4]) == "OggS":
			return "audio/ogg", "audio"
		case bytes.Equal(data[:4], []byte{0x1A, 0x45, 0xDF, 0xA3}):
			return "video/webm", "audio"
		}
	}
	if len(data) >= 3 && string(data[:3]) == "ID3" || len(data) >= 2 && data[0] == 0xFF && data[1]&0xE0 == 0xE0 {
		return "audio/mpeg", "audio"
	}
	return "", ""
}

// ClassifyMediaType maps a canonical MIME type to a Chronicle media type.
func ClassifyMediaType(ct string) string {
	mt, _, _ := mime.ParseMediaType(ct)
	if strings.HasPrefix(mt, "image/") {
		return "image"
	}
	if strings.HasPrefix(mt, "audio/") || mt == "video/webm" || mt == "video/ogg" {
		return "audio"
	}
	return ""
}

func extensionFor(contentType string) string {
	mt, _, _ := mime.ParseMediaType(contentType)
	exts, _ := mime.ExtensionsByType(mt)
	if len(exts) > 0 {
		return exts[0]
	}
	return ""
}

func nullableInt4(value *int32) pgtype.Int4 {
	if value == nil {
		return pgtype.Int4{}
	}
	return pgtype.Int4{Int32: *value, Valid: true}
}

func nullableText(value string) pgtype.Text {
	if value == "" {
		return pgtype.Text{}
	}
	return pgtype.Text{String: value, Valid: true}
}
