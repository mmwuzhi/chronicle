package archive

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/retrieval"
	"github.com/sikaoshenmi/chronicle/testutil"
)

type storedObject struct {
	data        []byte
	contentType string
}

type memoryStore struct {
	mu      sync.Mutex
	objects map[string]storedObject
	getErr  error
	putErr  error
}

func newMemoryStore() *memoryStore {
	return &memoryStore{objects: make(map[string]storedObject)}
}

func (store *memoryStore) PutObject(
	_ context.Context,
	input *s3.PutObjectInput,
	_ ...func(*s3.Options),
) (*s3.PutObjectOutput, error) {
	if store.putErr != nil {
		return nil, store.putErr
	}
	data, err := io.ReadAll(input.Body)
	if err != nil {
		return nil, err
	}
	store.mu.Lock()
	store.objects[aws.ToString(input.Key)] = storedObject{
		data:        data,
		contentType: aws.ToString(input.ContentType),
	}
	store.mu.Unlock()
	return &s3.PutObjectOutput{}, nil
}

func (store *memoryStore) GetObject(
	_ context.Context,
	input *s3.GetObjectInput,
	_ ...func(*s3.Options),
) (*s3.GetObjectOutput, error) {
	if store.getErr != nil {
		return nil, store.getErr
	}
	store.mu.Lock()
	object, exists := store.objects[aws.ToString(input.Key)]
	store.mu.Unlock()
	if !exists {
		return nil, errors.New("object not found")
	}
	return &s3.GetObjectOutput{
		Body:        io.NopCloser(bytes.NewReader(object.data)),
		ContentType: aws.String(object.contentType),
	}, nil
}

func (store *memoryStore) DeleteObject(
	_ context.Context,
	input *s3.DeleteObjectInput,
	_ ...func(*s3.Options),
) (*s3.DeleteObjectOutput, error) {
	store.mu.Lock()
	delete(store.objects, aws.ToString(input.Key))
	store.mu.Unlock()
	return &s3.DeleteObjectOutput{}, nil
}

func createArchiveUser(t *testing.T, q *db.Queries, email string) uuid.UUID {
	t.Helper()
	user, err := q.CreateUser(context.Background(), db.CreateUserParams{
		Email:        email,
		PasswordHash: pgtype.Text{String: "hash", Valid: true},
	})
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	return user.ID
}

func archiveCaptureParamsForTest(
	id, userID uuid.UUID,
	text string,
	createdAt time.Time,
) db.InsertArchiveCaptureParams {
	return db.InsertArchiveCaptureParams{
		ID:                  id,
		UserID:              userID,
		RawText:             pgtype.Text{String: text, Valid: true},
		MediaType:           db.CaptureMediaTypeText,
		ClassifiedAs:        db.CaptureClassifiedAsUnclassified,
		CreatedAt:           pgtype.Timestamptz{Time: createdAt, Valid: true},
		Source:              "web",
		TranscriptionStatus: db.TranscriptionStatusNone,
		RemindHide:          true,
	}
}

