package archive

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/retrieval"
)

func (s *Service) Import(
	ctx context.Context,
	userID uuid.UUID,
	operationID uuid.UUID,
	archivePath string,
	archiveHash string,
) (*ImportResult, error) {
	data, err := readArchive(archivePath, s.cfg.MaxBytes)
	if err != nil {
		return nil, &ImportError{Status: 422, Title: "invalid Chronicle archive", Err: err}
	}
	defer data.reader.Close()

	claimToken := uuid.New()
	operation, err := s.q.ClaimArchiveImportOperation(ctx, db.ClaimArchiveImportOperationParams{
		ID:          operationID,
		UserID:      userID,
		ArchiveHash: archiveHash,
		ClaimToken:  claimToken,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		existing, getErr := s.q.GetArchiveImportOperation(ctx, operationID)
		if getErr != nil {
			return nil, &ImportError{Status: 409, Title: "Idempotency-Key is already in use"}
		}
		if existing.UserID == userID &&
			existing.ArchiveHash == archiveHash &&
			existing.Status == "completed" {
			var result ImportResult
			if unmarshalErr := json.Unmarshal(existing.Result, &result); unmarshalErr != nil {
				return nil, &ImportError{Status: 500, Title: "stored import result is invalid", Err: unmarshalErr}
			}
			return &result, nil
		}
		return nil, &ImportError{Status: 409, Title: "Idempotency-Key is already in use"}
	}
	if err != nil {
		return nil, err
	}

	failed := true
	defer func() {
		if failed {
			failContext, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			// The request error remains authoritative. This best-effort state
			// update only makes an immediate retry possible; the lease expiry is
			// the crash-safe fallback if the database is unavailable too.
			_, _ = s.q.FailArchiveImportOperation(
				failContext,
				db.FailArchiveImportOperationParams{
					ID:          operation.ID,
					UserID:      userID,
					ArchiveHash: archiveHash,
					LastError:   "archive import did not complete",
					ClaimToken:  claimToken,
				},
			)
		}
	}()

	decisions, idMap, result, err := s.planImport(ctx, userID, data)
	if err != nil {
		return nil, err
	}

	decisionsBySource := make(map[uuid.UUID]*importDecision, len(decisions))
	for index := range decisions {
		decisionsBySource[decisions[index].sourceID] = &decisions[index]
	}
	stagedKeys := make([]string, 0)
	err = forEachNDJSON(data.files[capturesPath], func(record CaptureRecord) error {
		sourceID, parseErr := uuid.Parse(record.ID)
		if parseErr != nil {
			return parseErr
		}
		decision := decisionsBySource[sourceID]
		if decision == nil || !decision.create || record.MediaPath == nil {
			return nil
		}
		if s.s3 == nil || s.cfg.BucketName == "" || s.cfg.PublicBaseURL == "" {
			return &ImportError{Status: 503, Title: "object storage is required to restore media"}
		}
		mediaFile := data.files[*record.MediaPath]
		contentType, mediaType, detectErr := detectArchiveMedia(mediaFile)
		if detectErr != nil {
			return detectErr
		}
		if mediaType != record.MediaType {
			return fmt.Errorf("capture %s media bytes do not match mediaType", record.ID)
		}
		reader, openErr := mediaFile.Open()
		if openErr != nil {
			return openErr
		}
		key := restoredMediaKey(
			userID,
			decision.targetID,
			claimToken,
			*record.MediaSHA256,
			contentType,
		)
		_, putErr := s.s3.PutObject(ctx, &s3.PutObjectInput{
			Bucket:      aws.String(s.cfg.BucketName),
			Key:         aws.String(key),
			Body:        reader,
			ContentType: aws.String(contentType),
		})
		closeErr := reader.Close()
		if putErr != nil {
			// A failed S3 response can still follow a committed object write.
			// Include the current deterministic key in best-effort cleanup.
			s.cleanupStagedMedia(append(stagedKeys, key))
			return &ImportError{Status: 502, Title: "storage upload failed", Err: putErr}
		}
		if closeErr != nil {
			s.cleanupStagedMedia(append(stagedKeys, key))
			return closeErr
		}
		decision.mediaKey = key
		decision.mediaURL, err = publicObjectURL(s.cfg.PublicBaseURL, key)
		if err != nil {
			s.cleanupStagedMedia(append(stagedKeys, key))
			return err
		}
		stagedKeys = append(stagedKeys, key)
		result.Media++
		return nil
	})
	if err != nil {
		return nil, err
	}

	err = pgx.BeginFunc(ctx, s.pool, func(tx pgx.Tx) error {
		q := s.q.WithTx(tx)
		if insertErr := forEachNDJSON(data.files[capturesPath], func(record CaptureRecord) error {
			sourceID, parseErr := uuid.Parse(record.ID)
			if parseErr != nil {
				return parseErr
			}
			decision := decisionsBySource[sourceID]
			if decision == nil || !decision.create {
				return nil
			}
			params, paramsErr := archiveCaptureParams(userID, *decision, record)
			if paramsErr != nil {
				return paramsErr
			}
			if _, insertErr := q.InsertArchiveCapture(ctx, params); insertErr != nil {
				return insertErr
			}
			return nil
		}); insertErr != nil {
			return insertErr
		}
		if insertErr := forEachNDJSON(data.files[attachmentsPath], func(attachment AttachmentRecord) error {
			sourceCaptureID, parseErr := uuid.Parse(attachment.CaptureID)
			if parseErr != nil {
				return parseErr
			}
			targetCaptureID := idMap[sourceCaptureID]
			params, paramsErr := archiveAttachmentParams(
				userID,
				targetCaptureID,
				attachment,
			)
			if paramsErr != nil {
				return paramsErr
			}
			if _, insertErr := q.InsertArchiveCaptureAttachment(ctx, params); insertErr == nil {
				result.Attachments++
			} else if !errors.Is(insertErr, pgx.ErrNoRows) {
				return insertErr
			}
			return nil
		}); insertErr != nil {
			return insertErr
		}
		if insertErr := forEachNDJSON(data.files[linksPath], func(link LinkRecord) error {
			sourceA, parseErr := uuid.Parse(link.AID)
			if parseErr != nil {
				return parseErr
			}
			sourceB, parseErr := uuid.Parse(link.BID)
			if parseErr != nil {
				return parseErr
			}
			createdAt, parseErr := parseTimestamp(link.CreatedAt)
			if parseErr != nil {
				return parseErr
			}
			applied, insertErr := restoreArchiveLink(
				ctx, q, userID, idMap[sourceA], idMap[sourceB], createdAt,
			)
			if insertErr != nil && !errors.Is(insertErr, pgx.ErrNoRows) {
				return insertErr
			}
			if applied {
				result.Links++
			}
			return nil
		}); insertErr != nil {
			return insertErr
		}
		if data.manifest.FormatVersion >= 2 {
			if lockErr := q.LockSearchDismissals(ctx, userID); lockErr != nil {
				return lockErr
			}
			if insertErr := forEachNDJSON(data.files[dismissalsPath], func(record RetrievalDismissalRecord) error {
				targetID := idMap[uuid.MustParse(record.TargetID)]
				createdAt, parseErr := parseTimestamp(record.CreatedAt)
				if parseErr != nil {
					return parseErr
				}
				var rows int64
				var insertErr error
				switch record.Surface {
				case "search":
					rows, insertErr = q.InsertArchiveSearchDismissal(ctx, db.InsertArchiveSearchDismissalParams{
						UserID: userID, QueryHash: retrieval.QueryHash(userID, *record.Query),
						QueryText: *record.Query, TargetID: targetID, CreatedAt: createdAt,
					})
				case "related":
					anchorID := idMap[uuid.MustParse(*record.AnchorID)]
					// Version 2 stores both directions. Restore each undirected pair once.
					if anchorID.String() > targetID.String() {
						return nil
					}
					var applied bool
					applied, rows, insertErr = restoreArchiveRelatedDismissal(
						ctx, q, userID, anchorID, targetID, createdAt,
					)
					if !applied {
						rows = 0
					}
				}
				if insertErr != nil {
					return insertErr
				}
				result.Dismissals += int(rows)
				return nil
			}); insertErr != nil {
				return insertErr
			}
			if pruneErr := q.PruneSearchDismissals(ctx, db.PruneSearchDismissalsParams{
				UserID: userID, KeepLimit: retrieval.MaxSearchDismissalsPerUser,
			}); pruneErr != nil {
				return pruneErr
			}
		}
		resultBytes, marshalErr := json.Marshal(result)
		if marshalErr != nil {
			return marshalErr
		}
		rows, completeErr := q.CompleteArchiveImportOperation(
			ctx,
			db.CompleteArchiveImportOperationParams{
				IDMap:       []byte(`{}`),
				Result:      resultBytes,
				ID:          operationID,
				UserID:      userID,
				ArchiveHash: archiveHash,
				ClaimToken:  claimToken,
			},
		)
		if completeErr != nil {
			return completeErr
		}
		if rows != 1 {
			return errors.New("archive import operation lost its lease")
		}
		return nil
	})
	if err != nil {
		// COMMIT can succeed while its acknowledgement is lost. Confirm the
		// durable operation state before deleting claim-scoped objects; an
		// unknown state intentionally leaks temporary objects rather than
		// corrupting captures that may have committed.
		if completed, stored := s.completedImportResult(operationID, userID, archiveHash); completed {
			failed = false
			return stored, nil
		}
		if s.claimStillOwned(operationID, claimToken) {
			s.cleanupStagedMedia(stagedKeys)
		}
		return nil, err
	}
	failed = false

	var indexIDs []string
	for _, decision := range decisions {
		if decision.create && decision.active {
			indexIDs = append(indexIDs, decision.targetID.String())
		}
	}
	s.rag.IndexBatchWithoutWebhooks(userID.String(), indexIDs)
	return result, nil
}

func restoreArchiveLink(
	ctx context.Context,
	q *db.Queries,
	userID, first, second uuid.UUID,
	createdAt pgtype.Timestamptz,
) (bool, error) {
	if err := q.LockCapturePair(ctx, db.LockCapturePairParams{
		UserID: userID, X: first, Y: second,
	}); err != nil {
		return false, err
	}
	state, err := q.GetArchiveCapturePairState(ctx, db.GetArchiveCapturePairStateParams{
		UserID: userID, X: first, Y: second,
	})
	if err != nil {
		return false, err
	}
	if state.DismissalCreatedAt.Valid && state.DismissalCreatedAt.Time.After(createdAt.Time) {
		return false, nil
	}
	if err := q.RemoveRelatedDismissal(ctx, db.RemoveRelatedDismissalParams{
		UserID: userID, AnchorID: first, TargetID: second,
	}); err != nil {
		return false, err
	}
	_, err = q.InsertArchiveCaptureLink(ctx, db.InsertArchiveCaptureLinkParams{
		X: first, Y: second, UserID: userID, CreatedAt: createdAt,
	})
	return err == nil, err
}

func restoreArchiveRelatedDismissal(
	ctx context.Context,
	q *db.Queries,
	userID, first, second uuid.UUID,
	createdAt pgtype.Timestamptz,
) (bool, int64, error) {
	if err := q.LockCapturePair(ctx, db.LockCapturePairParams{
		UserID: userID, X: first, Y: second,
	}); err != nil {
		return false, 0, err
	}
	state, err := q.GetArchiveCapturePairState(ctx, db.GetArchiveCapturePairStateParams{
		UserID: userID, X: first, Y: second,
	})
	if err != nil {
		return false, 0, err
	}
	if state.LinkCreatedAt.Valid && state.LinkCreatedAt.Time.After(createdAt.Time) {
		return false, 0, nil
	}
	if err := q.RemoveCaptureLink(ctx, db.RemoveCaptureLinkParams{
		UserID: userID, X: first, Y: second,
	}); err != nil {
		return false, 0, err
	}
	rows, err := q.InsertArchiveRelatedDismissalPair(
		ctx, db.InsertArchiveRelatedDismissalPairParams{
			UserID: userID, X: first, Y: second, CreatedAt: createdAt,
		})
	return err == nil, rows, err
}

func (s *Service) completedImportResult(
	operationID, userID uuid.UUID,
	archiveHash string,
) (bool, *ImportResult) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	operation, err := s.q.GetArchiveImportOperation(ctx, operationID)
	if err != nil ||
		operation.UserID != userID ||
		operation.ArchiveHash != archiveHash ||
		operation.Status != "completed" {
		return false, nil
	}
	var result ImportResult
	if json.Unmarshal(operation.Result, &result) != nil {
		return false, nil
	}
	return true, &result
}

