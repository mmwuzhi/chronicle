package auth

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/redis/go-redis/v9"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
)

var errEphemeralStateNotFound = errors.New("authentication state not found or expired")

var consumeMatchingLegacyState = redis.NewScript(`
local value = redis.call("GET", KEYS[1])
if not value or value ~= ARGV[1] then
  return 0
end
redis.call("DEL", KEYS[1])
return 1
`)

func authStateKeyHash(key string) []byte {
	sum := sha256.Sum256([]byte(key))
	return sum[:]
}

func (h *handler) rateLimitSubjectHash(scope, subject string) []byte {
	mac := hmac.New(sha256.New, []byte(h.secret))
	_, _ = mac.Write([]byte(scope))
	_, _ = mac.Write([]byte{0})
	_, _ = mac.Write([]byte(subject))
	return mac.Sum(nil)
}

func (h *handler) storeEphemeralState(
	ctx context.Context,
	purpose string,
	key string,
	payload []byte,
	ttl time.Duration,
) error {
	if legacyKey, ok := legacyEphemeralKey(purpose, key); h.legacyRedis != nil && ok {
		if err := h.legacyRedis.Set(ctx, legacyKey, payload, ttl).Err(); err != nil {
			return fmt.Errorf("store legacy authentication state: %w", err)
		}
		return nil
	}
	return h.q.StoreAuthEphemeralState(ctx, db.StoreAuthEphemeralStateParams{
		Purpose:   purpose,
		KeyHash:   authStateKeyHash(key),
		Payload:   payload,
		ExpiresAt: pgtype.Timestamptz{Time: time.Now().Add(ttl), Valid: true},
	})
}

func (h *handler) getEphemeralState(ctx context.Context, purpose, key string) ([]byte, error) {
	if legacyKey, ok := legacyEphemeralKey(purpose, key); h.legacyRedis != nil && ok {
		payload, err := h.legacyRedis.Get(ctx, legacyKey).Bytes()
		if errors.Is(err, redis.Nil) {
			return nil, errEphemeralStateNotFound
		}
		if err != nil {
			return nil, fmt.Errorf("get legacy authentication state: %w", err)
		}
		return payload, nil
	}
	payload, err := h.q.GetAuthEphemeralState(ctx, db.GetAuthEphemeralStateParams{
		Purpose: purpose,
		KeyHash: authStateKeyHash(key),
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, errEphemeralStateNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("get authentication state: %w", err)
	}
	return payload, nil
}

func (h *handler) consumeEphemeralState(ctx context.Context, purpose, key string) ([]byte, error) {
	if legacyKey, ok := legacyEphemeralKey(purpose, key); h.legacyRedis != nil && ok {
		payload, err := h.legacyRedis.GetDel(ctx, legacyKey).Bytes()
		if errors.Is(err, redis.Nil) {
			return nil, errEphemeralStateNotFound
		}
		if err != nil {
			return nil, fmt.Errorf("consume legacy authentication state: %w", err)
		}
		return payload, nil
	}
	payload, err := h.q.ConsumeAuthEphemeralState(ctx, db.ConsumeAuthEphemeralStateParams{
		Purpose: purpose,
		KeyHash: authStateKeyHash(key),
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, errEphemeralStateNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("consume authentication state: %w", err)
	}
	return payload, nil
}

func (h *handler) consumeMatchingEphemeralState(
	ctx context.Context,
	purpose string,
	key string,
	payload []byte,
) error {
	if legacyKey, ok := legacyEphemeralKey(purpose, key); h.legacyRedis != nil && ok {
		matched, err := consumeMatchingLegacyState.Run(
			ctx,
			h.legacyRedis,
			[]string{legacyKey},
			string(payload),
		).Int()
		if err != nil {
			return fmt.Errorf("consume matching legacy authentication state: %w", err)
		}
		if matched != 1 {
			return errEphemeralStateNotFound
		}
		return nil
	}
	_, err := h.q.ConsumeMatchingAuthEphemeralState(ctx, db.ConsumeMatchingAuthEphemeralStateParams{
		Purpose: purpose,
		KeyHash: authStateKeyHash(key),
		Payload: payload,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return errEphemeralStateNotFound
	}
	if err != nil {
		return fmt.Errorf("consume matching authentication state: %w", err)
	}
	return nil
}

func legacyEphemeralKey(purpose, key string) (string, bool) {
	switch purpose {
	case oauthStatePurpose:
		return "oauth:state:" + key, true
	case desktopHandoffPurpose:
		return "oauth:desktop:" + key, true
	case passkeyRegisterPurpose:
		return "passkey:reg:" + key, true
	case passkeyLoginPurpose:
		return "passkey:login:" + key, true
	default:
		return "", false
	}
}

func (h *handler) incrementRateLimit(
	ctx context.Context,
	scope string,
	subject string,
	window time.Duration,
) (int32, error) {
	result, err := h.q.IncrementAuthRateLimit(ctx, db.IncrementAuthRateLimitParams{
		Scope:       scope,
		SubjectHash: h.rateLimitSubjectHash(scope, subject),
		ExpiresAt:   pgtype.Timestamptz{Time: time.Now().Add(window), Valid: true},
	})
	if err != nil {
		return 0, fmt.Errorf("increment authentication rate limit: %w", err)
	}
	return result.Attempts, nil
}

func (h *handler) clearRateLimit(ctx context.Context, scope, subject string) error {
	if err := h.q.ClearAuthRateLimit(ctx, db.ClearAuthRateLimitParams{
		Scope:       scope,
		SubjectHash: h.rateLimitSubjectHash(scope, subject),
	}); err != nil {
		return fmt.Errorf("clear authentication rate limit: %w", err)
	}
	return nil
}