func fileSHA256(t *testing.T, filename string) string {
	t.Helper()
	file, err := os.Open(filename)
	if err != nil {
		t.Fatalf("open file: %v", err)
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		t.Fatalf("hash file: %v", err)
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func TestCaptureContentDigestPreservesUserEditedMediaTranscript(t *testing.T) {
	text := "capture"
	firstTranscript := "first transcript"
	secondTranscript := "corrected transcript"
	base := CaptureRecord{
		RawText:   &text,
		MediaType: string(db.CaptureMediaTypeAudio),
		CreatedAt: time.Date(2026, 7, 20, 9, 30, 0, 0, time.UTC).Format(time.RFC3339Nano),
		Source:    "web",
	}
	first := base
	first.Transcript = &firstTranscript
	second := base
	second.Transcript = &secondTranscript
	firstDigest, err := captureContentDigest(first)
	if err != nil {
		t.Fatal(err)
	}
	secondDigest, err := captureContentDigest(second)
	if err != nil {
		t.Fatal(err)
	}
	if firstDigest == secondDigest {
		t.Fatal("media transcript edit was ignored by conflict identity")
	}

	first.MediaType = string(db.CaptureMediaTypeText)
	second.MediaType = string(db.CaptureMediaTypeText)
	firstDigest, err = captureContentDigest(first)
	if err != nil {
		t.Fatal(err)
	}
	secondDigest, err = captureContentDigest(second)
	if err != nil {
		t.Fatal(err)
	}
	if firstDigest != secondDigest {
		t.Fatal("derived link transcript changed text-capture conflict identity")
	}
}

func TestArchiveRoundTripMergePreservesTrashMediaLinksAndAttachments(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "users")
	q := db.New(pool)
	sourceUser := createArchiveUser(t, q, "archive-source@test.com")
	targetUser := createArchiveUser(t, q, "archive-target@test.com")
	createdAt := time.Date(2026, 7, 20, 9, 30, 0, 0, time.UTC)
	textID := uuid.New()
	mediaID := uuid.New()
	relatedID := uuid.New()

	if _, err := q.InsertArchiveCapture(
		context.Background(),
		archiveCaptureParamsForTest(textID, sourceUser, "remember the blue door", createdAt),
	); err != nil {
		t.Fatalf("insert text capture: %v", err)
	}
	mediaParams := archiveCaptureParamsForTest(
		mediaID,
		sourceUser,
		"voice note",
		createdAt.Add(time.Minute),
	)
	mediaParams.MediaType = db.CaptureMediaTypeAudio
	mediaParams.MediaUrl = pgtype.Text{String: "https://old.invalid/audio.m4a", Valid: true}
	mediaParams.MediaKey = pgtype.Text{
		String: "captures/" + sourceUser.String() + "/" + mediaID.String() + ".m4a",
		Valid:  true,
	}
	mediaParams.Transcript = pgtype.Text{String: "meet at the station", Valid: true}
	mediaParams.TranscriptionStatus = db.TranscriptionStatusCompleted
	mediaParams.TranscriptionModel = pgtype.Text{String: "test-model", Valid: true}
	mediaParams.TranscribedAt = pgtype.Timestamptz{Time: createdAt.Add(time.Minute), Valid: true}
	mediaParams.AudioDurationSec = pgtype.Int4{Int32: 12, Valid: true}
	mediaParams.DeletedAt = pgtype.Timestamptz{Time: createdAt.Add(time.Hour), Valid: true}
	if _, err := q.InsertArchiveCapture(context.Background(), mediaParams); err != nil {
		t.Fatalf("insert media capture: %v", err)
	}
	if _, err := q.InsertArchiveCapture(
		context.Background(),
		archiveCaptureParamsForTest(
			relatedID, sourceUser, "unrelated reference", createdAt.Add(90*time.Second),
		),
	); err != nil {
		t.Fatalf("insert related capture: %v", err)
	}
	if _, err := q.InsertArchiveCaptureLink(context.Background(), db.InsertArchiveCaptureLinkParams{
		X: textID, Y: mediaID, UserID: sourceUser,
		CreatedAt: pgtype.Timestamptz{Time: createdAt.Add(2 * time.Minute), Valid: true},
	}); err != nil {
		t.Fatalf("insert link: %v", err)
	}
	if _, err := q.InsertArchiveCaptureAttachment(
		context.Background(),
		db.InsertArchiveCaptureAttachmentParams{
			ID:             uuid.New(),
			UserID:         sourceUser,
			CaptureID:      textID,
			Provider:       db.CloudDriveProviderGoogleDrive,
			ProviderFileID: "drive-file",
			Name:           "reference.pdf",
			MimeType:       pgtype.Text{String: "application/pdf", Valid: true},
			SizeBytes:      pgtype.Int8{Int64: 42, Valid: true},
			WebUrl:         "https://drive.example/reference",
			CreatedAt:      pgtype.Timestamptz{Time: createdAt, Valid: true},
		},
	); err != nil {
		t.Fatalf("insert attachment: %v", err)
	}
	query := "blue door"
	if err := q.AddSearchDismissal(context.Background(), db.AddSearchDismissalParams{
		UserID: sourceUser, QueryHash: retrieval.QueryHash(sourceUser, query),
		QueryText: pgtype.Text{String: query, Valid: true}, TargetID: textID,
	}); err != nil {
		t.Fatalf("insert search preference: %v", err)
	}
	if err := q.AddRelatedDismissal(context.Background(), db.AddRelatedDismissalParams{
		UserID: sourceUser, AnchorID: textID, TargetID: relatedID,
	}); err != nil {
		t.Fatalf("insert related preference: %v", err)
	}

	store := newMemoryStore()
	audioBytes := []byte{0, 0, 0, 0, 'f', 't', 'y', 'p', 'M', '4', 'A', ' ', 0, 0, 0, 0}
	store.objects[mediaParams.MediaKey.String] = storedObject{
		data:        audioBytes,
		contentType: "audio/mp4",
	}
	service := NewService(pool, store, Config{
		BucketName:    "archive-test",
		PublicBaseURL: "https://media.example",
		MaxBytes:      32 << 20,
	}, nil)
	exported, err := service.Export(context.Background(), sourceUser)
	if err != nil {
		t.Fatalf("export: %v", err)
	}
	defer os.Remove(exported.Path)

	operationID := uuid.New()
	result, err := service.Import(
		context.Background(),
		targetUser,
		operationID,
		exported.Path,
		fileSHA256(t, exported.Path),
	)
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	if result.Created != 3 || result.Forked != 3 || result.Skipped != 0 {
		t.Fatalf("unexpected merge result: %+v", result)
	}
	if result.Media != 1 || result.Links != 1 || result.Attachments != 1 || result.Dismissals != 3 {
		t.Fatalf("relationships were not restored: %+v", result)
	}

	restored, err := q.ListArchiveCaptures(context.Background(), targetUser)
	if err != nil {
		t.Fatalf("list restored captures: %v", err)
	}
	if len(restored) != 3 {
		t.Fatalf("restored %d captures, want 3", len(restored))
	}
	var restoredMedia db.Capture
	for _, capture := range restored {
		if capture.MediaType == db.CaptureMediaTypeAudio {
			restoredMedia = capture
		}
	}
	if !restoredMedia.DeletedAt.Valid {
		t.Fatal("trashed media capture was restored as active")
	}
	if !restoredMedia.MediaKey.Valid || !restoredMedia.MediaUrl.Valid {
		t.Fatal("restored media is missing remapped storage fields")
	}
	store.mu.Lock()
	restoredObject := store.objects[restoredMedia.MediaKey.String]
	store.mu.Unlock()
	if !bytes.Equal(restoredObject.data, audioBytes) {
		t.Fatalf("restored media bytes = %x", restoredObject.data)
	}
	preferences, err := q.ListArchiveRetrievalDismissals(context.Background(), targetUser)
	if err != nil {
		t.Fatalf("list restored retrieval preferences: %v", err)
	}
	if len(preferences) != 3 {
		t.Fatalf("restored %d retrieval preferences, want 3", len(preferences))
	}
	searchFound := false
	for _, preference := range preferences {
		if preference.Surface == "search" {
			searchFound = preference.QueryText.Valid && preference.QueryText.String == query &&
				bytes.Equal(preference.QueryHash, retrieval.QueryHash(targetUser, query))
		}
	}
	if !searchFound {
		t.Fatal("search preference was not re-hashed for the importing account")
	}

	failingTarget := createArchiveUser(t, q, "archive-storage-failure@test.com")
	failingStore := newMemoryStore()
	failingStore.putErr = errors.New("storage unavailable")
	failingService := NewService(pool, failingStore, Config{
		BucketName:    "archive-test",
		PublicBaseURL: "https://media.example",
		MaxBytes:      32 << 20,
	}, nil)
	if _, err := failingService.Import(
		context.Background(),
		failingTarget,
		uuid.New(),
		exported.Path,
		fileSHA256(t, exported.Path),
	); err == nil {
		t.Fatal("import succeeded despite storage upload failure")
	}
	failedCaptures, err := q.ListArchiveCaptures(context.Background(), failingTarget)
	if err != nil {
		t.Fatalf("list failed target captures: %v", err)
	}
	if len(failedCaptures) != 0 {
		t.Fatalf("storage failure committed %d captures", len(failedCaptures))
	}

	replayed, err := service.Import(
		context.Background(),
		targetUser,
		operationID,
		exported.Path,
		fileSHA256(t, exported.Path),
	)
	if err != nil {
		t.Fatalf("replay import: %v", err)
	}
	if replayed.Created != result.Created || replayed.Forked != result.Forked {
		t.Fatalf("replayed result changed: %+v", replayed)
	}
	afterReplay, err := q.ListArchiveCaptures(context.Background(), targetUser)
	if err != nil {
		t.Fatalf("list after replay: %v", err)
	}
	if len(afterReplay) != 3 {
		t.Fatalf("idempotent replay created duplicates: %d captures", len(afterReplay))
	}

	newOperationResult, err := service.Import(
		context.Background(),
		targetUser,
		uuid.New(),
		exported.Path,
		fileSHA256(t, exported.Path),
	)
	if err != nil {
		t.Fatalf("new-operation import: %v", err)
	}
	if newOperationResult.Created != 0 || newOperationResult.Skipped != 3 {
		t.Fatalf("same archive with a new operation was not skipped: %+v", newOperationResult)
	}
	afterNewOperation, err := q.ListArchiveCaptures(context.Background(), targetUser)
	if err != nil {
		t.Fatalf("list after new operation: %v", err)
	}
	if len(afterNewOperation) != 3 {
		t.Fatalf("new operation created duplicate captures: %d", len(afterNewOperation))
	}

	sameUserResult, err := service.Import(
		context.Background(),
		sourceUser,
		uuid.New(),
		exported.Path,
		fileSHA256(t, exported.Path),
	)
	if err != nil {
		t.Fatalf("same-user import: %v", err)
	}
	if sameUserResult.Skipped != 3 || sameUserResult.Created != 0 {
		t.Fatalf("identical captures were not skipped: %+v", sameUserResult)
	}
}

func TestArchiveClaimTokenFencesCompletionAndMediaKeys(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "archive_import_operations", "users")
	q := db.New(pool)
	userID := createArchiveUser(t, q, "archive-fence@test.com")
	operationID := uuid.New()
	firstClaim := uuid.New()
	secondClaim := uuid.New()
	archiveHash := strings.Repeat("a", 64)

	if _, err := q.ClaimArchiveImportOperation(context.Background(), db.ClaimArchiveImportOperationParams{
		ID: operationID, UserID: userID, ArchiveHash: archiveHash, ClaimToken: firstClaim,
	}); err != nil {
		t.Fatalf("claim operation: %v", err)
	}
	rows, err := q.CompleteArchiveImportOperation(context.Background(), db.CompleteArchiveImportOperationParams{
		IDMap: []byte(`{}`), Result: []byte(`{}`), ID: operationID, UserID: userID,
		ArchiveHash: archiveHash, ClaimToken: secondClaim,
	})
	if err != nil {
		t.Fatalf("complete with stale token: %v", err)
	}
	if rows != 0 {
		t.Fatalf("stale claim completed %d rows", rows)
	}

	digest := strings.Repeat("b", 64)
	captureID := uuid.New()
	firstKey := restoredMediaKey(userID, captureID, firstClaim, digest, "image/png")
	secondKey := restoredMediaKey(userID, captureID, secondClaim, digest, "image/png")
	if firstKey == secondKey {
		t.Fatal("different import claims reused one media key")
	}
	if !strings.Contains(firstKey, "/"+firstClaim.String()+"/") {
		t.Fatalf("media key is not claim-scoped: %s", firstKey)
	}
	if !strings.HasSuffix(firstKey, ".png") {
		t.Fatalf("media key extension = %s", firstKey)
	}
}

