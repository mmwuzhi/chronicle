package search

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/danielgtaylor/huma/v2"
	"github.com/google/uuid"

	db "github.com/sikaoshenmi/chronicle/db/sqlc"
	"github.com/sikaoshenmi/chronicle/internal/middleware"
	"github.com/sikaoshenmi/chronicle/internal/ragclient"
)

// recall wires the semantic retrieval surface (hybrid /find + query-time /ask)
// backed by the Python RAG sidecar. /find degrades to keyword FTS when the
// sidecar is unavailable so search never goes dark; /ask requires the sidecar.

type recallHandler struct {
	q   *db.Queries
	rag *ragclient.Client
}

// RecallItem is one retrieved capture (shared by /find and the FTS fallback).
type RecallItem struct {
	ID        string  `json:"id"`
	Content   string  `json:"content"`
	CreatedAt string  `json:"createdAt"`
	Modality  string  `json:"modality"`
	Score     float64 `json:"score"`
	Lexical   bool    `json:"lexical"`
}

type FindInput struct {
	Q     string `query:"q" minLength:"1" maxLength:"200" required:"true"`
	Limit int    `query:"limit" minimum:"1" maximum:"50" default:"10"`
}

type FindOutput struct {
	Body struct {
		Items    []RecallItem `json:"items"`
		Degraded bool         `json:"degraded" doc:"true when the semantic sidecar was unavailable and keyword FTS was used"`
	}
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

	items, err := h.rag.Find(ctx, uid.String(), query, input.Limit)
	if err == nil {
		for _, it := range items {
			out.Body.Items = append(out.Body.Items, RecallItem{
				ID: it.ID, Content: it.Content, CreatedAt: it.CreatedAt,
				Modality: it.Modality, Score: it.Score, Lexical: it.Lexical,
			})
		}
		return out, nil
	}

	// Sidecar disabled or unreachable: fall back to keyword FTS over captures.
	rows, ferr := h.q.SearchCaptures(ctx, db.SearchCapturesParams{
		UserID: uid, Query: query, ResultLimit: int32(input.Limit),
	})
	if ferr != nil {
		return nil, huma.Error500InternalServerError("search failed")
	}
	for _, c := range rows {
		if len(out.Body.Items) >= input.Limit {
			break // honor the requested limit even in the degraded FTS path
		}
		content := c.RawText.String
		if c.MatchedField == "transcript" {
			content = c.Transcript.String
		}
		out.Body.Items = append(out.Body.Items, RecallItem{
			ID:        c.ID.String(),
			Content:   content,
			CreatedAt: c.CreatedAt.Time.UTC().Format(time.RFC3339),
			Modality:  string(c.MediaType),
			Score:     0,
			Lexical:   true,
		})
	}
	out.Body.Degraded = true
	return out, nil
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

func registerRecall(api huma.API, q *db.Queries, rag *ragclient.Client, authMW func(huma.Context, func(huma.Context))) {
	h := &recallHandler{q: q, rag: rag}
	op := func(id, method, path, summary string) huma.Operation {
		return huma.Operation{
			OperationID: id, Method: method, Path: path, Summary: summary,
			Tags: []string{"recall"}, Middlewares: huma.Middlewares{authMW},
		}
	}
	huma.Register(api, op("find", http.MethodGet, "/find", "Hybrid semantic search over captures"), h.find)
	huma.Register(api, op("ask", http.MethodPost, "/ask", "Ask a question answered over your captures"), h.ask)
}

func recallUserID(ctx context.Context) (uuid.UUID, error) {
	uid, err := uuid.Parse(middleware.GetUserID(ctx))
	if err != nil {
		return uuid.UUID{}, huma.Error401Unauthorized("unauthorized")
	}
	return uid, nil
}
