package importer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/capture"
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
)

type Service struct {
	pool *pgxpool.Pool
	q    *db.Queries
	cfg  Config
	rag  *ragclient.Client
}

func NewService(pool *pgxpool.Pool, cfg Config, rag *ragclient.Client) *Service {
	return &Service{pool: pool, q: db.New(pool), cfg: cfg, rag: rag}
}

func (s *Service) Import(
	ctx context.Context,
	userID, operationID uuid.UUID,
	inputPath, filename, contentType, inputHash string,
	location *time.Location,
) (*MarkdownImportResult, error) {
	if existing, getErr := s.q.GetImportOperation(ctx, operationID); getErr == nil {
		if existing.UserID != userID || existing.InputHash != inputHash {
			return nil, &ImportError{Status: 409, Title: "Idempotency-Key is already in use"}
		}
		if existing.Status == "completed" {
			return replayResult(existing.Result)
		}
		if existing.Status != "failed" && !(existing.Status == "processing" && existing.LeaseUntil.Valid && !existing.LeaseUntil.Time.After(time.Now())) {
			return nil, &ImportError{Status: 409, Title: "Idempotency-Key is already in use"}
		}
	} else if !errors.Is(getErr, pgx.ErrNoRows) {
		return nil, getErr
	}

	parsed, err := readInput(filename, inputPath, contentType, userID, operationID, location, s.cfg.MaxBytes)
	if err != nil {
		return nil, &ImportError{Status: 422, Title: "invalid Markdown import", Err: err}
	}
	claimToken := uuid.New()
	operation, err := s.q.ClaimMarkdownImportOperation(ctx, db.ClaimMarkdownImportOperationParams{
		ID: operationID, UserID: userID, InputHash: inputHash, ClaimToken: claimToken,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		existing, getErr := s.q.GetImportOperation(ctx, operationID)
		if getErr == nil && existing.UserID == userID &&
			existing.InputHash == inputHash && existing.Status == "completed" {
			return replayResult(existing.Result)
		}
		return nil, &ImportError{Status: 409, Title: "Idempotency-Key is already in use"}
	}
	if err != nil {
		return nil, err
	}

	failed := true
	defer func() {
		if !failed {
			return
		}
		failContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = s.q.FailMarkdownImportOperation(failContext, db.FailMarkdownImportOperationParams{
			LastError: "Markdown import did not complete",
			ID:        operation.ID, UserID: userID, InputHash: inputHash, ClaimToken: claimToken,
		})
	}()

	result := &MarkdownImportResult{
		OperationID:        operationID.String(),
		Created:            len(parsed.Notes),
		Skipped:            parsed.Skipped,
		FrontmatterApplied: parsed.FrontmatterApplied,
		AnalysisQueued:     s.rag.Enabled(),
		Issues:             parsed.Issues.list(),
		CreatedCaptureIDs:  make([]string, 0, len(parsed.Notes)),
	}
	createdIDs := make([]uuid.UUID, 0, len(parsed.Notes))
	importedAt := time.Now()
	err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		q := s.q.WithTx(tx)
		for _, importedNote := range parsed.Notes {
			createdAt := importedAt
			if importedNote.CreatedAt != "" {
				parsedCreatedAt, parseErr := time.Parse(time.RFC3339Nano, importedNote.CreatedAt)
				if parseErr != nil {
					return parseErr
				}
				createdAt = parsedCreatedAt
			}
			todoAt, doneAt := capture.DeriveTodoStamps(importedNote.RawText, importedAt)
			_, insertErr := q.InsertArchiveCapture(ctx, db.InsertArchiveCaptureParams{
				ID: importedNote.ID, UserID: userID,
				RawText:             pgtype.Text{String: importedNote.RawText, Valid: true},
				MediaType:           db.CaptureMediaTypeText,
				ClassifiedAs:        db.CaptureClassifiedAsUnclassified,
				CreatedAt:           pgtype.Timestamptz{Time: createdAt, Valid: true},
				Source:              markdownImportSource,
				TranscriptionStatus: db.TranscriptionStatusNone,
				RemindHide:          true,
				TodoAt:              todoAt, DoneAt: doneAt,
			})
			if insertErr != nil {
				return insertErr
			}
			createdIDs = append(createdIDs, importedNote.ID)
			result.CreatedCaptureIDs = append(result.CreatedCaptureIDs, importedNote.ID.String())
		}
		seenLinks := make(map[string]struct{})
		for _, importedNote := range parsed.Notes {
			for _, targetID := range importedNote.Targets {
				left, right := importedNote.ID, targetID
				if right.String() < left.String() {
					left, right = right, left
				}
				key := left.String() + ":" + right.String()
				if _, exists := seenLinks[key]; exists {
					continue
				}
				seenLinks[key] = struct{}{}
				if _, linkErr := q.InsertArchiveCaptureLink(ctx, db.InsertArchiveCaptureLinkParams{
					X: left, Y: right, UserID: userID,
					CreatedAt: pgtype.Timestamptz{Time: importedAt, Valid: true},
				}); linkErr == nil {
					result.Links++
				} else if !errors.Is(linkErr, pgx.ErrNoRows) {
					return linkErr
				}
			}
		}
		resultBytes, marshalErr := json.Marshal(result)
		if marshalErr != nil {
			return marshalErr
		}
		rows, completeErr := q.CompleteMarkdownImportOperation(ctx, db.CompleteMarkdownImportOperationParams{
			Result: resultBytes, CreatedCaptureIds: createdIDs,
			ID: operationID, UserID: userID, InputHash: inputHash, ClaimToken: claimToken,
		})
		if completeErr != nil {
			return completeErr
		}
		if rows != 1 {
			return fmt.Errorf("markdown import operation lost its lease")
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	failed = false
	s.rag.IndexBatchWithoutWebhooks(userID.String(), result.CreatedCaptureIDs)
	return result, nil
}

func (s *Service) Undo(ctx context.Context, userID, operationID uuid.UUID) (*MarkdownImportUndoResult, error) {
	operation, err := s.q.GetImportOperation(ctx, operationID)
	if errors.Is(err, pgx.ErrNoRows) || err == nil && operation.UserID != userID {
		return nil, &ImportError{Status: 404, Title: "Markdown import not found"}
	}
	if err != nil {
		return nil, err
	}
	if operation.Status == "undone" {
		return &MarkdownImportUndoResult{}, nil
	}
	if operation.Status != "completed" {
		return nil, &ImportError{Status: 409, Title: "Markdown import cannot be undone in its current state"}
	}
	result := &MarkdownImportUndoResult{}
	err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		q := s.q.WithTx(tx)
		trashed, deleteErr := q.SoftDeleteMarkdownImportCaptures(ctx, db.SoftDeleteMarkdownImportCapturesParams{
			UserID: userID, CaptureIds: operation.CreatedCaptureIds,
		})
		if deleteErr != nil {
			return deleteErr
		}
		result.Trashed = len(trashed)
		rows, markErr := q.MarkMarkdownImportUndone(ctx, db.MarkMarkdownImportUndoneParams{
			ID: operationID, UserID: userID,
		})
		if markErr != nil {
			return markErr
		}
		if rows != 1 {
			return fmt.Errorf("markdown import state changed during undo")
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	_ = s.rag.Invalidate(ctx, userID.String())
	return result, nil
}

func replayResult(data []byte) (*MarkdownImportResult, error) {
	var result MarkdownImportResult
	if err := json.Unmarshal(data, &result); err != nil {
		return nil, err
	}
	result.Replayed = true
	return &result, nil
}