func (s *Service) claimStillOwned(operationID, claimToken uuid.UUID) bool {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	operation, err := s.q.GetArchiveImportOperation(ctx, operationID)
	return err == nil && operation.Status == "processing" && operation.ClaimToken == claimToken
}

func (s *Service) planImport(
	ctx context.Context,
	userID uuid.UUID,
	data *archiveData,
) ([]importDecision, map[uuid.UUID]uuid.UUID, *ImportResult, error) {
	decisions := make([]importDecision, 0, data.manifest.Counts.Captures)
	idMap := make(map[uuid.UUID]uuid.UUID, data.manifest.Counts.Captures)
	result := &ImportResult{Warnings: []string{}, CreatedCaptureID: []string{}}

	err := forEachNDJSON(data.files[capturesPath], func(record CaptureRecord) error {
		sourceID, err := uuid.Parse(record.ID)
		if err != nil {
			return err
		}
		decision := importDecision{
			sourceID: sourceID,
			targetID: sourceID,
			create:   true,
			active:   record.DeletedAt == nil,
		}
		owner, ownerErr := s.q.GetCaptureOwner(ctx, sourceID)
		switch {
		case errors.Is(ownerErr, pgx.ErrNoRows):
		case ownerErr != nil:
			return ownerErr
		case owner.UserID != userID:
			var alreadyRestored bool
			decision.targetID, alreadyRestored, err = s.availableForkID(ctx, userID, sourceID, record)
			if err != nil {
				return err
			}
			decision.create = !alreadyRestored
			decision.forked = !alreadyRestored
		default:
			existing, getErr := s.q.GetCaptureAnyState(ctx, db.GetCaptureAnyStateParams{
				ID: sourceID, UserID: userID,
			})
			if getErr != nil {
				return getErr
			}
			same, compareErr := s.captureMatches(ctx, existing, record)
			if compareErr != nil {
				return compareErr
			}
			if same {
				decision.create = false
			} else {
				var alreadyRestored bool
				decision.targetID, alreadyRestored, err = s.availableForkID(ctx, userID, sourceID, record)
				if err != nil {
					return err
				}
				decision.create = !alreadyRestored
				decision.forked = !alreadyRestored
			}
		}
		idMap[sourceID] = decision.targetID
		switch {
		case !decision.create:
			result.Skipped++
		case decision.forked:
			result.Forked++
			result.Created++
			result.CreatedCaptureID = append(result.CreatedCaptureID, decision.targetID.String())
		default:
			result.Created++
			result.CreatedCaptureID = append(result.CreatedCaptureID, decision.targetID.String())
		}
		decisions = append(decisions, decision)
		return nil
	})
	if err != nil {
		return nil, nil, nil, err
	}
	return decisions, idMap, result, nil
}

