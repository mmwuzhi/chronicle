package archive

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/sikaoshenmi/chronicle/internal/objectstore"
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
)

const (
	transferIdleTimeout  = 30 * time.Second
	maxTransferDuration  = 2 * time.Hour
	maxConcurrentImports = 2
	maxConcurrentExports = 2
)

type handler struct {
	service     *Service
	validate    func(raw string) (string, error)
	maxBytes    int64
	importSlots chan struct{}
	exportSlots chan struct{}
	transferMu  sync.Mutex
	activeUsers map[uuid.UUID]struct{}
}

func Register(
	api huma.API,
	router chi.Router,
	pool *pgxpool.Pool,
	store objectstore.Client,
	cfg Config,
	rag *ragclient.Client,
	_ func(huma.Context, func(huma.Context)),
	validateJWT func(raw string) (string, error),
) {
	h := &handler{
		service:     NewService(pool, store, cfg, rag),
		validate:    validateJWT,
		maxBytes:    cfg.MaxBytes,
		importSlots: make(chan struct{}, maxConcurrentImports),
		exportSlots: make(chan struct{}, maxConcurrentExports),
		activeUsers: make(map[uuid.UUID]struct{}),
	}
	router.Get("/archive/export", h.exportArchive)
	api.OpenAPI().AddOperation(&huma.Operation{
		OperationID: "export-archive",
		Method:      http.MethodGet,
		Path:        "/archive/export",
		Summary:     "Export a complete Chronicle archive",
		Tags:        []string{"archive"},
		Responses: map[string]*huma.Response{
			"200": binaryResponse("Complete Chronicle archive"),
		},
	})

	// Archive imports are registered directly on chi so the request body can be
	// streamed to disk. Huma's RawBody path buffers the full payload before the
	// handler, which is unsuitable for multi-gigabyte archives. The operation is
	// still declared in the shared OpenAPI contract for generated web clients.
	router.Post("/archive/import", h.importArchive)
	importResultSchema := api.OpenAPI().Components.Schemas.Schema(
		reflect.TypeOf(ImportResult{}),
		true,
		"ArchiveImportResult",
	)
	api.OpenAPI().AddOperation(&huma.Operation{
		OperationID: "import-archive",
		Method:      http.MethodPost,
		Path:        "/archive/import",
		Summary:     "Merge a Chronicle archive into the current account",
		Tags:        []string{"archive"},
		Parameters: []*huma.Param{
			{
				Name:        "Idempotency-Key",
				In:          "header",
				Required:    true,
				Description: "Stable UUID for this import operation",
				Schema:      &huma.Schema{Type: "string", Format: "uuid"},
			},
		},
		RequestBody: &huma.RequestBody{
			Required: true,
			Content: map[string]*huma.MediaType{
				"application/zip": {
					Schema: &huma.Schema{Type: "string", Format: "binary"},
				},
			},
		},
		Responses: map[string]*huma.Response{
			"200": {
				Description: "Archive merge result",
				Content: map[string]*huma.MediaType{
					"application/json": {Schema: importResultSchema},
				},
			},
		},
	})
}

func binaryResponse(description string) *huma.Response {
	return &huma.Response{
		Description: description,
		Content: map[string]*huma.MediaType{
			"application/zip": {
				Schema: &huma.Schema{Type: "string", Format: "binary"},
			},
		},
	}
}

func (h *handler) exportArchive(writer http.ResponseWriter, request *http.Request) {
	rawToken := tokenFromRequest(request)
	if rawToken == "" {
		writeError(writer, http.StatusUnauthorized, "Unauthorized", "")
		return
	}
	userIDText, err := h.validate(rawToken)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, "Unauthorized", "")
		return
	}
	userID, err := uuid.Parse(userIDText)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, "Unauthorized", "")
		return
	}
	release, acquired := h.tryAcquireTransfer(userID, h.exportSlots)
	if !acquired {
		writer.Header().Set("Retry-After", "30")
		writeError(writer, http.StatusTooManyRequests, "Too many archive transfers are already running", "")
		return
	}
	defer release()
	controller := http.NewResponseController(writer)
	_ = controller.SetWriteDeadline(time.Now().Add(maxTransferDuration))
	exportContext, cancel := context.WithTimeout(request.Context(), maxTransferDuration)
	defer cancel()
	exported, err := h.service.Export(exportContext, userID)
	if err != nil {
		var importErr *ImportError
		if errors.As(err, &importErr) {
			writeError(writer, importErr.Status, importErr.Title, "")
			return
		}
		writeError(writer, http.StatusInternalServerError, "Could not create archive", "")
		return
	}
	defer os.Remove(exported.Path)
	stat, err := os.Stat(exported.Path)
	if err != nil {
		writeError(writer, http.StatusInternalServerError, "Could not open archive", "")
		return
	}
	file, err := os.Open(exported.Path)
	if err != nil {
		writeError(writer, http.StatusInternalServerError, "Could not open archive", "")
		return
	}
	defer file.Close()
	writer.Header().Set("Content-Type", "application/zip")
	writer.Header().Set(
		"Content-Disposition",
		fmt.Sprintf(`attachment; filename="%s"`, exported.Filename),
	)
	writer.Header().Set("Content-Length", strconv.FormatInt(stat.Size(), 10))
	_, _ = io.Copy(idleDeadlineWriter{writer: writer, controller: controller}, file)
}

