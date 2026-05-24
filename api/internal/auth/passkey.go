package auth

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
)

const passkeyChallengeTTL = 5 * time.Minute

type webauthnUser struct {
	id          []byte
	name        string
	credentials []webauthn.Credential
}

func (u *webauthnUser) WebAuthnID() []byte                         { return u.id }
func (u *webauthnUser) WebAuthnName() string                       { return u.name }
func (u *webauthnUser) WebAuthnDisplayName() string                { return u.name }
func (u *webauthnUser) WebAuthnCredentials() []webauthn.Credential { return u.credentials }

func dbPasskeysToCredentials(rows []db.Passkey) []webauthn.Credential {
	creds := make([]webauthn.Credential, 0, len(rows))
	for _, row := range rows {
		creds = append(creds, webauthn.Credential{
			ID:        row.CredentialID,
			PublicKey: row.PublicKey,
			Authenticator: webauthn.Authenticator{
				AAGUID:    row.Aaguid,
				SignCount: uint32(row.SignCount),
			},
		})
	}
	return creds
}

// --- register passkey begin ---

type PasskeyRegisterBeginOutput struct {
	Body struct {
		Options json.RawMessage `json:"options"`
	}
}

func (h *handler) passkeyRegisterBegin(ctx context.Context, _ *struct{}) (*PasskeyRegisterBeginOutput, error) {
	traceID := middleware.GetTraceID(ctx)

	if h.wan == nil {
		return nil, huma.Error500InternalServerError("passkeys not configured")
	}

	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	user, err := h.q.GetUserByID(ctx, uid)
	if err != nil {
		slog.ErrorContext(ctx, "failed to get user", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	existingPasskeys, err := h.q.GetPasskeysByUserID(ctx, uid)
	if err != nil {
		slog.ErrorContext(ctx, "failed to get passkeys", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	wanUser := &webauthnUser{
		id:          uid[:],
		name:        user.Email,
		credentials: dbPasskeysToCredentials(existingPasskeys),
	}

	creation, session, err := h.wan.BeginRegistration(wanUser)
	if err != nil {
		slog.ErrorContext(ctx, "webauthn begin registration failed", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	sessionJSON, err := json.Marshal(session)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	if err := h.rdb.Set(ctx, "passkey:reg:"+rawID, string(sessionJSON), passkeyChallengeTTL).Err(); err != nil {
		slog.ErrorContext(ctx, "failed to store passkey session", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	optionsJSON, err := json.Marshal(creation)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}

	out := &PasskeyRegisterBeginOutput{}
	out.Body.Options = optionsJSON
	return out, nil
}

// --- register passkey finish ---

type PasskeyRegisterFinishInput struct {
	Body struct {
		Credential json.RawMessage `json:"credential"`
		Name       string          `json:"name"`
	}
}

type PasskeyRegisterFinishOutput struct {
	Body struct {
		ID   string `json:"id"`
		Name string `json:"name"`
	}
}

func (h *handler) passkeyRegisterFinish(ctx context.Context, input *PasskeyRegisterFinishInput) (*PasskeyRegisterFinishOutput, error) {
	traceID := middleware.GetTraceID(ctx)

	if h.wan == nil {
		return nil, huma.Error500InternalServerError("passkeys not configured")
	}

	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	user, err := h.q.GetUserByID(ctx, uid)
	if err != nil {
		slog.ErrorContext(ctx, "failed to get user", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	sessionJSON, err := h.rdb.GetDel(ctx, "passkey:reg:"+rawID).Result()
	if err != nil {
		return nil, huma.Error400BadRequest("registration session expired")
	}

	var session webauthn.SessionData
	if err := json.Unmarshal([]byte(sessionJSON), &session); err != nil {
		return nil, huma.Error400BadRequest("invalid session")
	}

	existingPasskeys, err := h.q.GetPasskeysByUserID(ctx, uid)
	if err != nil {
		slog.ErrorContext(ctx, "failed to get passkeys", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	wanUser := &webauthnUser{
		id:          uid[:],
		name:        user.Email,
		credentials: dbPasskeysToCredentials(existingPasskeys),
	}

	parsedResponse, err := protocol.ParseCredentialCreationResponseBody(
		bytes.NewReader(input.Body.Credential),
	)
	if err != nil {
		slog.ErrorContext(ctx, "parse credential response failed", "traceId", traceID, "err", err)
		return nil, huma.Error400BadRequest("invalid credential response")
	}

	cred, err := h.wan.CreateCredential(wanUser, session, parsedResponse)
	if err != nil {
		slog.ErrorContext(ctx, "create credential failed", "traceId", traceID, "err", err)
		return nil, huma.Error400BadRequest("credential verification failed")
	}

	name := input.Body.Name
	if name == "" {
		name = "Passkey"
	}

	row, err := h.q.CreatePasskey(ctx, db.CreatePasskeyParams{
		UserID:       uid,
		CredentialID: cred.ID,
		PublicKey:    cred.PublicKey,
		Aaguid:       cred.Authenticator.AAGUID,
		SignCount:    int64(cred.Authenticator.SignCount),
		Name:         name,
	})
	if err != nil {
		slog.ErrorContext(ctx, "failed to store passkey", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	out := &PasskeyRegisterFinishOutput{}
	out.Body.ID = row.ID.String()
	out.Body.Name = row.Name
	return out, nil
}

// --- login passkey begin ---

type PasskeyLoginBeginOutput struct {
	Body struct {
		Options json.RawMessage `json:"options"`
	}
}

func (h *handler) passkeyLoginBegin(ctx context.Context, _ *struct{}) (*PasskeyLoginBeginOutput, error) {
	traceID := middleware.GetTraceID(ctx)

	if h.wan == nil {
		return nil, huma.Error500InternalServerError("passkeys not configured")
	}

	assertion, session, err := h.wan.BeginDiscoverableLogin()
	if err != nil {
		slog.ErrorContext(ctx, "webauthn begin login failed", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	sessionJSON, err := json.Marshal(session)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}

	challengeKey := "passkey:login:" + string(session.Challenge)
	if err := h.rdb.Set(ctx, challengeKey, string(sessionJSON), passkeyChallengeTTL).Err(); err != nil {
		slog.ErrorContext(ctx, "failed to store passkey login session", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	optionsJSON, err := json.Marshal(assertion)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}

	out := &PasskeyLoginBeginOutput{}
	out.Body.Options = optionsJSON
	return out, nil
}

// --- login passkey finish ---

type PasskeyLoginFinishInput struct {
	Body struct {
		Credential json.RawMessage `json:"credential"`
	}
}

type PasskeyLoginFinishOutput struct {
	Body struct {
		AccessToken string `json:"accessToken"`
	}
}

func (h *handler) passkeyLoginFinish(ctx context.Context, input *PasskeyLoginFinishInput) (*PasskeyLoginFinishOutput, error) {
	traceID := middleware.GetTraceID(ctx)

	if h.wan == nil {
		return nil, huma.Error500InternalServerError("passkeys not configured")
	}

	if h.rdb != nil {
		r, _ := responseWriter(ctx)
		ip := clientIP(r)
		key := "pk:login:ip:" + ip
		count, err := h.rdb.Incr(ctx, key).Result()
		if err == nil {
			if count == 1 {
				h.rdb.Expire(ctx, key, 15*time.Minute)
			}
			if count > 10 {
				return nil, huma.NewError(http.StatusTooManyRequests, "too many attempts, try again later")
			}
		}
	}

	parsedResponse, err := protocol.ParseCredentialRequestResponseBody(
		bytes.NewReader(input.Body.Credential),
	)
	if err != nil {
		slog.ErrorContext(ctx, "parse credential response failed", "traceId", traceID, "err", err)
		return nil, huma.Error400BadRequest("invalid credential response")
	}

	challengeKey := "passkey:login:" + string(parsedResponse.Response.CollectedClientData.Challenge)
	sessionJSON, err := h.rdb.GetDel(ctx, challengeKey).Result()
	if err != nil {
		return nil, huma.Error400BadRequest("login session expired")
	}

	var session webauthn.SessionData
	if err := json.Unmarshal([]byte(sessionJSON), &session); err != nil {
		return nil, huma.Error400BadRequest("invalid session")
	}

	userHandler := func(rawID, userHandle []byte) (webauthn.User, error) {
		uid, err := uuid.FromBytes(userHandle)
		if err != nil {
			return nil, err
		}
		user, err := h.q.GetUserByID(ctx, uid)
		if err != nil {
			return nil, err
		}
		passkeys, err := h.q.GetPasskeysByUserID(ctx, uid)
		if err != nil {
			return nil, err
		}
		return &webauthnUser{
			id:          uid[:],
			name:        user.Email,
			credentials: dbPasskeysToCredentials(passkeys),
		}, nil
	}

	cred, err := h.wan.ValidateDiscoverableLogin(userHandler, session, parsedResponse)
	if err != nil {
		slog.ErrorContext(ctx, "passkey login validation failed", "traceId", traceID, "err", err)
		return nil, huma.Error401Unauthorized("passkey verification failed")
	}

	passkeyRow, err := h.q.GetPasskeyByCredentialID(ctx, cred.ID)
	if err != nil {
		slog.ErrorContext(ctx, "failed to get passkey by credential ID", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	if err := h.q.UpdatePasskeySignCount(ctx, db.UpdatePasskeySignCountParams{
		ID:        passkeyRow.ID,
		SignCount: int64(cred.Authenticator.SignCount),
	}); err != nil {
		slog.ErrorContext(ctx, "failed to update sign count", "traceId", traceID, "err", err)
	}

	accessToken, err := NewAccessToken(passkeyRow.UserID.String(), h.secret)
	if err != nil {
		slog.ErrorContext(ctx, "access token generation failed", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	rawRefresh, hashedRefresh, err := NewRefreshToken()
	if err != nil {
		slog.ErrorContext(ctx, "refresh token generation failed", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	if _, err := h.q.CreateRefreshToken(ctx, db.CreateRefreshTokenParams{
		UserID:    passkeyRow.UserID,
		TokenHash: hashedRefresh,
		ExpiresAt: pgtype.Timestamptz{Time: time.Now().Add(RefreshTokenTTL), Valid: true},
	}); err != nil {
		slog.ErrorContext(ctx, "failed to store refresh token", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	setRefreshCookie(ctx, rawRefresh, RefreshTokenTTL)

	out := &PasskeyLoginFinishOutput{}
	out.Body.AccessToken = accessToken
	return out, nil
}

// --- list passkeys ---

type PasskeyInfo struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	CreatedAt string `json:"createdAt"`
}

type PasskeyListOutput struct {
	Body struct {
		Passkeys []PasskeyInfo `json:"passkeys"`
	}
}

func (h *handler) listPasskeys(ctx context.Context, _ *struct{}) (*PasskeyListOutput, error) {
	traceID := middleware.GetTraceID(ctx)

	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	rows, err := h.q.GetPasskeysByUserID(ctx, uid)
	if err != nil {
		slog.ErrorContext(ctx, "failed to get passkeys", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	passkeys := make([]PasskeyInfo, 0, len(rows))
	for _, row := range rows {
		passkeys = append(passkeys, PasskeyInfo{
			ID:        row.ID.String(),
			Name:      row.Name,
			CreatedAt: row.CreatedAt.Time.Format(time.RFC3339),
		})
	}

	out := &PasskeyListOutput{}
	out.Body.Passkeys = passkeys
	return out, nil
}

// --- delete passkey ---

type PasskeyDeleteInput struct {
	ID string `path:"id" format:"uuid"`
}

func (h *handler) deletePasskey(ctx context.Context, input *PasskeyDeleteInput) (*struct{}, error) {
	traceID := middleware.GetTraceID(ctx)

	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	passkeyID, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error400BadRequest("invalid passkey id")
	}

	if err := h.q.DeletePasskey(ctx, db.DeletePasskeyParams{
		ID:     passkeyID,
		UserID: uid,
	}); err != nil {
		slog.ErrorContext(ctx, "failed to delete passkey", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	return nil, nil
}

// --- rename passkey ---

type PasskeyRenameInput struct {
	ID   string `path:"id" format:"uuid"`
	Body struct {
		Name string `json:"name" minLength:"1" maxLength:"100"`
	}
}

func (h *handler) renamePasskey(ctx context.Context, input *PasskeyRenameInput) (*struct{}, error) {
	traceID := middleware.GetTraceID(ctx)

	rawID := middleware.GetUserID(ctx)
	uid, err := uuid.Parse(rawID)
	if err != nil {
		return nil, huma.Error401Unauthorized("unauthorized")
	}

	passkeyID, err := uuid.Parse(input.ID)
	if err != nil {
		return nil, huma.Error400BadRequest("invalid passkey id")
	}

	if err := h.q.RenamePasskey(ctx, db.RenamePasskeyParams{
		ID:     passkeyID,
		UserID: uid,
		Name:   input.Body.Name,
	}); err != nil {
		slog.ErrorContext(ctx, "failed to rename passkey", "traceId", traceID, "err", err)
		return nil, huma.Error500InternalServerError("internal error")
	}

	return nil, nil
}
