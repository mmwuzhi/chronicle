package middleware

import (
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

// RateLimit implements a Redis sliding window rate limiter.
// key is a function that derives the bucket key from the request (e.g. IP or user ID).
func RateLimit(rdb *redis.Client, limit int, window time.Duration, key func(*http.Request) string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ctx := r.Context()
			bucketKey := "rl:" + key(r)
			now := time.Now().UnixMilli()
			windowStart := now - window.Milliseconds()

			pipe := rdb.Pipeline()
			pipe.ZRemRangeByScore(ctx, bucketKey, "-inf", strconv.FormatInt(windowStart, 10))
			countCmd := pipe.ZCard(ctx, bucketKey)
			pipe.ZAdd(ctx, bucketKey, redis.Z{Score: float64(now), Member: fmt.Sprintf("%d-%s", now, GetTraceID(ctx))})
			pipe.Expire(ctx, bucketKey, window+time.Second)

			if _, err := pipe.Exec(ctx); err != nil {
				// fail open: if Redis is down, don't block the request
				next.ServeHTTP(w, r)
				return
			}

			if countCmd.Val() >= int64(limit) {
				retryAfter := int(window.Seconds())
				w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
				http.Error(w, `{"error":"rate limit exceeded"}`, http.StatusTooManyRequests)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}

func IPKey(r *http.Request) string {
	if ip := r.Header.Get("x-forwarded-for"); ip != "" {
		return "ip:" + ip
	}
	return "ip:" + r.RemoteAddr
}

func UserKey(r *http.Request) string {
	if id := GetUserID(r.Context()); id != "" {
		return "user:" + id
	}
	return "ip:" + r.RemoteAddr
}