func (h *handler) importArchive(writer http.ResponseWriter, request *http.Request) {
	rawToken := tokenFromRequest(request)
	if rawToken == "" {
		writeError(writer, http.StatusUnauthorized, "Unauthorized", "")
		return
	}
	userIDText, err := h.validate(rawToken)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, "Unauthorized", "")
		return
	}
	userID, err := uuid.Parse(userIDText)
	if err != nil {
		writeError(writer, http.StatusUnauthorized, "Unauthorized", "")
		return
	}
	controller := http.NewResponseController(writer)
	_ = controller.SetWriteDeadline(time.Now().Add(maxTransferDuration))
	operationID, err := uuid.Parse(strings.TrimSpace(request.Header.Get("Idempotency-Key")))
	if err != nil {
		writeError(writer, http.StatusUnprocessableEntity, "Idempotency-Key must be a UUID", "")
		return
	}
	contentType := strings.ToLower(strings.TrimSpace(strings.Split(request.Header.Get("Content-Type"), ";")[0]))
	if contentType != "application/zip" && contentType != "application/octet-stream" {
		writeError(writer, http.StatusUnsupportedMediaType, "Content-Type must be application/zip", "")
		return
	}
	if request.ContentLength > h.maxBytes && h.maxBytes > 0 {
		writeError(writer, http.StatusRequestEntityTooLarge, "Archive exceeds the configured size limit", "")
		return
	}
	release, acquired := h.tryAcquireTransfer(userID, h.importSlots)
	if !acquired {
		writer.Header().Set("Retry-After", "30")
		writeError(writer, http.StatusTooManyRequests, "Too many archive imports are already running", "")
		return
	}
	defer release()
	transferContext, cancelTransfer := context.WithTimeout(request.Context(), maxTransferDuration)
	defer cancelTransfer()
	stopClose := context.AfterFunc(transferContext, func() {
		_ = request.Body.Close()
	})
	defer stopClose()

	temp, err := os.CreateTemp("", "chronicle-import-*.zip")
	if err != nil {
		writeError(writer, http.StatusInternalServerError, "Could not receive archive", "")
		return
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)

	hash := sha256.New()
	reader := io.Reader(request.Body)
	if h.maxBytes > 0 {
		reader = io.LimitReader(reader, h.maxBytes+1)
	}
	written, copyErr := io.Copy(
		io.MultiWriter(temp, hash),
		idleDeadlineReader{reader: reader, writer: writer},
	)
	closeErr := temp.Close()
	if copyErr != nil {
		writeError(writer, http.StatusBadRequest, "Could not receive archive", "")
		return
	}
	if closeErr != nil {
		writeError(writer, http.StatusInternalServerError, "Could not store archive", "")
		return
	}
	if h.maxBytes > 0 && written > h.maxBytes {
		writeError(writer, http.StatusRequestEntityTooLarge, "Archive exceeds the configured size limit", "")
		return
	}

	result, err := h.service.Import(
		transferContext,
		userID,
		operationID,
		tempPath,
		hex.EncodeToString(hash.Sum(nil)),
	)
	if err != nil {
		_ = controller.SetWriteDeadline(time.Now().Add(transferIdleTimeout))
		var importErr *ImportError
		if errors.As(err, &importErr) {
			detail := ""
			if importErr.Err != nil && importErr.Status == http.StatusUnprocessableEntity {
				detail = importErr.Err.Error()
			}
			writeError(writer, importErr.Status, importErr.Title, detail)
			return
		}
		writeError(writer, http.StatusInternalServerError, "Could not import archive", "")
		return
	}
	_ = controller.SetWriteDeadline(time.Now().Add(transferIdleTimeout))
	writeJSON(writer, http.StatusOK, result)
}

func (h *handler) tryAcquireTransfer(
	userID uuid.UUID,
	slots chan struct{},
) (func(), bool) {
	h.transferMu.Lock()
	if _, active := h.activeUsers[userID]; active {
		h.transferMu.Unlock()
		return nil, false
	}
	h.activeUsers[userID] = struct{}{}
	h.transferMu.Unlock()

	select {
	case slots <- struct{}{}:
		return func() {
			<-slots
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

func tokenFromRequest(request *http.Request) string {
	if authorization := request.Header.Get("Authorization"); strings.HasPrefix(authorization, "Bearer ") {
		return strings.TrimPrefix(authorization, "Bearer ")
	}
	if cookie, err := request.Cookie("access_token"); err == nil {
		return cookie.Value
	}
	return ""
}

func writeJSON(writer http.ResponseWriter, status int, value interface{}) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}

func writeError(writer http.ResponseWriter, status int, title, detail string) {
	body := map[string]interface{}{"status": status, "title": title}
	if detail != "" {
		body["detail"] = detail
	}
	writeJSON(writer, status, body)
}

type idleDeadlineReader struct {
	reader io.Reader
	writer http.ResponseWriter
}

func (reader idleDeadlineReader) Read(buffer []byte) (int, error) {
	controller := http.NewResponseController(reader.writer)
	// A wrapper may not expose deadline control. The server-level ReadTimeout
	// remains the fallback in that case.
	_ = controller.SetReadDeadline(time.Now().Add(transferIdleTimeout))
	return reader.reader.Read(buffer)
}

type idleDeadlineWriter struct {
	writer     io.Writer
	controller *http.ResponseController
}

func (writer idleDeadlineWriter) Write(data []byte) (int, error) {
	if writer.controller != nil {
		_ = writer.controller.SetWriteDeadline(time.Now().Add(transferIdleTimeout))
	}
	return writer.writer.Write(data)
}
