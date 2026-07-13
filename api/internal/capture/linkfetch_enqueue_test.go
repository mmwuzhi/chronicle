package capture_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
)

// readLinkState reads the columns the link-fetch pipeline drives for one capture.
func readLinkState(t *testing.T, pool *pgxpool.Pool, id string) (status string, linkURL, transcript *string) {
	t.Helper()
	row := pool.QueryRow(context.Background(),
		"SELECT transcription_status::text, link_url, transcript FROM captures WHERE id = $1", id)
	if err := row.Scan(&status, &linkURL, &transcript); err != nil {
		t.Fatalf("read link state: %v", err)
	}
	return status, linkURL, transcript
}

// markEnriched sets the precondition of an already-link-enriched capture:
// completed status with the fetched URL and page text stored in transcript.
func markEnriched(t *testing.T, pool *pgxpool.Pool, id, url, transcript string) {
	t.Helper()
	if _, err := pool.Exec(context.Background(), `
		UPDATE captures
		SET link_url = $2, transcript = $3, transcription_status = 'completed',
		    transcription_model = 'link-fetch', transcribed_at = now()
		WHERE id = $1`, id, url, transcript); err != nil {
		t.Fatalf("mark enriched: %v", err)
	}
}

func TestCreateEnqueuesLinkFetch(t *testing.T) {
	srv, pool := newServerOpts(t, true)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", token, map[string]any{
		"mediaType": "text",
		"rawText":   "read later https://example.com/great-article thanks",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var out struct {
		ID                  string  `json:"id"`
		Transcript          *string `json:"transcript"`
		TranscriptionStatus string  `json:"transcriptionStatus"`
	}
	decodeBody(t, resp, &out)
	if out.TranscriptionStatus != "pending" || out.Transcript != nil {
		t.Fatalf("create response must reflect enqueued state: status=%q transcript=%v", out.TranscriptionStatus, out.Transcript)
	}

	status, linkURL, _ := readLinkState(t, pool, out.ID)
	if status != "pending" {
		t.Errorf("transcription_status = %q, want pending", status)
	}
	if linkURL == nil || *linkURL != "https://example.com/great-article" {
		t.Errorf("link_url = %v, want https://example.com/great-article", linkURL)
	}
}

func TestCreateNoURLDoesNotEnqueue(t *testing.T) {
	srv, pool := newServerOpts(t, true)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", token, map[string]any{
		"mediaType": "text",
		"rawText":   "just a plain thought, no link",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var out struct {
		ID string `json:"id"`
	}
	decodeBody(t, resp, &out)

	status, linkURL, _ := readLinkState(t, pool, out.ID)
	if status != "none" {
		t.Errorf("transcription_status = %q, want none", status)
	}
	if linkURL != nil {
		t.Errorf("link_url = %v, want nil", linkURL)
	}
}

func TestLinkFetchDisabledDoesNotEnqueue(t *testing.T) {
	srv, pool := newServer(t) // link fetch off
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures", token, map[string]any{
		"mediaType": "text",
		"rawText":   "https://example.com/should-not-enqueue",
	})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var out struct {
		ID string `json:"id"`
	}
	decodeBody(t, resp, &out)

	status, linkURL, _ := readLinkState(t, pool, out.ID)
	if status != "none" {
		t.Errorf("transcription_status = %q, want none (feature disabled)", status)
	}
	if linkURL != nil {
		t.Errorf("link_url = %v, want nil (feature disabled)", linkURL)
	}
}

// The two workers share the transcription_status column but must never claim
// each other's rows: link jobs (media_key IS NULL) vs media jobs (media_key set).
func TestLinkFetchQueuePartition(t *testing.T) {
	_, pool := newServer(t)
	userID, _ := createTestUser(t, pool)
	ctx := context.Background()
	queries := db.New(pool)

	linkID := uuid.New()
	if _, err := pool.Exec(ctx, `
		INSERT INTO captures (id, user_id, raw_text, media_type, source,
			link_url, transcription_status, next_transcription_at)
		VALUES ($1, $2, 'read https://example.com', 'text', 'web',
			'https://example.com', 'pending', now())`,
		linkID, userID); err != nil {
		t.Fatalf("insert link job: %v", err)
	}

	mediaID := uuid.New()
	if _, err := pool.Exec(ctx, `
		INSERT INTO captures (id, user_id, media_type, source, media_url, media_key,
			audio_duration_sec, transcription_status, next_transcription_at)
		VALUES ($1, $2, 'audio', 'web', 'https://example.test/a.webm',
			'captures/a.webm', 60, 'pending', now())`,
		mediaID, userID); err != nil {
		t.Fatalf("insert media job: %v", err)
	}

	link, err := queries.ClaimPendingLinkFetch(ctx)
	if err != nil {
		t.Fatalf("ClaimPendingLinkFetch: %v", err)
	}
	if link.ID != linkID {
		t.Errorf("link claim got %s, want the link job %s", link.ID, linkID)
	}

	media, err := queries.ClaimPendingTranscription(ctx)
	if err != nil {
		t.Fatalf("ClaimPendingTranscription: %v", err)
	}
	if media.ID != mediaID {
		t.Errorf("transcription claim got %s, want the media job %s", media.ID, mediaID)
	}

	// Reset the link job to claimable and confirm the transcription worker still
	// won't take it (media_key IS NULL), even with no media job left to claim.
	if _, err := pool.Exec(ctx,
		"UPDATE captures SET transcription_status='pending', next_transcription_at=now() WHERE id=$1",
		linkID); err != nil {
		t.Fatalf("reset link job: %v", err)
	}
	if _, err := queries.ClaimPendingTranscription(ctx); !errors.Is(err, pgx.ErrNoRows) {
		t.Errorf("transcription claim should find no media job, got err=%v", err)
	}
}

