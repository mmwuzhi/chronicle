package capture

import (
	"net/url"
	"regexp"
	"strings"
)

// The link facet's URL grammar. Like the #todo tag, the capture text is the
// source of truth: a text capture that contains a URL is eligible for link
// enrichment (fetch the page's readable text into `transcript`). This is the
// single definition of "what counts as a URL" — the SQL backfill only does a
// coarse presence check and defers the exact extraction to FirstURL.
var urlRe = regexp.MustCompile(`https?://[^\s<>"'` + "`" + `)\]}]+`)

// FirstURL returns the first http(s) URL in the text, or "" if there is none.
// Trailing sentence punctuation is trimmed (a URL at the end of prose usually
// picks up a period or bracket), and the result must parse with a host so a bare
// "https://" or a mangled fragment does not enqueue an unfetchable job.
func FirstURL(text string) string {
	match := urlRe.FindString(text)
	if match == "" {
		return ""
	}
	match = strings.TrimRight(match, ".,;:!?)]}\"'>")
	u, err := url.Parse(match)
	if err != nil || u.Host == "" {
		return ""
	}
	return match
}
