package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

// ingressLine is one pre-dispatch ingress ledger record: one physical HTTP
// delivery, written before the A2A SDK sees the request. Identity fields are
// filled from the JSON-RPC body when it parses; a body that does not parse
// still produces a line with its hash and length.
type ingressLine struct {
	Ledger            string `json:"ledger"`
	TSArrival         string `json:"ts_arrival"`
	Remote            string `json:"remote"`
	Method            string `json:"method"`
	ID                string `json:"id"`
	MessageID         string `json:"messageId"`
	TaskID            string `json:"taskId"`
	ContextID         string `json:"contextId,omitempty"`
	LogicalWorkItemID string `json:"logical_work_item_id"`
	A2AVersion        string `json:"a2a_version"`
	ContentType       string `json:"content_type"`
	BodySHA256        string `json:"body_sha256"`
	BodyLen           int    `json:"body_len"`
	Status            int    `json:"status"`
}

// jsonRPCEnvelope is the tolerant view of a request body: every field is
// optional and unknown shapes are ignored rather than rejected.
type jsonRPCEnvelope struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params struct {
		ID      string `json:"id"`
		TaskID  string `json:"taskId"`
		Message struct {
			MessageID    string         `json:"messageId"`
			MessageIDAlt string         `json:"message_id"`
			TaskID       string         `json:"taskId"`
			ContextID    string         `json:"contextId"`
			Metadata     map[string]any `json:"metadata"`
		} `json:"message"`
	} `json:"params"`
}

func parseIngress(r *http.Request, body []byte) ingressLine {
	sum := sha256.Sum256(body)
	line := ingressLine{
		Ledger:      "ingress",
		TSArrival:   time.Now().UTC().Format(time.RFC3339Nano),
		Remote:      r.RemoteAddr,
		A2AVersion:  r.Header.Get("A2A-Version"),
		ContentType: r.Header.Get("Content-Type"),
		BodySHA256:  hex.EncodeToString(sum[:]),
		BodyLen:     len(body),
	}
	var env jsonRPCEnvelope
	if len(body) > 0 && json.Unmarshal(body, &env) == nil && env.Method != "" {
		line.Method = env.Method
		line.ID = rawIDString(env.ID)
		line.MessageID = env.Params.Message.MessageID
		if line.MessageID == "" {
			line.MessageID = env.Params.Message.MessageIDAlt
		}
		switch {
		case env.Params.Message.TaskID != "":
			line.TaskID = env.Params.Message.TaskID
		case env.Params.ID != "":
			line.TaskID = env.Params.ID
		case env.Params.TaskID != "":
			line.TaskID = env.Params.TaskID
		}
		line.ContextID = env.Params.Message.ContextID
		if v, ok := env.Params.Message.Metadata["logical_work_item_id"].(string); ok {
			line.LogicalWorkItemID = v
		}
		return line
	}
	if r.Method != http.MethodPost || len(body) == 0 {
		line.Method = r.Method + " " + r.URL.Path
	}
	return line
}

// rawIDString renders a JSON-RPC id (string, number, or null) as text so the
// ledger can compare ids across replays without caring about their JSON type.
func rawIDString(raw json.RawMessage) string {
	if len(raw) == 0 || string(raw) == "null" {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var n json.Number
	if json.Unmarshal(raw, &n) == nil {
		return n.String()
	}
	return string(raw)
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
	}
	return s.ResponseWriter.Write(b)
}

// Flush lets the SDK's streaming responses flush through the recorder.
func (s *statusRecorder) Flush() {
	if f, ok := s.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

type lineWriter struct {
	mu  sync.Mutex
	out io.Writer
}

func (w *lineWriter) write(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		b = []byte(fmt.Sprintf(`{"ledger":"error","error":%q}`, err.Error()))
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	_, _ = w.out.Write(append(b, '\n'))
}

// newIngressMiddleware reads and restores the body, serves the request, then
// writes exactly one ingress line with the response status. It never rejects.
func newIngressMiddleware(next http.Handler, out io.Writer) http.Handler {
	lw := &lineWriter{out: out}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body []byte
		if r.Body != nil {
			body, _ = io.ReadAll(r.Body)
			_ = r.Body.Close()
			r.Body = io.NopCloser(bytes.NewReader(body))
		}
		line := parseIngress(r, body)
		rec := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)
		if rec.status == 0 {
			rec.status = http.StatusOK
		}
		line.Status = rec.status
		lw.write(line)
	})
}
