package archive

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
)

const archivePageSize = 500

func (s *Service) Export(ctx context.Context, userID uuid.UUID) (*ExportFile, error) {
	temp, err := os.CreateTemp("", "chronicle-export-*.zip")
	if err != nil {
		return nil, err
	}
	tempPath := temp.Name()
	cleanup := true
	defer func() {
		if cleanup {
			_ = temp.Close()
			_ = os.Remove(tempPath)
		}
	}()

	writer := zip.NewWriter(temp)
	manifest, checksums, err := s.writeExport(ctx, writer, userID)
	if err != nil {
		_ = writer.Close()
		return nil, err
	}
	manifestBytes, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		_ = writer.Close()
		return nil, err
	}
	manifestBytes = append(manifestBytes, '\n')
	if err := addZipBytes(writer, manifestPath, manifestBytes, checksums); err != nil {
		_ = writer.Close()
		return nil, err
	}
	if _, err := addZipReader(writer, checksumsPath, bytes.NewReader(renderChecksums(checksums))); err != nil {
		_ = writer.Close()
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	if err := temp.Close(); err != nil {
		return nil, err
	}
	verified, err := readArchive(tempPath, 0)
	if err != nil {
		return nil, fmt.Errorf("verify completed archive: %w", err)
	}
	if err := verified.reader.Close(); err != nil {
		return nil, fmt.Errorf("close verified archive: %w", err)
	}

	cleanup = false
	return &ExportFile{
		Path:     tempPath,
		Filename: "chronicle-" + time.Now().UTC().Format("20060102-150405") + ".zip",
	}, nil
}

