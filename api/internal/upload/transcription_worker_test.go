package upload

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/s3"
)

type workerS3 struct {
	body string
}

func (s workerS3) PutObject(context.Context, *s3.PutObjectInput, ...func(*s3.Options)) (*s3.PutObjectOutput, error) {
	return &s3.PutObjectOutput{}, nil
}

func (s workerS3) GetObject(context.Context, *s3.GetObjectInput, ...func(*s3.Options)) (*s3.GetObjectOutput, error) {
	return &s3.GetObjectOutput{
		Body: io.NopCloser(strings.NewReader(s.body)),
	}, nil
}

func TestTranscribeUsesConfiguredEndpointAndModel(t *testing.T) {
	var receivedPath string
	var receivedModel string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedPath = r.URL.Path
		if err := r.ParseMultipartForm(maxUploadSize); err != nil {
			t.Fatalf("parse multipart: %v", err)
		}
		receivedModel = r.FormValue("model")
		if r.Header.Get("Authorization") != "Bearer test-key" {
			t.Fatalf("unexpected authorization header")
		}
		_, _ = w.Write([]byte("configured transcript"))
	}))
	t.Cleanup(server.Close)

	worker := transcriptionWorker{
		s3:     workerS3{body: "audio"},
		bucket: "bucket",
		apiKey: "test-key",
		apiURL: transcriptionEndpoint(server.URL),
		model:  "test-transcription-model",
		client: server.Client(),
	}
	text, err := worker.transcribe(context.Background(), "captures/audio.webm")
	if err != nil {
		t.Fatalf("transcribe: %v", err)
	}
	if text != "configured transcript" {
		t.Fatalf("unexpected transcript %q", text)
	}
	if receivedPath != "/audio/transcriptions" {
		t.Fatalf("unexpected path %q", receivedPath)
	}
	if receivedModel != "test-transcription-model" {
		t.Fatalf("unexpected model %q", receivedModel)
	}
}

func TestTranscriptionEndpointAcceptsFullEndpoint(t *testing.T) {
	full := "https://example.test/v1/audio/transcriptions"
	if got := transcriptionEndpoint(full); got != full {
		t.Fatalf("expected full endpoint unchanged, got %q", got)
	}
	if got := transcriptionEndpoint("https://example.test/v1/"); got != full {
		t.Fatalf("unexpected endpoint %q", got)
	}
}
