package httpclient

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// The lab's HTTP clients must carry no replay path beyond what net/http does
// on its own. These assertions pin the transport settings the baseline entry records.
func TestNew_TransportHasNoRetryCapableFeatures(t *testing.T) {
	c := New(30 * time.Second)
	if c.Timeout != 30*time.Second {
		t.Fatalf("client timeout = %v, want 30s", c.Timeout)
	}
	tr, ok := c.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport is %T, want *http.Transport", c.Transport)
	}
	if tr.ForceAttemptHTTP2 {
		t.Errorf("ForceAttemptHTTP2 = true, want false")
	}
	if tr.TLSNextProto == nil || len(tr.TLSNextProto) != 0 {
		t.Errorf("TLSNextProto = %v, want empty non-nil map (HTTP/2 off)", tr.TLSNextProto)
	}
	if tr.DisableKeepAlives {
		t.Errorf("DisableKeepAlives = true, want false (keep-alives on so the stale scenario is real)")
	}
	if tr.MaxIdleConnsPerHost <= 0 {
		t.Errorf("MaxIdleConnsPerHost = %d, want > 0", tr.MaxIdleConnsPerHost)
	}
	if tr.Proxy != nil {
		t.Errorf("Proxy set, want nil (no environment proxy)")
	}
	if tr.ResponseHeaderTimeout <= 0 || tr.TLSHandshakeTimeout <= 0 || tr.IdleConnTimeout <= 0 {
		t.Errorf("timeouts not all explicit: response-header %v, tls %v, idle %v", tr.ResponseHeaderTimeout, tr.TLSHandshakeTimeout, tr.IdleConnTimeout)
	}
}

func TestNew_EachCallReturnsIndependentTransport(t *testing.T) {
	a, b := New(time.Second), New(time.Second)
	if a.Transport == b.Transport {
		t.Fatalf("two clients share one transport; per-caller pools are expected")
	}
}

// closeAfterReadServer answers the first n requests by reading the body and then
// taking the connection away and closing it, which is what the worker's
// close-after-read injection does, and answers every later request with 200. It
// records the body of every request it read, so a caller can compare the bytes
// of two attempts.
type closeAfterReadServer struct {
	mu      sync.Mutex
	bodies  [][]byte
	headers []http.Header
	closes  int
	limit   int
}

func (s *closeAfterReadServer) handler(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	s.mu.Lock()
	s.bodies = append(s.bodies, body)
	s.headers = append(s.headers, r.Header.Clone())
	closeThis := s.closes < s.limit
	if closeThis {
		s.closes++
	}
	s.mu.Unlock()
	if closeThis {
		hj, ok := w.(http.Hijacker)
		if !ok {
			http.Error(w, "no hijacker", http.StatusInternalServerError)
			return
		}
		conn, _, err := hj.Hijack()
		if err != nil {
			return
		}
		_ = conn.Close()
		return
	}
	_, _ = w.Write([]byte(`{"ok":true}`))
}

func (s *closeAfterReadServer) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.bodies)
}

func postJSON(t *testing.T, c *http.Client, url, body string) (*http.Response, error) {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	return c.Do(req)
}

