package upload

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net/http"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
)

const maxUploadSize = 20 << 20 // 20 MB

// S3Client is the subset of aws s3.Client used by uploads and transcription.
type S3Client interface {
	PutObject(ctx context.Context, input *s3.PutObjectInput, opts ...func(*s3.Options)) (*s3.PutObjectOutput, error)
	GetObject(ctx context.Context, input *s3.GetObjectInput, opts ...func(*s3.Options)) (*s3.GetObjectOutput, error)
}

type Config struct {
	R2BucketName  string
	R2AccountID   string
	OpenAIKey     string
	OpenAIBaseURL string
	OpenAIModel   string
}

type handler struct {
	s3       S3Client
	q        *db.Queries
	cfg      Config
	validate func(raw string) (string, error)
}

// Register mounts POST /captures/upload on the chi router as a plain http.Handler.
// Multipart parsing requires direct *http.Request access, so huma is bypassed here.
func Register(r chi.Router, pool *pgxpool.Pool, s3c S3Client, cfg Config, validate func(raw string) (string, error)) {
	h := &handler{s3: s3c, q: db.New(pool), cfg: cfg, validate: validate}
	r.Post("/captures/upload", h.upload)
}

type uploadResponse struct {
	ID                  string  `json:"id,omitempty"`
	MediaUrl            string  `json:"mediaUrl"`
	MediaType           string  `json:"mediaType"`
	ClassifiedAs        string  `json:"classifiedAs,omitempty"`
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

	if h.s3 == nil || h.cfg.R2BucketName == "" {
		writeErr(w, http.StatusServiceUnavailable, "file upload not configured")
		return
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

	contentType := fh.Header.Get("Content-Type")
	if contentType == "" {
		contentType = http.DetectContentType(data)
	}
	mediaType := classifyMediaType(contentType)
	if mediaType == "" {
		writeErr(w, http.StatusUnprocessableEntity, "unsupported file type (image or audio only)")
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

	ext := extensionFor(fh.Filename, contentType)
	key := fmt.Sprintf("captures/%s/%s%s", userID, uuid.New().String(), ext)
	publicURL := fmt.Sprintf("https://%s.%s.r2.cloudflarestorage.com/%s",
		h.cfg.R2BucketName, h.cfg.R2AccountID, key)

	_, err = h.s3.PutObject(r.Context(), &s3.PutObjectInput{
		Bucket:      aws.String(h.cfg.R2BucketName),
		Key:         aws.String(key),
		Body:        bytes.NewReader(data),
		ContentType: aws.String(contentType),
	})
	if err != nil {
		writeErr(w, http.StatusBadGateway, "storage upload failed")
		return
	}
	if !createCapture {
		writeJSON(w, http.StatusOK, uploadResponse{
			MediaUrl:  publicURL,
			MediaType: mediaType,
		})
		return
	}

	c, err := h.q.CreateUploadedCapture(r.Context(), db.CreateUploadedCaptureParams{
		UserID:               uid,
		MediaUrl:             pgtype.Text{String: publicURL, Valid: true},
		MediaType:            db.CaptureMediaType(mediaType),
		MediaKey:             pgtype.Text{String: key, Valid: true},
		AudioDurationSec:     nullableInt4(duration),
		TranscriptionEnabled: h.cfg.OpenAIKey != "",
	})
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "could not create capture")
		return
	}
	resp := uploadResponse{
		ID:                  c.ID.String(),
		MediaUrl:            publicURL,
		MediaType:           mediaType,
		ClassifiedAs:        string(c.ClassifiedAs),
		Source:              c.Source,
		TranscriptionStatus: string(c.TranscriptionStatus),
		CreatedAt:           c.CreatedAt.Time.UTC().Format(time.RFC3339),
	}
	if c.AudioDurationSec.Valid {
		resp.AudioDurationSec = &c.AudioDurationSec.Int32
	}
	writeJSON(w, http.StatusOK, resp)
}

func classifyMediaType(ct string) string {
	mt, _, _ := mime.ParseMediaType(ct)
	if strings.HasPrefix(mt, "image/") {
		return "image"
	}
	if strings.HasPrefix(mt, "audio/") || mt == "video/webm" || mt == "video/ogg" {
		return "audio"
	}
	return ""
}

func extensionFor(filename, contentType string) string {
	if ext := filepath.Ext(filename); ext != "" {
		return ext
	}
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
