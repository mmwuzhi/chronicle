package capture

import (
	"regexp"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
)

// The #todo system tag is the todo facet's only entry point: a capture is a
// todo iff its raw text carries the standalone token #todo. Done state is a
// parameter of that tag — #todo(done) or #todo(done:2026-07-09) — never a
// separate tag, so a plain word "done" in prose can never complete anything.
// The todo_at/done_at columns are derived indexes: the text decides on every
// save, the columns only make the browse-path filter cheap. todo_at records
// the first time the tag appeared and is never written into the text.
//
// Token boundaries: the tag must be preceded by start-of-text or whitespace
// (a URL fragment like example.com/#todo never counts) and followed by
// end-of-text or a character that cannot extend a tag name — #todos,
// #todo-list, and #todo买牛奶 are different tags, not todo flags. A malformed
// parameter (#todo(later)) disqualifies the token entirely rather than
// half-matching: only the three exact shapes count.
//
// Group 1 = the whole token, group 2 = the (done…) parameter with parens,
// group 3 = the YYYY-MM-DD date inside the parameter.
var todoTagRe = regexp.MustCompile(`(?:^|\s)(#todo(\(done(?::(\d{4}-\d{2}-\d{2}))?\))?)(?:[^\p{L}\p{N}_(-]|$)`)

type todoTag struct {
	present  bool
	done     bool
	doneDate string // YYYY-MM-DD from #todo(done:…); empty for bare (done)
}

// parseTodoTag reads the first #todo token in text. Later occurrences are
// inert: the first one is authoritative for parsing and rewriting alike.
func parseTodoTag(text string) todoTag {
	m := todoTagRe.FindStringSubmatch(text)
	if m == nil {
		return todoTag{}
	}
	if m[3] != "" {
		if _, err := time.Parse("2006-01-02", m[3]); err != nil {
			return todoTag{}
		}
	}
	return todoTag{present: true, done: m[2] != "", doneDate: m[3]}
}

// doneDateStamp turns the already-validated tag date into UTC midnight. An
// absent date returns NULL so the caller handles the bare #todo(done) case.
func doneDateStamp(d string) pgtype.Timestamptz {
	t, err := time.Parse("2006-01-02", d)
	if err != nil {
		return pgtype.Timestamptz{}
	}
	return pgtype.Timestamptz{Time: t, Valid: true}
}

// DeriveTodoStamps parses text's #todo tag and returns the todo_at/done_at
// stamps for a capture being created now with that text. Exported for the
// other capture-creating path (internal/upload's composer-draft text); the
// grammar itself stays private to this package.
func DeriveTodoStamps(text string, now time.Time) (todoAt, doneAt pgtype.Timestamptz) {
	return createTodoStamps(parseTodoTag(text), now)
}

// createTodoStamps derives a fresh capture's todo_at/done_at from its parsed
// text: the tag present at birth dates the flag now; a dated done parameter
// wins over now for the completion stamp (imported/hand-written history).
func createTodoStamps(tag todoTag, now time.Time) (todoAt, doneAt pgtype.Timestamptz) {
	if !tag.present {
		return
	}
	todoAt = pgtype.Timestamptz{Time: now, Valid: true}
	if tag.done {
		if ds := doneDateStamp(tag.doneDate); ds.Valid {
			doneAt = ds
		} else {
			doneAt = pgtype.Timestamptz{Time: now, Valid: true}
		}
	}
	return
}
