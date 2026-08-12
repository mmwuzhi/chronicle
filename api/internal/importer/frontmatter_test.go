package importer

import (
	"strings"
	"testing"
	"time"

	"github.com/sikaoshenmi/chronicle/internal/capture"
)

func TestParseNoteMapsFrontmatterIntoCaptureText(t *testing.T) {
	issues := newIssueCollector()
	rawText, createdAt, aliases, _, applied := parseNote("travel.md", `---
title: 京都旅行清单
created: 2026-08-05 09:30:00+09:00
tags:
  - travel
  - "Japan plans"
aliases: [Kyoto list]
source: https://example.com/kyoto
completed?: false
unknown: preserved-in-source-file
---

订酒店和新干线。
`, time.UTC, issues)

	if !applied {
		t.Fatal("frontmatter was not applied")
	}
	if createdAt != "2026-08-05T00:30:00Z" {
		t.Fatalf("createdAt = %q", createdAt)
	}
	if len(aliases) != 1 || aliases[0] != "Kyoto list" {
		t.Fatalf("aliases = %#v", aliases)
	}
	for _, expected := range []string{
		"# 京都旅行清单", "订酒店和新干线。", "https://example.com/kyoto",
		"Aliases: Kyoto list", "#travel", "#Japan-plans", "#todo",
		"unknown: preserved-in-source-file",
	} {
		if !strings.Contains(rawText, expected) {
			t.Errorf("raw text missing %q:\n%s", expected, rawText)
		}
	}
	gotIssues := issues.list()
	if len(gotIssues) != 2 || !hasIssue(gotIssues, "normalized_tag") || !hasIssue(gotIssues, "ignored_frontmatter_fields") {
		t.Fatalf("issues = %+v", gotIssues)
	}
}

func TestPreservedFrontmatterDoesNotCreateTodoOrLinks(t *testing.T) {
	issues := newIssueCollector()
	rawText, _, _, linkText, _ := parseNote(
		"legacy.md",
		"---\nlegacy: |\n  #todo\n  [[Other]]\n---\nBody",
		time.UTC,
		issues,
	)
	todoAt, _ := capture.DeriveTodoStamps(rawText, time.Now())
	if todoAt.Valid {
		t.Fatalf("preserved frontmatter created a todo: %q", rawText)
	}
	if strings.Contains(linkText, "[[Other]]") {
		t.Fatalf("preserved frontmatter leaked into link text: %q", linkText)
	}
	if !strings.Contains(rawText, `\#todo`) || !strings.Contains(rawText, "[[Other]]") {
		t.Fatalf("preserved frontmatter content was lost: %q", rawText)
	}
}

func TestInvalidFrontmatterSequenceItemIsPreserved(t *testing.T) {
	issues := newIssueCollector()
	rawText, _, _, _, _ := parseNote(
		"mixed.md",
		"---\ntags: [good, {private: value}]\n---\nBody",
		time.UTC,
		issues,
	)
	if !strings.Contains(rawText, "private: value") || !hasIssue(issues.list(), "invalid_frontmatter_field") {
		t.Fatalf("mixed sequence was not preserved and reported: %q %+v", rawText, issues.list())
	}
}

func TestParseNoteDoesNotTreatLongerTagAsExisting(t *testing.T) {
	issues := newIssueCollector()
	rawText, _, _, _, _ := parseNote("tags.md", "---\ntags: [go]\n---\n#golang", time.UTC, issues)
	if !strings.Contains(rawText, "#go") {
		t.Fatalf("standalone #go tag was not appended: %q", rawText)
	}
}

func hasIssue(issues []MarkdownImportIssue, code string) bool {
	for _, issue := range issues {
		if issue.Code == code {
			return true
		}
	}
	return false
}

func TestParseNoteKeepsMalformedFrontmatterAsContent(t *testing.T) {
	issues := newIssueCollector()
	rawText, _, _, _, applied := parseNote("broken.md", "---\ntitle: [broken\n---\nbody", time.UTC, issues)
	if applied {
		t.Fatal("malformed frontmatter was applied")
	}
	if !strings.Contains(rawText, "title: [broken") {
		t.Fatalf("malformed source content was lost: %q", rawText)
	}
	if got := issues.list(); len(got) != 1 || got[0].Code != "malformed_frontmatter" {
		t.Fatalf("issues = %+v", got)
	}
}

func TestParseNoteOnlyAddsUserAuthoredHeadings(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{name: "plain body", input: "Body", want: "Body"},
		{name: "body H1", input: "# Human title\n\nBody", want: "# Human title\n\nBody"},
		{
			name:  "frontmatter title",
			input: "---\ntitle: User title\n---\nBody",
			want:  "# User title\n\nBody",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			issues := newIssueCollector()
			rawText, _, _, _, _ := parseNote("machine-generated-slug.md", test.input, time.UTC, issues)
			if rawText != test.want {
				t.Fatalf("raw text = %q, want %q", rawText, test.want)
			}
		})
	}
}

func TestParseImportTimeUsesProvidedLocationForNaiveValues(t *testing.T) {
	location, err := time.LoadLocation("Asia/Tokyo")
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := parseImportTime("2026-08-05", location)
	if err != nil {
		t.Fatal(err)
	}
	if got := parsed.UTC().Format(time.RFC3339); got != "2026-08-04T15:00:00Z" {
		t.Fatalf("parsed = %s", got)
	}
}

func TestContentImportHashIncludesFilenameAndTimezone(t *testing.T) {
	fileHash := strings.Repeat("a", 64)
	base := contentImportHash(fileHash, "note.md", time.UTC)
	if base == contentImportHash(fileHash, "renamed.md", time.UTC) {
		t.Fatal("filename was not included in import identity")
	}
	if base == contentImportHash(fileHash, "note.md", time.FixedZone("JST", 9*60*60)) {
		t.Fatal("timezone was not included in import identity")
	}
}

func TestDecodeImportFilenameSupportsPercentEncodedUnicode(t *testing.T) {
	got, err := decodeImportFilename("%E4%BA%AC%E9%83%BD%E3%83%A1%E3%83%A2.md")
	if err != nil {
		t.Fatal(err)
	}
	if got != "京都メモ.md" {
		t.Fatalf("filename = %q", got)
	}
	if _, err := decodeImportFilename("..%2Fsecret.md"); err == nil {
		t.Fatal("encoded path separator was accepted")
	}
}
