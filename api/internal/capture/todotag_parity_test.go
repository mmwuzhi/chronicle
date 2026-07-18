package capture

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The #todo grammar is defined in Go, web, and desktop, and the root CLAUDE.md
// requires all three to change together. This test drives the Go parser against
// the same golden fixture consumed by the web and desktop parity tests.

type todoParityFixture struct {
	Cases []struct {
		Desc     string `json:"desc"`
		Text     string `json:"text"`
		Present  bool   `json:"present"`
		Done     bool   `json:"done"`
		DoneDate string `json:"doneDate"`
	} `json:"cases"`
}

func TestTodoTagGrammarParity(t *testing.T) {
	// Test CWD is the package dir (api/internal/capture); the fixture lives at
	// the repo root under shared/fixtures.
	path := filepath.Join("..", "..", "..", "shared", "fixtures", "todo-tag.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared fixture %s: %v", path, err)
	}
	var fx todoParityFixture
	if err := json.Unmarshal(data, &fx); err != nil {
		t.Fatalf("parse shared fixture: %v", err)
	}
	if len(fx.Cases) == 0 {
		t.Fatal("shared fixture has no cases")
	}

	for _, c := range fx.Cases {
		t.Run(c.Desc, func(t *testing.T) {
			got := parseTodoTag(c.Text)
			if got.present != c.Present {
				t.Errorf("present: got %v want %v (text %q)", got.present, c.Present, c.Text)
			}
			if got.done != c.Done {
				t.Errorf("done: got %v want %v (text %q)", got.done, c.Done, c.Text)
			}
			if got.doneDate != c.DoneDate {
				t.Errorf("doneDate: got %q want %q (text %q)", got.doneDate, c.DoneDate, c.Text)
			}
		})
	}
}
