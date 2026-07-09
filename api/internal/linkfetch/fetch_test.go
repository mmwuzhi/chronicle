package linkfetch

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestBlockedIP(t *testing.T) {
	cases := []struct {
		ip      string
		blocked bool
	}{
		{"127.0.0.1", true},       // loopback
		{"::1", true},             // loopback v6
		{"10.0.0.1", true},        // private
		{"172.16.5.4", true},      // private
		{"192.168.1.1", true},     // private
		{"169.254.169.254", true}, // cloud metadata (link-local)
		{"fe80::1", true},         // link-local v6
		{"fc00::1", true},         // ULA private v6
		{"0.0.0.0", true},         // unspecified
		{"224.0.0.1", true},       // multicast
		{"8.8.8.8", false},        // public
		{"1.1.1.1", false},        // public
		{"93.184.216.34", false},  // public (example.com)
	}
	for _, c := range cases {
		if got := blockedIP(net.ParseIP(c.ip)); got != c.blocked {
			t.Errorf("blockedIP(%s) = %v, want %v", c.ip, got, c.blocked)
		}
	}
	if !blockedIP(nil) {
		t.Error("blockedIP(nil) should be true")
	}
}

func TestIsHTML(t *testing.T) {
	cases := map[string]bool{
		"text/html":                true,
		"text/html; charset=utf-8": true,
		"application/xhtml+xml":    true,
		"  text/html ":             true,
		"application/json":         false,
		"application/pdf":          false,
		"image/png":                false,
		"text/plain":               false,
		"application/octet-stream": false,
		"":                         false,
	}
	for ct, want := range cases {
		if got := isHTML(ct); got != want {
			t.Errorf("isHTML(%q) = %v, want %v", ct, got, want)
		}
	}
}

// The core SSRF defense: the real safe client must refuse to connect to a
// loopback httptest server, even though the URL is syntactically fine.
func TestFetchBlocksLoopback(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte("<html><body>secret internal</body></html>"))
	}))
	defer srv.Close()

	w := &worker{client: newSafeClient()}
	_, err := w.fetch(context.Background(), srv.URL)
	if err == nil {
		t.Fatal("expected loopback fetch to be blocked, got nil error")
	}
	if !errors.Is(err, ErrBlockedAddress) &&
		!strings.Contains(err.Error(), "private or non-public") {
		t.Errorf("expected ErrBlockedAddress, got %v", err)
	}
}

// fetch mechanics (status, content-type gate, size cap) using a permissive
// client so the loopback test server is reachable — these paths are independent
// of the SSRF dialer guard, which TestFetchBlocksLoopback covers.
func permissiveWorker() *worker {
	return &worker{client: &http.Client{}}
}

func TestFetchRejectsNonHTML(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"a":1}`))
	}))
	defer srv.Close()

	_, err := permissiveWorker().fetch(context.Background(), srv.URL)
	if err == nil || !strings.Contains(err.Error(), "content type") {
		t.Errorf("expected content-type rejection, got %v", err)
	}
}

func TestFetchRejectsNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	_, err := permissiveWorker().fetch(context.Background(), srv.URL)
	if err == nil || !strings.Contains(err.Error(), "status 404") {
		t.Errorf("expected 404 rejection, got %v", err)
	}
}

func TestFetchRejectsBadScheme(t *testing.T) {
	_, err := permissiveWorker().fetch(context.Background(), "ftp://example.com/file")
	if err == nil || !strings.Contains(err.Error(), "scheme") {
		t.Errorf("expected scheme rejection, got %v", err)
	}
}

func TestFetchHappyPath(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte("<html><head><title>Ok</title></head><body><p>Hi</p></body></html>"))
	}))
	defer srv.Close()

	body, err := permissiveWorker().fetch(context.Background(), srv.URL)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	title, text := Extract(body)
	if title != "Ok" || !strings.Contains(text, "Hi") {
		t.Errorf("extract = (%q, %q), want title Ok / body Hi", title, text)
	}
}
