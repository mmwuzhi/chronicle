package auth_test

import (
	"context"
	"crypto/sha256"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/testutil"
)

func TestAuthEphemeralStateConsumesExactlyOnceUnderConcurrency(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "auth_ephemeral_states")
	queries := db.New(pool)
	keyHash := sha256.Sum256([]byte("one-time-code"))
	params := db.StoreAuthEphemeralStateParams{
		Purpose:   "test",
		KeyHash:   keyHash[:],
		Payload:   []byte(`{"ok":true}`),
		ExpiresAt: pgtype.Timestamptz{Time: time.Now().Add(time.Minute), Valid: true},
	}
	if err := queries.StoreAuthEphemeralState(context.Background(), params); err != nil {
		t.Fatalf("store state: %v", err)
	}

	var consumed atomic.Int32
	var unexpected atomic.Int32
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := queries.ConsumeAuthEphemeralState(
				context.Background(),
				db.ConsumeAuthEphemeralStateParams{
					Purpose: params.Purpose,
					KeyHash: params.KeyHash,
				},
			)
			switch {
			case err == nil:
				consumed.Add(1)
			case errors.Is(err, pgx.ErrNoRows):
			default:
				unexpected.Add(1)
			}
		}()
	}
	wg.Wait()

	if consumed.Load() != 1 || unexpected.Load() != 0 {
		t.Fatalf("consume results: success=%d unexpected=%d, want 1 and 0", consumed.Load(), unexpected.Load())
	}
}

func TestAuthEphemeralStateRejectsExpiredRows(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "auth_ephemeral_states")
	queries := db.New(pool)
	keyHash := sha256.Sum256([]byte("expired-code"))
	if err := queries.StoreAuthEphemeralState(
		context.Background(),
		db.StoreAuthEphemeralStateParams{
			Purpose:   "test",
			KeyHash:   keyHash[:],
			Payload:   []byte("expired"),
			ExpiresAt: pgtype.Timestamptz{Time: time.Now().Add(-time.Second), Valid: true},
		},
	); err != nil {
		t.Fatalf("store expired state: %v", err)
	}

	_, err := queries.GetAuthEphemeralState(
		context.Background(),
		db.GetAuthEphemeralStateParams{Purpose: "test", KeyHash: keyHash[:]},
	)
	if !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("get expired state error = %v, want pgx.ErrNoRows", err)
	}
}

func TestAuthRateLimitIncrementIsAtomic(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "auth_rate_limits")
	queries := db.New(pool)
	subjectHash := sha256.Sum256([]byte("subject"))

	const attempts = 12
	results := make(chan int32, attempts)
	errorsSeen := make(chan error, attempts)
	var wg sync.WaitGroup
	for range attempts {
		wg.Add(1)
		go func() {
			defer wg.Done()
			result, err := queries.IncrementAuthRateLimit(
				context.Background(),
				db.IncrementAuthRateLimitParams{
					Scope:       "test",
					SubjectHash: subjectHash[:],
					ExpiresAt:   pgtype.Timestamptz{Time: time.Now().Add(time.Minute), Valid: true},
				},
			)
			if err != nil {
				errorsSeen <- err
				return
			}
			results <- result.Attempts
		}()
	}
	wg.Wait()
	close(results)
	close(errorsSeen)

	for err := range errorsSeen {
		t.Errorf("increment rate limit: %v", err)
	}
	seen := make(map[int32]bool, attempts)
	for count := range results {
		seen[count] = true
	}
	for want := int32(1); want <= attempts; want++ {
		if !seen[want] {
			t.Errorf("missing atomic attempt count %d; got %v", want, seen)
		}
	}
}