func (s *Service) availableForkID(
	ctx context.Context,
	userID uuid.UUID,
	sourceID uuid.UUID,
	record CaptureRecord,
) (uuid.UUID, bool, error) {
	digest, err := captureContentDigest(record)
	if err != nil {
		return uuid.Nil, false, err
	}
	for salt := 0; salt < 100; salt++ {
		name := fmt.Sprintf("archive-capture:%s:%s:%d", sourceID, digest, salt)
		candidate := uuid.NewSHA1(userID, []byte(name))
		owner, err := s.q.GetCaptureOwner(ctx, candidate)
		if errors.Is(err, pgx.ErrNoRows) {
			return candidate, false, nil
		}
		if err != nil {
			return uuid.Nil, false, err
		}
		if owner.UserID != userID {
			continue
		}
		existing, err := s.q.GetCaptureAnyState(ctx, db.GetCaptureAnyStateParams{
			ID: candidate, UserID: userID,
		})
		if err != nil {
			return uuid.Nil, false, err
		}
		matches, err := s.captureMatches(ctx, existing, record)
		if err != nil {
			return uuid.Nil, false, err
		}
		if matches {
			return candidate, true, nil
		}
	}
	return uuid.Nil, false, errors.New("could not allocate a conflict-free capture ID")
}

