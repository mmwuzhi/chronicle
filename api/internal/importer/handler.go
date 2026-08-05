package importer

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"reflect"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/danielgtaylor/huma/v2"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
)

const (
	importIdleTimeout      = 30 * time.Second
	importMaxDuration      = 10 * time.Minute
	maxConcurrentTransfers = 2
)

type handler struct {
	service     *Service
	validate    func(raw string) (string, error)
	maxBytes    int64
	slots       chan struct{}
	transferMu  sync.Mutex
	activeUsers map[uuid.UUID]struct{}
}

type undoInput struct {
	OperationID string `path:"operationId" format:"uuid"`
}

type undoOutput struct {
	Body MarkdownImportUndoResult
}

func Register(
	api huma.API,
	router chi.Router,
	pool *pgxpool.Pool,
	cfg Config,
	rag *ragclient.Client,
	authMW func(huma.Context, func(huma.Context)),
	validateJWT func(raw string) (string, error),
) {
	maxBytes := min(cfg.MaxBytes, int64(maxMarkdownImportBytes))
	cfg.MaxBytes = maxBytes
	h := &handler{
		service: NewService(pool, cfg, rag), validate: validateJWT, maxBytes: maxBytes,
		slots: make(chan struct{}, maxConcurrentTransfers), activeUsers: make(map[uuid.UUID]struct{}),
	}
	router.Post("/imports/markdown", h.importMarkdown)
	resultSchema := api.OpenAPI().Components.Schemas.Schema(reflect.TypeOf(MarkdownImportResult{}), true, "MarkdownImportResult")
	api.OpenAPI().AddOperation(&huma.Operation{
		OperationID: "import-markdown", Method: http.MethodPost, Path: "/imports/markdown",
		Summary: "Import Markdown or text files as Captures", Tags: []string{"imports"},
		Description: "Accepts one UTF-8 .md/.markdown/.txt file (1 MiB), or a ZIP with up to 5,000 notes and 10,000 entries (32 MiB compressed and expanded).",
		Parameters: []*huma.Param{
			{Name: "Idempotency-Key", In: "header", Required: true, Schema: &huma.Schema{Type: "string", Format: "uuid"}},
			{
				Name: "X-Import-Filename", In: "header", Required: true,
				Description: "Percent-encoded UTF-8 plain filename", Schema: &huma.Schema{Type: "string"},
			},
			{Name: "X-Import-Time-Zone", In: "header", Required: false, Schema: &huma.Schema{Type: "string"}},
		},
		RequestBody: &huma.RequestBody{Required: true, Content: map[string]*huma.MediaType{
			"application/octet-stream": {Schema: &huma.Schema{Type: "string", Format: "binary"}},
		}},
		Responses: map[string]*huma.Response{"200": {
			Description: "Markdown import result",
			Content:     map[string]*huma.MediaType{"application/json": {Schema: resultSchema}},
		}},
	})
	huma.Register(api, huma.Operation{
		OperationID: "undo-markdown-import", Method: http.MethodPost,
		Path: "/imports/markdown/{operationId}/undo", Summary: "Move Captures from a Markdown import to Trash",
		Tags: []string{"imports"}, Middlewares: huma.Middlewares{authMW},
	}, h.undo)
}

