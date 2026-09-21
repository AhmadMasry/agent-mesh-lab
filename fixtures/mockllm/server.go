package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
)

var errNotHijackable = errors.New("response writer does not support hijacking")

// Config holds the values that make responses deterministic (ResponseText,
// LatencyMs, both overridable by environment) and the explicit http.Server
// timeouts (fixed, chosen by this fixture; mockllm makes no outbound calls,
// so there is no HTTP client to configure retries on).
type Config struct {
	ResponseText string
	LatencyMs    int

	ReadHeaderTimeout time.Duration
	ReadTimeout       time.Duration
	WriteTimeout      time.Duration
	IdleTimeout       time.Duration
}

type ctxKey int

const connFlagCtxKey ctxKey = 0

type server struct {
	cfg    Config
	mux    *http.ServeMux
	ledger ledgerWriter

	mu              sync.Mutex
	invocationCount int
	injection       *injectionConfig

	// connFlags maps a live net.Conn to the flag the stale-mode handler
	// sets to ask for that connection to be closed the next time it goes
	// idle. Populated in connContext, read and cleaned up in connState.
	connFlags sync.Map

	// answerDeadline is the write deadline a delay-mode answer is given when
	// its delay ends (see delayThenAnswer). A field only so a test can put it
	// in the past and make the write fail on a real socket.
	answerDeadline func() time.Time
}

// connFlag is stale mode's per-connection state. armStaleClose sets
// identity then stores armed=true (in that order); connState's StateIdle
// case only ever reads identity after observing armed==true, so the plain
// identity field needs no separate lock: Go's atomics are sequentially
// consistent, so the identity write happens-before the read that follows
// the armed load. closed guards against writing the close ledger line (or
// closing the conn) more than once.
type connFlag struct {
	armed    atomic.Bool
	closed   atomic.Bool
	identity identity
}

func newServer(cfg Config, ledgerOut io.Writer) *server {
	s := &server{cfg: cfg, ledger: ledgerWriter{out: ledgerOut}}
	s.answerDeadline = func() time.Time {
		if cfg.WriteTimeout <= 0 {
			return time.Time{} // no deadline, as net/http reads a zero WriteTimeout
		}
		return time.Now().Add(cfg.WriteTimeout)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/chat/completions", s.handleChatCompletions)
	mux.HandleFunc("/control/inject", s.handleInject)
	mux.HandleFunc("/control/reset", s.handleReset)
	mux.HandleFunc("/healthz", s.handleHealthz)
	s.mux = mux
	return s
}

// configureHTTPServer wires this server's handler and connection tracking
// into hs. hs's timeouts (ReadHeaderTimeout etc.) are set by the caller
// (main, or a test) from the same Config.
func (s *server) configureHTTPServer(hs *http.Server) {
	hs.Handler = s.mux
	hs.ConnContext = s.connContext
	hs.ConnState = s.connState
}

func (s *server) connContext(ctx context.Context, c net.Conn) context.Context {
	flag := &connFlag{}
	s.connFlags.Store(c, flag)
	return context.WithValue(ctx, connFlagCtxKey, flag)
}

// connState is stale mode's second half. armStaleClose (called from the
// handler, while serving the response normally) only arms the connection;
// the close — and the ledger line recording it — happens here, if and
// only if this specific connection later reaches StateIdle. A connection
// that never idles (the client sends Connection: close, drops the
// connection itself, or the pod is torn down first) stays armed forever
// with no close and no second ledger line: that absence is itself
// informative, not a bug, so callers must not assume "stale-armed" implies
// a matching "stale-closed".
func (s *server) connState(c net.Conn, state http.ConnState) {
	switch state {
	case http.StateIdle:
		if v, ok := s.connFlags.Load(c); ok {
			if flag, ok := v.(*connFlag); ok && flag.armed.Load() && flag.closed.CompareAndSwap(false, true) {
				_ = c.Close()
				s.ledger.writeLine(invocationLine{
					Ledger:            "invocation",
					TS:                nowRFC3339Nano(),
					LogicalWorkItemID: flag.identity.LWI,
					MessageID:         flag.identity.MessageID,
					TaskID:            flag.identity.TaskID,
					Caller:            flag.identity.Caller,
					Injection:         modeStale,
					Outcome:           "stale-closed",
				})
			}
		}
	case http.StateClosed, http.StateHijacked:
		s.connFlags.Delete(c)
	}
}

func (s *server) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (s *server) handleInject(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "failed to read request body", http.StatusBadRequest)
		return
	}
	var req injectRequest
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}
	cfg, err := newInjectionConfig(req)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	s.mu.Lock()
	s.injection = cfg
	s.mu.Unlock()

	s.ledger.writeLine(controlLine{
		Ledger:   "control",
		TS:       nowRFC3339Nano(),
		Endpoint: "/control/inject",
		Detail:   string(body),
	})
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) handleReset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	s.mu.Lock()
	s.invocationCount = 0
	s.injection = nil
	s.mu.Unlock()

	s.ledger.writeLine(controlLine{
		Ledger:   "control",
		TS:       nowRFC3339Nano(),
		Endpoint: "/control/reset",
	})
	w.WriteHeader(http.StatusNoContent)
}

