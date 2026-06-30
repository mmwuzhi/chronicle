package capture_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humachi"
	"github.com/go-chi/chi/v5"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/auth"
	"github.com/sikaoshenmi/chronicle/internal/capture"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
	"github.com/sikaoshenmi/chronicle/testutil"
)

func newServer(t *testing.T) (*httptest.Server, *pgxpool.Pool) {
	t.Helper()
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "users")

	r := chi.NewRouter()
	api := humachi.New(r, huma.DefaultConfig("Test", "0.0.0"))
	api.UseMiddleware(auth.InjectHumaContext)

	authMW := middleware.RequireAuthHuma(func(raw string) (string, error) {
		tok, err := jwt.Parse(raw, func(_ *jwt.Token) (any, error) {
			return []byte(testutil.TestJWTSecret), nil
		}, jwt.WithValidMethods([]string{"HS256"}))
		if err != nil || !tok.Valid {
			return "", fmt.Errorf("invalid token")
		}
		sub, _ := tok.Claims.GetSubject()
		return sub, nil
	})

	// create accepts a JWT or a capture token (the real create-only validator);
	// read/mutate routes stay JWT-only via authMW.
	createMW := middleware.RequireAuthHumaCtx(auth.ValidateTokenOrPAT(testutil.TestJWTSecret, db.New(pool)))
	capture.Register(api, pool, ragclient.New(""), authMW, createMW)

	srv := httptest.NewServer(r)
	t.Cleanup(srv.Close)
	return srv, pool
}

func createTestUser(t *testing.T, pool *pgxpool.Pool) (userID, token string) {
	t.Helper()
	uid := uuid.New()
	_, err := pool.Exec(context.Background(),
		"INSERT INTO users (id, email, password_hash) VALUES ($1, $2, $3)",
		uid, fmt.Sprintf("%s@test.com", uid), "testhash",
	)
	if err != nil {
		t.Fatalf("create test user: %v", err)
	}
	return uid.String(), testutil.MakeToken(t, uid.String())
}

func do(t *testing.T, client *http.Client, method, url, token string, body any) *http.Response {
	t.Helper()
	var r io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		r = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, url, r)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	return resp
}

func decodeBody(t *testing.T, resp *http.Response, dst any) {
	t.Helper()
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(dst); err != nil {
		t.Fatalf("decode response: %v", err)
	}
}

func createCapture(t *testing.T, srv *httptest.Server, token string, extras map[string]any) string {
	t.Helper()
	body := map[string]any{
		"mediaType":    "text",
		"classifiedAs": "unclassified",
		"rawText":      "test capture",
	}
	for k, v := range extras {
		body[k] = v
	}
	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", token, body)
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("setup: create capture: got %d", resp.StatusCode)
	}
	var out struct {
		ID string `json:"id"`
	}
	decodeBody(t, resp, &out)
	return out.ID
}

// --- create ---

func TestCreateCapture_TextHappyPath(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", token, map[string]any{
		"mediaType":    "text",
		"classifiedAs": "idea",
		"rawText":      "Build a time-lapse camera from a Raspberry Pi",
	})

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		ID           string  `json:"id"`
		RawText      *string `json:"rawText"`
		MediaType    string  `json:"mediaType"`
		ClassifiedAs string  `json:"classifiedAs"`
		Source       string  `json:"source"`
	}
	decodeBody(t, resp, &body)

	if body.ID == "" {
		t.Fatal("expected non-empty id")
	}
	if body.RawText == nil || *body.RawText != "Build a time-lapse camera from a Raspberry Pi" {
		t.Fatalf("unexpected rawText: %v", body.RawText)
	}
	if body.MediaType != "text" {
		t.Fatalf("expected mediaType 'text', got %q", body.MediaType)
	}
	if body.ClassifiedAs != "idea" {
		t.Fatalf("expected classifiedAs 'idea', got %q", body.ClassifiedAs)
	}
	if body.Source != "web" {
		t.Fatalf("expected default source 'web', got %q", body.Source)
	}
}

func TestCreateCapture_DesktopSource(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", token, map[string]any{
		"mediaType":    "text",
		"classifiedAs": "unclassified",
		"rawText":      "Captured from a global shortcut",
		"source":       "desktop_quick_capture",
	})

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		Source string `json:"source"`
	}
	decodeBody(t, resp, &body)

	if body.Source != "desktop_quick_capture" {
		t.Fatalf("expected desktop source, got %q", body.Source)
	}
}

