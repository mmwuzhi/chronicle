package upload

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
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
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
)

type transcriptionWorker struct {
	q             *db.Queries
	s3            S3Client
	bucket        string
	apiKey        string
	apiURL        string
	model         string
	visionURL     string
	visionModel   string
	client        *http.Client
	rag           *ragclient.Client
	visionEnabled bool
}

func StartTranscriptionWorker(ctx context.Context, pool *pgxpool.Pool, s3c S3Client, cfg Config, rag *ragclient.Client) {
	if s3c == nil || cfg.R2BucketName == "" || cfg.OpenAIKey == "" {
		return
	}
	worker := &transcriptionWorker{
		q:             db.New(pool),
		s3:            s3c,
		bucket:        cfg.R2BucketName,
		apiKey:        cfg.OpenAIKey,
		apiURL:        transcriptionEndpoint(cfg.OpenAIBaseURL),
		model:         cfg.OpenAIModel,
		visionURL:     chatCompletionsEndpoint(cfg.OpenAIBaseURL),
		visionModel:   cfg.OpenAIVisionModel,
		client:        &http.Client{Timeout: 90 * time.Second},
		rag:           rag,
		visionEnabled: cfg.VisionEnabled,
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

		// Enforce the vision opt-out at the sink. Create marks images skipped when
		// VISION_ENABLED is off, but a later path (e.g. retry) can move one back to
		// pending; refuse to send it to the vision provider here too, marking it
		// skipped so it leaves the queue instead of looping. Audio is unaffected.
		if capture.MediaType == db.CaptureMediaTypeImage && !w.visionEnabled {
			if err := w.q.SkipCaptureTranscription(ctx, capture.ID); err != nil {
				return err
			}
			continue
		}

		transcript, model, err := w.transcribeCapture(ctx, capture)
		if err != nil {
			if failErr := w.q.FailCaptureTranscription(ctx, capture.ID); failErr != nil {
				return failErr
			}
			slog.Warn(
				"transcription attempt failed",
				"traceId", "transcription-worker",
				"captureId", capture.ID,
				"mediaType", string(capture.MediaType),
				"attempt", capture.TranscriptionAttempts,
				"err", err,
			)
			continue
		}
		if err := w.q.CompleteCaptureTranscription(ctx, db.CompleteCaptureTranscriptionParams{
			ID:                 capture.ID,
			Transcript:         pgtype.Text{String: transcript, Valid: true},
			TranscriptionModel: pgtype.Text{String: model, Valid: true},
		}); err != nil {
			return err
		}
		// Transcript is now the capture's indexable content — embed it.
		w.rag.Index(capture.UserID.String(), capture.ID.String())
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

// transcribeCapture turns one media capture into indexable text, picking the
// backend by media type: audio → speech-to-text, image → vision description.
// Returns the transcript and the model name that produced it.
func (w *transcriptionWorker) transcribeCapture(ctx context.Context, capture db.Capture) (string, string, error) {
	if capture.MediaType == db.CaptureMediaTypeImage {
		text, err := w.visionTranscribe(ctx, capture.MediaKey.String)
		return text, w.visionModel, err
	}
	text, err := w.transcribe(ctx, capture.MediaKey.String)
	return text, w.model, err
}

// visionPrompt is ported from rag3/vision.py: transcribe receipts verbatim,
// describe ordinary photos factually, output only the text. The result flows
// through the same embed + extract pipeline as audio transcripts.
const visionPrompt = "读取这张图片。" +
	"若是收据/票据/账单：逐行转写全部内容（商户、日期、品项、金额照实誊写）。" +
	"若是普通照片：客观描述画面中的事实（出现的文字、物体、人物、场景）。" +
	"只输出转写/描述本身，不要任何解释或评论。"

type visionRequest struct {
	Model    string          `json:"model"`
	Messages []visionMessage `json:"messages"`
}

type visionMessage struct {
	Role    string          `json:"role"`
	Content []visionContent `json:"content"`
}

type visionContent struct {
	Type     string          `json:"type"`
	Text     string          `json:"text,omitempty"`
	ImageURL *visionImageURL `json:"image_url,omitempty"`
}

type visionImageURL struct {
	URL string `json:"url"`
}

type visionResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
}

// visionTranscribe downloads an image from R2 and asks the vision model to
// transcribe/describe it as factual text via the OpenAI-compatible chat API.
func (w *transcriptionWorker) visionTranscribe(ctx context.Context, key string) (string, error) {
	object, err := w.s3.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(w.bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return "", err
	}
	defer object.Body.Close()

	image, err := io.ReadAll(io.LimitReader(object.Body, maxUploadSize+1))
	if err != nil {
		return "", err
	}
	if len(image) > maxUploadSize {
		return "", errors.New("image exceeds vision size limit")
	}
	if len(image) == 0 {
		return "", errors.New("image object is empty")
	}

	dataURL := "data:" + http.DetectContentType(image) + ";base64," +
		base64.StdEncoding.EncodeToString(image)
	payload, err := json.Marshal(visionRequest{
		Model: w.visionModel,
		Messages: []visionMessage{{
			Role: "user",
			Content: []visionContent{
				{Type: "text", Text: visionPrompt},
				{Type: "image_url", ImageURL: &visionImageURL{URL: dataURL}},
			},
		}},
	})
	if err != nil {
		return "", err
	}

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, w.visionURL, bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	request.Header.Set("Authorization", "Bearer "+w.apiKey)
	request.Header.Set("Content-Type", "application/json")

	response, err := w.client.Do(request)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", errors.New("vision provider returned " + response.Status)
	}

	var parsed visionResponse
	if err := json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(&parsed); err != nil {
		return "", err
	}
	if len(parsed.Choices) == 0 {
		return "", errors.New("vision provider returned no choices")
	}
	text := strings.TrimSpace(parsed.Choices[0].Message.Content)
	if text == "" {
		return "", errors.New("vision provider returned empty text")
	}
	return text, nil
}

// chatCompletionsEndpoint resolves the OpenAI-compatible chat URL from the base
// URL (which already includes /v1), mirroring transcriptionEndpoint.
func chatCompletionsEndpoint(baseURL string) string {
	trimmed := strings.TrimRight(baseURL, "/")
	if parsed, err := url.Parse(trimmed); err == nil && parsed.Path == "/v1/chat/completions" {
		return trimmed
	}
	return trimmed + "/chat/completions"
}

func transcriptionEndpoint(baseURL string) string {
	trimmed := strings.TrimRight(baseURL, "/")
	if parsed, err := url.Parse(trimmed); err == nil && parsed.Path == "/v1/audio/transcriptions" {
		return trimmed
	}
	return trimmed + "/audio/transcriptions"
}
