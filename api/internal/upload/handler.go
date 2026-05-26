package upload

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"path/filepath"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
)

const maxUploadSize = 20 << 20 // 20 MB

// S3Putter is the subset of aws s3.Client we need.
type S3Putter interface {
	PutObject(ctx context.Context, input *s3.PutObjectInput, opts ...func(*s3.Options)) (*s3.PutObjectOutput, error)
}

type Config struct {
	R2BucketName string
	R2AccountID  string
	OpenAIKey    string
}

type handler struct {
	s3       S3Putter
	cfg      Config
	validate func(raw string) (string, error)
}

// Register mounts POST /captures/upload on the chi router as a plain http.Handler.
// Multipart parsing requires direct *http.Request access, so huma is bypassed here.
func Register(r chi.Router, s3c S3Putter, cfg Config, validate func(raw string) (string, error)) {
	h := &handler{s3: s3c, cfg: cfg, validate: validate}
	r.Post("/captures/upload", h.upload)
}

type uploadResponse struct {
	MediaUrl  string  `json:"mediaUrl"`
	MediaType string  `json:"mediaType"`
	RawText   *string `json:"rawText,omitempty"`
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

	resp := uploadResponse{MediaUrl: publicURL, MediaType: mediaType}

	if mediaType == "audio" && h.cfg.OpenAIKey != "" {
		if text := transcribe(r.Context(), data, fh.Filename, contentType, h.cfg.OpenAIKey); text != "" {
			resp.RawText = &text
		}
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

func transcribe(ctx context.Context, data []byte, filename, contentType, apiKey string) string {
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)

	fw, err := mw.CreateFormFile("file", filenameOrDefault(filename, contentType))
	if err != nil {
		return ""
	}
	if _, err = fw.Write(data); err != nil {
		return ""
	}
	_ = mw.WriteField("model", "whisper-1")
	_ = mw.WriteField("response_format", "text")
	mw.Close()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://api.openai.com/v1/audio/transcriptions", &buf)
	if err != nil {
		return ""
	}
	req.Header.Set("Authorization", "Bearer "+apiKey)
	req.Header.Set("Content-Type", mw.FormDataContentType())

	resp, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		if resp != nil {
			resp.Body.Close()
		}
		return ""
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return strings.TrimSpace(string(body))
}

func filenameOrDefault(name, contentType string) string {
	if name != "" {
		return name
	}
	mt, _, _ := mime.ParseMediaType(contentType)
	switch mt {
	case "audio/webm", "video/webm":
		return "recording.webm"
	case "audio/ogg", "video/ogg":
		return "recording.ogg"
	default:
		return "recording.mp3"
	}
}