func (h *handler) importMarkdown(writer http.ResponseWriter, request *http.Request) {
	userID, ok := h.authenticate(writer, request)
	if !ok {
		return
	}
	operationID, err := uuid.Parse(strings.TrimSpace(request.Header.Get("Idempotency-Key")))
	if err != nil {
		writeError(writer, 422, "Idempotency-Key must be a UUID", "")
		return
	}
	filename, err := decodeImportFilename(request.Header.Get("X-Import-Filename"))
	if err != nil {
		writeError(writer, 422, "X-Import-Filename must be a plain filename", "")
		return
	}
	location := time.UTC
	if timezone := strings.TrimSpace(request.Header.Get("X-Import-Time-Zone")); timezone != "" {
		location, err = time.LoadLocation(timezone)
		if err != nil {
			writeError(writer, 422, "X-Import-Time-Zone must be a valid IANA time zone", "")
			return
		}
	}
	contentType := strings.ToLower(strings.TrimSpace(strings.Split(request.Header.Get("Content-Type"), ";")[0]))
	if !allowedContentType(contentType) {
		writeError(writer, 415, "Unsupported Markdown import Content-Type", "")
		return
	}
	if request.ContentLength > h.maxBytes && h.maxBytes > 0 {
		writeError(writer, 413, "Import exceeds the configured size limit", "")
		return
	}
	controller := http.NewResponseController(writer)
	_ = controller.SetWriteDeadline(time.Now().Add(importMaxDuration))
	release, acquired := h.tryAcquire(userID)
	if !acquired {
		writer.Header().Set("Retry-After", "30")
		writeError(writer, 429, "A data import is already running", "")
		return
	}
	defer release()
	transferContext, cancel := context.WithTimeout(request.Context(), importMaxDuration)
	defer cancel()
	stopClose := context.AfterFunc(transferContext, func() {
		_ = request.Body.Close()
	})
	defer stopClose()
	temp, err := os.CreateTemp("", "chronicle-markdown-import-*")
	if err != nil {
		writeError(writer, 500, "Could not receive import", "")
		return
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	hash := sha256.New()
	reader := io.Reader(deadlineReader{reader: request.Body, writer: writer})
	if h.maxBytes > 0 {
		reader = io.LimitReader(reader, h.maxBytes+1)
	}
	written, copyErr := io.Copy(io.MultiWriter(temp, hash), reader)
	closeErr := temp.Close()
	if copyErr != nil || closeErr != nil {
		writeError(writer, 400, "Could not receive import", "")
		return
	}
	if h.maxBytes > 0 && written > h.maxBytes {
		writeError(writer, 413, "Import exceeds the configured size limit", "")
		return
	}
	result, err := h.service.Import(
		transferContext, userID, operationID, tempPath, filename, contentType,
		contentImportHash(hex.EncodeToString(hash.Sum(nil)), filename, location), location,
	)
	if err != nil {
		var importErr *ImportError
		if errors.As(err, &importErr) {
			detail := ""
			if importErr.Status == 422 && importErr.Err != nil {
				detail = importErr.Err.Error()
			}
			writeError(writer, importErr.Status, importErr.Title, detail)
			return
		}
		writeError(writer, 500, "Could not import Markdown", "")
		return
	}
	writeResult(writer, 200, result)
}

func contentImportHash(fileHash, filename string, location *time.Location) string {
	hash := sha256.Sum256([]byte(fileHash + "\x00" + filename + "\x00" + location.String()))
	return hex.EncodeToString(hash[:])
}

func decodeImportFilename(raw string) (string, error) {
	filename, err := url.PathUnescape(strings.TrimSpace(raw))
	if err != nil || filename == "" || !utf8.ValidString(filename) || path.Base(filename) != filename || strings.ContainsAny(filename, "/\\") {
		return "", errors.New("invalid import filename")
	}
	return filename, nil
}

func (h *handler) undo(ctx context.Context, input *undoInput) (*undoOutput, error) {
	userIDText := middleware.GetUserID(ctx)
	userID, err := uuid.Parse(userIDText)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}
	operationID, err := uuid.Parse(input.OperationID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid operationId")
	}
	result, err := h.service.Undo(ctx, userID, operationID)
	if err != nil {
		var importErr *ImportError
		if errors.As(err, &importErr) {
			return nil, huma.NewError(importErr.Status, importErr.Title)
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return &undoOutput{Body: *result}, nil
}

func (h *handler) authenticate(writer http.ResponseWriter, request *http.Request) (uuid.UUID, bool) {
	rawToken := ""
	if authorization := request.Header.Get("Authorization"); strings.HasPrefix(authorization, "Bearer ") {
		rawToken = strings.TrimPrefix(authorization, "Bearer ")
	} else if cookie, err := request.Cookie("access_token"); err == nil {
		rawToken = cookie.Value
	}
	if rawToken == "" {
		writeError(writer, 401, "Unauthorized", "")
		return uuid.Nil, false
	}
	userIDText, err := h.validate(rawToken)
	if err != nil {
		writeError(writer, 401, "Unauthorized", "")
		return uuid.Nil, false
	}
	userID, err := uuid.Parse(userIDText)
	if err != nil {
		writeError(writer, 401, "Unauthorized", "")
		return uuid.Nil, false
	}
	return userID, true
}

func (h *handler) tryAcquire(userID uuid.UUID) (func(), bool) {
	h.transferMu.Lock()
	if _, active := h.activeUsers[userID]; active {
		h.transferMu.Unlock()
		return nil, false
	}
	h.activeUsers[userID] = struct{}{}
	h.transferMu.Unlock()
	select {
	case h.slots <- struct{}{}:
		return func() {
			<-h.slots
			h.transferMu.Lock()
			delete(h.activeUsers, userID)
			h.transferMu.Unlock()
		}, true
	default:
		h.transferMu.Lock()
		delete(h.activeUsers, userID)
		h.transferMu.Unlock()
		return nil, false
	}
}

func allowedContentType(contentType string) bool {
	return contentType == "application/octet-stream" || contentType == "application/zip" ||
		contentType == "text/plain" || contentType == "text/markdown"
}

type deadlineReader struct {
	reader io.Reader
	writer http.ResponseWriter
}

func (reader deadlineReader) Read(buffer []byte) (int, error) {
	controller := http.NewResponseController(reader.writer)
	_ = controller.SetReadDeadline(time.Now().Add(importIdleTimeout))
	return reader.reader.Read(buffer)
}

func writeResult(writer http.ResponseWriter, status int, value *MarkdownImportResult) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)
	// The response is already committed, so an encoding failure cannot be
	// reported to the client through a second response.
	_ = json.NewEncoder(writer).Encode(value)
}

func writeError(writer http.ResponseWriter, status int, title, detail string) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)
	// The response is already committed, so an encoding failure cannot be
	// reported to the client through a second response.
	_ = json.NewEncoder(writer).Encode(struct {
		Status int    `json:"status"`
		Title  string `json:"title"`
		Detail string `json:"detail,omitempty"`
	}{Status: status, Title: title, Detail: detail})
}
