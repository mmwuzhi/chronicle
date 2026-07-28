package upload

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/testutil"
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

func (s workerS3) DeleteObject(context.Context, *s3.DeleteObjectInput, ...func(*s3.Options)) (*s3.DeleteObjectOutput, error) {
	return &s3.DeleteObjectOutput{}, nil
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

func TestVisionTranscribeUsesChatEndpointAndModel(t *testing.T) {
	var receivedPath, receivedModel, receivedAuth string
	var hadImage bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		receivedPath = r.URL.Path
		receivedAuth = r.Header.Get("Authorization")
		var req struct {
			Model    string `json:"model"`
			Messages []struct {
				Content []struct {
					Type     string `json:"type"`
					ImageURL *struct {
						URL string `json:"url"`
					} `json:"image_url"`
				} `json:"content"`
			} `json:"messages"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		receivedModel = req.Model
		for _, m := range req.Messages {
			for _, c := range m.Content {
				if c.Type == "image_url" && c.ImageURL != nil && strings.HasPrefix(c.ImageURL.URL, "data:") {
					hadImage = true
				}
			}
		}
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"  ラーメン 1,180円  "}}]}`))
	}))
	t.Cleanup(server.Close)

	worker := transcriptionWorker{
		s3:          workerS3{body: "fake-image-bytes"},
		bucket:      "bucket",
		apiKey:      "test-key",
		visionURL:   chatCompletionsEndpoint(server.URL),
		visionModel: "test-vision-model",
		client:      server.Client(),
	}
	text, err := worker.visionTranscribe(context.Background(), "captures/receipt.jpg")
	if err != nil {
		t.Fatalf("visionTranscribe: %v", err)
	}
	if text != "ラーメン 1,180円" {
		t.Fatalf("unexpected transcript %q (whitespace should be trimmed)", text)
	}
	if receivedPath != "/chat/completions" {
		t.Fatalf("unexpected path %q", receivedPath)
	}
	if receivedModel != "test-vision-model" {
		t.Fatalf("unexpected model %q", receivedModel)
	}
	if receivedAuth != "Bearer test-key" {
		t.Fatalf("unexpected authorization %q", receivedAuth)
	}
	if !hadImage {
		t.Fatalf("expected a data: image_url part in the request body")
	}
}

// Regression for the vision opt-out bypass: VISION_ENABLED=false marks uploaded
// images as skipped, but RetryCaptureTranscription let any image return to
// pending, and the worker sent every pending image to the vision provider. The
// opt-out is now enforced at the sink — a pending image with vision disabled is
// skipped, never transcribed.
func TestProcessAvailableSkipsImageWhenVisionDisabled(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "users")
	ctx := context.Background()

	userID := uuid.New()
	if _, err := pool.Exec(ctx,
		"INSERT INTO users (id, email, password_hash) VALUES ($1, $2, 'hash')",
		userID, userID.String()+"@test.com",
	); err != nil {
		t.Fatalf("create user: %v", err)
	}

	q := db.New(pool)
	// An image sitting at 'pending' (created when vision was on, or moved back by
	// retry) — the exact state the bypass exploited.
	capture, err := q.CreateUploadedCapture(ctx, db.CreateUploadedCaptureParams{
		ID:            uuid.New(),
		UserID:        userID,
		MediaUrl:      "https://r2.example/x.jpg",
		MediaType:     db.CaptureMediaTypeImage,
		Source:        "desktop",
		MediaKey:      "captures/x.jpg",
		VisionEnabled: true, // create as pending
	})
	if err != nil {
		t.Fatalf("create capture: %v", err)
	}
	if capture.TranscriptionStatus != db.TranscriptionStatusPending {
		t.Fatalf("precondition: expected pending, got %q", capture.TranscriptionStatus)
	}

	// Any call to the vision provider while disabled is a bypass — fail the test.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("vision provider must not be called when VISION_ENABLED is off (hit %s)", r.URL.Path)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(server.Close)

	worker := transcriptionWorker{
		q:             q,
		s3:            workerS3{body: "image-bytes"},
		bucket:        "bucket",
		visionURL:     chatCompletionsEndpoint(server.URL),
		visionModel:   "test-vision-model",
		client:        server.Client(),
		visionEnabled: false,
	}
	if _, err := worker.processAvailable(ctx); err != nil {
		t.Fatalf("processAvailable: %v", err)
	}

	var status string
	if err := pool.QueryRow(ctx,
		"SELECT transcription_status FROM captures WHERE id = $1", capture.ID,
	).Scan(&status); err != nil {
		t.Fatalf("read status: %v", err)
	}
	if status != string(db.TranscriptionStatusSkipped) {
		t.Fatalf("expected image skipped when vision disabled, got %q", status)
	}
}

