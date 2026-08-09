package capture

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
)

const (
	defaultSharePageSize = 50
	maxSharePageSize     = 100
	shareSecretBytes     = 32
)

type captureShareCursor struct {
	CreatedAt time.Time `json:"createdAt"`
	ID        uuid.UUID `json:"id"`
}

type CaptureShareBody struct {
	ID              string  `json:"id"`
	CaptureID       string  `json:"captureId"`
	SnapshotRawText string  `json:"snapshotRawText"`
	CapturedAt      string  `json:"capturedAt"`
	ExpiresAt       *string `json:"expiresAt"`
	CreatedAt       string  `json:"createdAt"`
	Secret          string  `json:"secret" doc:"Bearer secret placed in the URL fragment; returned only to the authenticated owner"`
	URL             string  `json:"url" doc:"Canonical public Web URL, including the fragment secret; returned only to the authenticated owner"`
}

type CaptureShareCreateInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		ExpiresIn       string `json:"expiresIn" enum:"1d,7d,30d,never" default:"7d"`
		SnapshotRawText string `json:"snapshotRawText" minLength:"1" doc:"Exact Capture text previewed and explicitly approved by the owner"`
	}
}

type CaptureShareCreateOutput struct {
	Body CaptureShareBody
}

type CaptureShareListInput struct {
	CaptureID string `query:"captureId" format:"uuid" doc:"Optional exact Capture filter used by the share dialog"`
	Cursor    string `query:"cursor"`
	Limit     int    `query:"limit" minimum:"1" maximum:"100" default:"50"`
}

type CaptureSharePageBody struct {
	Items      []CaptureShareBody `json:"items"`
	NextCursor *string            `json:"nextCursor"`
}

type CaptureShareListOutput struct {
	Body CaptureSharePageBody
}

type CaptureShareRevokeInput struct {
	ID string `path:"id" format:"uuid"`
}

type PublicCaptureShareInput struct {
	ID            string `path:"id"`
	Authorization string `header:"Authorization"`
}

type PublicCaptureShareBody struct {
	SnapshotRawText string  `json:"snapshotRawText"`
	CapturedAt      string  `json:"capturedAt"`
	ExpiresAt       *string `json:"expiresAt"`
}

type PublicCaptureShareOutput struct {
	Body PublicCaptureShareBody
}

