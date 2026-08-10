package search

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"slices"
	"strings"
	"time"
	"unicode"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
	"github.com/sikaoshenmi/chronicle/internal/retrieval"
)

// recall wires the semantic retrieval surface (hybrid /find + query-time /ask)
// backed by the Python RAG sidecar. /find degrades to keyword FTS when the
// sidecar is unavailable so search never goes dark; /ask requires the sidecar.

type recallHandler struct {
	pool *pgxpool.Pool
	q    *db.Queries
	rag  *ragclient.Client
}

// RecallItem is one retrieved capture (shared by /find and the FTS fallback).
type RecallItem struct {
	ID        string  `json:"id"`
	Content   string  `json:"content"`
	Snippet   string  `json:"snippet,omitempty"`
	CreatedAt string  `json:"createdAt"`
	Modality  string  `json:"modality"`
	Score     float64 `json:"score"`
	Lexical   bool    `json:"lexical"`
	Dismissed bool    `json:"dismissed,omitempty" doc:"true only when includeDismissed returns a result hidden for this query"`
}

type FindInput struct {
	Q                string `query:"q" minLength:"1" maxLength:"200" required:"true"`
	Limit            int    `query:"limit" minimum:"1" maximum:"50" default:"10"`
	IncludeDismissed bool   `query:"includeDismissed" default:"false" doc:"Include results the user hid for this exact normalized query"`
}

type FindOutput struct {
	Body struct {
		Items                   []RecallItem `json:"items"`
		Degraded                bool         `json:"degraded" doc:"true when the semantic sidecar was unavailable and keyword FTS was used"`
		HiddenCount             int          `json:"hiddenCount" doc:"Number of live results hidden for this exact normalized query"`
		DismissalsAuthoritative bool         `json:"dismissalsAuthoritative" doc:"false when retrieval preferences could not be read completely"`
	}
}

func normalizedSearchQuery(query string) string {
	return retrieval.NormalizeQuery(query)
}

func searchQueryHash(userID uuid.UUID, query string) []byte {
	return retrieval.QueryHash(userID, query)
}

func (h *recallHandler) find(ctx context.Context, input *FindInput) (*FindOutput, error) {
	uid, err := recallUserID(ctx)
	if err != nil {
		return nil, err
	}
	query := strings.TrimSpace(input.Q)
	if query == "" {
		return nil, huma.Error422UnprocessableEntity("q must not be empty")
	}

	out := &FindOutput{}
	out.Body.Items = []RecallItem{}
	out.Body.DismissalsAuthoritative = true
	dismissedIDs, dismissErr := h.q.ListSearchDismissedIDs(ctx, db.ListSearchDismissedIDsParams{
		UserID: uid, QueryHash: searchQueryHash(uid, query),
	})
	if dismissErr != nil {
		// Feedback is a preference layer, not a search dependency. A missing or
		// temporarily unavailable preference table must not take retrieval down.
		slog.WarnContext(ctx, "search dismissals unavailable",
			"traceId", middleware.GetTraceID(ctx), "err", dismissErr)
		dismissedIDs = nil
		out.Body.DismissalsAuthoritative = false
	}
	out.Body.HiddenCount = len(dismissedIDs)
	excluded := make([]string, 0, len(dismissedIDs))
	for _, id := range dismissedIDs {
		excluded = append(excluded, id.String())
	}
	var dismissedRows []db.ListSearchDismissedCapturesRow
	if input.IncludeDismissed && len(dismissedIDs) > 0 {
		dismissedRows, dismissErr = h.q.ListSearchDismissedCaptures(ctx, db.ListSearchDismissedCapturesParams{
			UserID: uid, QueryHash: searchQueryHash(uid, query),
		})
		if dismissErr != nil {
			slog.WarnContext(ctx, "search dismissal recovery unavailable",
				"traceId", middleware.GetTraceID(ctx), "err", dismissErr)
			dismissedRows = nil
			out.Body.DismissalsAuthoritative = false
		}
	}

	items, err := h.rag.Find(ctx, uid.String(), query, input.Limit, excluded)
	if err == nil {
		candidates := make([]RecallItem, 0, len(items))
		for _, it := range items {
			candidates = append(candidates, RecallItem{
				ID: it.ID, Content: it.Content, Snippet: it.Snippet, CreatedAt: it.CreatedAt,
				Modality: it.Modality, Score: it.Score, Lexical: it.Lexical,
			})
		}
		out.Body.Items = assembleFindItems(candidates, dismissedIDs, dismissedRows, input.Limit, input.IncludeDismissed)
		return out, nil
	}

	// Sidecar disabled or unreachable: fall back to keyword FTS over captures.
	rows, ferr := h.q.SearchCaptures(ctx, db.SearchCapturesParams{
		UserID: uid, Query: query, ResultLimit: int32(input.Limit), ExcludedIds: dismissedIDs,
	})
	if ferr != nil {
		return nil, huma.Error500InternalServerError("search failed")
	}
	candidates := make([]RecallItem, 0, len(rows))
	for _, c := range rows {
		content := c.RawText.String
		if c.MatchedField == "transcript" {
			content = c.Transcript.String
		}
		candidates = append(candidates, RecallItem{
			ID:        c.ID.String(),
			Content:   content,
			Snippet:   searchSnippet(content, query, 240),
			CreatedAt: c.CreatedAt.Time.UTC().Format(time.RFC3339),
			Modality:  string(c.MediaType),
			Score:     0,
			Lexical:   true,
		})
	}
	out.Body.Items = assembleFindItems(candidates, dismissedIDs, dismissedRows, input.Limit, input.IncludeDismissed)
	out.Body.Degraded = true
	return out, nil
}

