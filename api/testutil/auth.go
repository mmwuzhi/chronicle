package testutil

import (
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const TestJWTSecret = "test-jwt-secret-long-enough"

// MakeToken creates a signed JWT for use in tests.
func MakeToken(t *testing.T, userID string) string {
	t.Helper()
	claims := jwt.MapClaims{
		"sub": userID,
		"exp": time.Now().Add(time.Hour).Unix(),
		"iat": time.Now().Unix(),
	}
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(TestJWTSecret))
	if err != nil {
		t.Fatalf("testutil: make token: %v", err)
	}
	return token
}
