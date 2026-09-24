package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
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
	// LWISource is written only when logical_work_item_id did not come from the
	// body. A2A v1.0's SubscribeToTask carries no Message and therefore no
	// metadata (specification v1.0.1 §9.4.6), so the only identity such a
	// delivery can be collected by is the header the load client puts on every
	// request. Absent means the body carried the id, so a line never implies a
	// body field that was not there.
	LWISource string `json:"lwi_source,omitempty"`
	// TSEnd and StreamEnd are written on the response line of a streamed
	// response only, which is a response this receiver actually sent as
	// text/event-stream. A unary response's line carries neither, so its shape
	// is what it was before streaming was served at all.
	//
	// The response line of a stream is written when the handler returns, which
	// for SSE is when the stream ended, so ts_arrival alone cannot say when that
	// was; ts_end is that stamp. stream_end says how it ended, from what this
	// boundary can observe: write-failed when a write to the client returned an
	// error, client-gone when the request context was cancelled (net/http
	// cancels it when the client's connection closes), complete otherwise. A
	// write error is reported ahead of a cancellation because it is the more
	// specific observation: the bytes did not leave.
	//
	// complete says only that this receiver's handler returned with neither of
	// those observed. It is not evidence that a terminal event was sent: this
	// boundary counts bytes and never reads the events, so a handler that
	// stopped early and a task that reached a terminal state look the same here.
	// What the stream carried is the execution ledger's delivered lines, and
	// what the Task did is its state lines.
	TSEnd     string `json:"ts_end,omitempty"`
	StreamEnd string `json:"stream_end,omitempty"`
	// Headers is the header reading (headers.go), written on the arrival line
	// only and only with LEDGER_HEADERS=on. Last, and absent when off, so a line
	// written with the setting off is byte for byte the line written before the
	// setting existed.
	Headers *headerRecord `json:"headers,omitempty"`
}

const (
	streamEndComplete    = "complete"
	streamEndClientGone  = "client-gone"
	streamEndWriteFailed = "write-failed"
)

// responseLine turns an arrival line into the matching response line. Every
// response line carries a status, including 0 for a connection closed before
// anything was written.
func responseLine(arrival ingressLine, status int, injection string) ingressLine {
	line := arrival
	line.Phase = "response"
	line.Headers = nil
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
		// Only a JSON-RPC delivery whose body carried no work item falls back to
		// the header, and it says so. A request that is not JSON-RPC — the agent
		// card fetch above all — keeps the empty work item it has always had, so
		// what a work item's collection contains does not change for any traffic
		// that existed before streaming was served.
		if line.LogicalWorkItemID == "" {
			if v := r.Header.Get("X-Logical-Work-Item-Id"); v != "" {
				line.LogicalWorkItemID = v
				line.LWISource = "header"
			}
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

// deadlineKey carries a request's write-deadline lift down the handler chain.
type deadlineKey struct{}

// newWriteDeadlineLift must wrap the OUTERMOST handler, because it is the only
// place where the ResponseWriter is still net/http's own: measured through this
// process's chain, http.NewResponseController inside the handler answers
// "feature not supported", since neither the tracing instrumentation's wrapper
// nor this ledger's recorder offers SetWriteDeadline or Unwrap. So the lift is
// taken here, where it works, and handed on for the recorder to use when — and
// only when — the response actually goes out as Server-Sent Events.
//
// Why it is needed: http.Server.WriteTimeout bounds the whole response and is
// set once, when the request's header is read (net/http server.go), so a stream
// that outlives it is cut by this receiver itself. That cut is
// indistinguishable at every ledger from a transport that went away: the
// request context is cancelled and the SDK answers "queue read failed: context
// canceled", which is exactly the shape Experiment B counts as a lost
// transport. Lifting it per streaming request, rather than lowering the
// server's default for every request, keeps the bound on unary traffic where it
// is useful and removes this receiver from the list of things that can end a
// stream.
func newWriteDeadlineLift(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		controller := http.NewResponseController(w)
		lift := func() error { return controller.SetWriteDeadline(time.Time{}) }
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), deadlineKey{}, lift)))
	})
}

