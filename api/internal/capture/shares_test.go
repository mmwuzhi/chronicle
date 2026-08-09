package capture_test

import (
	"context"
	"net/http"
	"net/url"
	"testing"
)

type captureShareResponse struct {
	ID              string  `json:"id"`
	CaptureID       string  `json:"captureId"`
	SnapshotRawText string  `json:"snapshotRawText"`
	CapturedAt      string  `json:"capturedAt"`
	ExpiresAt       *string `json:"expiresAt"`
	CreatedAt       string  `json:"createdAt"`
	Secret          string  `json:"secret"`
	URL             string  `json:"url"`
}

type publicCaptureShareResponse struct {
	SnapshotRawText string  `json:"snapshotRawText"`
	CapturedAt      string  `json:"capturedAt"`
	ExpiresAt       *string `json:"expiresAt"`
}

type captureSharePageResponse struct {
	Items      []captureShareResponse `json:"items"`
	NextCursor *string                `json:"nextCursor"`
}

func createShare(t *testing.T, serverURL, token, captureID, snapshotRawText, expiresIn string) captureShareResponse {
	t.Helper()
	resp := do(t, http.DefaultClient, http.MethodPost, serverURL+"/captures/"+captureID+"/shares", token, map[string]string{
		"expiresIn":       expiresIn,
		"snapshotRawText": snapshotRawText,
	})
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		t.Fatalf("create share: got %d", resp.StatusCode)
	}
	var share captureShareResponse
	decodeBody(t, resp, &share)
	return share
}

func readPublicShare(t *testing.T, serverURL string, share captureShareResponse) *http.Response {
	t.Helper()
	return doWithHeaders(
		t,
		http.DefaultClient,
		http.MethodGet,
		serverURL+"/public/shares/"+share.ID,
		"",
		nil,
		map[string]string{"Authorization": "Share " + share.Secret},
	)
}

func TestCaptureShare_IsExplicitImmutableAndRevocable(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)
	id := createCapture(t, srv, token, map[string]any{"rawText": "original private text"})

	share := createShare(t, srv.URL, token, id, "owner-approved preview", "7d")
	if share.CaptureID != id || share.SnapshotRawText != "owner-approved preview" || share.Secret == "" {
		t.Fatalf("unexpected share: %+v", share)
	}
	if want := "http://localhost:5173/s/" + share.ID + "#" + share.Secret; share.URL != want {
		t.Fatalf("share URL = %q, want %q", share.URL, want)
	}
	listed := do(t, srv.Client(), http.MethodGet, srv.URL+"/shares?captureId="+id, token, nil)
	var page captureSharePageResponse
	decodeBody(t, listed, &page)
	if len(page.Items) != 1 || page.Items[0].Secret != share.Secret || page.Items[0].URL != share.URL {
		t.Fatalf("owner could not recover the same share URL: %+v", page)
	}

	public := readPublicShare(t, srv.URL, share)
	if public.StatusCode != http.StatusOK {
		public.Body.Close()
		t.Fatalf("read public share: got %d", public.StatusCode)
	}
	var body publicCaptureShareResponse
	decodeBody(t, public, &body)
	if body.SnapshotRawText != "owner-approved preview" || body.CapturedAt == "" || body.ExpiresAt == nil {
		t.Fatalf("unexpected public body: %+v", body)
	}

	updated := do(t, srv.Client(), http.MethodPatch, srv.URL+"/captures/"+id, token, map[string]string{
		"rawText": "later private edit",
	})
	updated.Body.Close()
	if updated.StatusCode != http.StatusOK {
		t.Fatalf("update capture: got %d", updated.StatusCode)
	}
	public = readPublicShare(t, srv.URL, share)
	var unchanged publicCaptureShareResponse
	decodeBody(t, public, &unchanged)
	if unchanged.SnapshotRawText != "owner-approved preview" {
		t.Fatalf("share changed with Capture edit: %q", unchanged.SnapshotRawText)
	}

	revoked := do(t, srv.Client(), http.MethodDelete, srv.URL+"/shares/"+share.ID, token, nil)
	revoked.Body.Close()
	if revoked.StatusCode != http.StatusNoContent {
		t.Fatalf("revoke share: got %d", revoked.StatusCode)
	}
	public = readPublicShare(t, srv.URL, share)
	defer public.Body.Close()
	if public.StatusCode != http.StatusNotFound {
		t.Fatalf("revoked public share: got %d", public.StatusCode)
	}
}