func TestCreateCapture_WithReminder(t *testing.T) {
	srv, pool := newServer(t)
	userID, token := createTestUser(t, pool)
	remindAt := time.Now().Add(time.Hour).UTC().Truncate(time.Second).Format(time.RFC3339)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", token, map[string]any{
		"mediaType":    "text",
		"classifiedAs": "unclassified",
		"rawText":      "Remind me from desktop",
		"remindAt":     remindAt,
	})

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		ID       string  `json:"id"`
		RemindAt *string `json:"remindAt"`
	}
	decodeBody(t, resp, &body)

	if body.RemindAt == nil || *body.RemindAt != remindAt {
		t.Fatalf("expected remindAt %q, got %v", remindAt, body.RemindAt)
	}

	queries := db.New(pool)
	uid := uuid.MustParse(userID)
	rows, err := queries.PendingReminders(context.Background(), uid)
	if err != nil {
		t.Fatalf("pending reminders: %v", err)
	}
	if len(rows) != 1 || rows[0].ID.String() != body.ID {
		t.Fatalf("expected created capture in pending reminders, got %d rows", len(rows))
	}
}

func TestCreateCapture_InvalidReminderDoesNotCreateCapture(t *testing.T) {
	srv, pool := newServer(t)
	userID, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", token, map[string]any{
		"mediaType":    "text",
		"classifiedAs": "unclassified",
		"rawText":      "Bad reminder",
		"remindAt":     "tomorrow-ish",
	})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d", resp.StatusCode)
	}

	rows, err := db.New(pool).ListCaptures(context.Background(), db.ListCapturesParams{
		UserID: uuid.MustParse(userID),
	})
	if err != nil {
		t.Fatalf("list captures: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("invalid reminder should not create capture, got %d rows", len(rows))
	}
}

func TestCreateCapture_InvalidMediaType(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", token, map[string]any{
		"mediaType":    "video",
		"classifiedAs": "unclassified",
	})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d", resp.StatusCode)
	}
}

func TestCreateCapture_TextRequiresRawText(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", token, map[string]any{
		"mediaType":    "text",
		"classifiedAs": "unclassified",
		"rawText":      "   ",
	})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d", resp.StatusCode)
	}
}

func TestUpdateCapture_TranscriptIsIndependent(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)
	id := createCapture(t, srv, token, nil)

	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/captures/"+id, token, map[string]any{
		"transcript": "AI generated transcript",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var body struct {
		RawText    *string `json:"rawText"`
		Transcript *string `json:"transcript"`
	}
	decodeBody(t, resp, &body)
	if body.RawText == nil || *body.RawText != "test capture" {
		t.Fatalf("expected original raw text, got %v", body.RawText)
	}
	if body.Transcript == nil || *body.Transcript != "AI generated transcript" {
		t.Fatalf("unexpected transcript: %v", body.Transcript)
	}
}

func TestRetryCaptureTranscription(t *testing.T) {
	srv, pool := newServer(t)
	userID, token := createTestUser(t, pool)
	id := uuid.New()
	_, err := pool.Exec(context.Background(), `
		INSERT INTO captures (
			id, user_id, media_type, classified_as, source, media_url, media_key,
			audio_duration_sec, transcription_status, transcription_attempts
		)
		VALUES ($1, $2, 'audio', 'unclassified', 'web', 'https://example.test/audio.webm',
			'captures/audio.webm', 120, 'failed', 4)`,
		id, userID,
	)
	if err != nil {
		t.Fatalf("create failed audio capture: %v", err)
	}

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+id.String()+"/transcription/retry", token, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var body struct {
		Status string `json:"transcriptionStatus"`
	}
	decodeBody(t, resp, &body)
	if body.Status != "pending" {
		t.Fatalf("expected pending status, got %q", body.Status)
	}
}