// The opt-in retry re-sends the same bytes and nothing else: no added header,
// and the second attempt's body equal to the first's. This is the retry the A.2
// runs switch on at the HTTP layer; it is off unless NewRetrying is asked for it.
func TestNewRetrying_ResendsIdenticalBytesOnceOnTransportError(t *testing.T) {
	srv := &closeAfterReadServer{limit: 1}
	ts := httptest.NewServer(http.HandlerFunc(srv.handler))
	defer ts.Close()

	c := NewRetrying(10*time.Second, 1)
	resp, err := postJSON(t, c, ts.URL, `{"jsonrpc":"2.0","id":"fixed","method":"SendMessage"}`)
	if err != nil {
		t.Fatalf("Do returned %v, want the second attempt to succeed", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200", resp.StatusCode)
	}
	if got := srv.count(); got != 2 {
		t.Fatalf("server read %d requests, want 2 (one closed, one answered)", got)
	}
	if !bytes.Equal(srv.bodies[0], srv.bodies[1]) {
		t.Errorf("bodies differ:\n attempt 1 %q\n attempt 2 %q", srv.bodies[0], srv.bodies[1])
	}
	for i, h := range srv.headers {
		for _, k := range []string{"Idempotency-Key", "X-Idempotency-Key"} {
			if v := h.Get(k); v != "" {
				t.Errorf("attempt %d carries %s: %q; lab code sets no idempotency header", i+1, k, v)
			}
		}
	}
}

// A response, of any status, ends the request. The retry is for a transport
// error only, so a 503 is returned to the caller and never re-sent: the A.2 runs
// measure what one client retry delivers, not what a status-code policy would.
func TestNewRetrying_DoesNotRetryOnResponse(t *testing.T) {
	var mu sync.Mutex
	seen := 0
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		mu.Lock()
		seen++
		mu.Unlock()
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer ts.Close()

	c := NewRetrying(10*time.Second, 3)
	resp, err := postJSON(t, c, ts.URL, `{"jsonrpc":"2.0","id":"fixed","method":"SendMessage"}`)
	if err != nil {
		t.Fatalf("Do returned %v, want the 503 response", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503", resp.StatusCode)
	}
	mu.Lock()
	defer mu.Unlock()
	if seen != 1 {
		t.Errorf("server saw %d requests, want 1: a response is not retried", seen)
	}
}

// The default client is unchanged by this package's opt-in addition: New has no
// retry wrapper, and against the same close-after-read server it delivers once
// and reports the transport error. NewRetrying with 0 retries is New.
func TestNew_DefaultsHaveNoRetries(t *testing.T) {
	if _, wrapped := New(time.Second).Transport.(*retryTransport); wrapped {
		t.Fatalf("New's transport is a retryTransport; the default must carry no retry")
	}
	if _, wrapped := NewRetrying(time.Second, 0).Transport.(*retryTransport); wrapped {
		t.Fatalf("NewRetrying(_, 0) wrapped the transport; zero retries must be the default client")
	}

	srv := &closeAfterReadServer{limit: 1}
	ts := httptest.NewServer(http.HandlerFunc(srv.handler))
	defer ts.Close()

	resp, err := postJSON(t, New(10*time.Second), ts.URL, `{"jsonrpc":"2.0","id":"fixed","method":"SendMessage"}`)
	if err == nil {
		_ = resp.Body.Close()
		t.Fatalf("Do succeeded; the default client must report the closed connection")
	}
	if got := srv.count(); got != 1 {
		t.Errorf("server read %d requests, want 1: the default client re-sends nothing", got)
	}
}

// statusServer answers every request with a fixed status and records the bodies
// and headers it read, so a caller can compare the bytes of two attempts and
// count how many attempts a status produced.
type statusServer struct {
	mu      sync.Mutex
	status  int
	bodies  [][]byte
	headers []http.Header
	// afterFirst, when non-zero, is the status of every request after the first.
	afterFirst int
}

func (s *statusServer) handler(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	s.mu.Lock()
	s.bodies = append(s.bodies, body)
	s.headers = append(s.headers, r.Header.Clone())
	status := s.status
	if len(s.bodies) > 1 && s.afterFirst != 0 {
		status = s.afterFirst
	}
	s.mu.Unlock()
	w.WriteHeader(status)
	_, _ = w.Write([]byte(`{"answered":true}`))
}

func (s *statusServer) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.bodies)
}

// The mode is opt-in and its default is the transport-error-only behaviour, so
// a caller that does not name a mode, or names one this package does not know,
// gets the client that re-sends on a transport error and on nothing else.
func TestParseRetryOn_DefaultsToTransport(t *testing.T) {
	for _, s := range []string{"", "transport", "503", "transport+500", "TRANSPORT+503", "yes", "transport+503 "} {
		want := RetryOnTransport
		if s == "transport+503" {
			want = RetryOnTransportOr503
		}
		if got := ParseRetryOn(s); got != want {
			t.Errorf("ParseRetryOn(%q) = %q, want %q", s, got, want)
		}
	}
	if ParseRetryOn("transport+503") != RetryOnTransportOr503 {
		t.Errorf("the one value that switches the mode on does not")
	}
	if _, wrapped := NewRetrying(time.Second, 0).Transport.(*retryTransport); wrapped {
		t.Errorf("NewRetrying(_, 0) wrapped the transport")
	}
	tr, ok := NewRetrying(time.Second, 1).Transport.(*retryTransport)
	if !ok {
		t.Fatalf("NewRetrying(_, 1) did not wrap the transport")
	}
	if tr.on != RetryOnTransport {
		t.Errorf("NewRetrying's mode = %q, want %q; the 503 mode is asked for by name or not at all", tr.on, RetryOnTransport)
	}
}

