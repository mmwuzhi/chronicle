package capture_test

import (
	"context"
	"fmt"
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

// insertCaptureAt inserts a text capture with an explicit created_at expression
// (e.g. "now() - interval '1 year'") and returns its id.
func insertCaptureAt(t *testing.T, pool *pgxpool.Pool, userID, text, createdExpr string) string {
	t.Helper()
	id := uuid.New()
	sql := fmt.Sprintf(`INSERT INTO captures (id, user_id, raw_text, media_type, source, created_at)
		VALUES ($1, $2, $3, 'text', 'web', %s)`, createdExpr)
	if _, err := pool.Exec(context.Background(), sql, id, userID, text); err != nil {
		t.Fatalf("insert capture at %s: %v", createdExpr, err)
	}
	return id.String()
}

func TestReviewToday(t *testing.T) {
	srv, pool := newServer(t)
	userID, token := createTestUser(t, pool)

	yearAgo := insertCaptureAt(t, pool, userID, "one year ago today", "now() - interval '1 year'")
	today := insertCaptureAt(t, pool, userID, "captured today", "now()")
	monthAgo := insertCaptureAt(t, pool, userID, "thirty days ago", "now() - interval '30 days'")
	twoDaysAgo := insertCaptureAt(t, pool, userID, "two days ago", "now() - interval '2 days'")

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/review/today", token, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var body struct {
		OnThisDay  []struct{ ID string } `json:"onThisDay"`
		Rediscover []struct{ ID string } `json:"rediscover"`
	}
	decodeBody(t, resp, &body)

	onIDs := idsOf(body.OnThisDay)
	reIDs := idsOf(body.Rediscover)

	// On this day: the year-ago capture, but never today's or a different-day one.
	if !slices.Contains(onIDs, yearAgo) {
		t.Errorf("onThisDay should contain the one-year-ago capture; got %v", onIDs)
	}
	for _, bad := range []string{today, monthAgo, twoDaysAgo} {
		if slices.Contains(onIDs, bad) {
			t.Errorf("onThisDay should not contain %s; got %v", bad, onIDs)
		}
	}

	// Rediscover: older-than-a-week captures, excluding today's and recent ones.
	// The only rows older than 7 days are yearAgo and monthAgo; yearAgo is already
	// in onThisDay, so dedup leaves exactly monthAgo.
	if !slices.Contains(reIDs, monthAgo) {
		t.Errorf("rediscover should contain the 30-day-old capture; got %v", reIDs)
	}
	for _, bad := range []string{today, twoDaysAgo} {
		if slices.Contains(reIDs, bad) {
			t.Errorf("rediscover should exclude captures newer than 7 days (%s); got %v", bad, reIDs)
		}
	}

	// Dedup invariant: no capture appears in both buckets.
	for _, id := range onIDs {
		if slices.Contains(reIDs, id) {
			t.Errorf("capture %s appears in both onThisDay and rediscover", id)
		}
	}
}

func TestReviewTodayUsesTimezoneOffset(t *testing.T) {
	srv, pool := newServer(t)
	userID, token := createTestUser(t, pool)

	// A capture from today in Japan, one year ago, deliberately placed at a local
	// clock time whose UTC date is not today's UTC date. Review should care about
	// the caller's local calendar day, not the server's UTC day.
	jstOffset := -540 // JavaScript getTimezoneOffset for UTC+09:00.
	localClock := "interval '30 minutes'"
	if time.Now().UTC().Hour() >= 15 {
		localClock = "interval '12 hours'"
	}
	jstExpr := fmt.Sprintf("date_trunc('day', now() - make_interval(mins => -540)) + %s + make_interval(mins => -540) - interval '1 year'", localClock)
	jstToday := insertCaptureAt(t, pool, userID, "local today in Japan", jstExpr)

	resp := do(t, srv.Client(), http.MethodGet,
		fmt.Sprintf("%s/review/today?timezoneOffsetMinutes=%d", srv.URL, jstOffset),
		token, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 for JST review, got %d", resp.StatusCode)
	}
	var body struct {
		OnThisDay []struct{ ID string } `json:"onThisDay"`
	}
	decodeBody(t, resp, &body)
	if !slices.Contains(idsOf(body.OnThisDay), jstToday) {
		t.Fatalf("JST onThisDay should contain local-today capture; got %v", idsOf(body.OnThisDay))
	}

	resp = do(t, srv.Client(), http.MethodGet, srv.URL+"/review/today", token, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 for default UTC review, got %d", resp.StatusCode)
	}
	body.OnThisDay = nil
	decodeBody(t, resp, &body)
	if slices.Contains(idsOf(body.OnThisDay), jstToday) {
		t.Fatalf("default UTC onThisDay should not contain the JST-only local-today capture; got %v", idsOf(body.OnThisDay))
	}
}

func TestReviewTodayEmpty(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)

	resp := do(t, srv.Client(), http.MethodGet, srv.URL+"/review/today", token, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
	var body struct {
		OnThisDay  []struct{ ID string } `json:"onThisDay"`
		Rediscover []struct{ ID string } `json:"rediscover"`
	}
	decodeBody(t, resp, &body)
	if len(body.OnThisDay) != 0 || len(body.Rediscover) != 0 {
		t.Errorf("expected empty buckets for a new user, got on=%d re=%d",
			len(body.OnThisDay), len(body.Rediscover))
	}
}

func idsOf(rows []struct{ ID string }) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = r.ID
	}
	return out
}
