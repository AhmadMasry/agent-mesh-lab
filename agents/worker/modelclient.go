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

type chatResponse struct {
	Choices []struct {
		Message chatMessage `json:"message"`
	} `json:"choices"`
}

func (m *modelClient) complete(ctx context.Context, id identity, text string) (string, error) {
	body, err := json.Marshal(chatRequest{Model: m.model, Messages: []chatMessage{{Role: "user", Content: text}}})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, m.base+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+m.key)
	req.Header.Set("X-Logical-Work-Item-Id", id.WorkItem)
	req.Header.Set("X-A2A-Message-Id", id.MessageID)
	req.Header.Set("X-A2A-Task-Id", id.TaskID)
	req.Header.Set("X-Caller", id.Caller)

	resp, err := m.hc.Do(req)
	if err != nil {
		return "", fmt.Errorf("model call: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("model response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("model call: status %d", resp.StatusCode)
	}
	var cr chatResponse
	if err := json.Unmarshal(raw, &cr); err != nil {
		return "", fmt.Errorf("model response: %w", err)
	}
	if len(cr.Choices) == 0 {
		return "", errors.New("model response: no choices")
	}
	return cr.Choices[0].Message.Content, nil
}