func (s *Service) captureMatches(
	ctx context.Context,
	existing db.Capture,
	record CaptureRecord,
) (bool, error) {
	existingRecord := captureRecord(existing)
	if existing.MediaKey.Valid {
		if s.s3 == nil || s.cfg.BucketName == "" {
			return false, &ImportError{Status: 503, Title: "object storage is required to compare media"}
		}
		output, err := s.s3.GetObject(ctx, &s3.GetObjectInput{
			Bucket: aws.String(s.cfg.BucketName),
			Key:    aws.String(existing.MediaKey.String),
		})
		if err != nil {
			return false, err
		}
		sum, err := hashReader(output.Body)
		closeErr := output.Body.Close()
		if err != nil {
			return false, err
		}
		if closeErr != nil {
			return false, closeErr
		}
		contentType := aws.ToString(output.ContentType)
		if contentType == "" {
			contentType = "application/octet-stream"
		}
		existingRecord.MediaSHA256 = &sum
		existingRecord.MediaContentType = &contentType
	} else if existing.MediaUrl.Valid {
		existingRecord.LegacyMediaURL = &existing.MediaUrl.String
	}
	existingDigest, err := captureContentDigest(existingRecord)
	if err != nil {
		return false, err
	}
	importDigest, err := captureContentDigest(record)
	if err != nil {
		return false, err
	}
	return existingDigest == importDigest, nil
}

