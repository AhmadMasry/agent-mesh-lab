package main

import (
	"net/http"
	"strings"
	"unicode"
)

// identity is the caller attribution resolved for one call, in the order
// described in the Gate 1 interfaces: identity headers first, then a
// lwi:<id> token in the last user message when the work-item header is
// absent (for a client that cannot set per-request headers).
type identity struct {
	LWI       string
	MessageID string
	TaskID    string
	Caller    string
}

func resolveIdentity(r *http.Request, req chatCompletionRequest) identity {
	lwi := r.Header.Get("X-Logical-Work-Item-Id")
	if lwi == "" {
		lwi = lwiFromLastUserMessage(req.Messages)
	}
	return identity{
		LWI:       lwi,
		MessageID: r.Header.Get("X-A2A-Message-Id"),
		TaskID:    r.Header.Get("X-A2A-Task-Id"),
		Caller:    r.Header.Get("X-Caller"),
	}
}

func lwiFromLastUserMessage(messages []chatMessageInput) string {
	for i := len(messages) - 1; i >= 0; i-- {
		if messages[i].Role == "user" {
			return extractLWIToken(messages[i].Content)
		}
	}
	return ""
}

// extractLWIToken finds a lwi:<id> token in content, where <id> runs to the
// next whitespace (or end of string).
func extractLWIToken(content string) string {
	const marker = "lwi:"
	idx := strings.Index(content, marker)
	if idx == -1 {
		return ""
	}
	rest := content[idx+len(marker):]
	end := strings.IndexFunc(rest, unicode.IsSpace)
	if end == -1 {
		return rest
	}
	return rest[:end]
}