func TestCaptureShare_InvalidSecretAndExpiryAreNotFound(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)
	id := createCapture(t, srv, token, map[string]any{"rawText": "temporary snapshot"})
	share := createShare(t, srv.URL, token, id, "temporary snapshot", "1d")

	wrongSecret := doWithHeaders(
		t,
		srv.Client(),
		http.MethodGet,
		srv.URL+"/public/shares/"+share.ID,
		"",
		nil,
		map[string]string{"Authorization": "Share wrong"},
	)
	wrongSecret.Body.Close()
	if wrongSecret.StatusCode != http.StatusNotFound {
		t.Fatalf("wrong secret: got %d", wrongSecret.StatusCode)
	}

	missingSecret := doWithHeaders(
		t,
		srv.Client(),
		http.MethodGet,
		srv.URL+"/public/shares/"+share.ID,
		"",
		nil,
		nil,
	)
	missingSecret.Body.Close()
	if missingSecret.StatusCode != http.StatusNotFound {
		t.Fatalf("missing secret: got %d", missingSecret.StatusCode)
	}

	invalidID := doWithHeaders(
		t,
		srv.Client(),
		http.MethodGet,
		srv.URL+"/public/shares/not-a-share-id",
		"",
		nil,
		map[string]string{"Authorization": "Share wrong"},
	)
	invalidID.Body.Close()
	if invalidID.StatusCode != http.StatusNotFound {
		t.Fatalf("invalid id: got %d", invalidID.StatusCode)
	}

	if _, err := pool.Exec(context.Background(),
		"UPDATE capture_shares SET expires_at = now() - interval '1 second' WHERE id = $1",
		share.ID,
	); err != nil {
		t.Fatalf("expire share: %v", err)
	}
	expired := readPublicShare(t, srv.URL, share)
	defer expired.Body.Close()
	if expired.StatusCode != http.StatusNotFound {
		t.Fatalf("expired share: got %d", expired.StatusCode)
	}

	listed := do(t, srv.Client(), http.MethodGet, srv.URL+"/shares", token, nil)
	var page captureSharePageResponse
	decodeBody(t, listed, &page)
	if len(page.Items) != 0 {
		t.Fatalf("expired share remained in owner list: %+v", page.Items)
	}
}

func TestCaptureShare_TrashRevokesPermanently(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)
	id := createCapture(t, srv, token, map[string]any{"rawText": "trash-sensitive snapshot"})
	share := createShare(t, srv.URL, token, id, "trash-sensitive snapshot", "never")

	deleted := do(t, srv.Client(), http.MethodDelete, srv.URL+"/captures/"+id, token, nil)
	deleted.Body.Close()
	if deleted.StatusCode != http.StatusNoContent {
		t.Fatalf("delete capture: got %d", deleted.StatusCode)
	}
	restored := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+id+"/restore", token, nil)
	restored.Body.Close()
	if restored.StatusCode != http.StatusOK {
		t.Fatalf("restore capture: got %d", restored.StatusCode)
	}

	public := readPublicShare(t, srv.URL, share)
	defer public.Body.Close()
	if public.StatusCode != http.StatusNotFound {
		t.Fatalf("restored Capture reactivated share: got %d", public.StatusCode)
	}
}