func TestUploadedAudioTranscriptionDurationBoundary(t *testing.T) {
	_, pool := newServer(t)
	userID, _ := createTestUser(t, pool)
	queries := db.New(pool)

	for _, test := range []struct {
		name     string
		duration int32
		status   db.TranscriptionStatus
	}{
		{name: "five minutes is eligible", duration: 300, status: db.TranscriptionStatusPending},
		{name: "over five minutes is skipped", duration: 301, status: db.TranscriptionStatusSkipped},
	} {
		t.Run(test.name, func(t *testing.T) {
			capture, err := queries.CreateUploadedCapture(context.Background(), db.CreateUploadedCaptureParams{
				UserID:               uuid.MustParse(userID),
				MediaUrl:             pgtype.Text{String: "https://example.test/audio.webm", Valid: true},
				MediaType:            db.CaptureMediaTypeAudio,
				MediaKey:             pgtype.Text{String: "captures/audio.webm", Valid: true},
				AudioDurationSec:     pgtype.Int4{Int32: test.duration, Valid: true},
				TranscriptionEnabled: true,
			})
			if err != nil {
				t.Fatalf("create uploaded capture: %v", err)
			}
			if capture.TranscriptionStatus != test.status {
				t.Fatalf("expected %q, got %q", test.status, capture.TranscriptionStatus)
			}
		})
	}
}

func TestUploadedImageVisionTranscription(t *testing.T) {
	_, pool := newServer(t)
	userID, _ := createTestUser(t, pool)
	queries := db.New(pool)

	for _, test := range []struct {
		name          string
		visionEnabled bool
		status        db.TranscriptionStatus
	}{
		{name: "vision enabled is pending", visionEnabled: true, status: db.TranscriptionStatusPending},
		{name: "vision disabled is skipped", visionEnabled: false, status: db.TranscriptionStatusSkipped},
	} {
		t.Run(test.name, func(t *testing.T) {
			capture, err := queries.CreateUploadedCapture(context.Background(), db.CreateUploadedCaptureParams{
				UserID:        uuid.MustParse(userID),
				MediaUrl:      pgtype.Text{String: "https://example.test/receipt.jpg", Valid: true},
				MediaType:     db.CaptureMediaTypeImage,
				MediaKey:      pgtype.Text{String: "captures/receipt.jpg", Valid: true},
				VisionEnabled: test.visionEnabled,
			})
			if err != nil {
				t.Fatalf("create uploaded capture: %v", err)
			}
			if capture.TranscriptionStatus != test.status {
				t.Fatalf("expected %q, got %q", test.status, capture.TranscriptionStatus)
			}
		})
	}
}

func TestCaptureReminderBrowseAndRecall(t *testing.T) {
	_, pool := newServer(t)
	userID, _ := createTestUser(t, pool)
	queries := db.New(pool)
	uid := uuid.MustParse(userID)
	ctx := context.Background()

	mk := func(text string) db.Capture {
		c, err := queries.CreateCapture(ctx, db.CreateCaptureParams{
			UserID:       uid,
			RawText:      pgtype.Text{String: text, Valid: true},
			MediaType:    db.CaptureMediaTypeText,
			ClassifiedAs: db.CaptureClassifiedAsUnclassified,
			Source:       "web",
		})
		if err != nil {
			t.Fatalf("create capture %q: %v", text, err)
		}
		return c
	}
	setRemind := func(c db.Capture, at pgtype.Timestamptz) {
		if _, err := queries.SetCaptureRemind(ctx, db.SetCaptureRemindParams{
			ID: c.ID, UserID: uid, RemindAt: at,
		}); err != nil {
			t.Fatalf("set remind: %v", err)
		}
	}
	ids := func(rows []db.Capture) map[uuid.UUID]bool {
		m := make(map[uuid.UUID]bool, len(rows))
		for _, c := range rows {
			m[c.ID] = true
		}
		return m
	}

	plain := mk("plain note")
	future := mk("buy milk later")
	past := mk("call the dentist")
	setRemind(future, pgtype.Timestamptz{Time: time.Now().Add(time.Hour), Valid: true})
	setRemind(past, pgtype.Timestamptz{Time: time.Now().Add(-time.Hour), Valid: true})

	// Default browse hides the not-yet-due reminder, keeps plain + past-due.
	browse, err := queries.ListCaptures(ctx, db.ListCapturesParams{UserID: uid})
	if err != nil {
		t.Fatalf("list captures: %v", err)
	}
	got := ids(browse)
	if !got[plain.ID] || !got[past.ID] {
		t.Fatalf("default browse should include plain and past-due captures")
	}
	if got[future.ID] {
		t.Fatalf("default browse should hide the not-yet-due reminder")
	}

	// include_reminded shows everything (management view).
	all, err := queries.ListCaptures(ctx, db.ListCapturesParams{UserID: uid, IncludeReminded: true})
	if err != nil {
		t.Fatalf("list captures (include_reminded): %v", err)
	}
	if len(all) != 3 {
		t.Fatalf("expected 3 with include_reminded, got %d", len(all))
	}

	// DueReminders returns only the past-due one.
	due, err := queries.DueReminders(ctx, db.DueRemindersParams{
		UserID: uid,
		Since:  pgtype.Timestamptz{Time: time.Now().Add(-24 * time.Hour), Valid: true},
	})
	if err != nil {
		t.Fatalf("due reminders: %v", err)
	}
	if len(due) != 1 || due[0].ID != past.ID {
		t.Fatalf("expected only the past-due reminder, got %d rows", len(due))
	}

	// PendingReminders returns only the not-yet-due one.
	pending, err := queries.PendingReminders(ctx, uid)
	if err != nil {
		t.Fatalf("pending reminders: %v", err)
	}
	if len(pending) != 1 || pending[0].ID != future.ID {
		t.Fatalf("expected only the not-yet-due reminder, got %d rows", len(pending))
	}

	// Clearing the reminder returns the capture to the default browse.
	setRemind(future, pgtype.Timestamptz{})
	browse2, err := queries.ListCaptures(ctx, db.ListCapturesParams{UserID: uid})
	if err != nil {
		t.Fatalf("list captures after clear: %v", err)
	}
	if !ids(browse2)[future.ID] {
		t.Fatalf("cleared reminder should reappear in default browse")
	}
}

