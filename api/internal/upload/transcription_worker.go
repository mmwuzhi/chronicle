package upload

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"mime/multipart"
	"net/http"
	"net/url"
	"path"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
)

type transcriptionWorker struct {
	q      *db.Queries
	s3     S3Client
	bucket string
	apiKey string
	apiURL string
	model  string
	client *http.Client
}

func StartTranscriptionWorker(ctx context.Context, pool *pgxpool.Pool, s3c S3Client, cfg Config) {
	if s3c == nil || cfg.R2BucketName == "" || cfg.OpenAIKey == "" {
		return
	}
	worker := &transcriptionWorker{
		q:      db.New(pool),
		s3:     s3c,
		bucket: cfg.R2BucketName,
		apiKey: cfg.OpenAIKey,
		apiURL: transcriptionEndpoint(cfg.OpenAIBaseURL),
		model:  cfg.OpenAIModel,
		client: &http.Client{Timeout: 90 * time.Second},
	}
	go worker.run(ctx)
}

func (w *transcriptionWorker) run(ctx context.Context) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		if err := w.processAvailable(ctx); err != nil && !errors.Is(err, context.Canceled) {
			slog.Error("transcription worker failed", "traceId", "transcription-worker", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (w *transcriptionWorker) processAvailable(ctx context.Context) error {
	for {
		capture, err := w.q.ClaimPendingTranscription(ctx)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}

		transcript, err := w.transcribe(ctx, capture.MediaKey.String)
		if err != nil {
			if failErr := w.q.FailCaptureTranscription(ctx, capture.ID); failErr != nil {
				return failErr
			}
			slog.Warn(
				"audio transcription attempt failed",
				"traceId", "transcription-worker",
				"captureId", capture.ID,
				"attempt", capture.TranscriptionAttempts,
				"err", err,
			)
			continue
		}
		if err := w.q.CompleteCaptureTranscription(ctx, db.CompleteCaptureTranscriptionParams{
			ID:                 capture.ID,
			Transcript:         pgtype.Text{String: transcript, Valid: true},
			TranscriptionModel: pgtype.Text{String: w.model, Valid: true},
		}); err != nil {
			return err
		}
	}
}

func (w *transcriptionWorker) transcribe(ctx context.Context, key string) (string, error) {
	object, err := w.s3.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(w.bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return "", err
	}
	defer object.Body.Close()

	audio, err := io.ReadAll(io.LimitReader(object.Body, maxUploadSize+1))
	if err != nil {
		return "", err
	}
	if len(audio) > maxUploadSize {
		return "", errors.New("audio exceeds transcription size limit")
	}

	var body bytes.Buffer
	writer := multipart.NewWriter(&body)
	fileWriter, err := writer.CreateFormFile("file", path.Base(key))
	if err != nil {
		return "", err
	}
	if _, err := fileWriter.Write(audio); err != nil {
		return "", err
	}
	if err := writer.WriteField("model", w.model); err != nil {
		return "", err
	}
	if err := writer.WriteField("response_format", "text"); err != nil {
		return "", err
	}
	if err := writer.Close(); err != nil {
		return "", err
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, w.apiURL, &body)
	if err != nil {
		return "", err
	}
	request.Header.Set("Authorization", "Bearer "+w.apiKey)
	request.Header.Set("Content-Type", writer.FormDataContentType())

	response, err := w.client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", errors.New("transcription provider returned " + response.Status)
	}

	text, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		return "", err
	}
	if len(bytes.TrimSpace(text)) == 0 {
		return "", errors.New("transcription provider returned empty text")
	}
	return string(bytes.TrimSpace(text)), nil
}

func transcriptionEndpoint(baseURL string) string {
	trimmed := strings.TrimRight(baseURL, "/")
	if parsed, err := url.Parse(trimmed); err == nil && parsed.Path == "/v1/audio/transcriptions" {
		return trimmed
	}
	return trimmed + "/audio/transcriptions"
}
