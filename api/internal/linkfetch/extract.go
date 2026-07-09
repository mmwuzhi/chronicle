package linkfetch

import (
	"bytes"
	"strings"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
)

// maxExtractRunes bounds the stored transcript so one enormous page can't bloat
// the row or the embedding input. Article text is far smaller; this is a guard.
const maxExtractRunes = 20000

// nonContent are elements whose text is chrome, not content — skipped whole so
// scripts, styles, and boilerplate navigation don't pollute the searchable text.
var nonContent = map[atom.Atom]bool{
	atom.Script:   true,
	atom.Style:    true,
	atom.Noscript: true,
	atom.Nav:      true,
	atom.Header:   true,
	atom.Footer:   true,
	atom.Aside:    true,
	atom.Form:     true,
	atom.Template: true,
}

// Extract pulls a page's title and readable text from its HTML. The result is
// the capture's new transcript: it feeds the same FTS index and RAG embedding as
// a voice transcript, so a captured URL becomes findable by what the page says.
// Not a full readability implementation — it drops obvious chrome, joins the
// title, meta description, and remaining text, and collapses whitespace, which
// is enough for content search. Returns ("", "") on unparseable HTML.
func Extract(body []byte) (title, text string) {
	doc, err := html.Parse(bytes.NewReader(body))
	if err != nil {
		return "", ""
	}

	var b strings.Builder
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.ElementNode {
			if n.DataAtom == atom.Title && title == "" {
				title = strings.TrimSpace(collectText(n))
				return
			}
			if n.DataAtom == atom.Meta {
				if d := metaDescription(n); d != "" {
					b.WriteString(d)
					b.WriteByte('\n')
				}
				return
			}
			if nonContent[n.DataAtom] {
				return
			}
		}
		if n.Type == html.TextNode {
			if t := strings.TrimSpace(n.Data); t != "" {
				b.WriteString(t)
				b.WriteByte(' ')
			}
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(doc)

	text = normalizeSpace(b.String())
	if title != "" {
		title = normalizeSpace(title)
	}
	return title, truncateRunes(text, maxExtractRunes)
}

// metaDescription returns the content of a <meta name="description"> or
// <meta property="og:description">, the page's own summary of itself.
func metaDescription(n *html.Node) string {
	var key, content string
	for _, a := range n.Attr {
		switch strings.ToLower(a.Key) {
		case "name", "property":
			key = strings.ToLower(a.Val)
		case "content":
			content = a.Val
		}
	}
	if key == "description" || key == "og:description" {
		return strings.TrimSpace(content)
	}
	return ""
}

// collectText returns the concatenated text of a node's descendants.
func collectText(n *html.Node) string {
	var b strings.Builder
	var walk func(*html.Node)
	walk = func(n *html.Node) {
		if n.Type == html.TextNode {
			b.WriteString(n.Data)
		}
		for c := n.FirstChild; c != nil; c = c.NextSibling {
			walk(c)
		}
	}
	walk(n)
	return b.String()
}

// normalizeSpace collapses every run of whitespace to a single space.
func normalizeSpace(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

func truncateRunes(s string, max int) string {
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return string(r[:max])
}