func liftFrom(ctx context.Context) func() error {
	lift, _ := ctx.Value(deadlineKey{}).(func() error)
	return lift
}

type statusRecorder struct {
	http.ResponseWriter
	status int
	// liftWriteDeadline removes this response's write deadline, or is nil when
	// nothing upstream could offer one. Called once, when the response turns out
	// to be a stream.
	liftWriteDeadline func() error
	deadlineLifted    bool
	// contentType is the type this receiver actually sent, read when the header
	// was written. It is what says a response was a stream: the ledger records
	// the response that left, not the one the method name implies.
	contentType string
	// writeErr is the first error a write to the client returned. The SDK's SSE
	// writer reports it and stops; keeping it here is how the response line can
	// say the stream ended because its bytes did not leave.
	writeErr error
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.contentType = s.Header().Get("Content-Type")
	s.liftDeadlineIfStreaming()
	s.ResponseWriter.WriteHeader(code)
}

// liftDeadlineIfStreaming removes this response's write deadline once the
// response turns out to be a stream, so that the server's own WriteTimeout
// cannot end one. A failure is logged and nothing else: the ledger's job is to
// record what happened, and the run that follows reads the line.
func (s *statusRecorder) liftDeadlineIfStreaming() {
	if s.deadlineLifted || !s.streamed() || s.liftWriteDeadline == nil {
		return
	}
	s.deadlineLifted = true
	if err := s.liftWriteDeadline(); err != nil {
		log.Printf("ingress: could not lift the write deadline for a streamed response: %v", err)
	}
}

func (s *statusRecorder) Write(b []byte) (int, error) {
	if s.status == 0 {
		s.status = http.StatusOK
		s.contentType = s.Header().Get("Content-Type")
	}
	s.liftDeadlineIfStreaming()
	n, err := s.ResponseWriter.Write(b)
	if err != nil && s.writeErr == nil {
		s.writeErr = err
	}
	return n, err
}

// streamed says this response left as Server-Sent Events, which is the
// transport A2A v1.0's JSON-RPC binding streams over.
func (s *statusRecorder) streamed() bool {
	return strings.HasPrefix(s.contentType, "text/event-stream")
}

// streamEnd reads how a streamed response ended from the two things this
// boundary can see: whether a write to the client failed, and whether the
// request context was cancelled under the handler.
func (s *statusRecorder) streamEnd(r *http.Request) string {
	switch {
	case s.writeErr != nil:
		return streamEndWriteFailed
	case r.Context().Err() != nil:
		return streamEndClientGone
	default:
		return streamEndComplete
	}
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
//
// opts are the ledger's settings; with none the ledger is what it was before any
// existed.
func newIngressMiddleware(next http.Handler, lw *lineWriter, inj *injector, opts ...ingressOption) http.Handler {
	var cfg ingressConfig
	for _, o := range opts {
		o(&cfg)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body []byte
		if r.Body != nil {
			body, _ = io.ReadAll(r.Body)
			_ = r.Body.Close()
			r.Body = io.NopCloser(bytes.NewReader(body))
		}
		line := parseIngress(r, body)
		if cfg.headers {
			line.Headers = readHeaders(r)
		}
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
				// A taken connection also marks this request's own server span,
				// which the HTTP instrumentation would otherwise leave reading 200
				// with status Unset (labotel.MarkInjection has the measurement).
				// Only a taken one: the 500 below is a real answer that the span
				// already reads as Error, and a marking there would name a close
				// that did not happen (span_test.go; reading-notes.txt in
				// experiments/runs/2026-09-19-worker-span-on-injected-close/).
				// The ledger lines are what they were.
				if hijacked {
					labotel.MarkInjection(r.Context(), mode, err)
				}
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
		rec := &statusRecorder{ResponseWriter: w, liftWriteDeadline: liftFrom(r.Context())}
		next.ServeHTTP(rec, r)
		if rec.status == 0 {
			rec.status = http.StatusOK
		}
		response := responseLine(line, rec.status, "")
		if rec.streamed() {
			response.TSEnd = time.Now().UTC().Format(time.RFC3339Nano)
			response.StreamEnd = rec.streamEnd(r)
		}
		lw.write(response)
	})
}
