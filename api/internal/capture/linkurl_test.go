package capture

import "testing"

func TestFirstURL(t *testing.T) {
	cases := []struct {
		name string
		text string
		want string
	}{
		{"bare https", "https://example.com", "https://example.com"},
		{"bare http", "http://example.com/path", "http://example.com/path"},
		{"url in prose", "check this out https://example.com/article it's great", "https://example.com/article"},
		{"trailing period trimmed", "see https://example.com/page.", "https://example.com/page"},
		{"trailing paren trimmed", "(https://example.com/x)", "https://example.com/x"},
		{"markdown link", "[title](https://example.com/md)", "https://example.com/md"},
		{"keeps path query", "https://example.com/a/b?q=1&r=2", "https://example.com/a/b?q=1&r=2"},
		{"keeps fragment todo", "https://example.com/#todo", "https://example.com/#todo"},
		{"first of several", "https://a.com then https://b.com", "https://a.com"},
		{"no url", "just some text, no link here", ""},
		{"scheme only is rejected", "https:// missing host", ""},
		{"ftp not matched", "ftp://example.com/file", ""},
		{"www without scheme not matched", "visit www.example.com today", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := FirstURL(c.text); got != c.want {
				t.Errorf("FirstURL(%q) = %q, want %q", c.text, got, c.want)
			}
		})
	}
}
