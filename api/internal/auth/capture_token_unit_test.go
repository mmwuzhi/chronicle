package auth_test

import (
	"context"
	"strings"
	"testing"

	"github.com/sikaoshenmi/chronicle/internal/auth"
)

func TestNewCaptureToken_FormatAndHash(t *testing.T) {
	raw, hashed, err := auth.NewCaptureToken()
	if err != nil {
		t.Fatalf("NewCaptureToken: %v", err)
	}
	if !strings.HasPrefix(raw, auth.CaptureTokenPrefix) {
		t.Fatalf("raw %q missing prefix %q", raw, auth.CaptureTokenPrefix)
	}
	if hashed == raw || hashed != auth.HashToken(raw) {
		t.Fatal("hashed must equal HashToken(raw) and differ from raw")
	}
	if raw2, _, _ := auth.NewCaptureToken(); raw2 == raw {
		t.Fatal("tokens must be unique")
	}
}

func TestValidateTokenOrPAT_JWTPassthrough(t *testing.T) {
	const secret = "unit-secret-long-enough"
	const userID = "11111111-1111-1111-1111-111111111111"

	jwt, err := auth.NewAccessToken(userID, secret)
	if err != nil {
		t.Fatalf("NewAccessToken: %v", err)
	}

	// q is nil: the JWT path must not touch the DB, and a non-prefixed garbage
	// value must be rejected by the prefix gate before any lookup (a nil-deref
	// panic here would prove the gate is missing).
	validate := auth.ValidateTokenOrPAT(secret, nil)

	got, err := validate(context.Background(), jwt)
	if err != nil {
		t.Fatalf("valid JWT rejected: %v", err)
	}
	if got != userID {
		t.Fatalf("got %q want %q", got, userID)
	}

	if _, err := validate(context.Background(), "not-a-jwt-not-a-token"); err == nil {
		t.Fatal("expected error for garbage credential")
	}
}