// --- list ---

func TestListCaptures_IsolatedByUser(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	createCapture(t, srv, tokenA, nil)
	createCapture(t, srv, tokenB, nil)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures", tokenA, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var captures []any
	decodeBody(t, resp, &captures)

	if len(captures) != 1 {
		t.Fatalf("expected 1 capture, got %d", len(captures))
	}
}

func TestListCaptures_FilterByClassifiedAs(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	createCapture(t, srv, token, map[string]any{"classifiedAs": "idea"})
	createCapture(t, srv, token, map[string]any{"classifiedAs": "task"})

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures?classifiedAs=idea", token, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var captures []struct {
		ClassifiedAs string `json:"classifiedAs"`
	}
	decodeBody(t, resp, &captures)

	if len(captures) != 1 {
		t.Fatalf("expected 1 idea capture, got %d", len(captures))
	}
	if captures[0].ClassifiedAs != "idea" {
		t.Fatalf("expected classifiedAs 'idea', got %q", captures[0].ClassifiedAs)
	}
}

func TestListCaptures_IncludeReminded(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	createCapture(t, srv, token, map[string]any{"rawText": "plain note"})
	future := time.Now().Add(time.Hour).UTC().Format(time.RFC3339)
	createCapture(t, srv, token, map[string]any{"rawText": "buy milk later", "remindAt": future})

	// Default browse hides the not-yet-due reminder.
	def := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures", token, nil)
	if def.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", def.StatusCode)
	}
	var defItems []map[string]any
	decodeBody(t, def, &defItems)
	if len(defItems) != 1 {
		t.Fatalf("default browse should hide the future reminder, got %d", len(defItems))
	}

	// includeReminded=true must reach the query so the management view can surface
	// and edit/clear the reminder (regression guard for the unplumbed handler param).
	all := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures?includeReminded=true", token, nil)
	if all.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", all.StatusCode)
	}
	var allItems []map[string]any
	decodeBody(t, all, &allItems)
	if len(allItems) != 2 {
		t.Fatalf("includeReminded should surface the future reminder, got %d", len(allItems))
	}
}

func TestListCapturePage_IncludeReminded(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	createCapture(t, srv, token, map[string]any{"rawText": "plain note"})
	future := time.Now().Add(time.Hour).UTC().Format(time.RFC3339)
	createCapture(t, srv, token, map[string]any{"rawText": "buy milk later", "remindAt": future})

	page := func(query string) int {
		resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/page"+query, token, nil)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("expected 200, got %d", resp.StatusCode)
		}
		var body struct {
			Items []map[string]any `json:"items"`
		}
		decodeBody(t, resp, &body)
		return len(body.Items)
	}

	if n := page(""); n != 1 {
		t.Fatalf("default page should hide the future reminder, got %d", n)
	}
	if n := page("?includeReminded=true"); n != 2 {
		t.Fatalf("includeReminded page should surface the future reminder, got %d", n)
	}
}