func (s *server) nextInvocationCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.invocationCount++
	return s.invocationCount
}

func (s *server) checkInjection(count int, lwi string) (fire bool, mode string, delayMs int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.injection == nil {
		return false, "", 0
	}
	if !s.injection.fires(count, lwi) {
		return false, "", 0
	}
	return true, s.injection.Mode, s.injection.DelayMs
}

func (s *server) sleepMs(ms int) {
	if ms > 0 {
		time.Sleep(time.Duration(ms) * time.Millisecond)
	}
}

func (s *server) hijackAndClose(w http.ResponseWriter) error {
	hj, ok := w.(http.Hijacker)
	if !ok {
		return errNotHijackable
	}
	conn, _, err := hj.Hijack()
	if err != nil {
		return err
	}
	return conn.Close()
}

// armStaleClose arms this connection for a close on its next StateIdle
// (handled in connState), carrying ident so the resulting "stale-closed"
// ledger line is attributable to the same work item as this "stale-armed"
// one. identity is written before armed is set (see connFlag's comment).
func (s *server) armStaleClose(r *http.Request, ident identity) {
	if flag, ok := r.Context().Value(connFlagCtxKey).(*connFlag); ok {
		flag.identity = ident
		flag.armed.Store(true)
	}
}

func (s *server) writeNormalResponse(w http.ResponseWriter, req chatCompletionRequest, bodySHA256 string) {
	if req.Stream {
		writeSSEResponse(w, s.cfg.ResponseText, bodySHA256, req)
		return
	}
	writeJSONResponse(w, http.StatusOK, buildResponse(s.cfg.ResponseText, bodySHA256, req))
}

// The three outcomes of a delay-mode call. Each is read from one thing:
//
//   - outcomeClientGone: the request context was done before the answer was
//     written. net/http cancels it when its background read of the connection
//     ends, which is the caller closing or resetting it (a caller's own timeout
//     does exactly that), and also a caller that only half-closed its sending
//     side: a half-close alone counts as client-gone. The handler writes no
//     answer; net/http then sends the empty 200 (Content-Length: 0) a handler
//     that wrote nothing gets, which a caller that only half-closed receives.
//   - outcomeWriteFailed: a write or a flush of the answer returned an error.
//     A write that fails also cancels the request context in net/http, so the
//     context is not consulted once writing has begun: the error decides.
//   - outcomeOK: every write and the final flush returned nil, meaning the
//     answer's bytes were handed to the kernel's socket buffer. That is what
//     the fixture can see; it is not proof the caller read them.
const (
	outcomeOK          = "ok"
	outcomeClientGone  = "client-gone"
	outcomeWriteFailed = "write-failed"
)

