package webhook_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/testutil"
)

func mkUser(t *testing.T, pool interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}, email string) uuid.UUID {
	t.Helper()
	var id uuid.UUID
	if err := pool.QueryRow(context.Background(),
		"INSERT INTO users (email, password_hash) VALUES ($1, $2) RETURNING id",
		email, "x").Scan(&id); err != nil {
		t.Fatalf("create user: %v", err)
	}
	return id
}

func TestWebhookCRUD(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "capture_webhooks", "users")
	q := db.New(pool)
	ctx := context.Background()
	uid := mkUser(t, pool, "webhook@test.com")

	created, err := q.CreateWebhook(ctx, db.CreateWebhookParams{
		UserID:            uid,
		Name:              "receipts to sheet",
		TargetUrl:         "https://example.test/hook",
		Keywords:          []string{"receipt", "領収書"},
		SemanticQuery:     pgtype.Text{String: "expense receipt", Valid: true},
		SemanticThreshold: 0.6,
		PayloadTemplate:   `{"text":"[capture.text]"}`,
		Enabled:           true,
	})
	if err != nil {
		t.Fatalf("create webhook: %v", err)
	}
	if created.Name != "receipts to sheet" || len(created.Keywords) != 2 {
		t.Fatalf("unexpected created webhook: %+v", created)
	}

	if list, err := q.ListWebhooks(ctx, uid); err != nil || len(list) != 1 {
		t.Fatalf("list webhooks: got %d (%v)", len(list), err)
	}

	if got, err := q.GetWebhook(ctx, db.GetWebhookParams{ID: created.ID, UserID: uid}); err != nil || got.ID != created.ID {
		t.Fatalf("get webhook: %v", err)
	}

	updated, err := q.UpdateWebhook(ctx, db.UpdateWebhookParams{
		ID:                created.ID,
		UserID:            uid,
		Name:              "disabled rule",
		TargetUrl:         "https://example.test/hook2",
		Keywords:          []string{},
		SemanticQuery:     pgtype.Text{}, // cleared
		SemanticThreshold: 0.8,
		PayloadTemplate:   "plain [capture.text]",
		Enabled:           false,
	})
	if err != nil {
		t.Fatalf("update webhook: %v", err)
	}
	if updated.Enabled || updated.SemanticQuery.Valid || updated.SemanticThreshold != 0.8 {
		t.Fatalf("unexpected updated webhook: %+v", updated)
	}

	if _, err := q.SoftDeleteWebhook(ctx, db.SoftDeleteWebhookParams{ID: created.ID, UserID: uid}); err != nil {
		t.Fatalf("soft delete: %v", err)
	}

	if after, err := q.ListWebhooks(ctx, uid); err != nil || len(after) != 0 {
		t.Fatalf("list after delete: got %d (%v)", len(after), err)
	}
	if _, err := q.GetWebhook(ctx, db.GetWebhookParams{ID: created.ID, UserID: uid}); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("get after delete should be ErrNoRows, got %v", err)
	}
}

func TestWebhookUserIsolation(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "capture_webhooks", "users")
	q := db.New(pool)
	ctx := context.Background()
	a := mkUser(t, pool, "a@test.com")
	b := mkUser(t, pool, "b@test.com")

	wh, err := q.CreateWebhook(ctx, db.CreateWebhookParams{
		UserID: a, Name: "a's", TargetUrl: "https://x.test", Keywords: []string{},
		SemanticThreshold: 0.6, PayloadTemplate: "x", Enabled: true,
	})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := q.GetWebhook(ctx, db.GetWebhookParams{ID: wh.ID, UserID: b}); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("user B should not get user A's webhook, got %v", err)
	}
	if list, _ := q.ListWebhooks(ctx, b); len(list) != 0 {
		t.Fatalf("user B should see no webhooks")
	}
}