func TestListCapturePage_UsesStableCursor(t *testing.T) {
	srv, pool := newServer(t)
	userID, token := createTestUser(t, pool)
	uid := uuid.MustParse(userID)
	createdAt := time.Date(2026, time.June, 6, 12, 0, 0, 0, time.UTC)
	ids := []uuid.UUID{uuid.New(), uuid.New(), uuid.New()}
	for _, id := range ids {
		_, err := pool.Exec(context.Background(), `
			INSERT INTO captures (id, user_id, raw_text, media_type, classified_as, source, created_at)
			VALUES ($1, $2, $3, 'text', 'unclassified', 'web', $4)`,
			id, uid, id.String(), createdAt,
		)
		if err != nil {
			t.Fatalf("insert capture: %v", err)
		}
	}

	firstResp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/page?limit=2", token, nil)
	if firstResp.StatusCode != http.StatusOK {
		t.Fatalf("expected first page 200, got %d", firstResp.StatusCode)
	}
	var first struct {
		Items []struct {
			ID string `json:"id"`
		} `json:"items"`
		NextCursor *string `json:"nextCursor"`
	}
	decodeBody(t, firstResp, &first)
	if len(first.Items) != 2 || first.NextCursor == nil {
		t.Fatalf("unexpected first page: items=%d cursor=%v", len(first.Items), first.NextCursor)
	}

	secondURL := srv.URL + "/captures/page?limit=2&cursor=" + url.QueryEscape(*first.NextCursor)
	secondResp := do(t, srv.Client(), http.MethodGet, secondURL, token, nil)
	if secondResp.StatusCode != http.StatusOK {
		t.Fatalf("expected second page 200, got %d", secondResp.StatusCode)
	}
	var second struct {
		Items []struct {
			ID string `json:"id"`
		} `json:"items"`
		NextCursor *string `json:"nextCursor"`
	}
	decodeBody(t, secondResp, &second)
	if len(second.Items) != 1 || second.NextCursor != nil {
		t.Fatalf("unexpected second page: items=%d cursor=%v", len(second.Items), second.NextCursor)
	}

	seen := map[string]bool{}
	for _, item := range append(first.Items, second.Items...) {
		if seen[item.ID] {
			t.Fatalf("duplicate capture %s across pages", item.ID)
		}
		seen[item.ID] = true
	}
	if len(seen) != 3 {
		t.Fatalf("expected all 3 captures, got %d", len(seen))
	}
}

func TestListCapturePage_InvalidCursor(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/page?cursor=not-a-cursor", token, nil)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("expected 422, got %d", resp.StatusCode)
	}
}

func TestCaptureContext_ReturnsWindowInChronologicalOrder(t *testing.T) {
	srv, pool := newServer(t)
	userID, token := createTestUser(t, pool)
	uid := uuid.MustParse(userID)
	ids := make([]uuid.UUID, 7)
	for i := range ids {
		ids[i] = uuid.New()
		_, err := pool.Exec(context.Background(), `
			INSERT INTO captures (id, user_id, raw_text, media_type, classified_as, source, created_at)
			VALUES ($1, $2, $3, 'text', 'unclassified', 'web', $4)`,
			ids[i], uid, fmt.Sprintf("capture-%d", i),
			time.Date(2026, time.June, 6, 12, i, 0, 0, time.UTC),
		)
		if err != nil {
			t.Fatalf("insert capture: %v", err)
		}
	}

	contextURL := fmt.Sprintf("%s/captures/context?anchorId=%s&before=2&after=2", srv.URL, ids[3])
	resp := do(t, srv.Client(), http.MethodGet, contextURL, token, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var body struct {
		Items []struct {
			ID string `json:"id"`
		} `json:"items"`
		AnchorIndex int  `json:"anchorIndex"`
		HasEarlier  bool `json:"hasEarlier"`
		HasLater    bool `json:"hasLater"`
	}
	decodeBody(t, resp, &body)
	if len(body.Items) != 5 || body.AnchorIndex != 2 || !body.HasEarlier || !body.HasLater {
		t.Fatalf("unexpected context metadata: %+v", body)
	}
	for i, expected := range ids[1:6] {
		if body.Items[i].ID != expected.String() {
			t.Fatalf("item %d: expected %s, got %s", i, expected, body.Items[i].ID)
		}
	}
}

func TestCaptureContext_DoesNotExposeAnotherUsersAnchor(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)
	id := createCapture(t, srv, tokenA, nil)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/context?anchorId="+id, tokenB, nil)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

// --- update ---

func TestUpdateCapture_Reclassify(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	id := createCapture(t, srv, token, map[string]any{"classifiedAs": "unclassified"})

	newClass := "task"
	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/captures/"+id, token, map[string]*string{
		"classifiedAs": &newClass,
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}

	var body struct {
		ClassifiedAs string `json:"classifiedAs"`
	}
	decodeBody(t, resp, &body)

	if body.ClassifiedAs != "task" {
		t.Fatalf("expected 'task', got %q", body.ClassifiedAs)
	}
}

