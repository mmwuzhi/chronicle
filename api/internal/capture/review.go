package capture

import (
	"context"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
)

// Review is the resurfacing surface derived from captures (Capture → Review in
// the conceptual model): it pulls old captures back into view so the memory
// system does more than accept writes. Deliberately minimal — no spaced
// repetition, no scoring, no read/seen state — matching the product guardrail
// to prefer recall over maintenance.

const (
	// onThisDayLimit caps the same-calendar-day list; reviewToday dedupes
	// rediscover against it, so a generous cap here only trims very busy days.
	onThisDayLimit = 20
	// rediscoverLimit is the random-older handful that keeps the panel populated
	// when "on this day" is empty in a young library.
	rediscoverLimit = 5
)

type ReviewTodayInput struct {
	TimezoneOffsetMinutes int `query:"timezoneOffsetMinutes" minimum:"-840" maximum:"720" default:"0" doc:"Client timezone offset in minutes, same sign as JavaScript getTimezoneOffset (UTC minus local)"`
}

type ReviewTodayOutput struct {
	Body struct {
		OnThisDay  []CaptureBody `json:"onThisDay" doc:"Captures from this same calendar day in an earlier period"`
		Rediscover []CaptureBody `json:"rediscover" doc:"A random handful of older captures for serendipitous recall"`
	}
}

// reviewToday returns two small buckets to revisit: same-calendar-day captures
// and a random sample of older ones. Rediscover is deduped against onThisDay so
// a card never shows twice. Both are always non-nil arrays so the client renders
// an empty state rather than branching on null.
func (h *handler) reviewToday(ctx context.Context, input *ReviewTodayInput) (*ReviewTodayOutput, error) {
	uid, err := userID(ctx)
	if err != nil {
		return nil, err
	}

	onThisDay, err := h.q.ListOnThisDay(ctx, db.ListOnThisDayParams{
		UserID:                uid,
		TimezoneOffsetMinutes: int32(input.TimezoneOffsetMinutes),
		ResultLimit:           onThisDayLimit,
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	rediscover, err := h.q.ListRediscover(ctx, db.ListRediscoverParams{
		UserID:      uid,
		ResultLimit: rediscoverLimit,
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}

	out := &ReviewTodayOutput{}
	out.Body.OnThisDay = []CaptureBody{}
	out.Body.Rediscover = []CaptureBody{}

	seen := make(map[uuid.UUID]bool, len(onThisDay))
	for _, c := range onThisDay {
		seen[c.ID] = true
		out.Body.OnThisDay = append(out.Body.OnThisDay, toBody(c))
	}
	for _, c := range rediscover {
		if seen[c.ID] {
			continue
		}
		out.Body.Rediscover = append(out.Body.Rediscover, toBody(c))
	}
	return out, nil
}
