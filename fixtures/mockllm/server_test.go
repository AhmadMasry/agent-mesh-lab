package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/http/httputil"
	"strings"
	"sync"
	"testing"
	"time"
)

// syncBuffer is a mutex-protected byte buffer. The fixture's ledgerWriter
// already serializes its own writes; this gives the test's concurrent
// reads (from the goroutine driving the HTTP client) the same protection,
// since a plain *bytes.Buffer is not safe for concurrent read/write.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// testConfig is a fast, deterministic Config for unit tests: zero latency so
// tests run quickly, generous server timeouts so slow CI machines never trip
// them.
func testConfig() Config {
	return Config{
		ResponseText:      "fixed test response",
		LatencyMs:         0,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       5 * time.Second,
	}
}

func newTestServer(t *testing.T) (*httptest.Server, *syncBuffer) {
	t.Helper()
	ledger := &syncBuffer{}
	s := newServer(testConfig(), ledger)
	ts := httptest.NewUnstartedServer(nil)
	s.configureHTTPServer(ts.Config)
	ts.Start()
	t.Cleanup(ts.Close)
	return ts, ledger
}

// freshClient never reuses a connection. That keeps every test request on a
// newly dialed connection, so Go's transport-level retry of a request found
// dead on a *reused* connection (net/http only retries when the connection
// was reused: see persistConn.shouldRetryRequest) can never mask what the
// fixture actually did on a single attempt.
func freshClient() *http.Client {
	return &http.Client{
		Timeout:   3 * time.Second,
		Transport: &http.Transport{DisableKeepAlives: true},
	}
}

func doPost(t *testing.T, base string, body []byte, headers map[string]string) (int, []byte) {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, base+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := freshClient().Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return resp.StatusCode, b
}

func mustInject(t *testing.T, base string, payload map[string]any) {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal inject payload: %v", err)
	}
	resp, err := freshClient().Post(base+"/control/inject", "application/json", bytes.NewReader(b))
	if err != nil {
		t.Fatalf("inject: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("inject: got status %d: %s", resp.StatusCode, body)
	}
}

