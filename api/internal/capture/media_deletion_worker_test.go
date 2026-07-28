package capture

import (
	"context"
	"errors"
	"sync"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/testutil"
)

type scriptedObjectDeleter struct {
	mu       sync.Mutex
	failures []error
	keys     []string
	buckets  []string
}

func (s *scriptedObjectDeleter) DeleteObject(
	_ context.Context,
	input *s3.DeleteObjectInput,
	_ ...func(*s3.Options),
) (*s3.DeleteObjectOutput, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.keys = append(s.keys, *input.Key)
	s.buckets = append(s.buckets, *input.Bucket)
	if len(s.failures) > 0 {
		err := s.failures[0]
		s.failures = s.failures[1:]
		if err != nil {
			return nil, err
		}
	}
	return &s3.DeleteObjectOutput{}, nil
}

func setupMediaDeletionTest(t *testing.T) (*pgxpool.Pool, uuid.UUID) {
	t.Helper()
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "capture_media_deletions", "captures", "users")
	uid := uuid.New()
	if _, err := pool.Exec(
		context.Background(),
		"INSERT INTO users (id, email, password_hash) VALUES ($1, $2, 'hash')",
		uid,
		uid.String()+"@test.invalid",
	); err != nil {
		t.Fatalf("insert user: %v", err)
	}
	return pool, uid
}

func insertTrashedCapture(
	t *testing.T,
	pool *pgxpool.Pool,
	uid uuid.UUID,
	key *string,
) uuid.UUID {
	t.Helper()
	id := uuid.New()
	if _, err := pool.Exec(
		context.Background(),
		`INSERT INTO captures
		    (id, user_id, raw_text, media_type, media_key, deleted_at)
		 VALUES ($1, $2, 'trash', 'image', $3, now())`,
		id,
		uid,
		key,
	); err != nil {
		t.Fatalf("insert trashed capture: %v", err)
	}
	return id
}

func TestMediaDeletion_PermanentDeleteRetainsCancellationAndRetries(t *testing.T) {
	pool, uid := setupMediaDeletionTest(t)
	key := "captures/user/permanent-image.jpg"
	id := insertTrashedCapture(t, pool, uid, &key)
	q := db.New(pool)

	if _, err := q.PermanentDeleteCapture(
		context.Background(),
		db.PermanentDeleteCaptureParams{ID: id, UserID: uid},
	); err != nil {
		t.Fatalf("permanent delete: %v", err)
	}

	var queued string
	if err := pool.QueryRow(
		context.Background(),
		"SELECT object_key FROM capture_media_deletions",
	).Scan(&queued); err != nil {
		t.Fatalf("read durable tombstone: %v", err)
	}
	if queued != key {
		t.Fatalf("queued key = %q, want %q", queued, key)
	}

	store := &scriptedObjectDeleter{failures: []error{context.Canceled, nil}}
	worker := &mediaDeletionWorker{q: q, store: store, bucket: "test-bucket"}
	if _, err := worker.processAvailable(context.Background()); err != nil {
		t.Fatalf("first drain: %v", err)
	}

	var attempts int
	if err := pool.QueryRow(
		context.Background(),
		"SELECT attempts FROM capture_media_deletions WHERE object_key = $1",
		key,
	).Scan(&attempts); err != nil {
		t.Fatalf("read retained retry: %v", err)
	}
	if attempts != 1 {
		t.Fatalf("attempts = %d, want 1", attempts)
	}

	if _, err := pool.Exec(
		context.Background(),
		"UPDATE capture_media_deletions SET next_attempt_at = now() WHERE object_key = $1",
		key,
	); err != nil {
		t.Fatalf("make retry due: %v", err)
	}
	if _, err := worker.processAvailable(context.Background()); err != nil {
		t.Fatalf("retry drain: %v", err)
	}

	var remaining int
	if err := pool.QueryRow(
		context.Background(),
		"SELECT count(*) FROM capture_media_deletions",
	).Scan(&remaining); err != nil {
		t.Fatalf("count tombstones: %v", err)
	}
	if remaining != 0 {
		t.Fatalf("remaining tombstones = %d, want 0", remaining)
	}
	if len(store.keys) != 2 || store.keys[0] != key || store.keys[1] != key {
		t.Fatalf("delete attempts = %v, want [%q %q]", store.keys, key, key)
	}
	if store.buckets[0] != "test-bucket" || store.buckets[1] != "test-bucket" {
		t.Fatalf("delete buckets = %v", store.buckets)
	}
}