func TestUpdateCapture_NotOwned(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	id := createCapture(t, srv, tokenA, nil)

	newClass := "task"
	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/captures/"+id, tokenB, map[string]*string{
		"classifiedAs": &newClass,
	})
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

// --- get one ---

func TestGetCapture(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)

	id := createCapture(t, srv, tokenA, map[string]any{"rawText": "find me by id"})

	// Owner gets the capture, content intact.
	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/"+id, tokenA, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("get own capture: expected 200, got %d", resp.StatusCode)
	}
	var body struct {
		ID      string  `json:"id"`
		RawText *string `json:"rawText"`
	}
	decodeBody(t, resp, &body)
	if body.ID != id || body.RawText == nil || *body.RawText != "find me by id" {
		t.Fatalf("get own capture: unexpected body %+v", body)
	}

	// Another user cannot read it (scoped to owner, so a 404 not a leak).
	other := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/"+id, tokenB, nil)
	other.Body.Close()
	if other.StatusCode != http.StatusNotFound {
		t.Fatalf("get another user's capture: expected 404, got %d", other.StatusCode)
	}

	// Unknown id is a 404.
	missing := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/"+uuid.New().String(), tokenA, nil)
	missing.Body.Close()
	if missing.StatusCode != http.StatusNotFound {
		t.Fatalf("get missing capture: expected 404, got %d", missing.StatusCode)
	}

	// A soft-deleted capture is a 404 (GetCapture excludes deleted_at rows).
	del := do(t, srv.Client(), http.MethodDelete, srv.URL+"/captures/"+id, tokenA, nil)
	del.Body.Close()
	deleted := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/"+id, tokenA, nil)
	deleted.Body.Close()
	if deleted.StatusCode != http.StatusNotFound {
		t.Fatalf("get soft-deleted capture: expected 404, got %d", deleted.StatusCode)
	}
}

// --- delete ---

func TestDeleteCapture_HappyPath(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	id := createCapture(t, srv, token, nil)

	delResp := do(t, srv.Client(), http.MethodDelete, srv.URL+"/captures/"+id, token, nil)
	delResp.Body.Close()

	if delResp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", delResp.StatusCode)
	}

	listResp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures", token, nil)
	var items []any
	decodeBody(t, listResp, &items)
	if len(items) != 0 {
		t.Fatalf("expected empty list after delete, got %d items", len(items))
	}
}

// --- external attachments ---

func TestCaptureAttachments_AddListDelete(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)
	id := createCapture(t, srv, token, nil)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+id+"/attachments", token, map[string]any{
		"provider":       "google_drive",
		"providerFileId": "drive-file-123",
		"name":           "receipt.pdf",
		"mimeType":       "application/pdf",
		"sizeBytes":      2048,
		"webUrl":         "https://drive.google.com/file/d/drive-file-123/view",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("add attachment: expected 200, got %d", resp.StatusCode)
	}
	var created struct {
		ID             string `json:"id"`
		CaptureID      string `json:"captureId"`
		Provider       string `json:"provider"`
		ProviderFileID string `json:"providerFileId"`
		Name           string `json:"name"`
		MimeType       string `json:"mimeType"`
		SizeBytes      int64  `json:"sizeBytes"`
		WebURL         string `json:"webUrl"`
	}
	decodeBody(t, resp, &created)
	if created.ID == "" || created.CaptureID != id {
		t.Fatalf("unexpected attachment identity: %+v", created)
	}
	if created.Provider != "google_drive" || created.ProviderFileID != "drive-file-123" {
		t.Fatalf("unexpected provider fields: %+v", created)
	}
	if created.Name != "receipt.pdf" || created.MimeType != "application/pdf" || created.SizeBytes != 2048 {
		t.Fatalf("unexpected display fields: %+v", created)
	}

	list := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/"+id+"/attachments", token, nil)
	if list.StatusCode != http.StatusOK {
		t.Fatalf("list attachments: expected 200, got %d", list.StatusCode)
	}
	var items []struct {
		ID string `json:"id"`
	}
	decodeBody(t, list, &items)
	if len(items) != 1 || items[0].ID != created.ID {
		t.Fatalf("expected listed attachment %s, got %+v", created.ID, items)
	}

	del := do(t, srv.Client(), http.MethodDelete, srv.URL+"/captures/"+id+"/attachments/"+created.ID, token, nil)
	del.Body.Close()
	if del.StatusCode != http.StatusNoContent {
		t.Fatalf("delete attachment: expected 204, got %d", del.StatusCode)
	}

	list = do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/"+id+"/attachments", token, nil)
	var after []any
	decodeBody(t, list, &after)
	if len(after) != 0 {
		t.Fatalf("expected no live attachments after delete, got %d", len(after))
	}
}