func (s *Service) writeExport(
	ctx context.Context,
	writer *zip.Writer,
	userID uuid.UUID,
) (Manifest, map[string]string, error) {
	checksums := make(map[string]string)
	counts := ManifestCounts{}
	err := pgx.BeginTxFunc(ctx, s.pool, pgx.TxOptions{
		IsoLevel:   pgx.RepeatableRead,
		AccessMode: pgx.ReadOnly,
	}, func(tx pgx.Tx) error {
		q := s.q.WithTx(tx)
		captureFile, err := os.CreateTemp("", "chronicle-captures-*.ndjson")
		if err != nil {
			return err
		}
		defer func() {
			_ = captureFile.Close()
			_ = os.Remove(captureFile.Name())
		}()
		notesFile, err := os.CreateTemp("", "chronicle-notes-*.md")
		if err != nil {
			return err
		}
		defer func() {
			_ = notesFile.Close()
			_ = os.Remove(notesFile.Name())
		}()
		if _, err := io.WriteString(notesFile, "# Chronicle Captures\n\n"); err != nil {
			return err
		}

		captureEncoder := json.NewEncoder(captureFile)
		var afterCreatedAt pgtype.Timestamptz
		var afterID uuid.UUID
		for {
			page, err := q.ListArchiveCapturesPage(ctx, db.ListArchiveCapturesPageParams{
				UserID:         userID,
				AfterCreatedAt: afterCreatedAt,
				AfterID:        afterID,
				PageSize:       archivePageSize,
			})
			if err != nil {
				return err
			}
			for _, capture := range page {
				counts.Captures++
				if counts.Captures > maxArchiveRecords {
					return &ImportError{Status: 413, Title: "account has too many Captures to export"}
				}
				record := captureRecord(capture)
				switch {
				case capture.MediaKey.Valid:
					if s.s3 == nil || s.cfg.BucketName == "" {
						return &ImportError{Status: 503, Title: "object storage is required to export media"}
					}
					output, getErr := s.s3.GetObject(ctx, &s3.GetObjectInput{
						Bucket: aws.String(s.cfg.BucketName),
						Key:    aws.String(capture.MediaKey.String),
					})
					if getErr != nil {
						return fmt.Errorf("read media for capture %s: %w", capture.ID, getErr)
					}
					contentType := aws.ToString(output.ContentType)
					if contentType == "" {
						contentType = "application/octet-stream"
					}
					mediaPath := path.Join("media", capture.ID.String()+mediaExtension(capture.MediaKey.String))
					sum, addErr := addZipReader(writer, mediaPath, output.Body)
					closeErr := output.Body.Close()
					if addErr != nil {
						return addErr
					}
					if closeErr != nil {
						return closeErr
					}
					checksums[mediaPath] = sum
					record.MediaPath = &mediaPath
					record.MediaSHA256 = &sum
					record.MediaContentType = &contentType
					counts.Media++
				case capture.MediaUrl.Valid:
					return &ImportError{
						Status: 422,
						Title:  "legacy external media cannot be included in a complete archive",
					}
				}
				if err := captureEncoder.Encode(record); err != nil {
					return err
				}
				if _, err := fmt.Fprintf(notesFile, "## Capture %s\n\n", record.ID); err != nil {
					return err
				}
				if _, err := notesFile.Write(renderNote(record)); err != nil {
					return err
				}
				if _, err := io.WriteString(notesFile, "\n---\n\n"); err != nil {
					return err
				}
			}
			if len(page) < archivePageSize {
				break
			}
			last := page[len(page)-1]
			afterCreatedAt = last.CreatedAt
			afterID = last.ID
		}
		if err := addTempFile(writer, capturesPath, captureFile, checksums); err != nil {
			return err
		}
		if err := addTempFile(writer, notesPath, notesFile, checksums); err != nil {
			return err
		}

		linkSum, err := addZipGenerated(writer, linksPath, func(output io.Writer) error {
			encoder := json.NewEncoder(output)
			var afterCreatedAt pgtype.Timestamptz
			var afterAID, afterBID uuid.UUID
			for {
				page, err := q.ListArchiveCaptureLinksPage(ctx, db.ListArchiveCaptureLinksPageParams{
					UserID:         userID,
					AfterCreatedAt: afterCreatedAt,
					AfterAID:       afterAID,
					AfterBID:       afterBID,
					PageSize:       archivePageSize,
				})
				if err != nil {
					return err
				}
				for _, link := range page {
					counts.Links++
					if counts.Links > maxArchiveRecords {
						return &ImportError{Status: 413, Title: "account has too many Capture links to export"}
					}
					if err := encoder.Encode(linkRecord(link)); err != nil {
						return err
					}
				}
				if len(page) < archivePageSize {
					return nil
				}
				last := page[len(page)-1]
				afterCreatedAt = last.CreatedAt
				afterAID = last.AID
				afterBID = last.BID
			}
		})
		if err != nil {
			return err
		}
		checksums[linksPath] = linkSum

		attachmentSum, err := addZipGenerated(writer, attachmentsPath, func(output io.Writer) error {
			encoder := json.NewEncoder(output)
			var afterCreatedAt pgtype.Timestamptz
			var afterID uuid.UUID
			for {
				page, err := q.ListArchiveCaptureAttachmentsPage(ctx, db.ListArchiveCaptureAttachmentsPageParams{
					UserID:         userID,
					AfterCreatedAt: afterCreatedAt,
					AfterID:        afterID,
					PageSize:       archivePageSize,
				})
				if err != nil {
					return err
				}
				for _, attachment := range page {
					counts.Attachments++
					if counts.Attachments > maxArchiveRecords {
						return &ImportError{Status: 413, Title: "account has too many Capture attachments to export"}
					}
					if err := encoder.Encode(attachmentRecord(attachment)); err != nil {
						return err
					}
				}
				if len(page) < archivePageSize {
					return nil
				}
				last := page[len(page)-1]
				afterCreatedAt = last.CreatedAt
				afterID = last.ID
			}
		})
		if err != nil {
			return err
		}
		checksums[attachmentsPath] = attachmentSum

		dismissalSum, err := addZipGenerated(writer, dismissalsPath, func(output io.Writer) error {
			encoder := json.NewEncoder(output)
			var afterCreatedAt pgtype.Timestamptz
			var afterQueryHash []byte
			var afterTargetID uuid.UUID
			for {
				page, listErr := q.ListArchiveSearchDismissalsPage(
					ctx, db.ListArchiveSearchDismissalsPageParams{
						UserID: userID, AfterCreatedAt: afterCreatedAt,
						AfterQueryHash: afterQueryHash, AfterTargetID: afterTargetID,
						PageSize: archivePageSize,
					})
				if listErr != nil {
					return listErr
				}
				for _, row := range page {
					counts.Dismissals++
					if counts.Dismissals > maxArchiveRecords {
						return &ImportError{Status: 413, Title: "account has too many retrieval preferences to export"}
					}
					if err := encoder.Encode(retrievalDismissalRecord(row)); err != nil {
						return err
					}
				}
				if len(page) < archivePageSize {
					break
				}
				last := page[len(page)-1]
				afterCreatedAt = last.CreatedAt
				afterQueryHash = last.QueryHash
				afterTargetID = last.TargetID
			}

			afterCreatedAt = pgtype.Timestamptz{}
			var afterAnchorID uuid.UUID
			afterTargetID = uuid.Nil
			for {
				page, listErr := q.ListArchiveRelatedDismissalsPage(
					ctx, db.ListArchiveRelatedDismissalsPageParams{
						UserID: userID, AfterCreatedAt: afterCreatedAt,
						AfterAnchorID: afterAnchorID, AfterTargetID: afterTargetID,
						PageSize: archivePageSize,
					})
				if listErr != nil {
					return listErr
				}
				for _, row := range page {
					counts.Dismissals++
					if counts.Dismissals > maxArchiveRecords {
						return &ImportError{Status: 413, Title: "account has too many retrieval preferences to export"}
					}
					if err := encoder.Encode(retrievalDismissalRecord(row)); err != nil {
						return err
					}
				}
				if len(page) < archivePageSize {
					break
				}
				last := page[len(page)-1]
				afterCreatedAt = last.CreatedAt
				afterAnchorID = last.AnchorID.Bytes
				afterTargetID = last.TargetID
			}
			return nil
		})
		if err != nil {
			return err
		}
		checksums[dismissalsPath] = dismissalSum
		return nil
	})
	if err != nil {
		return Manifest{}, nil, err
	}
	return Manifest{
		Format:        formatName,
		FormatVersion: formatVersion,
		ExportedAt:    formatTime(time.Now()),
		IncludesTrash: true,
		MediaComplete: true,
		Counts:        counts,
	}, checksums, nil
}

func addTempFile(
	writer *zip.Writer,
	name string,
	file *os.File,
	checksums map[string]string,
) error {
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return err
	}
	sum, err := addZipReader(writer, name, file)
	if err != nil {
		return err
	}
	checksums[name] = sum
	return nil
}
