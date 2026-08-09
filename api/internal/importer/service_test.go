package importer

import (
	"archive/zip"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/testutil"
)

func TestServiceImportsReplaysAndUndoesMarkdownZip(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "markdown_import_operations", "users")
	q := db.New(pool)
	user, err := q.CreateUser(context.Background(), db.CreateUserParams{
		Email:        "markdown-import@test.com",
		PasswordHash: pgtype.Text{String: "hash", Valid: true},
	})
	if err != nil {
		t.Fatal(err)
	}

	archivePath := filepath.Join(t.TempDir(), "notes.zip")
	writeTestZip(t, archivePath, map[string]string{
		"Notes/A.md": `---
title: Imported task
created: 2026-08-05 09:30:00
tags: [imported]
completed: true
---
Read [[B]].`,
		"Notes/B.md": "Reference note https://example.com/imported",
	})
	service := NewService(pool, Config{MaxBytes: 32 << 20}, nil)
	operationID := uuid.New()
	result, err := service.Import(
		context.Background(), user.ID, operationID, archivePath, "notes.zip",
		"application/zip", strings.Repeat("a", 64), time.FixedZone("test", 9*60*60),
	)
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	if result.Created != 2 || result.Links != 1 || result.FrontmatterApplied != 1 {
		t.Fatalf("result = %+v", result)
	}

	captures, err := q.ListArchiveCaptures(context.Background(), user.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(captures) != 2 {
		t.Fatalf("captures = %d, want 2", len(captures))
	}
	queued, err := q.BackfillLinkFetchQueue(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if queued != 0 {
		t.Fatalf("link fetch backfill queued %d imported Captures, want 0", queued)
	}
	var task db.Capture
	for _, imported := range captures {
		if strings.Contains(imported.RawText.String, "Imported task") {
			task = imported
		}
		if imported.Source != markdownImportSource {
			t.Errorf("source = %q", imported.Source)
		}
	}
	if task.ID == uuid.Nil || !task.TodoAt.Valid || !task.DoneAt.Valid {
		t.Fatalf("todo state was not derived: %+v", task)
	}
	wantCreatedAt := time.Date(2026, 8, 5, 0, 30, 0, 0, time.UTC)
	if !task.CreatedAt.Time.Equal(wantCreatedAt) {
		t.Fatalf("created_at = %s, want %s", task.CreatedAt.Time, wantCreatedAt)
	}

	replayed, err := service.Import(
		context.Background(), user.ID, operationID, archivePath, "notes.zip",
		"application/zip", strings.Repeat("a", 64), time.UTC,
	)
	if err != nil {
		t.Fatalf("replay: %v", err)
	}
	if !replayed.Replayed || replayed.OperationID != operationID.String() {
		t.Fatalf("replay result = %+v", replayed)
	}
	sharedCaptureID, err := uuid.Parse(result.CreatedCaptureIDs[0])
	if err != nil {
		t.Fatal(err)
	}
	shareID := uuid.New()
	if _, err := pool.Exec(context.Background(), `
		INSERT INTO capture_shares (
			id, user_id, capture_id, secret, snapshot_raw_text, captured_at, expires_at
		)
		SELECT $1, user_id, id, $3, raw_text, created_at, NULL
		FROM captures
		WHERE id = $2
	`, shareID, sharedCaptureID, strings.Repeat("s", 43)); err != nil {
		t.Fatalf("create imported Capture share: %v", err)
	}

	undone, err := service.Undo(context.Background(), user.ID, operationID)
	if err != nil {
		t.Fatalf("undo: %v", err)
	}
	if undone.Trashed != 2 {
		t.Fatalf("trashed = %d, want 2", undone.Trashed)
	}
	for _, captureID := range result.CreatedCaptureIDs {
		id, parseErr := uuid.Parse(captureID)
		if parseErr != nil {
			t.Fatal(parseErr)
		}
		capture, getErr := q.GetCaptureAnyState(context.Background(), db.GetCaptureAnyStateParams{
			ID: id, UserID: user.ID,
		})
		if getErr != nil {
			t.Fatal(getErr)
		}
		if !capture.DeletedAt.Valid {
			t.Fatalf("capture %s was not moved to Trash", captureID)
		}
	}
	var revoked bool
	if err := pool.QueryRow(
		context.Background(),
		"SELECT revoked_at IS NOT NULL FROM capture_shares WHERE id = $1",
		shareID,
	).Scan(&revoked); err != nil {
		t.Fatalf("read imported Capture share: %v", err)
	}
	if !revoked {
		t.Fatal("undoing a Markdown import did not permanently revoke its Capture share")
	}
	secondUndo, err := service.Undo(context.Background(), user.ID, operationID)
	if err != nil || secondUndo.Trashed != 0 {
		t.Fatalf("idempotent undo = %+v, %v", secondUndo, err)
	}
}

func writeTestZip(t *testing.T, filename string, entries map[string]string) {
	t.Helper()
	file, err := os.Create(filename)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	for name, body := range entries {
		entry, createErr := writer.Create(name)
		if createErr != nil {
			t.Fatal(createErr)
		}
		if _, writeErr := entry.Write([]byte(body)); writeErr != nil {
			t.Fatal(writeErr)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}