func TestCaptureAttachments_ValidationAndDuplicate(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)
	id := createCapture(t, srv, token, nil)
	base := map[string]any{
		"provider":       "dropbox",
		"providerFileId": "dropbox-file-123",
		"name":           "contract.txt",
		"webUrl":         "https://dropbox.com/s/dropbox-file-123/contract.txt",
	}

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+id+"/attachments", token, base)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("first add: expected 200, got %d", resp.StatusCode)
	}
	dup := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+id+"/attachments", token, base)
	dup.Body.Close()
	if dup.StatusCode != http.StatusConflict {
		t.Fatalf("duplicate add: expected 409, got %d", dup.StatusCode)
	}

	for _, test := range []struct {
		name string
		body map[string]any
	}{
		{
			name: "bad provider",
			body: map[string]any{
				"provider":       "icloud_drive",
				"providerFileId": "file-1",
				"name":           "x.txt",
				"webUrl":         "https://example.test/x.txt",
			},
		},
		{
			name: "bad url scheme",
			body: map[string]any{
				"provider":       "onedrive",
				"providerFileId": "file-1",
				"name":           "x.txt",
				"webUrl":         "file:///tmp/x.txt",
			},
		},
		{
			name: "negative size",
			body: map[string]any{
				"provider":       "onedrive",
				"providerFileId": "file-1",
				"name":           "x.txt",
				"sizeBytes":      -1,
				"webUrl":         "https://example.test/x.txt",
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+id+"/attachments", token, test.body)
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusUnprocessableEntity {
				t.Fatalf("expected 422, got %d", resp.StatusCode)
			}
		})
	}
}

func TestCaptureAttachments_NotOwnedOrMissing(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)
	id := createCapture(t, srv, tokenA, nil)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/"+id+"/attachments", tokenB, nil)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("another user's attachments: expected 404, got %d", resp.StatusCode)
	}

	missing := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/"+uuid.New().String()+"/attachments", tokenA, nil)
	defer missing.Body.Close()
	if missing.StatusCode != http.StatusNotFound {
		t.Fatalf("missing capture attachments: expected 404, got %d", missing.StatusCode)
	}
}

// --- related captures (links + suggestions) ---

func TestCaptureLinks_AddListRemoveBothDirections(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)
	a := createCapture(t, srv, token, map[string]any{"rawText": "capture A"})
	b := createCapture(t, srv, token, map[string]any{"rawText": "capture B"})

	// Link A → B.
	add := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+a+"/links", token, map[string]any{"targetId": b})
	add.Body.Close()
	if add.StatusCode != http.StatusNoContent {
		t.Fatalf("add link: expected 204, got %d", add.StatusCode)
	}

	// Undirected: B's links must include A, and A's links must include B.
	linksOf := func(id string) []string {
		resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/"+id+"/links", token, nil)
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("list links: expected 200, got %d", resp.StatusCode)
		}
		var items []struct {
			ID string `json:"id"`
		}
		decodeBody(t, resp, &items)
		out := make([]string, len(items))
		for i, it := range items {
			out[i] = it.ID
		}
		return out
	}
	if got := linksOf(a); len(got) != 1 || got[0] != b {
		t.Fatalf("A links: expected [%s], got %v", b, got)
	}
	if got := linksOf(b); len(got) != 1 || got[0] != a {
		t.Fatalf("B links: expected [%s], got %v", a, got)
	}

	// Remove from the opposite direction (B → A) — same undirected edge.
	del := do(t, srv.Client(), http.MethodDelete, srv.URL+"/captures/"+b+"/links/"+a, token, nil)
	del.Body.Close()
	if del.StatusCode != http.StatusNoContent {
		t.Fatalf("remove link: expected 204, got %d", del.StatusCode)
	}
	if got := linksOf(a); len(got) != 0 {
		t.Fatalf("A links after remove: expected none, got %v", got)
	}
}

