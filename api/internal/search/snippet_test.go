package search

import (
	"strings"
	"testing"
)

func TestSearchSnippetCentersLiteralMatchAndCapsRunes(t *testing.T) {
	text := strings.Repeat("前文", 80) + "目标短语" + strings.Repeat("后文", 80)
	got := searchSnippet(text, "目标短语", 60)
	if !strings.Contains(got, "目标短语") {
		t.Fatalf("snippet missed literal evidence: %q", got)
	}
	if len([]rune(strings.Trim(got, "…"))) > 60 {
		t.Fatalf("snippet exceeded rune cap: %d", len([]rune(got)))
	}
	if !strings.HasPrefix(got, "…") || !strings.HasSuffix(got, "…") {
		t.Fatalf("centered snippet should mark both clipped edges: %q", got)
	}
}

func TestSearchSnippetReturnsShortContentUnchanged(t *testing.T) {
	const text = "short capture"
	if got := searchSnippet(text, "capture", 240); got != text {
		t.Fatalf("got %q, want %q", got, text)
	}
}
