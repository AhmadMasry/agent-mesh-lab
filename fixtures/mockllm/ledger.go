package main

import (
	"encoding/json"
	"io"
	"sync"
	"time"
)

// invocationLine is one line of the model invocation ledger: one JSON
// object per call to /v1/chat/completions, written to stdout. Field names
// follow the identity-field convention in CLAUDE.md (see "Identity fields"
// under Conventions); encoding/json with a struct keeps them stable across
// changes to this file.
type invocationLine struct {
	Ledger            string  `json:"ledger"`
	TS                string  `json:"ts"`
	LogicalWorkItemID string  `json:"logical_work_item_id"`
	MessageID         string  `json:"messageId"`
	TaskID            string  `json:"taskId"`
	Caller            string  `json:"caller"`
	BodySHA256        string  `json:"body_sha256"`
	Stream            bool    `json:"stream"`
	Injection         string  `json:"injection"`
	Outcome           string  `json:"outcome"`
	LatencyMs         float64 `json:"latency_ms"`
}

// controlLine is one line recording a call to /control/inject or
// /control/reset, so a run's ledger output is self-describing without
// needing the request log alongside it.
type controlLine struct {
	Ledger   string `json:"ledger"`
	TS       string `json:"ts"`
	Endpoint string `json:"endpoint"`
	Detail   string `json:"detail,omitempty"`
}

// ledgerWriter serializes writes to the ledger output so concurrent
// requests never interleave partial JSON lines.
type ledgerWriter struct {
	mu  sync.Mutex
	out io.Writer
}

func (w *ledgerWriter) writeLine(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		// A ledger line that cannot be marshalled is a bug in this file,
		// not a runtime condition to recover from; drop it rather than
		// write malformed JSON that would break every downstream reader.
		return
	}
	b = append(b, '\n')
	w.mu.Lock()
	defer w.mu.Unlock()
	_, _ = w.out.Write(b)
}

func nowRFC3339Nano() string {
	return time.Now().UTC().Format(time.RFC3339Nano)
}