func assembleFindItems(
	candidates []RecallItem,
	dismissedIDs []uuid.UUID,
	dismissedRows []db.ListSearchDismissedCapturesRow,
	visibleLimit int,
	includeDismissed bool,
) []RecallItem {
	dismissed := make(map[string]struct{}, len(dismissedIDs))
	for _, id := range dismissedIDs {
		dismissed[id.String()] = struct{}{}
	}
	items := make([]RecallItem, 0, visibleLimit+len(dismissedRows))
	seen := make(map[string]struct{}, len(candidates))
	visibleCount := 0
	for _, item := range candidates {
		seen[item.ID] = struct{}{}
		_, item.Dismissed = dismissed[item.ID]
		if item.Dismissed {
			if includeDismissed {
				items = append(items, item)
			}
			continue
		}
		if visibleCount < visibleLimit {
			items = append(items, item)
			visibleCount++
		}
	}
	if !includeDismissed {
		return items
	}
	// A dismissal can outlive the candidate window as ranking changes. Append
	// those records after ranked candidates so every explicit preference remains
	// recoverable without letting it consume the visible-result limit.
	for _, row := range dismissedRows {
		id := row.ID.String()
		if _, ok := seen[id]; ok {
			continue
		}
		items = append(items, RecallItem{
			ID: id, Content: row.Content,
			CreatedAt: row.CreatedAt.Time.UTC().Format(time.RFC3339),
			Modality:  string(row.MediaType), Dismissed: true,
		})
	}
	return items
}

type FindDismissalInput struct {
	TargetID string `path:"targetId" format:"uuid"`
	Q        string `query:"q" minLength:"1" maxLength:"200" required:"true"`
}

