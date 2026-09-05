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

	start := time.Now()
	switch {
	case fire && mode == modeHTTP500:
		line.Injection = mode
		s.sleepMs(s.cfg.LatencyMs)
		writeJSONResponse(w, http.StatusInternalServerError, errorBody{Error: errorDetail{
			Message: "injected failure", Type: "mockllm_injected",
		}})
		line.Outcome = "http500"

	case fire && mode == modeClose:
		line.Injection = mode
		if err := s.hijackAndClose(w); err != nil {
			line.Outcome = "closed-error"
		} else {
			line.Outcome = "closed"
		}

	case fire && mode == modeDelayThenClose:
		line.Injection = mode
		s.sleepMs(delayMs)
		if err := s.hijackAndClose(w); err != nil {
			line.Outcome = "closed-error"
		} else {
			line.Outcome = "delayed-close"
		}

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
	line.TS = nowRFC3339Nano()
	line.LatencyMs = float64(time.Since(start).Microseconds()) / 1000.0
	s.ledger.writeLine(line)
}