func archiveCaptureParams(
	userID uuid.UUID,
	decision importDecision,
	record CaptureRecord,
) (db.InsertArchiveCaptureParams, error) {
	createdAt, err := parseTimestamp(record.CreatedAt)
	if err != nil {
		return db.InsertArchiveCaptureParams{}, err
	}
	transcribedAt, err := parseOptionalTimestamp(record.TranscribedAt)
	if err != nil {
		return db.InsertArchiveCaptureParams{}, err
	}
	nextTranscriptionAt, err := parseOptionalTimestamp(record.NextTranscriptionAt)
	if err != nil {
		return db.InsertArchiveCaptureParams{}, err
	}
	remindAt, err := parseOptionalTimestamp(record.RemindAt)
	if err != nil {
		return db.InsertArchiveCaptureParams{}, err
	}
	deletedAt, err := parseOptionalTimestamp(record.DeletedAt)
	if err != nil {
		return db.InsertArchiveCaptureParams{}, err
	}
	todoAt, err := parseOptionalTimestamp(record.TodoAt)
	if err != nil {
		return db.InsertArchiveCaptureParams{}, err
	}
	doneAt, err := parseOptionalTimestamp(record.DoneAt)
	if err != nil {
		return db.InsertArchiveCaptureParams{}, err
	}

	status := db.TranscriptionStatus(record.TranscriptionStatus)
	if status == db.TranscriptionStatusProcessing {
		status = db.TranscriptionStatusPending
		nextTranscriptionAt = pgtype.Timestamptz{Time: time.Now(), Valid: true}
	}
	attempts := record.TranscriptionAttempts
	if status == db.TranscriptionStatusPending {
		attempts = 0
		nextTranscriptionAt = pgtype.Timestamptz{Time: time.Now(), Valid: true}
	}
	var mediaURL *string
	var mediaKey *string
	if record.MediaPath != nil {
		mediaURL = &decision.mediaURL
		mediaKey = &decision.mediaKey
	} else {
		mediaURL = record.LegacyMediaURL
	}
	return db.InsertArchiveCaptureParams{
		ID:                    decision.targetID,
		UserID:                userID,
		RawText:               nullableText(record.RawText),
		MediaUrl:              nullableText(mediaURL),
		MediaType:             db.CaptureMediaType(record.MediaType),
		ClassifiedAs:          db.CaptureClassifiedAs(record.ClassifiedAs),
		CreatedAt:             createdAt,
		Source:                record.Source,
		Transcript:            nullableText(record.Transcript),
		TranscriptionStatus:   status,
		TranscriptionModel:    nullableText(record.TranscriptionModel),
		TranscriptionAttempts: attempts,
		TranscribedAt:         transcribedAt,
		NextTranscriptionAt:   nextTranscriptionAt,
		AudioDurationSec:      nullableInt4(record.AudioDurationSec),
		MediaKey:              nullableText(mediaKey),
		RemindAt:              remindAt,
		DeletedAt:             deletedAt,
		RemindHide:            record.RemindHide,
		TodoAt:                todoAt,
		DoneAt:                doneAt,
		LinkUrl:               nullableText(record.LinkURL),
	}, nil
}

func archiveAttachmentParams(
	userID uuid.UUID,
	targetCaptureID uuid.UUID,
	record AttachmentRecord,
) (db.InsertArchiveCaptureAttachmentParams, error) {
	sourceID, err := uuid.Parse(record.ID)
	if err != nil {
		return db.InsertArchiveCaptureAttachmentParams{}, err
	}
	createdAt, err := parseTimestamp(record.CreatedAt)
	if err != nil {
		return db.InsertArchiveCaptureAttachmentParams{}, err
	}
	deletedAt, err := parseOptionalTimestamp(record.DeletedAt)
	if err != nil {
		return db.InsertArchiveCaptureAttachmentParams{}, err
	}
	return db.InsertArchiveCaptureAttachmentParams{
		ID:             uuid.NewSHA1(targetCaptureID, []byte("archive-attachment:"+sourceID.String())),
		UserID:         userID,
		CaptureID:      targetCaptureID,
		Provider:       db.CloudDriveProvider(record.Provider),
		ProviderFileID: record.ProviderFileID,
		Name:           record.Name,
		MimeType:       nullableText(record.MimeType),
		SizeBytes:      nullableInt8(record.SizeBytes),
		WebUrl:         record.WebURL,
		CreatedAt:      createdAt,
		DeletedAt:      deletedAt,
	}, nil
}
