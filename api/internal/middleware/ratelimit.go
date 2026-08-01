package middleware

import (
	"net"
	"net/http"
	"strconv"
	"sync"
	"time"
)

const maxRateLimitBuckets = 10_000

type rateLimitBucket struct {
	count     int
	expiresAt time.Time
}

type memoryRateLimiter struct {
	mu      sync.Mutex
	buckets map[string]rateLimitBucket
}

// RateLimit implements a bounded, per-process fixed-window limiter for general
// API traffic. Security-sensitive authentication limits are persisted in
// PostgreSQL; deployments may add a coarse outer limit at the Cloudflare edge.
func RateLimit(limit int, window time.Duration, key func(*http.Request) string) func(http.Handler) http.Handler {
	limiter := &memoryRateLimiter{buckets: make(map[string]rateLimitBucket)}

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			now := time.Now()
			bucketKey := key(r)
			count, retryAfter := limiter.increment(bucketKey, now, window)
			if count > limit {
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
				http.Error(w, `{"error":"rate limit exceeded"}`, http.StatusTooManyRequests)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func (l *memoryRateLimiter) increment(key string, now time.Time, window time.Duration) (int, int) {
	l.mu.Lock()
	defer l.mu.Unlock()

	bucket, exists := l.buckets[key]
	if exists && !now.Before(bucket.expiresAt) {
		delete(l.buckets, key)
		exists = false
	}

	if !exists && len(l.buckets) >= maxRateLimitBuckets {
		l.pruneExpired(now)
		if len(l.buckets) >= maxRateLimitBuckets {
			l.evictOldest()
		}
	}

	if !exists {
		bucket = rateLimitBucket{expiresAt: now.Add(window)}
	}
	bucket.count++
	l.buckets[key] = bucket

	remaining := bucket.expiresAt.Sub(now)
	retryAfter := int((remaining + time.Second - 1) / time.Second)
	if retryAfter < 1 {
		retryAfter = 1
	}
	return bucket.count, retryAfter
}

func (l *memoryRateLimiter) pruneExpired(now time.Time) {
	for key, bucket := range l.buckets {
		if !now.Before(bucket.expiresAt) {
			delete(l.buckets, key)
		}
	}
}

func (l *memoryRateLimiter) evictOldest() {
	var oldestKey string
	var oldestExpiry time.Time
	for key, bucket := range l.buckets {
		if oldestKey == "" || bucket.expiresAt.Before(oldestExpiry) {
			oldestKey = key
			oldestExpiry = bucket.expiresAt
		}
	}
	if oldestKey != "" {
		delete(l.buckets, oldestKey)
	}
}

func IPKey(r *http.Request) string {
	return "ip:" + ClientIP(r)
}

// ClientIP returns a canonical client address from proxy headers that Chronicle
// deployments explicitly overwrite, falling back to the direct peer.
func ClientIP(r *http.Request) string {
	for _, header := range []string{"Fly-Client-IP", "CF-Connecting-IP"} {
		if ip := net.ParseIP(r.Header.Get(header)); ip != nil {
			return ip.String()
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

func UserKey(r *http.Request) string {
	if id := GetUserID(r.Context()); id != "" {
		return "user:" + id
	}
	return "ip:" + r.RemoteAddr
}
