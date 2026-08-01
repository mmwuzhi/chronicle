package middleware

import (
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"
)

func TestRateLimitAllowsLimitThenReturnsRetryAfter(t *testing.T) {
	handler := RateLimit(2, time.Minute, func(*http.Request) string {
		return "same-client"
	})(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	for attempt, wantStatus := range []int{
		http.StatusNoContent,
		http.StatusNoContent,
		http.StatusTooManyRequests,
	} {
		request := httptest.NewRequest(http.MethodGet, "/", nil)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != wantStatus {
			t.Fatalf("attempt %d status = %d, want %d", attempt+1, response.Code, wantStatus)
		}
		if wantStatus == http.StatusTooManyRequests && response.Header().Get("Retry-After") == "" {
			t.Fatal("limited response must include Retry-After")
		}
	}
}

func TestRateLimitSeparatesKeys(t *testing.T) {
	handler := RateLimit(1, time.Minute, func(r *http.Request) string {
		return r.Header.Get("X-Test-Key")
	})(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	for _, key := range []string{"first", "second"} {
		request := httptest.NewRequest(http.MethodGet, "/", nil)
		request.Header.Set("X-Test-Key", key)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		if response.Code != http.StatusNoContent {
			t.Fatalf("first request for %q status = %d, want %d", key, response.Code, http.StatusNoContent)
		}
	}
}

func TestRateLimiterEvictsInsteadOfSharingOverflowBucket(t *testing.T) {
	limiter := &memoryRateLimiter{buckets: make(map[string]rateLimitBucket)}
	now := time.Now()
	for index := 0; index < maxRateLimitBuckets; index++ {
		key := strconv.Itoa(index)
		limiter.buckets[key] = rateLimitBucket{count: 99, expiresAt: now.Add(time.Minute)}
	}
	count, _ := limiter.increment("new-client", now, time.Minute)
	if count != 1 {
		t.Fatalf("new client count = %d, want isolated count 1", count)
	}
	if len(limiter.buckets) != maxRateLimitBuckets {
		t.Fatalf("bucket count = %d, want %d", len(limiter.buckets), maxRateLimitBuckets)
	}
}

func TestIPKeyIgnoresUntrustedForwardedFor(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	request.RemoteAddr = "192.0.2.10:1234"
	request.Header.Set("X-Forwarded-For", "198.51.100.4")
	if got := IPKey(request); got != "ip:192.0.2.10" {
		t.Fatalf("IPKey = %q", got)
	}
	request.Header.Set("Fly-Client-IP", "2001:db8::1")
	if got := IPKey(request); got != "ip:2001:db8::1" {
		t.Fatalf("Fly IPKey = %q", got)
	}
}