// Regression for the cross-drain wake loss: the retry a failed attempt
// schedules must be reported by *every* later drain, not only the drain that
// scheduled it. The run loop resets its timer after each wake-up, so if an
// unrelated kick drained an empty queue and got zero back, a due-in-1-minute
// retry would silently wait for the 15-minute fallback.
func TestProcessAvailableReportsScheduledRetryAcrossDrains(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "users")
	ctx := context.Background()

	userID := uuid.New()
	if _, err := pool.Exec(ctx,
		"INSERT INTO users (id, email, password_hash) VALUES ($1, $2, 'hash')",
		userID, userID.String()+"@test.com",
	); err != nil {
		t.Fatalf("create user: %v", err)
	}

	q := db.New(pool)
	if _, err := q.CreateUploadedCapture(ctx, db.CreateUploadedCaptureParams{
		ID:                   uuid.New(),
		UserID:               userID,
		MediaUrl:             "https://r2.example/a.webm",
		MediaType:            db.CaptureMediaTypeAudio,
		Source:               "desktop",
		MediaKey:             "captures/a.webm",
		AudioDurationSec:     pgtype.Int4{Int32: 60, Valid: true},
		TranscriptionEnabled: true,
	}); err != nil {
		t.Fatalf("create capture: %v", err)
	}

	// A provider that always fails, so the first drain schedules the attempt-1
	// backoff (1 minute) via FailCaptureTranscription.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	t.Cleanup(server.Close)

	worker := transcriptionWorker{
		q:      q,
		s3:     workerS3{body: "audio"},
		bucket: "bucket",
		apiKey: "test-key",
		apiURL: transcriptionEndpoint(server.URL),
		model:  "test-transcription-model",
		client: server.Client(),
	}

	first, err := worker.processAvailable(ctx)
	if err != nil {
		t.Fatalf("first drain: %v", err)
	}
	if first <= 0 || first > time.Minute {
		t.Fatalf("first drain should report the 1-minute backoff, got %v", first)
	}

	// An unrelated wake-up with nothing claimable must still see the scheduled
	// retry instead of reporting "nothing scheduled".
	second, err := worker.processAvailable(ctx)
	if err != nil {
		t.Fatalf("second drain: %v", err)
	}
	if second <= 0 || second > time.Minute {
		t.Fatalf("later drains must keep reporting the pending retry, got %v", second)
	}
}

