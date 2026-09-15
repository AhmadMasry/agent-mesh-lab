package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
)

// identity is what every model call carries so the invocation ledger can
// attribute it: the work item, the A2A message, the Task, and who called.
type identity struct {
	WorkItem  string
	MessageID string
	TaskID    string
	Caller    string
}

// modelClient makes exactly one non-streaming chat-completions call per
// complete(). It has no retry path: one request, one outcome.
type modelClient struct {
	base  string
	model string
	key   string
	hc    *http.Client
}

func newModelClient(base, model, key string, hc *http.Client) *modelClient {
	return &modelClient{base: strings.TrimRight(base, "/"), model: model, key: key, hc: hc}
}

type chatRequest struct {
	Model    string        `json:"model"`
	Messages []chatMessage `json:"messages"`
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// chatResponse reads back what the lab needs from an OpenAI-compatible answer:
// the text, and -- since follow-ups 14 -- everything the GenAI conventions ask a
// chat span to carry about the response, which is the id, the model that
// answered, the finish reasons and the two token counts. The mock answers fixed
// usage counts, so those two numbers are the same on every clean call.
type chatResponse struct {
	ID      string `json:"id"`
	Model   string `json:"model"`
	Choices []struct {
		Message      chatMessage `json:"message"`
		FinishReason string      `json:"finish_reason"`
	} `json:"choices"`
	Usage struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
	} `json:"usage"`
}

// finishReasons is one entry per choice, in order, skipping a choice that
// carried none. The conventions describe the attribute as an "Array of reasons
// the model stopped generating tokens, corresponding to each generation
// received".
func (c *chatResponse) finishReasons() []string {
	var out []string
	for _, choice := range c.Choices {
		if choice.FinishReason != "" {
			out = append(out, choice.FinishReason)
		}
	}
	return out
}

// statusError is a model call the endpoint answered with a status other than
// 200. It carries the status so the chat span can record it as error.type,
// which the conventions ask to be "the error code returned by the Generative AI
// provider" and give `500` as an example value for. Its message is the text the
// call has always failed with, unchanged.
type statusError struct{ status int }

func (e *statusError) Error() string   { return fmt.Sprintf("model call: status %d", e.status) }
func (e *statusError) StatusCode() int { return e.status }

// complete makes the one call and wraps it in the GenAI `chat <model>` client
// span. The span wraps the call rather than sitting inside it, so the otelhttp
// client span is its child, and it reads the model's own answer onto itself
// afterwards. Nothing about the request changes: the same bytes, the same
// headers, the same retry-free client, and a call made with no tracer provider
// installed is unchanged in every respect.
func (m *modelClient) complete(ctx context.Context, id identity, text string) (string, error) {
	ctx, span := labotel.ModelCall(ctx, m.model, m.base, labotel.Identity{
		WorkItem: id.WorkItem, MessageID: id.MessageID, TaskID: id.TaskID, Caller: id.Caller,
	})
	answer, cr, err := m.send(ctx, id, text)
	if cr != nil {
		span.Response(labotel.ModelResponse{
			ID:            cr.ID,
			Model:         cr.Model,
			FinishReasons: cr.finishReasons(),
			InputTokens:   cr.Usage.PromptTokens,
			OutputTokens:  cr.Usage.CompletionTokens,
		})
	}
	span.End(err)
	return answer, err
}

// send is the call itself, unchanged from what it was before the span was put
// around it. It returns the parsed response beside the text when there was one
// to parse, so the span can carry the id and the counts even on a call that then
// failed to yield text.
func (m *modelClient) send(ctx context.Context, id identity, text string) (string, *chatResponse, error) {
	body, err := json.Marshal(chatRequest{Model: m.model, Messages: []chatMessage{{Role: "user", Content: text}}})
	if err != nil {
		return "", nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, m.base+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+m.key)
	req.Header.Set("X-Logical-Work-Item-Id", id.WorkItem)
	req.Header.Set("X-A2A-Message-Id", id.MessageID)
	req.Header.Set("X-A2A-Task-Id", id.TaskID)
	req.Header.Set("X-Caller", id.Caller)

	resp, err := m.hc.Do(req)
	if err != nil {
		return "", nil, fmt.Errorf("model call: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", nil, fmt.Errorf("model response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", nil, &statusError{status: resp.StatusCode}
	}
	var cr chatResponse
	if err := json.Unmarshal(raw, &cr); err != nil {
		return "", nil, fmt.Errorf("model response: %w", err)
	}
	if len(cr.Choices) == 0 {
		return "", &cr, errors.New("model response: no choices")
	}
	return cr.Choices[0].Message.Content, &cr, nil
}