func TestCaptureShare_OwnerBoundaryAndTextOnly(t *testing.T) {
	srv, pool := newServer(t)
	_, ownerToken := createTestUser(t, pool)
	_, otherToken := createTestUser(t, pool)
	id := createCapture(t, srv, ownerToken, map[string]any{"rawText": "owner only"})

	unauthorized := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+id+"/shares", "", map[string]string{
		"expiresIn": "7d", "snapshotRawText": "owner only",
	})
	unauthorized.Body.Close()
	if unauthorized.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthenticated create share: got %d", unauthorized.StatusCode)
	}

	wrongOwner := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+id+"/shares", otherToken, map[string]string{
		"expiresIn": "7d", "snapshotRawText": "owner only",
	})
	wrongOwner.Body.Close()
	if wrongOwner.StatusCode != http.StatusNotFound {
		t.Fatalf("other owner create share: got %d", wrongOwner.StatusCode)
	}

	mediaOnly := createCapture(t, srv, ownerToken, map[string]any{
		"mediaType": "image",
		"rawText":   nil,
		"mediaUrl":  "https://media.example/private.png",
	})
	mediaShare := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+mediaOnly+"/shares", ownerToken, map[string]string{
		"expiresIn": "7d", "snapshotRawText": "not actually in the Capture",
	})
	defer mediaShare.Body.Close()
	if mediaShare.StatusCode != http.StatusNotFound {
		t.Fatalf("media-only share: got %d", mediaShare.StatusCode)
	}
}

func TestCaptureShare_MissingFrontendURLFailsBeforeCreatingShare(t *testing.T) {
	srv, pool := newServerOptsWithRAGAndFrontend(t, false, "", "")
	_, token := createTestUser(t, pool)
	id := createCapture(t, srv, token, map[string]any{"rawText": "private until configured"})

	resp := do(t, srv.Client(), http.MethodPost, srv.URL+"/captures/"+id+"/shares", token, map[string]string{
		"expiresIn": "7d", "snapshotRawText": "private until configured",
	})
	resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("create without frontend URL: got %d", resp.StatusCode)
	}

	listed := do(t, srv.Client(), http.MethodGet, srv.URL+"/shares", token, nil)
	var page captureSharePageResponse
	decodeBody(t, listed, &page)
	if len(page.Items) != 0 {
		t.Fatalf("created %d shares without a frontend URL", len(page.Items))
	}
}

func TestCaptureShare_ListIsCursorPaginatedAndFilterable(t *testing.T) {
	srv, pool := newServer(t)
	_, token := createTestUser(t, pool)
	ids := make([]string, 0, 3)
	for _, text := range []string{"first share", "second share", "third share"} {
		id := createCapture(t, srv, token, map[string]any{"rawText": text})
		ids = append(ids, id)
		createShare(t, srv.URL, token, id, text, "never")
	}

	first := do(t, srv.Client(), http.MethodGet, srv.URL+"/shares?limit=2", token, nil)
	var firstPage captureSharePageResponse
	decodeBody(t, first, &firstPage)
	if len(firstPage.Items) != 2 || firstPage.NextCursor == nil {
		t.Fatalf("first page = %+v", firstPage)
	}
	second := do(
		t,
		srv.Client(),
		http.MethodGet,
		srv.URL+"/shares?limit=2&cursor="+url.QueryEscape(*firstPage.NextCursor),
		token,
		nil,
	)
	var secondPage captureSharePageResponse
	decodeBody(t, second, &secondPage)
	if len(secondPage.Items) != 1 || secondPage.NextCursor != nil {
		t.Fatalf("second page = %+v", secondPage)
	}

	filtered := do(t, srv.Client(), http.MethodGet, srv.URL+"/shares?captureId="+ids[0], token, nil)
	var filteredPage captureSharePageResponse
	decodeBody(t, filtered, &filteredPage)
	if len(filteredPage.Items) != 1 || filteredPage.Items[0].CaptureID != ids[0] {
		t.Fatalf("filtered page = %+v", filteredPage)
	}
}