func TestCaptureLink_Idempotent(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)
	a := createCapture(t, srv, token, map[string]any{"rawText": "A"})
	b := createCapture(t, srv, token, map[string]any{"rawText": "B"})

	for i := 0; i < 2; i++ {
		resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+a+"/links", token, map[string]any{"targetId": b})
		resp.Body.Close()
		if resp.StatusCode != http.StatusNoContent {
			t.Fatalf("add link #%d: expected 204, got %d", i, resp.StatusCode)
		}
	}
	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/"+a+"/links", token, nil)
	var items []any
	decodeBody(t, resp, &items)
	if len(items) != 1 {
		t.Fatalf("expected a single link after duplicate adds, got %d", len(items))
	}
}

func TestCaptureLink_SelfLinkRejected(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)
	a := createCapture(t, srv, token, nil)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+a+"/links", token, map[string]any{"targetId": a})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("self-link: expected 422, got %d", resp.StatusCode)
	}
}

func TestCaptureLink_TargetNotOwned(t *testing.T) {
	srv, pool := newServer(t)
	_, tokenA := createTestUser(t, pool)
	_, tokenB := createTestUser(t, pool)
	a := createCapture(t, srv, tokenA, nil)
	other := createCapture(t, srv, tokenB, nil)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+a+"/links", tokenA, map[string]any{"targetId": other})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("link to another user's capture: expected 404, got %d", resp.StatusCode)
	}
}

func TestRelated_DegradesWhenRagDisabled(t *testing.T) {
	srv, pool := newServer(t) // newServer wires a disabled rag client (ragclient.New(""))
	_, token := createTestUser(t, pool)
	a := createCapture(t, srv, token, nil)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/"+a+"/related", token, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("related (rag disabled): expected 200, got %d", resp.StatusCode)
	}
	var items []any
	decodeBody(t, resp, &items)
	if len(items) != 0 {
		t.Fatalf("related (rag disabled): expected empty list, got %d", len(items))
	}
}

func TestRelated_NotFound(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/"+uuid.New().String()+"/related", token, nil)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("related for missing capture: expected 404, got %d", resp.StatusCode)
	}
}

// --- trash (list + restore) ---

func TestTrash_DeleteListRestore(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)
	id := createCapture(t, srv, token, map[string]any{"rawText": "recover me"})

	del := do(t, srv.Client(), http.MethodDelete, srv.URL+"/captures/"+id, token, nil)
	del.Body.Close()
	if del.StatusCode != http.StatusNoContent {
		t.Fatalf("delete: expected 204, got %d", del.StatusCode)
	}

	// Trash lists the deleted capture; the live feed does not.
	trash := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/trash", token, nil)
	var trashed []struct {
		ID string `json:"id"`
	}
	decodeBody(t, trash, &trashed)
	if len(trashed) != 1 || trashed[0].ID != id {
		t.Fatalf("trash should list the deleted capture, got %v", trashed)
	}

	// Restore returns it to the live feed and clears it from trash.
	restore := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+id+"/restore", token, nil)
	if restore.StatusCode != http.StatusOK {
		t.Fatalf("restore: expected 200, got %d", restore.StatusCode)
	}
	restore.Body.Close()

	live := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures", token, nil)
	var liveItems []any
	decodeBody(t, live, &liveItems)
	if len(liveItems) != 1 {
		t.Fatalf("restored capture should be back in the live feed, got %d", len(liveItems))
	}
	trash2 := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures/trash", token, nil)
	var trashed2 []any
	decodeBody(t, trash2, &trashed2)
	if len(trashed2) != 0 {
		t.Fatalf("trash should be empty after restore, got %d", len(trashed2))
	}
}

func TestRestore_LiveCaptureNotFound(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)
	id := createCapture(t, srv, token, nil) // never deleted

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+id+"/restore", token, nil)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("restore of a live capture: expected 404, got %d", resp.StatusCode)
	}
}

// --- auth ---

func TestCaptures_Unauthenticated(t *testing.T) {
	srv, _ := newServer(t)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures", "", nil)
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}
