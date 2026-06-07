package upload

import (
	"bytes"
	"context"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/textproto"
	"testing"

	"github.com/google/uuid"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/testutil"
)

func TestUploadCreatesCaptureOnlyWhenRequested(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "users")
	userID := uuid.New()
	if _, err := pool.Exec(
		context.Background(),
		"INSERT INTO users (id, email, password_hash) VALUES ($1, $2, 'hash')",
		userID,
		userID.String()+"@test.com",
	); err != nil {
		t.Fatalf("create user: %v", err)
	}

	h := handler{
		s3: workerS3{},
		q:  db.New(pool),
		cfg: Config{
			R2BucketName: "bucket",
			R2AccountID:  "account",
			OpenAIKey:    "key",
		},
		validate: func(string) (string, error) {
			return userID.String(), nil
		},
	}

	for _, test := range []struct {
		name           string
		createCapture  bool
		expectedCount  int
		expectedStatus string
	}{
		{name: "attachment upload", expectedCount: 0},
		{
			name:           "capture upload",
			createCapture:  true,
			expectedCount:  1,
			expectedStatus: "pending",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			request := newUploadRequest(t, test.createCapture)
			recorder := httptest.NewRecorder()
			h.upload(recorder, request)
			if recorder.Code != http.StatusOK {
				t.Fatalf("expected 200, got %d: %s", recorder.Code, recorder.Body.String())
			}

			var count int
			if err := pool.QueryRow(context.Background(), "SELECT count(*) FROM captures").Scan(&count); err != nil {
				t.Fatalf("count captures: %v", err)
			}
			if count != test.expectedCount {
				t.Fatalf("expected %d captures, got %d", test.expectedCount, count)
			}
			if test.expectedStatus != "" {
				var status string
				if err := pool.QueryRow(context.Background(), "SELECT transcription_status FROM captures").Scan(&status); err != nil {
					t.Fatalf("read transcription status: %v", err)
				}
				if status != test.expectedStatus {
					t.Fatalf("expected status %q, got %q", test.expectedStatus, status)
				}
			}
		})
	}
}

func newUploadRequest(t *testing.T, createCapture bool) *http.Request {
	t.Helper()
	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	header := make(textproto.MIMEHeader)
	header.Set("Content-Disposition", `form-data; name="file"; filename="recording.webm"`)
	header.Set("Content-Type", "audio/webm")
	part, err := writer.CreatePart(header)
	if err != nil {
		t.Fatalf("create multipart file: %v", err)
	}
	if _, err := part.Write([]byte("audio")); err != nil {
		t.Fatalf("write multipart file: %v", err)
	}
	if err := writer.WriteField("durationSec", "300"); err != nil {
		t.Fatalf("write duration: %v", err)
	}
	if createCapture {
		if err := writer.WriteField("createCapture", "true"); err != nil {
			t.Fatalf("write createCapture: %v", err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close multipart: %v", err)
	}

	request := httptest.NewRequest(http.MethodPost, "/captures/upload", &body)
	request.Header.Set("Content-Type", writer.FormDataContentType())
	request.Header.Set("Authorization", "Bearer token")
	return request
}