// A processing row can be reclaimed after its lease expires. The original
// worker must not be able to complete, fail, or skip the newer worker's claim.
func TestTranscriptionTerminalWritesRequireCurrentClaimLease(t *testing.T) {
	for _, terminal := range []string{"complete", "fail", "skip"} {
		t.Run(terminal, func(t *testing.T) {
			pool := testutil.NewPool(t)
			testutil.Truncate(t, pool, "captures", "users")
			ctx := context.Background()

			userID := uuid.New()
			if _, err := pool.Exec(ctx,
				"INSERT INTO users (id, email, password_hash) VALUES ($1, $2, 'hash')",
				userID, userID.String()+"@test.com",
			); err != nil {
				t.Fatalf("create user: %v", err)
			}

			q := db.New(pool)
			created, err := q.CreateUploadedCapture(ctx, db.CreateUploadedCaptureParams{
				ID:                   uuid.New(),
				UserID:               userID,
				MediaUrl:             "https://r2.example/a.webm",
				MediaType:            db.CaptureMediaTypeAudio,
				Source:               "desktop",
				MediaKey:             "captures/a.webm",
				AudioDurationSec:     pgtype.Int4{Int32: 60, Valid: true},
				TranscriptionEnabled: true,
			})
			if err != nil {
				t.Fatalf("create capture: %v", err)
			}
			if _, err := q.ClaimPendingTranscription(ctx); err != nil {
				t.Fatalf("first claim: %v", err)
			}

			// Model the first claim reaching its expiry while its worker still
			// holds the old token, then let another worker reclaim the row.
			var expiredLease time.Time
			if err := pool.QueryRow(ctx, `
				UPDATE captures
				SET next_transcription_at = now() - interval '1 second'
				WHERE id = $1
				RETURNING next_transcription_at`,
				created.ID,
			).Scan(&expiredLease); err != nil {
				t.Fatalf("expire first lease: %v", err)
			}
			staleLease := pgtype.Timestamptz{Time: expiredLease, Valid: true}
			current, err := q.ClaimPendingTranscription(ctx)
			if err != nil {
				t.Fatalf("reclaim: %v", err)
			}
			if current.NextTranscriptionAt.Time.Equal(expiredLease) {
				t.Fatal("reclaim must issue a new lease token")
			}

			var affected int64
			switch terminal {
			case "complete":
				affected, err = q.CompleteCaptureTranscription(ctx, db.CompleteCaptureTranscriptionParams{
					ID:                 created.ID,
					Transcript:         pgtype.Text{String: "stale transcript", Valid: true},
					TranscriptionModel: pgtype.Text{String: "stale-model", Valid: true},
					LeaseExpiresAt:     staleLease,
				})
			case "fail":
				affected, err = q.FailCaptureTranscription(ctx, db.FailCaptureTranscriptionParams{
					ID:             created.ID,
					LeaseExpiresAt: staleLease,
				})
			case "skip":
				affected, err = q.SkipCaptureTranscription(ctx, db.SkipCaptureTranscriptionParams{
					ID:             created.ID,
					LeaseExpiresAt: staleLease,
				})
			}
			if err != nil {
				t.Fatalf("stale %s: %v", terminal, err)
			}
			if affected != 0 {
				t.Fatalf("stale %s changed %d rows, want 0", terminal, affected)
			}

			state, err := q.GetCapture(ctx, db.GetCaptureParams{ID: created.ID, UserID: userID})
			if err != nil {
				t.Fatalf("read reclaimed capture: %v", err)
			}
			if state.TranscriptionStatus != db.TranscriptionStatusProcessing {
				t.Fatalf("stale %s changed status to %q", terminal, state.TranscriptionStatus)
			}
			if state.TranscriptionAttempts != 2 {
				t.Fatalf("stale %s changed attempts to %d, want 2", terminal, state.TranscriptionAttempts)
			}
			if state.Transcript.Valid {
				t.Fatalf("stale %s stored transcript %q", terminal, state.Transcript.String)
			}
			if !state.NextTranscriptionAt.Time.Equal(current.NextTranscriptionAt.Time) {
				t.Fatalf("stale %s changed the current lease", terminal)
			}

			switch terminal {
			case "complete":
				affected, err = q.CompleteCaptureTranscription(ctx, db.CompleteCaptureTranscriptionParams{
					ID:                 created.ID,
					Transcript:         pgtype.Text{String: "current transcript", Valid: true},
					TranscriptionModel: pgtype.Text{String: "current-model", Valid: true},
					LeaseExpiresAt:     current.NextTranscriptionAt,
				})
			case "fail":
				affected, err = q.FailCaptureTranscription(ctx, db.FailCaptureTranscriptionParams{
					ID:             created.ID,
					LeaseExpiresAt: current.NextTranscriptionAt,
				})
			case "skip":
				affected, err = q.SkipCaptureTranscription(ctx, db.SkipCaptureTranscriptionParams{
					ID:             created.ID,
					LeaseExpiresAt: current.NextTranscriptionAt,
				})
			}
			if err != nil {
				t.Fatalf("current %s: %v", terminal, err)
			}
			if affected != 1 {
				t.Fatalf("current %s changed %d rows, want 1", terminal, affected)
			}
		})
	}
}

func TestChatCompletionsEndpointAcceptsFullEndpoint(t *testing.T) {
	full := "https://example.test/v1/chat/completions"
	if got := chatCompletionsEndpoint(full); got != full {
		t.Fatalf("expected full endpoint unchanged, got %q", got)
	}
	if got := chatCompletionsEndpoint("https://example.test/v1/"); got != full {
		t.Fatalf("unexpected endpoint %q", got)
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