// waitOrGone sleeps ms milliseconds unless ctx ends first, and reports whether
// the caller is still there. A caller that left as the delay ended counts as
// gone: no answer is written to it. The last check covers two windows: no delay
// at all with the caller already gone (pinned by TestWaitOrGone), and, on the
// timer path, the instant where the timer and the caller's leaving are both
// ready and select picks the timer, which select decides at random and a test
// cannot force.
func waitOrGone(ctx context.Context, ms int) bool {
	if ms > 0 {
		timer := time.NewTimer(time.Duration(ms) * time.Millisecond)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-ctx.Done():
			return false
		}
	}
	return ctx.Err() == nil
}

// innermost follows Unwrap down to the writer net/http itself created.
func innermost(w http.ResponseWriter) http.ResponseWriter {
	for {
		u, ok := w.(interface{ Unwrap() http.ResponseWriter })
		if !ok {
			return w
		}
		w = u.Unwrap()
	}
}

// answerWriter is the chain's writer with every write and flush error kept.
// Headers and body go through the chain as for any answer; flushes go to the
// innermost writer's controller, whose Flush returns the socket write's error.
type answerWriter struct {
	http.ResponseWriter
	rc  *http.ResponseController
	err error
}

func (a *answerWriter) Write(p []byte) (int, error) {
	n, err := a.ResponseWriter.Write(p)
	a.keep(err)
	return n, err
}

func (a *answerWriter) Flush() { a.keep(a.rc.Flush()) }

func (a *answerWriter) keep(err error) {
	if a.err == nil {
		a.err = err
	}
}

// delayThenAnswer is the delay mode: sleep delayMs (in place of the fixture's
// LatencyMs, as delay-then-close does), then answer as a call with no
// injection would, and return what happened to the answer.
//
// The write deadline. net/http sets it once, when the request header is read,
// to WriteTimeout later (10 s in main), and the handler does not move it; an
// answer written after a longer delay would fail at the socket. So when the
// delay ends, this answer is given a deadline of its own: WriteTimeout from
// that moment (answerDeadline), the same budget a normal answer gets from its
// header. The bound stays; it is only counted from when the answer starts.
//
// What this chain lets a handler reach (measured through servedHandler, the
// otelhttp handler at the pinned version): SetWriteDeadline on the chain's
// writer reaches net/http's, but a Flush through it does not report the
// socket's error — otelhttp's Flush hook calls the plain http.Flusher, which
// has none, so a failed write reads as a clean flush. Every layer of this chain
// offers Unwrap, so both the deadline and the flush are taken on the innermost
// writer, net/http's own. TestDelay_WriteFailureIsRecorded runs through
// servedHandler and fails if that stops being true.
//
// A JSON answer is written with an explicit Content-Length: flushing before
// the handler returns would otherwise send it chunked, where a normal answer
// is framed by the length net/http computes. Framing and body bytes are the
// same as a normal answer's; the header block differs in order only
// (Content-Length is written before Content-Type and Date here, after them in
// a normal answer).
//
// The span. The mock's own server span is marked with lab.injection=delay, and
// with status Error named by the outcome when the answer did not leave
// (labotel.MarkInjectionOutcome, which has what the instrumentation still
// stamps beside it).
func (s *server) delayThenAnswer(w http.ResponseWriter, r *http.Request, req chatCompletionRequest, bodySHA256 string, delayMs int) string {
	if !waitOrGone(r.Context(), delayMs) {
		return outcomeClientGone
	}
	rc := http.NewResponseController(innermost(w))
	// If the deadline cannot be moved, the one net/http set stands, and a write
	// past it fails and is recorded as write-failed below.
	_ = rc.SetWriteDeadline(s.answerDeadline())
	aw := &answerWriter{ResponseWriter: w, rc: rc}
	if req.Stream {
		writeSSEResponse(aw, s.cfg.ResponseText, bodySHA256, req)
	} else {
		writeLengthFramedJSON(aw, buildResponse(s.cfg.ResponseText, bodySHA256, req))
	}
	aw.Flush()
	if aw.err != nil {
		return outcomeWriteFailed
	}
	return outcomeOK
}