func mustReset(t *testing.T, base string) {
	t.Helper()
	resp, err := freshClient().Post(base+"/control/reset", "application/json", nil)
	if err != nil {
		t.Fatalf("reset: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("reset: got status %d: %s", resp.StatusCode, body)
	}
}

type ledgerLineForTest struct {
	Ledger            string `json:"ledger"`
	LogicalWorkItemID string `json:"logical_work_item_id"`
	MessageID         string `json:"messageId"`
	TaskID            string `json:"taskId"`
	Injection         string `json:"injection"`
	Outcome           string `json:"outcome"`
}

// parseLedgerLines parses every JSON ledger line in text, in order.
func parseLedgerLines(text string) []ledgerLineForTest {
	var out []ledgerLineForTest
	for _, raw := range strings.Split(strings.TrimSpace(text), "\n") {
		if raw == "" {
			continue
		}
		var l ledgerLineForTest
		if err := json.Unmarshal([]byte(raw), &l); err != nil {
			continue
		}
		out = append(out, l)
	}
	return out
}

// findLastInvocationLine returns the most recent ledger=invocation line in
// text, skipping ledger=control lines interleaved by /control/* calls.
func findLastInvocationLine(text string) (ledgerLineForTest, bool) {
	lines := parseLedgerLines(text)
	for i := len(lines) - 1; i >= 0; i-- {
		if lines[i].Ledger == "invocation" {
			return lines[i], true
		}
	}
	return ledgerLineForTest{}, false
}

// lastInvocationLine waits for the handler goroutine to finish writing its
// ledger line and returns it. A wait is needed because a client can observe
// its request finish (a response fully read, or a connection error after a
// hijack-and-close) slightly before the handler goroutine that served it
// appends the ledger line.
func lastInvocationLine(t *testing.T, buf *syncBuffer) ledgerLineForTest {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		if line, ok := findLastInvocationLine(buf.String()); ok {
			return line
		}
		if time.Now().After(deadline) {
			t.Fatalf("no invocation ledger line found within timeout:\n%s", buf.String())
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// waitForLedgerLine polls buf until a line matching want appears anywhere
// in it (not just as the most recent line — stale mode writes a second,
// later "stale-closed" line alongside the earlier "stale-armed" one for
// the same call, and both must remain findable).
func waitForLedgerLine(t *testing.T, buf *syncBuffer, want func(ledgerLineForTest) bool) ledgerLineForTest {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		for _, l := range parseLedgerLines(buf.String()) {
			if want(l) {
				return l
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("no matching ledger line found within timeout:\n%s", buf.String())
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestIdenticalRequestTwiceGivesIdenticalResponseBytes(t *testing.T) {
	ts, _ := newTestServer(t)
	mustReset(t, ts.URL)
	body := []byte(`{"model":"test-model","messages":[{"role":"user","content":"hello"}]}`)

	status1, resp1 := doPost(t, ts.URL, body, nil)
	status2, resp2 := doPost(t, ts.URL, body, nil)

	if status1 != http.StatusOK || status2 != http.StatusOK {
		t.Fatalf("got statuses %d, %d, want 200, 200", status1, status2)
	}
	if len(resp1) == 0 {
		t.Fatal("expected a non-empty response body")
	}
	if !bytes.Equal(resp1, resp2) {
		t.Fatalf("responses differ:\n%s\n---\n%s", resp1, resp2)
	}
}

func TestCountKeyedInjectionFiresExactlyOnConfiguredInvocationAndNotBefore(t *testing.T) {
	ts, _ := newTestServer(t)
	mustReset(t, ts.URL)
	mustInject(t, ts.URL, map[string]any{"mode": "http500", "at_count": 3})

	body := []byte(`{"model":"m","messages":[{"role":"user","content":"hi"}]}`)
	for i := 1; i <= 4; i++ {
		status, _ := doPost(t, ts.URL, body, nil)
		want := http.StatusOK
		if i == 3 {
			want = http.StatusInternalServerError
		}
		if status != want {
			t.Fatalf("invocation %d: got status %d, want %d", i, status, want)
		}
	}
}

func TestWorkItemKeyedInjectionFiresOnlyForThatID(t *testing.T) {
	ts, _ := newTestServer(t)
	mustReset(t, ts.URL)
	mustInject(t, ts.URL, map[string]any{"mode": "http500", "lwi": "det-003"})

	body := []byte(`{"model":"m","messages":[{"role":"user","content":"hi"}]}`)

	status, _ := doPost(t, ts.URL, body, map[string]string{"X-Logical-Work-Item-Id": "det-003"})
	if status != http.StatusInternalServerError {
		t.Fatalf("det-003: got status %d, want 500", status)
	}

	status, _ = doPost(t, ts.URL, body, map[string]string{"X-Logical-Work-Item-Id": "det-004"})
	if status != http.StatusOK {
		t.Fatalf("det-004: got status %d, want 200", status)
	}

	// lwi-keyed injection fires on every call for that id, not just once.
	status, _ = doPost(t, ts.URL, body, map[string]string{"X-Logical-Work-Item-Id": "det-003"})
	if status != http.StatusInternalServerError {
		t.Fatalf("det-003 second call: got status %d, want 500", status)
	}
}

func TestHeaderAttributionWinsOverPromptToken(t *testing.T) {
	ts, ledger := newTestServer(t)
	mustReset(t, ts.URL)
	body := []byte(`{"model":"m","messages":[{"role":"user","content":"please handle lwi:prompt-id now"}]}`)

	status, _ := doPost(t, ts.URL, body, map[string]string{"X-Logical-Work-Item-Id": "header-id"})
	if status != http.StatusOK {
		t.Fatalf("got status %d, want 200", status)
	}

	line := lastInvocationLine(t, ledger)
	if line.LogicalWorkItemID != "header-id" {
		t.Fatalf("got logical_work_item_id %q, want %q", line.LogicalWorkItemID, "header-id")
	}
}

func TestPromptTokenAttributionWorksWhenHeadersAreAbsent(t *testing.T) {
	ts, ledger := newTestServer(t)
	mustReset(t, ts.URL)
	body := []byte(`{"model":"m","messages":[{"role":"user","content":"start lwi:prompt-only-id please"}]}`)

	status, _ := doPost(t, ts.URL, body, nil)
	if status != http.StatusOK {
		t.Fatalf("got status %d, want 200", status)
	}

	line := lastInvocationLine(t, ledger)
	if line.LogicalWorkItemID != "prompt-only-id" {
		t.Fatalf("got logical_work_item_id %q, want %q", line.LogicalWorkItemID, "prompt-only-id")
	}
}

func TestSSEStreamEndsWithTerminalChunkAndDone(t *testing.T) {
	ts, _ := newTestServer(t)
	mustReset(t, ts.URL)
	body := []byte(`{"model":"m","stream":true,"messages":[{"role":"user","content":"hi"}]}`)

	req, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	resp, err := freshClient().Do(req)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("got status %d, want 200", resp.StatusCode)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	text := string(b)

	if !strings.Contains(text, `"finish_reason":"stop"`) {
		t.Fatalf("missing terminal finish_reason chunk:\n%s", text)
	}
	if !strings.HasSuffix(strings.TrimRight(text, "\n"), "data: [DONE]") {
		t.Fatalf("stream does not end with data: [DONE]:\n%s", text)
	}
	finishIdx := strings.Index(text, `"finish_reason":"stop"`)
	doneIdx := strings.Index(text, "data: [DONE]")
	if finishIdx == -1 || doneIdx == -1 || finishIdx > doneIdx {
		t.Fatalf("terminal chunk must precede [DONE]:\n%s", text)
	}
}

func TestCloseModeYieldsConnectionErrorOnClientSideWithNoResponse(t *testing.T) {
	ts, ledger := newTestServer(t)
	mustReset(t, ts.URL)
	mustInject(t, ts.URL, map[string]any{"mode": "close", "at_count": 1})

	body := []byte(`{"model":"m","messages":[{"role":"user","content":"hi"}]}`)
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	resp, err := freshClient().Do(req)
	if err == nil {
		resp.Body.Close()
		t.Fatalf("expected a connection error, got response status %d", resp.StatusCode)
	}

	line := lastInvocationLine(t, ledger)
	if line.Outcome != "closed" {
		t.Fatalf("got outcome %q, want %q", line.Outcome, "closed")
	}
}

func TestDelayThenCloseWaitsAtLeastDelayMsBeforeClosing(t *testing.T) {
	ts, ledger := newTestServer(t)
	mustReset(t, ts.URL)
	const delayMs = 150
	mustInject(t, ts.URL, map[string]any{"mode": "delay-then-close", "at_count": 1, "delay_ms": delayMs})

	body := []byte(`{"model":"m","messages":[{"role":"user","content":"hi"}]}`)
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("build request: %v", err)
	}

	start := time.Now()
	resp, err := freshClient().Do(req)
	elapsed := time.Since(start)
	if err == nil {
		resp.Body.Close()
		t.Fatalf("expected a connection error, got response status %d", resp.StatusCode)
	}
	if elapsed < delayMs*time.Millisecond {
		t.Fatalf("connection error arrived after %v, want at least %dms", elapsed, delayMs)
	}

	line := lastInvocationLine(t, ledger)
	if line.Outcome != "delayed-close" {
		t.Fatalf("got outcome %q, want %q", line.Outcome, "delayed-close")
	}
}

// TestStaleModeClosesConnectionAfterItGoesIdle proves the *effect* named
// by "stale-closed" actually happens, and that a second request on that
// same connection observes a failure.
//
// This cannot be done with an ordinary http.Client, even one configured
// with MaxConnsPerHost: 1 to force reuse: measured against this fixture,
// http.Transport's built-in retry-on-reused-connection (net/http,
// persistConn.shouldRetryRequest's nothingWrittenError case) silently
// redials and re-sends the second request on a *fresh* connection and
// returns 200 with no visible error, because the failure this fixture
// produces — the server closing the socket while it sat idle in the
// client's pool, before any byte of request 2 was written — is exactly
// the one case that retry exists to paper over. (This differs from
// close/delay-then-close, which close *during* request handling: net/http
// classifies that as a response-read failure, not covered by the same
// retry path, and does not retry it — see
// TestCloseModeYieldsConnectionErrorOnClientSideWithNoResponse.) So this
// test drives both requests directly over one net.Conn via
// httputil.ClientConn, which does no pooling and no retries at all, to
// observe what actually happened on that one connection instead of what
// an http.Client's own recovery logic makes it look like from outside.
func TestStaleModeClosesConnectionAfterItGoesIdle(t *testing.T) {
	ts, ledger := newTestServer(t)
	mustReset(t, ts.URL)
	mustInject(t, ts.URL, map[string]any{"mode": "stale", "lwi": "stale-001"})

	conn, err := net.Dial("tcp", ts.Listener.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	cc := httputil.NewClientConn(conn, nil)

	body := []byte(`{"model":"m","messages":[{"role":"user","content":"hi"}]}`)

	req1, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("build request 1: %v", err)
	}
	req1.Header.Set("X-Logical-Work-Item-Id", "stale-001")
	resp1, err := cc.Do(req1)
	if err != nil {
		t.Fatalf("request 1 failed: %v", err)
	}
	if _, err := io.ReadAll(resp1.Body); err != nil {
		t.Fatalf("read response 1: %v", err)
	}
	resp1.Body.Close()
	if resp1.StatusCode != http.StatusOK {
		t.Fatalf("request 1: got status %d, want 200", resp1.StatusCode)
	}

	// Wait for connState to see this connection go idle and close it: a
	// second, later ledger line, distinct from the "stale-armed" one
	// already written by request 1's handler.
	closedLine := waitForLedgerLine(t, ledger, func(l ledgerLineForTest) bool {
		return l.Ledger == "invocation" && l.Outcome == "stale-closed" && l.LogicalWorkItemID == "stale-001"
	})
	if closedLine.Injection != "stale" {
		t.Fatalf("got injection %q on the stale-closed line, want %q", closedLine.Injection, "stale")
	}

	// The connection is now closed server-side. A second request sent
	// directly on the same net.Conn (no pooling, no retry layer to redial
	// a fresh one) must fail.
	req2, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("build request 2: %v", err)
	}
	req2.Header.Set("X-Logical-Work-Item-Id", "stale-001")
	resp2, err := cc.Do(req2)
	if err == nil {
		resp2.Body.Close()
		t.Fatalf("expected request 2 to fail on the closed connection, got status %d", resp2.StatusCode)
	}
}