// patchRawText edits a capture's text and asserts a 200.
func patchRawText(t *testing.T, srv *httptest.Server, token, id, text string) {
	t.Helper()
	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/captures/"+id, token,
		map[string]any{"rawText": text})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("patch rawText: got %d", resp.StatusCode)
	}
}

func TestUpdateAddsLinkFetch(t *testing.T) {
	srv, pool := newServerOpts(t, true)
	_, token := createTestUser(t, pool)
	id := createCapture(t, srv, token, map[string]any{"rawText": "a plain note"})

	if status, linkURL, _ := readLinkState(t, pool, id); status != "none" || linkURL != nil {
		t.Fatalf("precondition: status=%q linkURL=%v, want none/nil", status, linkURL)
	}

	patchRawText(t, srv, token, id, "a plain note now with https://example.com/added")

	status, linkURL, _ := readLinkState(t, pool, id)
	if status != "pending" {
		t.Errorf("status = %q, want pending (enqueued on edit)", status)
	}
	if linkURL == nil || *linkURL != "https://example.com/added" {
		t.Errorf("link_url = %v, want https://example.com/added", linkURL)
	}
}

func TestUpdateChangesLinkURL(t *testing.T) {
	srv, pool := newServerOpts(t, true)
	_, token := createTestUser(t, pool)
	id := createCapture(t, srv, token, map[string]any{"rawText": "see https://old.example.com/a"})
	markEnriched(t, pool, id, "https://old.example.com/a", "old page text")

	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/captures/"+id, token,
		map[string]any{"rawText": "see https://new.example.com/b instead"})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("patch rawText: got %d", resp.StatusCode)
	}
	var updated struct {
		Transcript          *string `json:"transcript"`
		TranscriptionStatus string  `json:"transcriptionStatus"`
	}
	decodeBody(t, resp, &updated)
	if updated.TranscriptionStatus != "pending" || updated.Transcript != nil {
		t.Fatalf("update response must reflect replacement queue: status=%q transcript=%v", updated.TranscriptionStatus, updated.Transcript)
	}

	status, linkURL, transcript := readLinkState(t, pool, id)
	if status != "pending" {
		t.Errorf("status = %q, want pending (re-enqueued for the new URL)", status)
	}
	if linkURL == nil || *linkURL != "https://new.example.com/b" {
		t.Errorf("link_url = %v, want https://new.example.com/b", linkURL)
	}
	if transcript != nil {
		t.Errorf("transcript = %v, want nil so old page text stops matching search", transcript)
	}
}

// The idempotency guard: editing words around an unchanged URL must not reset an
// already-enriched capture to pending or discard its fetched transcript.
func TestUpdateSameURLNoRefetch(t *testing.T) {
	srv, pool := newServerOpts(t, true)
	_, token := createTestUser(t, pool)
	id := createCapture(t, srv, token, map[string]any{"rawText": "read https://example.com/x now"})
	markEnriched(t, pool, id, "https://example.com/x", "fetched body text")

	patchRawText(t, srv, token, id, "later: read https://example.com/x now please")

	status, linkURL, transcript := readLinkState(t, pool, id)
	if status != "completed" {
		t.Errorf("status = %q, want completed (no re-fetch on unchanged URL)", status)
	}
	if transcript == nil || *transcript != "fetched body text" {
		t.Errorf("transcript = %v, want it preserved", transcript)
	}
	if linkURL == nil || *linkURL != "https://example.com/x" {
		t.Errorf("link_url = %v, want unchanged", linkURL)
	}
}

