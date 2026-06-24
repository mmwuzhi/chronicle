// Package ragclient is a thin HTTP client for the Python RAG sidecar.
//
// The sidecar has no auth of its own and is reachable only from this API over a
// private network. We authenticate the user here and pass a trusted user id in
// the X-User-Id header. A nil/disabled client (no RAG_SERVICE_URL configured)
// makes every call a no-op or returns ErrDisabled, so the rest of the API keeps
// working without semantic recall.
package ragclient

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"time"
)

// ErrDisabled is returned by query calls when no RAG sidecar is configured, so
// callers can fall back (e.g. to keyword FTS) instead of surfacing an error.
var ErrDisabled = errors.New("rag sidecar not configured")

// Per-call deadlines. They must stay below the HTTP server's WriteTimeout (30s)
// so a slow sidecar can never hold a request past the point where the response
// can still be written — a cold model that overruns this returns an error the
// caller degrades on, rather than a truncated/never-written response.
const (
	indexTimeout = 10 * time.Second
	findTimeout  = 20 * time.Second
	askTimeout   = 25 * time.Second
)

type Client struct {
	baseURL string
	http    *http.Client
}

// New returns a client, or nil if baseURL is empty (RAG disabled). A nil *Client
// is safe to call: query methods return ErrDisabled and Index is a no-op.
func New(baseURL string) *Client {
	if baseURL == "" {
		return nil
	}
	// No global client timeout — each call sets its own deadline via context.
	return &Client{baseURL: baseURL, http: &http.Client{}}
}

func (c *Client) Enabled() bool { return c != nil }

// FindItem is one ranked capture from the hybrid search.
type FindItem struct {
	ID        string  `json:"id"`
	Content   string  `json:"content"`
	CreatedAt string  `json:"created_at"`
	Modality  string  `json:"modality"`
	Score     float64 `json:"score"`
	Lexical   bool    `json:"lexical"`
}

// Source is one capture cited by an analysis answer.
type Source struct {
	N         int    `json:"n"`
	ID        string `json:"id"`
	Content   string `json:"content"`
	CreatedAt string `json:"created_at"`
}

// AskResult is the query-time analysis output.
type AskResult struct {
	Answer  string   `json:"answer"`
	Sources []Source `json:"sources"`
}

// Index asks the sidecar to (re)embed and extract metadata for one capture.
// Fire-and-forget: it runs on a background context with a short timeout and only
// logs failures — a missed index is healed by the sidecar's backfill. Safe on a
// nil client.
func (c *Client) Index(userID, captureID string) {
	if c == nil {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), indexTimeout)
		defer cancel()
		body, _ := json.Marshal(map[string]string{"capture_id": captureID})
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/index", bytes.NewReader(body))
		if err != nil {
			return
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-User-Id", userID)
		resp, err := c.http.Do(req)
		if err != nil {
			slog.Warn("rag index failed", "captureId", captureID, "err", err)
			return
		}
		resp.Body.Close()
		if resp.StatusCode >= 300 {
			slog.Warn("rag index non-2xx", "captureId", captureID, "status", resp.StatusCode)
		}
	}()
}

// Find runs the hybrid semantic search. Returns ErrDisabled on a nil client.
func (c *Client) Find(ctx context.Context, userID, query string, limit int) ([]FindItem, error) {
	if c == nil {
		return nil, ErrDisabled
	}
	ctx, cancel := context.WithTimeout(ctx, findTimeout)
	defer cancel()
	u := fmt.Sprintf("%s/find?q=%s&limit=%d", c.baseURL, url.QueryEscape(query), limit)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("X-User-Id", userID)
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("rag find status %d", resp.StatusCode)
	}
	var items []FindItem
	if err := json.NewDecoder(resp.Body).Decode(&items); err != nil {
		return nil, err
	}
	return items, nil
}

// Ask runs query-time cluster analysis. Returns ErrDisabled on a nil client.
func (c *Client) Ask(ctx context.Context, userID, question string) (*AskResult, error) {
	if c == nil {
		return nil, ErrDisabled
	}
	ctx, cancel := context.WithTimeout(ctx, askTimeout)
	defer cancel()
	body, _ := json.Marshal(map[string]string{"question": question})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/ask", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-User-Id", userID)
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("rag ask status %d", resp.StatusCode)
	}
	var out AskResult
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return &out, nil
}

// WebhookTestResult is the sidecar's verdict for one rule against one capture:
// whether it would match and the semantic cosine score (null when the rule has
// no semantic query or the capture has no embedding) — used to tune thresholds.
type WebhookTestResult struct {
	Matched bool     `json:"matched"`
	Score   *float64 `json:"score"`
}

// WebhookTest asks the sidecar to evaluate a webhook rule against a capture
// without delivering anything. body carries the rule fields + capture_id.
func (c *Client) WebhookTest(ctx context.Context, userID string, body any) (*WebhookTestResult, error) {
	if c == nil {
		return nil, ErrDisabled
	}
	ctx, cancel := context.WithTimeout(ctx, findTimeout)
	defer cancel()
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/webhooks/test", bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-User-Id", userID)
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("rag webhook test status %d", resp.StatusCode)
	}
	var out WebhookTestResult
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return &out, nil
}