func TestMediaDeletion_EmptyTrashQueuesEveryMediaKeyAndRetriesFailures(t *testing.T) {
	pool, uid := setupMediaDeletionTest(t)
	keyA := "captures/user/a.jpg"
	keyB := "captures/user/b.m4a"
	insertTrashedCapture(t, pool, uid, &keyA)
	insertTrashedCapture(t, pool, uid, &keyB)
	insertTrashedCapture(t, pool, uid, nil)

	liveID := uuid.New()
	if _, err := pool.Exec(
		context.Background(),
		`INSERT INTO captures (id, user_id, raw_text, media_type, media_key)
		 VALUES ($1, $2, 'live', 'image', 'captures/user/live.jpg')`,
		liveID,
		uid,
	); err != nil {
		t.Fatalf("insert live capture: %v", err)
	}

	q := db.New(pool)
	deleted, err := q.EmptyTrash(context.Background(), uid)
	if err != nil {
		t.Fatalf("empty trash: %v", err)
	}
	if len(deleted) != 3 {
		t.Fatalf("deleted captures = %d, want 3", len(deleted))
	}

	var capturesRemaining int
	if err := pool.QueryRow(
		context.Background(),
		"SELECT count(*) FROM captures",
	).Scan(&capturesRemaining); err != nil {
		t.Fatalf("count captures: %v", err)
	}
	if capturesRemaining != 1 {
		t.Fatalf("remaining captures = %d, want only live capture", capturesRemaining)
	}

	var tombstones int
	if err := pool.QueryRow(
		context.Background(),
		"SELECT count(*) FROM capture_media_deletions",
	).Scan(&tombstones); err != nil {
		t.Fatalf("count tombstones: %v", err)
	}
	if tombstones != 2 {
		t.Fatalf("media tombstones = %d, want 2", tombstones)
	}

	transient := errors.New("temporary R2 outage")
	store := &scriptedObjectDeleter{failures: []error{transient, nil, nil}}
	worker := &mediaDeletionWorker{q: q, store: store, bucket: "test-bucket"}
	if _, err := worker.processAvailable(context.Background()); err != nil {
		t.Fatalf("initial drain: %v", err)
	}

	if _, err := pool.Exec(
		context.Background(),
		"UPDATE capture_media_deletions SET next_attempt_at = now()",
	); err != nil {
		t.Fatalf("make retry due: %v", err)
	}
	if _, err := worker.processAvailable(context.Background()); err != nil {
		t.Fatalf("retry drain: %v", err)
	}
	if err := pool.QueryRow(
		context.Background(),
		"SELECT count(*) FROM capture_media_deletions",
	).Scan(&tombstones); err != nil {
		t.Fatalf("count final tombstones: %v", err)
	}
	if tombstones != 0 {
		t.Fatalf("remaining tombstones = %d, want 0", tombstones)
	}
	if len(store.keys) != 3 {
		t.Fatalf("R2 delete attempts = %v, want one failure + two successes", store.keys)
	}
}

func TestMediaDeletion_AccountDeleteQueuesMediaBeforeCascade(t *testing.T) {
	pool, uid := setupMediaDeletionTest(t)
	key := "captures/user/account-delete.jpg"
	if _, err := pool.Exec(
		context.Background(),
		`INSERT INTO captures (id, user_id, raw_text, media_type, media_key)
		 VALUES ($1, $2, 'live', 'image', $3)`,
		uuid.New(),
		uid,
		key,
	); err != nil {
		t.Fatalf("insert account capture: %v", err)
	}

	deletedID, err := db.New(pool).DeleteUser(context.Background(), uid)
	if err != nil {
		t.Fatalf("delete user: %v", err)
	}
	if deletedID != uid {
		t.Fatalf("deleted user = %s, want %s", deletedID, uid)
	}

	var userCount, captureCount int
	if err := pool.QueryRow(
		context.Background(),
		"SELECT count(*) FROM users WHERE id = $1",
		uid,
	).Scan(&userCount); err != nil {
		t.Fatalf("count user: %v", err)
	}
	if err := pool.QueryRow(
		context.Background(),
		"SELECT count(*) FROM captures WHERE user_id = $1",
		uid,
	).Scan(&captureCount); err != nil {
		t.Fatalf("count captures: %v", err)
	}
	if userCount != 0 || captureCount != 0 {
		t.Fatalf("account cascade incomplete: users=%d captures=%d", userCount, captureCount)
	}

	var queued string
	if err := pool.QueryRow(
		context.Background(),
		"SELECT object_key FROM capture_media_deletions",
	).Scan(&queued); err != nil {
		t.Fatalf("read account deletion tombstone: %v", err)
	}
	if queued != key {
		t.Fatalf("queued key = %q, want %q", queued, key)
	}
}