func TestReadArchiveRejectsPathTraversalAndChecksumMismatch(t *testing.T) {
	traversal, err := os.CreateTemp("", "chronicle-traversal-*.zip")
	if err != nil {
		t.Fatal(err)
	}
	traversalName := traversal.Name()
	writer := zip.NewWriter(traversal)
	entry, err := writer.Create("../outside")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := entry.Write([]byte("bad")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := traversal.Close(); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(traversalName)
	if _, err := readArchive(traversalName, 1<<20); err == nil ||
		!strings.Contains(err.Error(), "invalid archive path") {
		t.Fatalf("path traversal error = %v", err)
	}

	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "users")
	q := db.New(pool)
	userID := createArchiveUser(t, q, "archive-checksum@test.com")
	if _, err := q.InsertArchiveCapture(
		context.Background(),
		archiveCaptureParamsForTest(uuid.New(), userID, "checksum source", time.Now()),
	); err != nil {
		t.Fatal(err)
	}
	service := NewService(pool, nil, Config{MaxBytes: 8 << 20}, nil)
	exported, err := service.Export(context.Background(), userID)
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(exported.Path)
	tampered := rewriteZipEntry(t, exported.Path, capturesPath, func(data []byte) []byte {
		return bytes.Replace(data, []byte("checksum source"), []byte("tampered source"), 1)
	})
	defer os.Remove(tampered)
	if _, err := readArchive(tampered, 8<<20); err == nil ||
		!strings.Contains(err.Error(), "checksum") {
		t.Fatalf("checksum error = %v", err)
	}
}

