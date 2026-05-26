package ai

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/danielgtaylor/huma/v2"
)

const geminiModel = "gemini-3.1-flash-lite"

var (
	urlRe   = regexp.MustCompile(`https?://[^\s"'<>]+`)
	titleRe = regexp.MustCompile(`(?i)<title[^>]*>([^<]+)</title>`)
	descRe1 = regexp.MustCompile(`(?i)<meta[^>]+name=["']description["'][^>]+content=["']([^"']{1,300})["']`)
	descRe2 = regexp.MustCompile(`(?i)<meta[^>]+content=["']([^"']{1,300})["'][^>]+name=["']description["']`)

	// geminiClient caps Gemini API calls to 30s so we fail fast before Fly.io's 60s limit.
	geminiClient = &http.Client{Timeout: 30 * time.Second}
)

const systemPromptTmpl = `You are a personal assistant helping the user enrich their quick notes.
Current time: %s (UTC)

Transform the note as follows:
1. Resolve vague time words (等会, 待会, soon, later, 下午, 明天, tomorrow, etc.) into approximate concrete times based on the current time above.
2. If URLs are present and metadata is provided below, replace each bare URL with a concise inline description in the note's language and keep the URL in parentheses — e.g. "鶏そばきらり拉面 (https://...)".
3. Fix typos and improve clarity. Preserve the author's voice.
4. Return only the enriched note text. No explanation, no markdown, no extra commentary.

URL metadata:
%s`

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

type urlMeta struct {
	URL   string
	Title string
	Desc  string
}

func isPrivateHost(host string) bool {
	private := []string{
		"localhost", "127.", "0.0.0.0", "[::1]",
		"10.", "192.168.",
		"172.16.", "172.17.", "172.18.", "172.19.", "172.20.",
		"172.21.", "172.22.", "172.23.", "172.24.", "172.25.",
		"172.26.", "172.27.", "172.28.", "172.29.", "172.30.", "172.31.",
	}
	for _, p := range private {
		if strings.HasPrefix(host, p) {
			return true
		}
	}
	return false
}

func fetchMeta(ctx context.Context, rawURL string) urlMeta {
	meta := urlMeta{URL: rawURL}
	u, err := url.Parse(rawURL)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || isPrivateHost(u.Hostname()) {
		return meta
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return meta
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
	req.Header.Set("Accept-Language", "ja,zh;q=0.9,en;q=0.8")
	req.Header.Set("Accept", "text/html,application/xhtml+xml")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return meta
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return meta
	}

	chunk, _ := io.ReadAll(io.LimitReader(resp.Body, 8192))
	s := string(chunk)

	if m := titleRe.FindStringSubmatch(s); len(m) > 1 {
		meta.Title = html.UnescapeString(strings.TrimSpace(m[1]))
	}
	if m := descRe1.FindStringSubmatch(s); len(m) > 1 {
		meta.Desc = html.UnescapeString(strings.TrimSpace(m[1]))
	} else if m := descRe2.FindStringSubmatch(s); len(m) > 1 {
		meta.Desc = html.UnescapeString(strings.TrimSpace(m[1]))
	}

	return meta
}

func buildURLContext(metas []urlMeta) string {
	if len(metas) == 0 {
		return "(none)"
	}
	var sb strings.Builder
	for _, m := range metas {
		sb.WriteString(fmt.Sprintf("- %s", m.URL))
		if m.Title != "" {
			sb.WriteString(fmt.Sprintf(" → %s", m.Title))
		}
		if m.Desc != "" {
			sb.WriteString(fmt.Sprintf("; %s", m.Desc))
		}
		sb.WriteString("\n")
	}
	return sb.String()
}

func (h *handler) polish(ctx context.Context, input *PolishInput) (*PolishOutput, error) {
	if h.apiKey == "" {
		return nil, huma.NewError(http.StatusServiceUnavailable, "AI features not configured")
	}

	// Extract URLs (max 5) and fetch metadata in parallel with a 3s deadline
	urls := urlRe.FindAllString(input.Body.Text, 5)
	metas := make([]urlMeta, len(urls))
	if len(urls) > 0 {
		fetchCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		var wg sync.WaitGroup
		for i, u := range urls {
			wg.Add(1)
			go func(i int, u string) {
				defer wg.Done()
				metas[i] = fetchMeta(fetchCtx, u)
			}(i, u)
		}
		wg.Wait()
	}

	prompt := fmt.Sprintf(systemPromptTmpl,
		time.Now().UTC().Format("2006-01-02 15:04"),
		buildURLContext(metas),
	)

	reqBody, err := json.Marshal(geminiRequest{
		SystemInstruction: geminiContent{Parts: []geminiPart{{Text: prompt}}},
		Contents:          []geminiContent{{Parts: []geminiPart{{Text: input.Body.Text}}}},
	})
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}

	apiURL := fmt.Sprintf("https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent?key=%s", geminiModel, h.apiKey)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiURL, bytes.NewReader(reqBody))
	if err != nil {
		return nil, huma.Error500InternalServerError("internal error")
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := geminiClient.Do(req)
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
