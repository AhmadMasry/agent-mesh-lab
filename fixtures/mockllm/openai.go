package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// fixedCreatedUnix and the usage counts below are constants, never the wall
// clock or a computed count, so that two runs against the same request body
// produce byte-identical response bytes.
const (
	fixedCreatedUnix      int64 = 1734000000
	fixedPromptTokens           = 12
	fixedCompletionTokens       = 6
)

type chatMessageInput struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type chatCompletionRequest struct {
	Model    string             `json:"model"`
	Stream   bool               `json:"stream"`
	Messages []chatMessageInput `json:"messages"`
}

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type chatChoice struct {
	Index        int         `json:"index"`
	Message      chatMessage `json:"message"`
	FinishReason string      `json:"finish_reason"`
}

type chatUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

type chatCompletionResponse struct {
	ID      string       `json:"id"`
	Object  string       `json:"object"`
	Created int64        `json:"created"`
	Model   string       `json:"model"`
	Choices []chatChoice `json:"choices"`
	Usage   chatUsage    `json:"usage"`
}

type chunkDelta struct {
	Role    string `json:"role,omitempty"`
	Content string `json:"content,omitempty"`
}

type chunkChoice struct {
	Index        int        `json:"index"`
	Delta        chunkDelta `json:"delta"`
	FinishReason *string    `json:"finish_reason"`
}

type chatCompletionChunk struct {
	ID      string        `json:"id"`
	Object  string        `json:"object"`
	Created int64         `json:"created"`
	Model   string        `json:"model"`
	Choices []chunkChoice `json:"choices"`
}

type errorDetail struct {
	Message string `json:"message"`
	Type    string `json:"type"`
}

type errorBody struct {
	Error errorDetail `json:"error"`
}

// responseID derives the stable id from the request body hash so two runs
// against the same body compare byte-for-byte.
func responseID(bodySHA256 string) string {
	n := 16
	if len(bodySHA256) < n {
		n = len(bodySHA256)
	}
	return "chatcmpl-" + bodySHA256[:n]
}

func buildResponse(responseText, bodySHA256 string, req chatCompletionRequest) chatCompletionResponse {
	return chatCompletionResponse{
		ID:      responseID(bodySHA256),
		Object:  "chat.completion",
		Created: fixedCreatedUnix,
		Model:   req.Model,
		Choices: []chatChoice{{
			Index:        0,
			Message:      chatMessage{Role: "assistant", Content: responseText},
			FinishReason: "stop",
		}},
		Usage: chatUsage{
			PromptTokens:     fixedPromptTokens,
			CompletionTokens: fixedCompletionTokens,
			TotalTokens:      fixedPromptTokens + fixedCompletionTokens,
		},
	}
}

func writeJSONResponse(w http.ResponseWriter, status int, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(b)
}

// writeSSEResponse emits the response text as a single content chunk, a
// terminal chunk carrying finish_reason, then data: [DONE] — the same
// chunking every time for a given responseText and request, so streamed
// runs compare byte-for-byte like the non-streaming path.
func writeSSEResponse(w http.ResponseWriter, responseText, bodySHA256 string, req chatCompletionRequest) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)

	id := responseID(bodySHA256)

	contentChunk := chatCompletionChunk{
		ID:      id,
		Object:  "chat.completion.chunk",
		Created: fixedCreatedUnix,
		Model:   req.Model,
		Choices: []chunkChoice{{
			Index: 0,
			Delta: chunkDelta{Role: "assistant", Content: responseText},
		}},
	}
	writeSSEEvent(w, contentChunk)
	if flusher != nil {
		flusher.Flush()
	}

	stop := "stop"
	finalChunk := chatCompletionChunk{
		ID:      id,
		Object:  "chat.completion.chunk",
		Created: fixedCreatedUnix,
		Model:   req.Model,
		Choices: []chunkChoice{{
			Index:        0,
			Delta:        chunkDelta{},
			FinishReason: &stop,
		}},
	}
	writeSSEEvent(w, finalChunk)
	if flusher != nil {
		flusher.Flush()
	}

	fmt.Fprint(w, "data: [DONE]\n\n")
	if flusher != nil {
		flusher.Flush()
	}
}

func writeSSEEvent(w io.Writer, v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "data: %s\n\n", b)
}