// Behind a gateway that answers 503 when the receiver's connection goes away,
// a client that re-sends only on a transport error never re-sends at all, which
// A.2 measured. This is the opt-in mode that does re-send there, and what it
// re-sends is the same bytes: same JSON-RPC id, same messageId, same body.
func TestNewRetrying_ResendsIdenticalBytesOnceOn503WhenOptedIn(t *testing.T) {
	srv := &statusServer{status: http.StatusServiceUnavailable, afterFirst: http.StatusOK}
	ts := httptest.NewServer(http.HandlerFunc(srv.handler))
	defer ts.Close()

	c := NewRetryingOn(10*time.Second, 1, RetryOnTransportOr503)
	resp, err := postJSON(t, c, ts.URL, `{"jsonrpc":"2.0","id":"fixed","method":"SendMessage"}`)
	if err != nil {
		t.Fatalf("Do returned %v, want the second attempt's response", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200: the caller gets the second response", resp.StatusCode)
	}
	if got := srv.count(); got != 2 {
		t.Fatalf("server read %d requests, want 2 (one answered 503, one answered 200)", got)
	}
	if !bytes.Equal(srv.bodies[0], srv.bodies[1]) {
		t.Errorf("bodies differ:\n attempt 1 %q\n attempt 2 %q", srv.bodies[0], srv.bodies[1])
	}
	for i, h := range srv.headers {
		for _, k := range []string{"Idempotency-Key", "X-Idempotency-Key"} {
			if v := h.Get(k); v != "" {
				t.Errorf("attempt %d carries %s: %q; lab code sets no idempotency header", i+1, k, v)
			}
		}
	}
}

// 503 and nothing else. A success, a server error and a not-found are all
// answers, and this mode is a narrow allowance for one gateway behaviour rather
// than a general retry-on-failure policy.
func TestNewRetrying_503ModeDoesNotRetryOnOtherResponses(t *testing.T) {
	for _, status := range []int{http.StatusOK, http.StatusInternalServerError, http.StatusNotFound, http.StatusBadGateway, http.StatusGatewayTimeout} {
		srv := &statusServer{status: status}
		ts := httptest.NewServer(http.HandlerFunc(srv.handler))

		c := NewRetryingOn(10*time.Second, 3, RetryOnTransportOr503)
		resp, err := postJSON(t, c, ts.URL, `{"jsonrpc":"2.0","id":"fixed","method":"SendMessage"}`)
		if err != nil {
			ts.Close()
			t.Fatalf("status %d: Do returned %v, want the response", status, err)
		}
		_ = resp.Body.Close()
		if resp.StatusCode != status {
			t.Errorf("status = %d, want %d", resp.StatusCode, status)
		}
		if got := srv.count(); got != 1 {
			t.Errorf("status %d: server saw %d requests, want 1", status, got)
		}
		ts.Close()
	}
}

// The default mode is unchanged by the addition: a 503 is an answer and ends
// the request, which is what the first A.2 sub-row of each client measured.
func TestNewRetrying_DoesNotRetryOn503ByDefault(t *testing.T) {
	srv := &statusServer{status: http.StatusServiceUnavailable, afterFirst: http.StatusOK}
	ts := httptest.NewServer(http.HandlerFunc(srv.handler))
	defer ts.Close()

	c := NewRetryingOn(10*time.Second, 3, RetryOnTransport)
	resp, err := postJSON(t, c, ts.URL, `{"jsonrpc":"2.0","id":"fixed","method":"SendMessage"}`)
	if err != nil {
		t.Fatalf("Do returned %v, want the 503 response", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503", resp.StatusCode)
	}
	if got := srv.count(); got != 1 {
		t.Errorf("server saw %d requests, want 1: the default mode does not re-send on a 503", got)
	}
}

// The 503 mode still re-sends on a transport error; it adds a case rather than
// replacing one.
func TestNewRetrying_503ModeStillResendsOnTransportError(t *testing.T) {
	srv := &closeAfterReadServer{limit: 1}
	ts := httptest.NewServer(http.HandlerFunc(srv.handler))
	defer ts.Close()

	c := NewRetryingOn(10*time.Second, 1, RetryOnTransportOr503)
	resp, err := postJSON(t, c, ts.URL, `{"jsonrpc":"2.0","id":"fixed","method":"SendMessage"}`)
	if err != nil {
		t.Fatalf("Do returned %v, want the second attempt to succeed", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if got := srv.count(); got != 2 {
		t.Errorf("server read %d requests, want 2", got)
	}
}

// The 503 mode re-sends up to the retry count and then stops: a second 503 is
// the caller's answer, not the start of a third attempt. This is the bound on
// the path the A.2 503 sub-rows exercised.
func TestNewRetrying_503ModeReturnsSecond503(t *testing.T) {
	srv := &statusServer{status: http.StatusServiceUnavailable}
	ts := httptest.NewServer(http.HandlerFunc(srv.handler))
	defer ts.Close()

	c := NewRetryingOn(10*time.Second, 1, RetryOnTransportOr503)
	resp, err := postJSON(t, c, ts.URL, `{"jsonrpc":"2.0","id":"fixed","method":"SendMessage"}`)
	if err != nil {
		t.Fatalf("Do returned %v, want the second 503", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503: the second answer is the caller's", resp.StatusCode)
	}
	if got := srv.count(); got != 2 {
		t.Errorf("server read %d requests, want 2: one retry, then stop", got)
	}
	if !bytes.Equal(srv.bodies[0], srv.bodies[1]) {
		t.Errorf("bodies differ:\n attempt 1 %q\n attempt 2 %q", srv.bodies[0], srv.bodies[1])
	}
}
