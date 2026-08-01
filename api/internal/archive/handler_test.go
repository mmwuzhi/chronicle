package archive_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humachi"
	"github.com/go-chi/chi/v5"

	archiveapi "github.com/sikaoshenmi/chronicle/internal/archive"
	"github.com/sikaoshenmi/chronicle/internal/auth"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/testutil"
)

func TestCaptureTokenCannotExportOrImportArchive(t *testing.T) {
	router := chi.NewRouter()
	api := humachi.New(router, huma.DefaultConfig("Archive Test", "0.0.0"))
	api.UseMiddleware(auth.InjectHumaContext)
	validateJWT := auth.ValidateToken(testutil.TestJWTSecret)
	archiveapi.Register(
		api,
		router,
		nil,
		nil,
		archiveapi.Config{MaxBytes: 1 << 20},
		nil,
		middleware.RequireAuthHuma(validateJWT),
		validateJWT,
	)

	for _, testCase := range []struct {
		name        string
		method      string
		path        string
		contentType string
	}{
		{name: "export", method: http.MethodGet, path: "/archive/export"},
		{
			name:        "import",
			method:      http.MethodPost,
			path:        "/archive/import",
			contentType: "application/zip",
		},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			request := httptest.NewRequest(
				testCase.method,
				testCase.path,
				bytes.NewReader(nil),
			)
			request.Header.Set("Authorization", "Bearer chr_cap_not-a-jwt")
			if testCase.contentType != "" {
				request.Header.Set("Content-Type", testCase.contentType)
				request.Header.Set("Idempotency-Key", "3b69f923-dd6f-4611-90aa-642d2626dcd8")
			}
			response := httptest.NewRecorder()

			router.ServeHTTP(response, request)

			if response.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401", response.Code)
			}
		})
	}
}
