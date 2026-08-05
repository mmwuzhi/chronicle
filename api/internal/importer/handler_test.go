package importer_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humachi"
	"github.com/go-chi/chi/v5"

	"github.com/sikaoshenmi/chronicle/internal/auth"
	"github.com/sikaoshenmi/chronicle/internal/importer"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/testutil"
)

func TestCaptureTokenCannotImportOrUndoMarkdown(t *testing.T) {
	router := chi.NewRouter()
	api := humachi.New(router, huma.DefaultConfig("Import Test", "0.0.0"))
	api.UseMiddleware(auth.InjectHumaContext)
	validateJWT := auth.ValidateToken(testutil.TestJWTSecret)
	importer.Register(
		api,
		router,
		nil,
		importer.Config{MaxBytes: 1 << 20},
		nil,
		middleware.RequireAuthHuma(validateJWT),
		validateJWT,
	)

	for _, testCase := range []struct {
		name string
		path string
	}{
		{name: "import", path: "/imports/markdown"},
		{name: "undo", path: "/imports/markdown/3b69f923-dd6f-4611-90aa-642d2626dcd8/undo"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, testCase.path, bytes.NewBufferString("note"))
			request.Header.Set("Authorization", "Bearer chr_cap_not-a-jwt")
			if testCase.name == "import" {
				request.Header.Set("Content-Type", "text/markdown")
				request.Header.Set("Idempotency-Key", "3b69f923-dd6f-4611-90aa-642d2626dcd8")
				request.Header.Set("X-Import-Filename", "note.md")
			}
			response := httptest.NewRecorder()

			router.ServeHTTP(response, request)

			if response.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d, want 401", response.Code)
			}
		})
	}
}
