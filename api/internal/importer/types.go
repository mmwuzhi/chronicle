package importer

import (
	"errors"

	"github.com/google/uuid"
)

const (
	maxMarkdownImportBytes = 32 << 20
	maxImportEntries       = 10_000
	maxImportNotes         = 5_000
	maxImportNoteBytes     = 1 << 20
	maxImportLinkRefs      = 20_000
	maxImportLinks         = 10_000
	maxFrontmatterValues   = 256
	maxFrontmatterBytes    = 64 << 10
	maxIssueExamples       = 10
	markdownImportSource   = "markdown_import"
)

type Config struct {
	MaxBytes int64
}

type MarkdownImportIssue struct {
	Code     string   `json:"code"`
	Count    int      `json:"count"`
	Examples []string `json:"examples"`
}

type MarkdownImportResult struct {
	OperationID        string                `json:"operationId"`
	Created            int                   `json:"created"`
	Skipped            int                   `json:"skipped"`
	Links              int                   `json:"links"`
	FrontmatterApplied int                   `json:"frontmatterApplied"`
	AnalysisQueued     bool                  `json:"analysisQueued"`
	Replayed           bool                  `json:"replayed"`
	Issues             []MarkdownImportIssue `json:"issues"`
	CreatedCaptureIDs  []string              `json:"createdCaptureIds"`
}

type MarkdownImportUndoResult struct {
	Trashed int `json:"trashed"`
}

type ImportError struct {
	Status int
	Title  string
	Err    error
}

func (e *ImportError) Error() string {
	if e.Err == nil {
		return e.Title
	}
	return e.Title + ": " + e.Err.Error()
}

func (e *ImportError) Unwrap() error { return e.Err }

var errNoImportableNotes = errors.New("input contains no importable Markdown or text files")

type note struct {
	ID        uuid.UUID
	Path      string
	RawText   string
	LinkText  string
	CreatedAt string
	Aliases   []string
	Targets   []uuid.UUID
}

type parsedInput struct {
	Notes              []note
	Issues             *issueCollector
	FrontmatterApplied int
	Skipped            int
}

type issueCollector struct {
	order []string
	items map[string]*MarkdownImportIssue
}

func newIssueCollector() *issueCollector {
	return &issueCollector{items: make(map[string]*MarkdownImportIssue)}
}

func (c *issueCollector) add(code, example string) {
	issue := c.items[code]
	if issue == nil {
		issue = &MarkdownImportIssue{Code: code, Examples: []string{}}
		c.items[code] = issue
		c.order = append(c.order, code)
	}
	issue.Count++
	if example != "" && len(issue.Examples) < maxIssueExamples {
		issue.Examples = append(issue.Examples, example)
	}
}

func (c *issueCollector) list() []MarkdownImportIssue {
	result := make([]MarkdownImportIssue, 0, len(c.order))
	for _, code := range c.order {
		result = append(result, *c.items[code])
	}
	return result
}