func TestReadArchiveRejectsNegativeManifestCounts(t *testing.T) {
	temp, err := os.CreateTemp("", "chronicle-negative-count-*.zip")
	if err != nil {
		t.Fatal(err)
	}
	archivePath := temp.Name()
	defer os.Remove(archivePath)

	writer := zip.NewWriter(temp)
	checksums := make(map[string]string)
	manifest := Manifest{
		Format:        formatName,
		FormatVersion: formatVersion,
		ExportedAt:    formatTime(time.Now()),
		IncludesTrash: true,
		MediaComplete: true,
		Counts:        ManifestCounts{Captures: -1},
	}
	manifestBytes, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{
		manifestPath:    manifestBytes,
		capturesPath:    {},
		linksPath:       {},
		attachmentsPath: {},
		dismissalsPath:  {},
		notesPath:       []byte("# Chronicle Captures\n"),
	} {
		if err := addZipBytes(writer, name, data, checksums); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := addZipReader(writer, checksumsPath, bytes.NewReader(renderChecksums(checksums))); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := temp.Close(); err != nil {
		t.Fatal(err)
	}

	if _, err := readArchive(archivePath, 1<<20); err == nil ||
		!strings.Contains(err.Error(), "count is out of range") {
		t.Fatalf("negative manifest count error = %v", err)
	}
}

func TestReadArchiveAcceptsVersionOneWithoutRetrievalPreferences(t *testing.T) {
	temp, err := os.CreateTemp(t.TempDir(), "chronicle-v1-*.zip")
	if err != nil {
		t.Fatal(err)
	}
	archivePath := temp.Name()
	writer := zip.NewWriter(temp)
	checksums := make(map[string]string)
	manifestBytes, err := json.Marshal(Manifest{
		Format: formatName, FormatVersion: 1, ExportedAt: formatTime(time.Now()),
		IncludesTrash: true, MediaComplete: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{
		manifestPath: manifestBytes, capturesPath: {}, linksPath: {},
		attachmentsPath: {}, notesPath: []byte("# Chronicle Captures\n"),
	} {
		if err := addZipBytes(writer, name, data, checksums); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := addZipReader(
		writer, checksumsPath, bytes.NewReader(renderChecksums(checksums)),
	); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := temp.Close(); err != nil {
		t.Fatal(err)
	}

	data, err := readArchive(archivePath, 1<<20)
	if err != nil {
		t.Fatalf("read v1 archive: %v", err)
	}
	_ = data.reader.Close()
}

func TestExportFailsWhenOwnedMediaCannotBeRead(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "users")
	q := db.New(pool)
	userID := createArchiveUser(t, q, "archive-storage@test.com")
	params := archiveCaptureParamsForTest(uuid.New(), userID, "missing media", time.Now())
	params.MediaType = db.CaptureMediaTypeImage
	params.MediaKey = pgtype.Text{String: "captures/missing.png", Valid: true}
	params.MediaUrl = pgtype.Text{String: "https://media.example/missing.png", Valid: true}
	if _, err := q.InsertArchiveCapture(context.Background(), params); err != nil {
		t.Fatal(err)
	}
	store := newMemoryStore()
	store.getErr = errors.New("storage unavailable")
	service := NewService(pool, store, Config{BucketName: "test", MaxBytes: 1 << 20}, nil)
	if _, err := service.Export(context.Background(), userID); err == nil ||
		!strings.Contains(err.Error(), "storage unavailable") {
		t.Fatalf("export error = %v", err)
	}
}

func TestArchiveExportPaginatesEqualTimestampsWithoutDroppingCaptures(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "users")
	q := db.New(pool)
	userID := createArchiveUser(t, q, "archive-pagination@test.com")
	createdAt := time.Date(2026, 7, 20, 9, 30, 0, 0, time.UTC)
	for index := 0; index < archivePageSize+1; index++ {
		if _, err := q.InsertArchiveCapture(
			context.Background(),
			archiveCaptureParamsForTest(
				uuid.New(),
				userID,
				fmt.Sprintf("capture %d", index),
				createdAt,
			),
		); err != nil {
			t.Fatalf("insert capture %d: %v", index, err)
		}
	}
	service := NewService(pool, nil, Config{MaxBytes: 32 << 20}, nil)
	exported, err := service.Export(context.Background(), userID)
	if err != nil {
		t.Fatalf("export: %v", err)
	}
	defer os.Remove(exported.Path)
	data, err := readArchive(exported.Path, 32<<20)
	if err != nil {
		t.Fatalf("read exported archive: %v", err)
	}
	defer data.reader.Close()
	if data.manifest.Counts.Captures != archivePageSize+1 {
		t.Fatalf("exported %d captures, want %d", data.manifest.Counts.Captures, archivePageSize+1)
	}
}

func TestArchiveExportPaginatesRetrievalPreferences(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "users")
	q := db.New(pool)
	userID := createArchiveUser(t, q, "archive-preference-pages@test.com")
	targetID := uuid.New()
	createdAt := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
	if _, err := q.InsertArchiveCapture(
		context.Background(),
		archiveCaptureParamsForTest(targetID, userID, "preference target", createdAt),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(context.Background(), `
		INSERT INTO retrieval_dismissals (
			user_id, surface, query_hash, query_text, target_id, created_at
		)
		SELECT $1, 'search', convert_to(format('query-%s', value), 'UTF8'),
			format('query-%s', value), $2, $3
		FROM generate_series(1, $4::integer) AS value`,
		userID, targetID, createdAt, archivePageSize+1,
	); err != nil {
		t.Fatalf("insert preferences: %v", err)
	}

	service := NewService(pool, nil, Config{MaxBytes: 32 << 20}, nil)
	exported, err := service.Export(context.Background(), userID)
	if err != nil {
		t.Fatalf("export: %v", err)
	}
	defer os.Remove(exported.Path)
	data, err := readArchive(exported.Path, 32<<20)
	if err != nil {
		t.Fatalf("read exported archive: %v", err)
	}
	defer data.reader.Close()
	if data.manifest.Counts.Dismissals != archivePageSize+1 {
		t.Fatalf(
			"exported %d preferences, want %d",
			data.manifest.Counts.Dismissals, archivePageSize+1,
		)
	}
}

func TestArchiveExportRejectsContradictoryOrAsymmetricRelatedPreferences(t *testing.T) {
	for _, testCase := range []struct {
		name     string
		withLink bool
		want     string
	}{
		{name: "asymmetric", want: "missing its matching reverse record"},
		{name: "contradictory", withLink: true, want: "both linked and dismissed"},
	} {
		t.Run(testCase.name, func(t *testing.T) {
			pool := testutil.NewPool(t)
			testutil.Truncate(t, pool, "captures", "users")
			q := db.New(pool)
			userID := createArchiveUser(t, q, "archive-"+testCase.name+"@test.com")
			first, second := uuid.New(), uuid.New()
			createdAt := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
			for _, id := range []uuid.UUID{first, second} {
				if _, err := q.InsertArchiveCapture(
					context.Background(),
					archiveCaptureParamsForTest(id, userID, "pair", createdAt),
				); err != nil {
					t.Fatal(err)
				}
			}
			if testCase.withLink {
				if _, err := q.InsertArchiveCaptureLink(
					context.Background(), db.InsertArchiveCaptureLinkParams{
						X: first, Y: second, UserID: userID,
						CreatedAt: pgtype.Timestamptz{Time: createdAt, Valid: true},
					},
				); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := q.InsertArchiveRelatedDismissal(
				context.Background(), db.InsertArchiveRelatedDismissalParams{
					UserID: userID, AnchorID: first, TargetID: second,
					CreatedAt: pgtype.Timestamptz{Time: createdAt, Valid: true},
				},
			); err != nil {
				t.Fatal(err)
			}

			service := NewService(pool, nil, Config{MaxBytes: 32 << 20}, nil)
			_, err := service.Export(context.Background(), userID)
			if err == nil || !strings.Contains(err.Error(), testCase.want) {
				t.Fatalf("export error = %v, want %q", err, testCase.want)
			}
		})
	}
}

func TestArchiveImportPrunesMergedSearchPreferencesToRuntimeLimit(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "users")
	q := db.New(pool)
	sourceUser := createArchiveUser(t, q, "archive-prune-source@test.com")
	targetUser := createArchiveUser(t, q, "archive-prune-target@test.com")
	createdAt := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
	sourceTarget, existingTarget := uuid.New(), uuid.New()
	if _, err := q.InsertArchiveCapture(
		context.Background(),
		archiveCaptureParamsForTest(sourceTarget, sourceUser, "source target", createdAt),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := q.InsertArchiveCapture(
		context.Background(),
		archiveCaptureParamsForTest(existingTarget, targetUser, "existing target", createdAt),
	); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(context.Background(), `
		INSERT INTO retrieval_dismissals (
			user_id, surface, query_hash, query_text, target_id, created_at
		)
		SELECT $1, 'search', convert_to(format('source-%s', value), 'UTF8'),
			format('source-%s', value), $2, $3::timestamptz + value * interval '1 second'
		FROM generate_series(1, 10) AS value`,
		sourceUser, sourceTarget, createdAt,
	); err != nil {
		t.Fatalf("insert source preferences: %v", err)
	}
	if _, err := pool.Exec(context.Background(), `
		INSERT INTO retrieval_dismissals (
			user_id, surface, query_hash, query_text, target_id, created_at
		)
		SELECT $1, 'search', convert_to(format('existing-%s', value), 'UTF8'),
			format('existing-%s', value), $2, $3::timestamptz + value * interval '1 second'
		FROM generate_series(1, 999) AS value`,
		targetUser, existingTarget, createdAt,
	); err != nil {
		t.Fatalf("insert existing preferences: %v", err)
	}

	service := NewService(pool, nil, Config{MaxBytes: 32 << 20}, nil)
	exported, err := service.Export(context.Background(), sourceUser)
	if err != nil {
		t.Fatalf("export: %v", err)
	}
	defer os.Remove(exported.Path)
	if _, err := service.Import(
		context.Background(), targetUser, uuid.New(), exported.Path,
		fileSHA256(t, exported.Path),
	); err != nil {
		t.Fatalf("import: %v", err)
	}
	var count int
	if err := pool.QueryRow(context.Background(), `
		SELECT count(*) FROM retrieval_dismissals
		WHERE user_id = $1 AND surface = 'search'`, targetUser).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != retrieval.MaxSearchDismissalsPerUser {
		t.Fatalf("search preferences after import = %d", count)
	}
}

func TestArchiveRelationshipRestoreKeepsNewestPairState(t *testing.T) {
	pool := testutil.NewPool(t)
	testutil.Truncate(t, pool, "captures", "users")
	q := db.New(pool)
	userID := createArchiveUser(t, q, "archive-pair-state@test.com")
	first, second := uuid.New(), uuid.New()
	base := time.Date(2026, 8, 1, 0, 0, 0, 0, time.UTC)
	for _, id := range []uuid.UUID{first, second} {
		if _, err := q.InsertArchiveCapture(
			context.Background(), archiveCaptureParamsForTest(id, userID, "pair", base),
		); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := q.InsertArchiveCaptureLink(
		context.Background(), db.InsertArchiveCaptureLinkParams{
			X: first, Y: second, UserID: userID,
			CreatedAt: pgtype.Timestamptz{Time: base.Add(2 * time.Hour), Valid: true},
		},
	); err != nil {
		t.Fatal(err)
	}

	applyDismissal := func(at time.Time) (bool, int64) {
		t.Helper()
		var applied bool
		var rows int64
		err := pgx.BeginFunc(context.Background(), pool, func(tx pgx.Tx) error {
			var err error
			applied, rows, err = restoreArchiveRelatedDismissal(
				context.Background(), q.WithTx(tx), userID, first, second,
				pgtype.Timestamptz{Time: at, Valid: true},
			)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		return applied, rows
	}
	if applied, rows := applyDismissal(base.Add(time.Hour)); applied || rows != 0 {
		t.Fatalf("older dismissal applied=%v rows=%d", applied, rows)
	}
	if applied, rows := applyDismissal(base.Add(3 * time.Hour)); !applied || rows != 2 {
		t.Fatalf("newer dismissal applied=%v rows=%d", applied, rows)
	}

	applyLink := func(at time.Time) bool {
		t.Helper()
		var applied bool
		err := pgx.BeginFunc(context.Background(), pool, func(tx pgx.Tx) error {
			var err error
			applied, err = restoreArchiveLink(
				context.Background(), q.WithTx(tx), userID, first, second,
				pgtype.Timestamptz{Time: at, Valid: true},
			)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
		return applied
	}
	if applyLink(base.Add(2 * time.Hour)) {
		t.Fatal("older link replaced a newer dismissal")
	}
	if !applyLink(base.Add(4 * time.Hour)) {
		t.Fatal("newer link did not replace the older dismissal")
	}

	var links, dismissals int
	if err := pool.QueryRow(context.Background(), `
		SELECT count(*) FROM capture_links
		WHERE user_id = $1 AND a_id = LEAST($2::uuid, $3::uuid)
		  AND b_id = GREATEST($2::uuid, $3::uuid)`,
		userID, first, second,
	).Scan(&links); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(context.Background(), `
		SELECT count(*) FROM retrieval_dismissals
		WHERE user_id = $1 AND surface = 'related'
		  AND anchor_id IN ($2, $3) AND target_id IN ($2, $3)`,
		userID, first, second,
	).Scan(&dismissals); err != nil {
		t.Fatal(err)
	}
	if links != 1 || dismissals != 0 {
		t.Fatalf("final pair state links=%d dismissals=%d", links, dismissals)
	}
}

func rewriteZipEntry(
	t *testing.T,
	sourcePath string,
	targetName string,
	transform func([]byte) []byte,
) string {
	t.Helper()
	source, err := zip.OpenReader(sourcePath)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	target, err := os.CreateTemp("", "chronicle-tampered-*.zip")
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(target)
	for _, file := range source.File {
		reader, err := file.Open()
		if err != nil {
			t.Fatal(err)
		}
		data, err := io.ReadAll(reader)
		closeErr := reader.Close()
		if err != nil {
			t.Fatal(err)
		}
		if closeErr != nil {
			t.Fatal(closeErr)
		}
		if file.Name == targetName {
			data = transform(data)
		}
		entry, err := writer.Create(file.Name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := entry.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := target.Close(); err != nil {
		t.Fatal(err)
	}
	return target.Name()
}
