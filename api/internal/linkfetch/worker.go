package linkfetch

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/capture"
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
)

// The link-fetch worker is the exact structural twin of the transcription worker
// (internal/upload/transcription_worker.go): event-driven, single-flight kick,
// database-read backoff schedule. It processes the OTHER half of the shared
// transcription_status queue — text captures with a URL (media_key IS NULL) —
// so an idle deployment stays idle. See that file for the run-loop rationale.
const (
	workerFallbackInterval   = 15 * time.Minute
	workerErrorRetryInterval = 30 * time.Second
	// linkFetchModel labels the transcript's provenance in transcription_model,
	// mirroring how audio/vision record their model.
	linkFetchModel = "link-fetch"
)

type worker struct {
	q      *db.Queries
	rag    *ragclient.Client
	client *http.Client
}

// StartLinkFetchWorker launches the background worker and returns a non-blocking
// kick that wakes it immediately. When link fetch is disabled the worker doesn't
// start and the returned kick is a no-op. On start it enqueues any pre-existing
// URL captures once (backfill), so enabling the feature enriches history without
// a migration having mutated data while the feature was off.
func StartLinkFetchWorker(ctx context.Context, pool *pgxpool.Pool, enabled bool, rag *ragclient.Client) (kick func()) {
	if !enabled {
		return func() {}
	}
	w := &worker{q: db.New(pool), rag: rag, client: newSafeClient()}
	kickCh := make(chan struct{}, 1)
	go w.run(ctx, kickCh)
	return func() {
		select {
		case kickCh <- struct{}{}:
		default: // a wake-up is already queued
		}
	}
}

func (w *worker) run(ctx context.Context, kick <-chan struct{}) {
	if n, err := w.q.BackfillLinkFetchQueue(ctx); err != nil {
		if !errors.Is(err, context.Canceled) {
			slog.Warn("link-fetch backfill failed", "traceId", "link-fetch-worker", "err", err)
		}
	} else if n > 0 {
		slog.Info("link-fetch backfill enqueued captures", "traceId", "link-fetch-worker", "count", n)
	}

	timer := time.NewTimer(0) // fire immediately: drain the backfill + anything left from before a restart
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-kick:
		case <-timer.C:
		}
		wait := workerFallbackInterval
		retryIn, err := w.processAvailable(ctx)
		if err != nil && !errors.Is(err, context.Canceled) {
			slog.Error("link-fetch worker failed", "traceId", "link-fetch-worker", "err", err)
			wait = workerErrorRetryInterval
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

// processAvailable drains claimable link jobs, then reports how long until the
// next scheduled retry / expired lease comes due (zero when nothing is pending).
func (w *worker) processAvailable(ctx context.Context) (time.Duration, error) {
	for {
		c, err := w.q.ClaimPendingLinkFetch(ctx)
		if errors.Is(err, pgx.ErrNoRows) {
			return w.nextScheduledIn(ctx)
		}
		if err != nil {
			return 0, err
		}

		// Resolve the URL: new captures carry link_url; a backfilled row entered
		// the queue on a coarse presence check, so derive it from the text with
		// the one Go grammar. No URL at all → skip (leave the queue), don't loop.
		target := c.LinkUrl.String
		if !c.LinkUrl.Valid || target == "" {
			target = capture.FirstURL(c.RawText.String)
		}
		if target == "" {
			if err := w.q.SkipCaptureTranscription(ctx, c.ID); err != nil {
				return 0, err
			}
			continue
		}

		body, err := w.fetch(ctx, target)
		if err != nil {
			if failErr := w.q.FailCaptureTranscription(ctx, c.ID); failErr != nil {
				return 0, failErr
			}
			slog.Warn(
				"link fetch attempt failed",
				"traceId", "link-fetch-worker",
				"captureId", c.ID,
				"attempt", c.TranscriptionAttempts,
				"err", err,
			)
			continue
		}

		title, text := Extract(body)
		content := strings.TrimSpace(strings.TrimSpace(title) + "\n" + text)
		if content == "" {
			// A reachable page with no extractable text: skip so it leaves the
			// queue instead of failing and retrying to the same empty result.
			if err := w.q.SkipCaptureTranscription(ctx, c.ID); err != nil {
				return 0, err
			}
			continue
		}

		if err := w.q.CompleteCaptureLinkFetch(ctx, db.CompleteCaptureLinkFetchParams{
			ID:                 c.ID,
			Transcript:         pgtype.Text{String: content, Valid: true},
			LinkUrl:            pgtype.Text{String: target, Valid: true},
			TranscriptionModel: pgtype.Text{String: linkFetchModel, Valid: true},
		}); err != nil {
			return 0, err
		}
		// Transcript is now the capture's richest indexable content — re-embed it.
		w.rag.Index(c.UserID.String(), c.ID.String())
	}
}

// nextScheduledIn mirrors the transcription worker's helper: seconds until the
// earliest not-yet-claimable link job comes due, clamped to >=1s at the boundary
// so a due-but-invisible row is re-drained instead of treated as idle.
func (w *worker) nextScheduledIn(ctx context.Context) (time.Duration, error) {
	seconds, err := w.q.MinScheduledLinkFetchIn(ctx)
	if err != nil {
		return 0, err
	}
	if seconds <= 0 {
		return 0, nil
	}
	if wait := time.Duration(seconds * float64(time.Second)); wait > time.Second {
		return wait, nil
	}
	return time.Second, nil
}
