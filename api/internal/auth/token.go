package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"time"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"

	"github.com/golang-jwt/jwt/v5"
)

const (
	// Access tokens stay short-lived (the documented 15-minute contract): a stolen
	// bearer token has no server-side revocation, so its blast radius is bounded by
	// expiry. Staying signed in is the 30-day refresh token's job — the web client
	// transparently exchanges it on a 401 (see web/src/lib/axios.ts).
	AccessTokenTTL  = 15 * time.Minute
	RefreshTokenTTL = 30 * 24 * time.Hour
)

// CaptureTokenPrefix tags long-lived capture tokens so secret scanners and the
// auth middleware can recognize one without a DB hit.
const CaptureTokenPrefix = "chr_cap_"

// errInvalidCaptureToken is returned when a capture token is malformed, unknown,
// or revoked. The middleware only checks for a non-nil error, so the message is
// internal.
var errInvalidCaptureToken = errors.New("invalid capture token")

type Claims struct {
	UserID string `json:"sub"`
	MFA    bool   `json:"mfa,omitempty"`
	jwt.RegisteredClaims
}

func newTokenWithClaims(userID, secret string, ttl time.Duration, mfa bool) (string, error) {
	claims := Claims{
		UserID: userID,
		MFA:    mfa,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(ttl)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(secret))
}

func NewAccessToken(userID, secret string) (string, error) {
	return newTokenWithClaims(userID, secret, AccessTokenTTL, false)
}

func ParseAccessToken(raw, secret string) (*Claims, error) {
	claims := &Claims{}
	token, err := jwt.ParseWithClaims(raw, claims, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, jwt.ErrSignatureInvalid
		}
		return []byte(secret), nil
	})
	if err != nil || !token.Valid {
		return nil, jwt.ErrTokenInvalidClaims
	}
	return claims, nil
}

// NewRefreshToken generates a cryptographically random token and returns both
// the raw value (sent to the client) and its SHA-256 hash (stored in DB).
func NewRefreshToken() (raw, hashed string, err error) {
	b := make([]byte, 32)
	if _, err = rand.Read(b); err != nil {
		return "", "", err
	}
	raw = hex.EncodeToString(b)
	hashed = HashRefreshToken(raw)
	return raw, hashed, nil
}

// ValidateToken returns a TokenValidator that parses an access token and
// returns the user ID, suitable for use with middleware.RequireAuthHuma.
func ValidateToken(secret string) func(raw string) (string, error) {
	return func(raw string) (string, error) {
		claims, err := ParseAccessToken(raw, secret)
		if err != nil {
			return "", err
		}
		if claims.MFA {
			return "", jwt.ErrTokenInvalidClaims
		}
		return claims.UserID, nil
	}
}

// HashToken returns the SHA-256 hex digest of a high-entropy bearer token. A
// fast hash is sufficient because the input is cryptographically random (32
// bytes), so there is nothing to brute-force — the same reasoning behind storing
// refresh tokens this way.
func HashToken(raw string) string {
	h := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(h[:])
}

func HashRefreshToken(raw string) string {
	return HashToken(raw)
}

// NewCaptureToken generates a long-lived capture token: the raw value (shown to
// the user exactly once and carried by headless clients as a Bearer credential)
// and its hash (stored). The raw value is prefixed with CaptureTokenPrefix.
func NewCaptureToken() (raw, hashed string, err error) {
	b := make([]byte, 32)
	if _, err = rand.Read(b); err != nil {
		return "", "", err
	}
	raw = CaptureTokenPrefix + hex.EncodeToString(b)
	hashed = HashToken(raw)
	return raw, hashed, nil
}

// ValidateTokenOrPAT returns a validator that accepts either a normal access JWT
// or a long-lived capture token (CaptureTokenPrefix). It is wired ONLY onto
// POST /captures (see capture.Register) — never onto read/mutate/account routes
// — so a capture token's blast radius is bounded to appending captures.
//
// JWTs are tried first; only a prefixed value falls through to a DB lookup, so
// garbage credentials never touch the database. Revocation is immediate: every
// request re-reads the hash with no caching.
func ValidateTokenOrPAT(secret string, q *db.Queries) func(ctx context.Context, raw string) (string, error) {
	validateJWT := ValidateToken(secret)
	return func(ctx context.Context, raw string) (string, error) {
		if userID, err := validateJWT(raw); err == nil {
			return userID, nil
		}
		if !strings.HasPrefix(raw, CaptureTokenPrefix) {
			return "", errInvalidCaptureToken
		}
		tok, err := q.GetCaptureTokenByHash(ctx, HashToken(raw))
		if err != nil {
			return "", errInvalidCaptureToken
		}
		// Best-effort last-used bump; detached so it never blocks or fails the
		// request, and survives the request context being canceled on response.
		go func() {
			c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = q.TouchCaptureTokenLastUsed(c, tok.ID)
		}()
		return tok.UserID.String(), nil
	}
}
