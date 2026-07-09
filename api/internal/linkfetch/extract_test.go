package linkfetch

import (
	"strings"
	"testing"
)

func TestExtractTitleAndText(t *testing.T) {
	html := `<!doctype html><html><head>
		<title>  Hello World  </title>
		<meta name="description" content="A short summary.">
		<style>.x{color:red}</style>
	</head><body>
		<script>var a = 1;</script>
		<nav>Home About Contact</nav>
		<article><h1>Heading</h1><p>First paragraph.</p><p>Second paragraph.</p></article>
		<footer>Copyright 2026</footer>
	</body></html>`

	title, text := Extract([]byte(html))
	if title != "Hello World" {
		t.Errorf("title = %q, want %q", title, "Hello World")
	}
	// Content is present.
	for _, want := range []string{"A short summary.", "Heading", "First paragraph.", "Second paragraph."} {
		if !strings.Contains(text, want) {
			t.Errorf("text missing %q; got %q", want, text)
		}
	}
	// Chrome is dropped.
	for _, drop := range []string{"var a = 1", "color:red", "Home About Contact", "Copyright 2026"} {
		if strings.Contains(text, drop) {
			t.Errorf("text should not contain %q; got %q", drop, text)
		}
	}
}

func TestExtractOgDescription(t *testing.T) {
	html := `<html><head><meta property="og:description" content="OG summary."></head><body><p>Body.</p></body></html>`
	_, text := Extract([]byte(html))
	if !strings.Contains(text, "OG summary.") || !strings.Contains(text, "Body.") {
		t.Errorf("expected og description and body; got %q", text)
	}
}

func TestExtractEmpty(t *testing.T) {
	title, text := Extract(nil)
	if title != "" || text != "" {
		t.Errorf("empty input should yield empty output, got title=%q text=%q", title, text)
	}
}

func TestExtractTruncates(t *testing.T) {
	var b strings.Builder
	b.WriteString("<html><body>")
	for i := 0; i < 5000; i++ {
		b.WriteString("<p>word word word word</p>")
	}
	b.WriteString("</body></html>")
	_, text := Extract([]byte(b.String()))
	if n := len([]rune(text)); n > maxExtractRunes {
		t.Errorf("extracted text = %d runes, want <= %d", n, maxExtractRunes)
	}
}

func TestNormalizeSpace(t *testing.T) {
	if got := normalizeSpace("  a\n\tb   c  "); got != "a b c" {
		t.Errorf("normalizeSpace = %q, want %q", got, "a b c")
	}
}
