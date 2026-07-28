package capture

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
)

const (
	mediaDeletionFallbackInterval = 15 * time.Minute
	mediaDeletionErrorInterval    = 30 * time.Second
	mediaDeletionObjectTimeout    = 30 * time.Second
	maxMediaDeletionsPerDrain     = 100
)

type mediaDeletionWorker struct {
	q      *db.Queries
	store  objectDeleter
	bucket string
}

// StartMediaDeletionWorker drains durable media tombstones. The returned kick
// is non-blocking; the startup tick and fallback timer recover work when a
// request was cancelled after its transactional delete but before it could
// signal this process, or when another API instance enqueued the tombstone.
func StartMediaDeletionWorker(
	ctx context.Context,
	pool *pgxpool.Pool,
	store objectDeleter,
	bucket string,
) (kick func()) {
	if store == nil || bucket == "" {
		return func() {}
	}
	worker := &mediaDeletionWorker{
		q:      db.New(pool),
		store:  store,
		bucket: bucket,
	}
	kickCh := make(chan struct{}, 1)
	go worker.run(ctx, kickCh)
	return func() {
		select {
		case kickCh <- struct{}{}:
		default:
		}
	}
}

func (w *mediaDeletionWorker) run(ctx context.Context, kick <-chan struct{}) {
	timer := time.NewTimer(0)
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-kick:
		case <-timer.C:
		}

		wait := mediaDeletionFallbackInterval
		retryIn, err := w.processAvailable(ctx)
		if err != nil && !errors.Is(err, context.Canceled) {
			slog.Error(
				"media deletion worker failed",
				"traceId", "media-deletion-worker",
				"err", err,
			)
			wait = mediaDeletionErrorInterval
		}
		if retryIn > 0 && retryIn < wait {
			wait = retryIn
		}
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		timer.Reset(wait)
	}
}

func (w *mediaDeletionWorker) processAvailable(ctx context.Context) (time.Duration, error) {
	for processed := 0; processed < maxMediaDeletionsPerDrain; processed++ {
		deletion, err := w.q.ClaimCaptureMediaDeletion(ctx)
		if errors.Is(err, pgx.ErrNoRows) {
			return w.nextScheduledIn(ctx)
		}
		if err != nil {
			return 0, err
		}

		deleteCtx, cancel := context.WithTimeout(ctx, mediaDeletionObjectTimeout)
		_, deleteErr := w.store.DeleteObject(deleteCtx, &s3.DeleteObjectInput{
			Bucket: aws.String(w.bucket),
			Key:    aws.String(deletion.ObjectKey),
		})
		cancel()
		if deleteErr != nil {
			// On process shutdown the durable lease is enough: another worker
			// picks it up when it expires. Avoid attempting bookkeeping with an
			// already-cancelled root context.
			if ctx.Err() != nil {
				return 0, ctx.Err()
			}
			updated, failErr := w.q.FailCaptureMediaDeletion(
				ctx,
				db.FailCaptureMediaDeletionParams{
					ObjectKey:  deletion.ObjectKey,
					LeaseUntil: deletion.LeaseUntil,
					LastError: pgtype.Text{
						String: deleteErr.Error(),
						Valid:  true,
					},
				},
			)
			if failErr != nil {
				return 0, failErr
			}
			if updated > 0 {
				slog.Warn(
					"media object deletion failed; retry retained",
					"traceId", "media-deletion-worker",
					"key", deletion.ObjectKey,
					"attempt", deletion.Attempts+1,
					"err", deleteErr,
				)
			}
			continue
		}

		if _, err := w.q.CompleteCaptureMediaDeletion(
			ctx,
			db.CompleteCaptureMediaDeletionParams{
				ObjectKey:  deletion.ObjectKey,
				LeaseUntil: deletion.LeaseUntil,
			},
		); err != nil {
			return 0, err
		}
	}
	// Yield between bounded batches so a large empty-trash operation cannot
	// monopolize the process indefinitely.
	return time.Second, nil
}

func (w *mediaDeletionWorker) nextScheduledIn(ctx context.Context) (time.Duration, error) {
	next, err := w.q.NextCaptureMediaDeletionAt(ctx)
	if err != nil || !next.Valid {
		return 0, err
	}
	wait := time.Until(next.Time)
	if wait <= 0 {
		return time.Second, nil
	}
	return wait, nil
}