func (h *handler) createShare(ctx context.Context, input *CaptureShareCreateInput) (*CaptureShareCreateOutput, error) {
	if h.frontendURL == "" {
		return nil, huma.Error503ServiceUnavailable("Capture sharing is not configured")
	}
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	captureID, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	now := time.Now().UTC()
	expiresAt, err := parseShareExpiry(input.Body.ExpiresIn, now)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(input.Body.SnapshotRawText) == "" {
		return nil, huma.Error422UnprocessableEntity("snapshotRawText must not be empty")
	}
	secret, err := newCaptureShareSecret()
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}

	var share db.CaptureShare
	err = pgx.BeginFunc(ctx, h.pool, func(tx pgx.Tx) error {
		q := h.q.WithTx(tx)
		capture, getErr := q.GetShareableCaptureForUpdate(ctx, db.GetShareableCaptureForUpdateParams{
			CaptureID: captureID,
			UserID:    uid,
		})
		if getErr != nil {
			return getErr
		}
		if revokeErr := q.RevokeActiveCaptureShares(ctx, db.RevokeActiveCaptureSharesParams{
			CaptureID: captureID,
			UserID:    uid,
		}); revokeErr != nil {
			return revokeErr
		}
		share, getErr = q.CreateCaptureShare(ctx, db.CreateCaptureShareParams{
			ID:              uuid.New(),
			UserID:          uid,
			CaptureID:       captureID,
			Secret:          secret,
			SnapshotRawText: input.Body.SnapshotRawText,
			CapturedAt:      capture.CreatedAt,
			ExpiresAt:       expiresAt,
		})
		return getErr
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("capture not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}

	return &CaptureShareCreateOutput{Body: h.captureShareBody(share)}, nil
}

func (h *handler) listShares(ctx context.Context, input *CaptureShareListInput) (*CaptureShareListOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	limit := input.Limit
	if limit == 0 {
		limit = defaultSharePageSize
	}
	if limit < 1 || limit > maxSharePageSize {
		return nil, huma.Error422UnprocessableEntity("limit must be between 1 and 100")
	}

	var captureID pgtype.UUID
	if input.CaptureID != "" {
		parsed, parseErr := uuid.Parse(input.CaptureID)
		if parseErr != nil {
			return nil, huma.Error422UnprocessableEntity("invalid captureId")
		}
		captureID = pgtype.UUID{Bytes: parsed, Valid: true}
	}
	var cursorCreatedAt pgtype.Timestamptz
	var cursorID pgtype.UUID
	if input.Cursor != "" {
		cursor, decodeErr := decodeCaptureShareCursor(input.Cursor)
		if decodeErr != nil {
			return nil, huma.Error422UnprocessableEntity("invalid cursor")
		}
		cursorCreatedAt = pgtype.Timestamptz{Time: cursor.CreatedAt, Valid: true}
		cursorID = pgtype.UUID{Bytes: cursor.ID, Valid: true}
	}

	shares, err := h.q.ListCaptureSharesPage(ctx, db.ListCaptureSharesPageParams{
		UserID:          uid,
		CaptureID:       captureID,
		CursorCreatedAt: cursorCreatedAt,
		CursorID:        cursorID,
		PageSize:        int32(limit + 1),
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	hasMore := len(shares) > limit
	if hasMore {
		shares = shares[:limit]
	}
	out := &CaptureShareListOutput{Body: CaptureSharePageBody{
		Items: make([]CaptureShareBody, len(shares)),
	}}
	for i, share := range shares {
		out.Body.Items[i] = h.captureShareBody(share)
	}
	if hasMore && len(shares) > 0 {
		next, encodeErr := encodeCaptureShareCursor(shares[len(shares)-1])
		if encodeErr != nil {
			return nil, huma.Error500InternalServerError("internal error")
		}
		out.Body.NextCursor = &next
	}
	return out, nil
}

func (h *handler) revokeShare(ctx context.Context, input *CaptureShareRevokeInput) (*struct{}, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error422UnprocessableEntity("invalid id")
	}
	if _, err = h.q.RevokeCaptureShare(ctx, db.RevokeCaptureShareParams{ID: id, UserID: uid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("share not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	return nil, nil
}

func (h *handler) getPublicShare(ctx context.Context, input *PublicCaptureShareInput) (*PublicCaptureShareOutput, error) {
	id, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error404NotFound("not found")
	}
	share, err := h.q.GetPublicCaptureShare(ctx, id)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, huma.Error404NotFound("not found")
		}
		return nil, huma.Error500InternalServerError("internal error")
	}
	if !validShareAuthorization(share.Secret, input.Authorization) {
		return nil, huma.Error404NotFound("not found")
	}
	body := PublicCaptureShareBody{
		SnapshotRawText: share.SnapshotRawText,
		CapturedAt:      share.CapturedAt.Time.UTC().Format(time.RFC3339),
	}
	if share.ExpiresAt.Valid {
		expiresAt := share.ExpiresAt.Time.UTC().Format(time.RFC3339)
		body.ExpiresAt = &expiresAt
	}
	return &PublicCaptureShareOutput{Body: body}, nil
}

func parseShareExpiry(value string, now time.Time) (pgtype.Timestamptz, error) {
	switch value {
	case "", "7d":
		return pgtype.Timestamptz{Time: now.Add(7 * 24 * time.Hour), Valid: true}, nil
	case "1d":
		return pgtype.Timestamptz{Time: now.Add(24 * time.Hour), Valid: true}, nil
	case "30d":
		return pgtype.Timestamptz{Time: now.Add(30 * 24 * time.Hour), Valid: true}, nil
	case "never":
		return pgtype.Timestamptz{}, nil
	default:
		return pgtype.Timestamptz{}, huma.Error422UnprocessableEntity("invalid expiresIn")
	}
}

func (h *handler) captureShareBody(share db.CaptureShare) CaptureShareBody {
	body := CaptureShareBody{
		ID:              share.ID.String(),
		CaptureID:       share.CaptureID.String(),
		SnapshotRawText: share.SnapshotRawText,
		CapturedAt:      share.CapturedAt.Time.UTC().Format(time.RFC3339),
		CreatedAt:       share.CreatedAt.Time.UTC().Format(time.RFC3339),
		Secret:          share.Secret,
		URL:             h.frontendURL + "/s/" + share.ID.String() + "#" + share.Secret,
	}
	if share.ExpiresAt.Valid {
		expiresAt := share.ExpiresAt.Time.UTC().Format(time.RFC3339)
		body.ExpiresAt = &expiresAt
	}
	return body
}

func newCaptureShareSecret() (string, error) {
	value := make([]byte, shareSecretBytes)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func validShareAuthorization(expectedSecret, authorization string) bool {
	const scheme = "Share "
	if !strings.HasPrefix(authorization, scheme) {
		return false
	}
	provided, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(authorization, scheme))
	if err != nil {
		return false
	}
	expected, err := base64.RawURLEncoding.DecodeString(expectedSecret)
	return err == nil && hmac.Equal(provided, expected)
}

func encodeCaptureShareCursor(share db.CaptureShare) (string, error) {
	data, err := json.Marshal(captureShareCursor{
		CreatedAt: share.CreatedAt.Time.UTC(),
		ID:        share.ID,
	})
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(data), nil
}

func decodeCaptureShareCursor(value string) (captureShareCursor, error) {
	data, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return captureShareCursor{}, err
	}
	var cursor captureShareCursor
	if err := json.Unmarshal(data, &cursor); err != nil {
		return captureShareCursor{}, err
	}
	if cursor.CreatedAt.IsZero() || cursor.ID == uuid.Nil {
		return captureShareCursor{}, errors.New("cursor is incomplete")
	}
	return cursor, nil
}