func (h *recallHandler) addFindDismissal(ctx context.Context, input *FindDismissalInput) (*struct{}, error) {
	uid, target, query, err := h.findDismissalParams(ctx, input)
	if err != nil {
		return nil, err
	}
	err = pgx.BeginFunc(ctx, h.pool, func(tx pgx.Tx) error {
		q := h.q.WithTx(tx)
		if err := q.LockSearchDismissals(ctx, uid); err != nil {
			return err
		}
		if err := q.AddSearchDismissal(ctx, db.AddSearchDismissalParams{
			UserID: uid, QueryHash: searchQueryHash(uid, query),
			QueryText: pgtype.Text{String: normalizedSearchQuery(query), Valid: true},
			TargetID:  target,
		}); err != nil {
			return err
		}
		return q.PruneSearchDismissals(ctx, db.PruneSearchDismissalsParams{
			UserID: uid, KeepLimit: retrieval.MaxSearchDismissalsPerUser,
		})
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to hide search result")
	}
	return nil, nil
}

func (h *recallHandler) removeFindDismissal(ctx context.Context, input *FindDismissalInput) (*struct{}, error) {
	uid, target, query, err := h.findDismissalParams(ctx, input)
	if err != nil {
		return nil, err
	}
	err = pgx.BeginFunc(ctx, h.pool, func(tx pgx.Tx) error {
		q := h.q.WithTx(tx)
		if err := q.LockSearchDismissals(ctx, uid); err != nil {
			return err
		}
		return q.RemoveSearchDismissal(ctx, db.RemoveSearchDismissalParams{
			UserID: uid, QueryHash: searchQueryHash(uid, query), TargetID: target,
		})
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to restore search result")
	}
	return nil, nil
}

func (h *recallHandler) findDismissalParams(
	ctx context.Context, input *FindDismissalInput,
) (uuid.UUID, uuid.UUID, string, error) {
	uid, err := recallUserID(ctx)
	if err != nil {
		return uuid.Nil, uuid.Nil, "", err
	}
	target, err := uuid.Parse(input.TargetID)
	if err != nil {
		return uuid.Nil, uuid.Nil, "", huma.Error422UnprocessableEntity("invalid targetId")
	}
	query := strings.TrimSpace(input.Q)
	if query == "" {
		return uuid.Nil, uuid.Nil, "", huma.Error422UnprocessableEntity("q must not be empty")
	}
	if _, err := h.q.GetCapture(ctx, db.GetCaptureParams{ID: target, UserID: uid}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return uuid.Nil, uuid.Nil, "", huma.Error404NotFound("capture not found")
		}
		return uuid.Nil, uuid.Nil, "", huma.Error500InternalServerError("internal error")
	}
	return uid, target, query, nil
}

func searchSnippet(text, query string, maxRunes int) string {
	textRunes := []rune(strings.Join(strings.Fields(text), " "))
	if len(textRunes) <= maxRunes {
		return string(textRunes)
	}
	lowerText := make([]rune, len(textRunes))
	for i, r := range textRunes {
		lowerText[i] = unicode.ToLower(r)
	}
	find := func(needle []rune) int {
		if len(needle) == 0 || len(needle) > len(lowerText) {
			return -1
		}
		for i := 0; i <= len(lowerText)-len(needle); i++ {
			if slices.Equal(lowerText[i:i+len(needle)], needle) {
				return i
			}
		}
		return -1
	}
	lowerRunes := func(value string) []rune {
		runes := []rune(strings.TrimSpace(value))
		for i, r := range runes {
			runes[i] = unicode.ToLower(r)
		}
		return runes
	}
	at := find(lowerRunes(query))
	if at < 0 {
		for _, term := range strings.Fields(query) {
			needle := lowerRunes(term)
			if len(needle) < 2 {
				continue
			}
			if at = find(needle); at >= 0 {
				break
			}
		}
	}
	if at < 0 {
		at = 0
	}
	start := max(0, at-maxRunes/3)
	end := min(len(textRunes), start+maxRunes)
	if end == len(textRunes) {
		start = max(0, end-maxRunes)
	}
	body := strings.TrimSpace(string(textRunes[start:end]))
	if start > 0 {
		body = "…" + body
	}
	if end < len(textRunes) {
		body += "…"
	}
	return body
}

type AskInput struct {
	Body struct {
		Question string `json:"question" minLength:"1" maxLength:"500"`
	}
}

type AskSource struct {
	N         int    `json:"n"`
	ID        string `json:"id"`
	Content   string `json:"content"`
	CreatedAt string `json:"createdAt"`
}

type AskOutput struct {
	Body struct {
		Answer  string      `json:"answer"`
		Sources []AskSource `json:"sources"`
	}
}

func (h *recallHandler) ask(ctx context.Context, input *AskInput) (*AskOutput, error) {
	uid, err := recallUserID(ctx)
	if err != nil {
		return nil, err
	}
	question := strings.TrimSpace(input.Body.Question)
	if question == "" {
		return nil, huma.Error422UnprocessableEntity("question must not be empty")
	}
	if !h.rag.Enabled() {
		return nil, huma.Error503ServiceUnavailable("ask requires the RAG service, which is not configured")
	}
	res, err := h.rag.Ask(ctx, uid.String(), question)
	if err != nil {
		return nil, huma.Error503ServiceUnavailable("ask is temporarily unavailable")
	}
	out := &AskOutput{}
	out.Body.Answer = res.Answer
	out.Body.Sources = make([]AskSource, len(res.Sources))
	for i, s := range res.Sources {
		out.Body.Sources[i] = AskSource{N: s.N, ID: s.ID, Content: s.Content, CreatedAt: s.CreatedAt}
	}
	return out, nil
}

func registerRecall(
	api huma.API,
	pool *pgxpool.Pool,
	q *db.Queries,
	rag *ragclient.Client,
	authMW func(huma.Context, func(huma.Context)),
) {
	h := &recallHandler{pool: pool, q: q, rag: rag}
	op := func(id, method, path, summary string) huma.Operation {
		return huma.Operation{
			OperationID: id, Method: method, Path: path, Summary: summary,
			Tags: []string{"recall"}, Middlewares: huma.Middlewares{authMW},
		}
	}
	huma.Register(api, op("find", http.MethodGet, "/find", "Hybrid semantic search over captures"), h.find)
	huma.Register(api, op("dismiss-find-result", http.MethodPut, "/find/dismissals/{targetId}", "Hide a result for an exact normalized search query"), h.addFindDismissal)
	huma.Register(api, op("restore-find-result", http.MethodDelete, "/find/dismissals/{targetId}", "Restore a result hidden for an exact normalized search query"), h.removeFindDismissal)
	huma.Register(api, op("ask", http.MethodPost, "/ask", "Ask a question answered over your captures"), h.ask)
}

func recallUserID(ctx context.Context) (uuid.UUID, error) {
	uid, err := uuid.Parse(middleware.GetUserID(ctx))
	if err != nil {
		return uuid.UUID{}, huma.Error401Unauthorized("unauthorized")
	}
	return uid, nil
}
