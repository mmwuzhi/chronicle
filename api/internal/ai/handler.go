package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"github.com/danielgtaylor/huma/v2"
)

type handler struct {
	apiKey string
}

func Register(api huma.API, apiKey string, authMW func(huma.Context, func(huma.Context))) {
	h := &handler{apiKey: apiKey}

	huma.Register(api, huma.Operation{
		OperationID: "polish-text",
		Method:      http.MethodPost,
		Path:        "/ai/polish",
		Summary:     "Polish text with AI",
		Tags:        []string{"ai"},
		Middlewares: huma.Middlewares{authMW},
	}, h.polish)
}

type PolishInput struct {
	Body struct {
		Text string `json:"text" minLength:"1" maxLength:"4000"`
	}
}

type PolishOutput struct {
	Body struct {
		Polished string `json:"polished"`
	}
}

// Gemini API types
type geminiRequest struct {
	SystemInstruction geminiContent   `json:"system_instruction"`
	Contents          []geminiContent `json:"contents"`
}

type geminiContent struct {
	Parts []geminiPart `json:"parts"`
}

type geminiPart struct {
	Text string `json:"text"`
}

type geminiResponse struct {
	Candidates []struct {
		Content struct {
			Parts []geminiPart `json:"parts"`
		} `json:"content"`
	} `json:"candidates"`
}

const systemPrompt = "You are a writing assistant. Polish the following note: fix typos, improve grammar and clarity, keep it concise. Preserve the author's voice and original meaning. Return only the polished text, no explanation."

const geminiModel = "gemini-2.5-flash"

func (h *handler) polish(ctx context.Context, input *PolishInput) (*PolishOutput, error) {
	if h.apiKey == "" {
		return nil, huma.NewError(http.StatusServiceUnavailable, "AI features not configured")
	}

	reqBody, err := json.Marshal(geminiRequest{
		SystemInstruction: geminiContent{
			Parts: []geminiPart{{Text: systemPrompt}},
		},
		Contents: []geminiContent{
			{Parts: []geminiPart{{Text: input.Body.Text}}},
		},
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}

	url := fmt.Sprintf("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s", geminiModel, h.apiKey)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(reqBody))
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, huma.NewError(http.StatusBadGateway, "AI service unavailable")
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, huma.NewError(http.StatusBadGateway, fmt.Sprintf("AI service error: %d", resp.StatusCode))
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}

	var geminiResp geminiResponse
	if err := json.Unmarshal(body, &geminiResp); err != nil ||
		len(geminiResp.Candidates) == 0 ||
		len(geminiResp.Candidates[0].Content.Parts) == 0 {
		return nil, huma.Error500InternalServerError("invalid AI response")
	}

	out := &PolishOutput{}
	out.Body.Polished = geminiResp.Candidates[0].Content.Parts[0].Text
	return out, nil
}
