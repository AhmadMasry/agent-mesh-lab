package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"sync"
	"time"
)

// ingressLine is one pre-dispatch ingress ledger record. Every physical HTTP
// delivery produces two lines sharing ts_arrival and body_sha256: an "arrival"
// line written before the A2A SDK sees the request, so a delivery is counted
// even if its handler never returns, and a "response" line afterwards carrying
// the status. Identity fields are filled from the JSON-RPC body when it parses;
// a body that does not parse still produces lines with its hash and length.
type ingressLine struct {
	Ledger            string `json:"ledger"`
	Phase             string `json:"phase"`
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
	// Status is a pointer so the two cases stay distinguishable on the wire: an
	// arrival line, which carries no status key at all, and a response line for
	// a connection closed before any status was written, which carries an
	// explicit 0. A plain int with omitempty would collapse them, and the
	// Python receiver writes status unconditionally on response lines.
	Status *int `json:"status,omitempty"`
	// Injection names the receiver-side mode that fired for this delivery, on
	// the response line only. Absent on every request that was served normally.
	Injection string `json:"injection,omitempty"`
}

// responseLine turns an arrival line into the matching response line. Every
// response line carries a status, including 0 for a connection closed before
// anything was written.
func responseLine(arrival ingressLine, status int, injection string) ingressLine {
	line := arrival
	line.Phase = "response"
	line.Status = &status
	line.Injection = injection
	return line
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
		Phase:       "arrival",
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

// lineWriter serialises every ledger line of a process onto one stream. One
// instance is shared by the ingress, execution, and executor writers.
type lineWriter struct {
	mu  sync.Mutex
	out io.Writer
}

func newLineWriter(out io.Writer) *lineWriter { return &lineWriter{out: out} }

func (w *lineWriter) write(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		b = []byte(fmt.Sprintf(`{"ledger":"error","error":%q}`, err.Error()))
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	_, _ = w.out.Write(append(b, '\n'))
}

// hijackAndClose takes the connection away from net/http and closes it, so the
// client sees the connection go away with no status of any kind. hijacked says
// whether the connection was taken: while it is false the caller still owns the
// ResponseWriter and may answer, and once it is true nothing may be written, so
// a close error is reported with hijacked true and no response is possible.
func hijackAndClose(w http.ResponseWriter) (hijacked bool, err error) {
	hj, ok := w.(http.Hijacker)
	if !ok {
		return false, errors.New("response writer does not support hijacking")
	}
	conn, _, err := hj.Hijack()
	if err != nil {
		return false, err
	}
	return true, conn.Close()
}

// newIngressMiddleware reads and restores the body, writes the arrival line,
// serves the request, then writes the response line with the status. It rejects
// a request only when the injector has an armed work item matching it, and then
// only after the delivery has already been counted on the arrival line.
func newIngressMiddleware(next http.Handler, lw *lineWriter, inj *injector) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body []byte
		if r.Body != nil {
			body, _ = io.ReadAll(r.Body)
			_ = r.Body.Close()
			r.Body = io.NopCloser(bytes.NewReader(body))
		}
		line := parseIngress(r, body)
		lw.write(line)
		// The arrival is on the ledger before this point, so an injected
		// failure is still a counted delivery. take disarms the work item, so
		// one arming fires once; nothing here repeats or retries.
		if mode, ok := inj.take(line.LogicalWorkItemID); ok {
			switch mode {
			case modeHTTP503BeforeDispatch:
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusServiceUnavailable)
				_, _ = w.Write([]byte(`{"error":"injected"}`))
				lw.write(responseLine(line, http.StatusServiceUnavailable, mode))
				return
			case modeCloseAfterRead:
				// Recorded as what actually reached the client, not as the close
				// that was asked for: 0 when the connection was taken away, and
				// the status actually written when it could not be.
				status := 0
				hijacked, err := hijackAndClose(w)
				switch {
				case !hijacked:
					log.Printf("ingress: close-after-read could not hijack the connection: %v", err)
					w.WriteHeader(http.StatusInternalServerError)
					status = http.StatusInternalServerError
				case err != nil:
					// Taken away, so nothing may be written; the client sees the
					// connection go away either way.
					log.Printf("ingress: close-after-read hijacked the connection but closing it failed: %v", err)
				}
				lw.write(responseLine(line, status, mode))
				return
			default:
				// Unreachable while arm is unexported and every routed path
				// validates the mode. Serving the request normally keeps an
				// unknown mode from turning into a dropped delivery.
				log.Printf("ingress: armed mode %q is not served here; serving the request normally", mode)
			}
		}
		rec := &statusRecorder{ResponseWriter: w}
		next.ServeHTTP(rec, r)
		if rec.status == 0 {
			rec.status = http.StatusOK
		}
		lw.write(responseLine(line, rec.status, ""))
	})
}
