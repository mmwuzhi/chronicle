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
	"github.com/sikaoshenmi/chronicle/testutil"
)

func newServer(t *testing.T) (*httptest.Server, *pgxpool.Pool) {
	t.Helper()
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "tasks", "projects", "users")

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

	capture.Register(api, pool, authMW)

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

// --- auth ---

func TestCaptures_Unauthenticated(t *testing.T) {
	srv, _ := newServer(t)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/captures", "", nil)
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}