func (s *server) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	bodyBytes, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "failed to read request body", http.StatusBadRequest)
		return
	}
	sum := sha256.Sum256(bodyBytes)
	bodySHA256 := hex.EncodeToString(sum[:])

	var req chatCompletionRequest
	_ = json.Unmarshal(bodyBytes, &req) // best-effort: zero values on malformed input

	ident := resolveIdentity(r, req)
	count := s.nextInvocationCount()
	fire, mode, delayMs := s.checkInjection(count, ident.LWI)

	line := invocationLine{
		Ledger:            "invocation",
		LogicalWorkItemID: ident.LWI,
		MessageID:         ident.MessageID,
		TaskID:            ident.TaskID,
		Caller:            ident.Caller,
		BodySHA256:        bodySHA256,
		Stream:            req.Stream,
		Injection:         "none",
	}

	// The ledger line is written from a defer that reads the final line, so a
	// call is counted even when serving it does not finish normally: a hijacked
	// connection, or a panic on the way out. The second, asynchronous
	// "stale-closed" line still comes from connState, not from here.
	start := time.Now()
	defer func() {
		line.TS = nowRFC3339Nano()
		line.LatencyMs = float64(time.Since(start).Microseconds()) / 1000.0
		s.ledger.writeLine(line)
	}()

	switch {
	case fire && mode == modeHTTP500:
		line.Injection = mode
		s.sleepMs(s.cfg.LatencyMs)
		writeJSONResponse(w, http.StatusInternalServerError, errorBody{Error: errorDetail{
			Message: "injected failure", Type: "mockllm_injected",
		}})
		line.Outcome = "http500"

	// The two modes that end a request with no response also mark this
	// request's own server span, because the HTTP instrumentation cannot see a
	// hijacked connection and would otherwise leave the span reading 200 with
	// status Unset (labotel.MarkInjection has the measurement and the source
	// lines). The ledger line is what it was: same fields, same outcomes.
	case fire && mode == modeClose:
		line.Injection = mode
		err := s.hijackAndClose(w)
		labotel.MarkInjection(r.Context(), mode, err)
		if err != nil {
			line.Outcome = "closed-error"
		} else {
			line.Outcome = "closed"
		}

	case fire && mode == modeDelayThenClose:
		line.Injection = mode
		s.sleepMs(delayMs)
		err := s.hijackAndClose(w)
		labotel.MarkInjection(r.Context(), mode, err)
		if err != nil {
			line.Outcome = "closed-error"
		} else {
			line.Outcome = "delayed-close"
		}

	case fire && mode == modeDelay:
		line.Injection = mode
		line.Outcome = s.delayThenAnswer(w, r, req, bodySHA256, delayMs)
		labotel.MarkInjectionOutcome(r.Context(), mode, line.Outcome, line.Outcome == outcomeOK)

	case fire && mode == modeStale:
		// Two ledger lines for one stale injection: this "stale-armed" one,
		// recorded synchronously here once the response is served, and a
		// second "stale-closed" one from connState — only if and when this
		// connection actually reaches StateIdle and gets closed. See
		// connState's comment.
		line.Injection = mode
		s.sleepMs(s.cfg.LatencyMs)
		s.writeNormalResponse(w, req, bodySHA256)
		s.armStaleClose(r, ident)
		line.Outcome = "stale-armed"

	default:
		s.sleepMs(s.cfg.LatencyMs)
		s.writeNormalResponse(w, req, bodySHA256)
		line.Outcome = "ok"
	}
}
