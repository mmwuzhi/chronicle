package auth

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	AccessTokenTTL  = 15 * time.Minute
	RefreshTokenTTL = 30 * 24 * time.Hour
)

type Claims struct {
	UserID string `json:"sub"`
	jwt.RegisteredClaims
}

func NewAccessToken(userID, secret string) (string, error) {
	claims := Claims{
		UserID: userID,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(AccessTokenTTL)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(secret))
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
		return claims.UserID, nil
	}
}

func HashRefreshToken(raw string) string {
	h := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(h[:])
}