func TestUpdateRemovesURL(t *testing.T) {
	srv, pool := newServerOpts(t, true)
	_, token := createTestUser(t, pool)
	id := createCapture(t, srv, token, map[string]any{"rawText": "read https://example.com/gone"})
	markEnriched(t, pool, id, "https://example.com/gone", "gone page text")

	resp := do(t, srv.Client(), http.MethodPatch, srv.URL+"/captures/"+id, token,
		map[string]any{"rawText": "read nothing now"})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("patch rawText: got %d", resp.StatusCode)
	}
	var updated struct {
		Transcript          *string `json:"transcript"`
		TranscriptionStatus string  `json:"transcriptionStatus"`
	}
	decodeBody(t, resp, &updated)
	if updated.TranscriptionStatus != "none" || updated.Transcript != nil {
		t.Fatalf("update response must reflect cleared link state: status=%q transcript=%v", updated.TranscriptionStatus, updated.Transcript)
	}

	status, linkURL, transcript := readLinkState(t, pool, id)
	if status != "none" {
		t.Errorf("status = %q, want none (link enrichment cleared)", status)
	}
	if linkURL != nil {
		t.Errorf("link_url = %v, want nil", linkURL)
	}
	if transcript != nil {
		t.Errorf("transcript = %v, want nil (stale page text dropped)", transcript)
	}
}

func TestStaleLinkFetchCannotOverwriteReplacementURL(t *testing.T) {
	srv, pool := newServerOpts(t, true)
	_, token := createTestUser(t, pool)
	queries := db.New(pool)
	ctx := context.Background()
	oldURL := "https://old.example.com/a"
	newURL := "https://new.example.com/b"
	id := createCapture(t, srv, token, map[string]any{"rawText": "see " + oldURL})
	captureID := uuid.MustParse(id)

	claimed, err := queries.ClaimPendingLinkFetch(ctx)
	if err != nil || claimed.ID != captureID {
		t.Fatalf("claim old URL: capture=%s err=%v", claimed.ID, err)
	}
	if n, err := queries.PrepareCaptureLinkFetch(ctx, db.PrepareCaptureLinkFetchParams{
		ID: captureID, LinkUrl: oldURL,
	}); err != nil || n != 1 {
		t.Fatalf("prepare old URL: rows=%d err=%v", n, err)
	}

	// While A is in flight, the user changes the authoritative text to B.
	patchRawText(t, srv, token, id, "see "+newURL)

	// Every possible terminal path from A must become a stale no-op.
	if n, err := queries.CompleteCaptureLinkFetch(ctx, db.CompleteCaptureLinkFetchParams{
		ID:                 captureID,
		Transcript:         pgtype.Text{String: "old page", Valid: true},
		LinkUrl:            pgtype.Text{String: oldURL, Valid: true},
		TranscriptionModel: pgtype.Text{String: "link-fetch", Valid: true},
	}); err != nil || n != 0 {
		t.Fatalf("stale complete: rows=%d err=%v", n, err)
	}
	if n, err := queries.FailCaptureLinkFetch(ctx, db.FailCaptureLinkFetchParams{
		ID: captureID, LinkUrl: oldURL,
	}); err != nil || n != 0 {
		t.Fatalf("stale fail: rows=%d err=%v", n, err)
	}
	if n, err := queries.SkipCaptureLinkFetch(ctx, db.SkipCaptureLinkFetchParams{
		ID: captureID, LinkUrl: oldURL,
	}); err != nil || n != 0 {
		t.Fatalf("stale skip: rows=%d err=%v", n, err)
	}

	status, linkURL, transcript := readLinkState(t, pool, id)
	if status != "pending" || linkURL == nil || *linkURL != newURL || transcript != nil {
		t.Fatalf("replacement state changed: status=%q linkURL=%v transcript=%v", status, linkURL, transcript)
	}
}

func TestStaleLinkFetchCannotRestoreRemovedURL(t *testing.T) {
	srv, pool := newServerOpts(t, true)
	_, token := createTestUser(t, pool)
	queries := db.New(pool)
	ctx := context.Background()
	oldURL := "https://old.example.com/a"
	id := createCapture(t, srv, token, map[string]any{"rawText": "see " + oldURL})
	captureID := uuid.MustParse(id)

	if _, err := queries.ClaimPendingLinkFetch(ctx); err != nil {
		t.Fatalf("claim old URL: %v", err)
	}
	if n, err := queries.PrepareCaptureLinkFetch(ctx, db.PrepareCaptureLinkFetchParams{
		ID: captureID, LinkUrl: oldURL,
	}); err != nil || n != 1 {
		t.Fatalf("prepare old URL: rows=%d err=%v", n, err)
	}
	patchRawText(t, srv, token, id, "the link was removed")

	if n, err := queries.CompleteCaptureLinkFetch(ctx, db.CompleteCaptureLinkFetchParams{
		ID:                 captureID,
		Transcript:         pgtype.Text{String: "old page", Valid: true},
		LinkUrl:            pgtype.Text{String: oldURL, Valid: true},
		TranscriptionModel: pgtype.Text{String: "link-fetch", Valid: true},
	}); err != nil || n != 0 {
		t.Fatalf("stale complete after removal: rows=%d err=%v", n, err)
	}
	status, linkURL, transcript := readLinkState(t, pool, id)
	if status != "none" || linkURL != nil || transcript != nil {
		t.Fatalf("removed state changed: status=%q linkURL=%v transcript=%v", status, linkURL, transcript)
	}
}
