// Package linkfetch turns a URL captured as plain text into searchable content:
// it fetches the page (behind an SSRF guard), extracts the readable text, and
// the worker stores that in the capture's transcript. No external API key is
// needed — this is a self-contained enrichment.
package linkfetch

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"syscall"
	"time"
)

const (
	// maxBodyBytes caps how much of a page we read — enough for article text,
	// bounded so a hostile or accidental huge response can't exhaust memory.
	maxBodyBytes = 3 << 20 // 3 MB
	// fetchTimeout bounds the whole request (connect + redirects + body).
	fetchTimeout = 15 * time.Second
	// maxRedirects bounds redirect chains; each hop is re-validated by the dialer.
	maxRedirects = 5
	userAgent    = "ChronicleLinkFetcher/1.0 (+https://github.com/sikaoshenmi/chronicle)"
)

// ErrBlockedAddress is returned (at dial time) when a URL resolves to a private,
// loopback, or otherwise non-public address — the core SSRF defense.
var ErrBlockedAddress = errors.New("refusing to fetch a private or non-public address")

// blockedIP reports whether an address is one the fetcher must never connect to:
// loopback, RFC1918 / ULA private, link-local (incl. the 169.254.169.254 cloud
// metadata endpoint), unspecified, or multicast. Redirects and DNS results are
// checked through this at every dial, so a public hostname that resolves (or
// redirects) to an internal IP is still refused.
func blockedIP(ip net.IP) bool {
	return ip == nil ||
		ip.IsLoopback() ||
		ip.IsPrivate() ||
		ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() ||
		ip.IsMulticast()
}

// newSafeClient builds an HTTP client whose dialer rejects private/loopback
// destinations. The check lives in Dialer.Control, which runs after DNS
// resolution with the concrete IP for every connection — including each redirect
// hop — so it defends against DNS rebinding and redirect-to-internal, not just
// the literal host in the original URL.
func newSafeClient() *http.Client {
	dialer := &net.Dialer{
		Timeout: 10 * time.Second,
		Control: func(_, address string, _ syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return err
			}
			if blockedIP(net.ParseIP(host)) {
				return ErrBlockedAddress
			}
			return nil
		},
	}
	return &http.Client{
		Timeout:   fetchTimeout,
		Transport: &http.Transport{DialContext: dialer.DialContext},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= maxRedirects {
				return errors.New("too many redirects")
			}
			if req.URL.Scheme != "http" && req.URL.Scheme != "https" {
				return fmt.Errorf("refusing non-http redirect to %q", req.URL.Scheme)
			}
			return nil
		},
	}
}

// isHTML reports whether a Content-Type is an HTML document we can extract text
// from. Anything else (PDF, images, JSON, octet-stream) is refused — extraction
// only understands markup.
func isHTML(contentType string) bool {
	mediaType := contentType
	if i := strings.IndexByte(mediaType, ';'); i >= 0 {
		mediaType = mediaType[:i]
	}
	mediaType = strings.ToLower(strings.TrimSpace(mediaType))
	return mediaType == "text/html" || mediaType == "application/xhtml+xml"
}

// fetch retrieves an HTML page's bytes with the SSRF guard, size cap, timeout,
// and content-type restriction applied. Returns an error for any non-200, a
// non-HTML body, an oversize body, or a blocked address.
func (w *worker) fetch(ctx context.Context, rawURL string) ([]byte, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, fmt.Errorf("unsupported URL scheme %q", u.Scheme)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "text/html,application/xhtml+xml")

	resp, err := w.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("link fetch returned status %d", resp.StatusCode)
	}
	if !isHTML(resp.Header.Get("Content-Type")) {
		return nil, fmt.Errorf("unsupported content type %q", resp.Header.Get("Content-Type"))
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBodyBytes+1))
	if err != nil {
		return nil, err
	}
	if len(body) > maxBodyBytes {
		return nil, errors.New("link body exceeds size cap")
	}
	return body, nil
}
