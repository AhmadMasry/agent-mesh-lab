package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	otelapi "go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
)

// newServedTestServer starts the fixture behind the chain main serves
// (servedHandler), with the http.Server timeouts taken from cfg as main takes
// them. tweak, if given, runs on the server before it starts.
func newServedTestServer(t *testing.T, cfg Config, tweak func(*server)) (*httptest.Server, *syncBuffer) {
	t.Helper()
	ledger := &syncBuffer{}
	s := newServer(cfg, ledger)
	if tweak != nil {
		tweak(s)
	}
	ts := httptest.NewUnstartedServer(nil)
	ts.Config.ReadHeaderTimeout = cfg.ReadHeaderTimeout
	ts.Config.ReadTimeout = cfg.ReadTimeout
	ts.Config.WriteTimeout = cfg.WriteTimeout
	ts.Config.IdleTimeout = cfg.IdleTimeout
	s.configureHTTPServer(ts.Config)
	ts.Config.Handler = servedHandler(ts.Config.Handler)
	ts.Start()
	t.Cleanup(ts.Close)
	return ts, ledger
}

type invocationForTest struct {
	Ledger            string  `json:"ledger"`
	LogicalWorkItemID string  `json:"logical_work_item_id"`
	Injection         string  `json:"injection"`
	Outcome           string  `json:"outcome"`
	LatencyMs         float64 `json:"latency_ms"`
}

// invocationsFor returns every invocation line for lwi, in order.
func invocationsFor(text, lwi string) []invocationForTest {
	var out []invocationForTest
	for _, raw := range strings.Split(strings.TrimSpace(text), "\n") {
		var l invocationForTest
		if json.Unmarshal([]byte(raw), &l) != nil || l.Ledger != "invocation" || l.LogicalWorkItemID != lwi {
			continue
		}
		out = append(out, l)
	}
	return out
}

// onlyInvocation waits for the invocation line of lwi and returns it, failing
// unless there is exactly one: a call is one line, whatever happened to it.
func onlyInvocation(t *testing.T, buf *syncBuffer, lwi string, wait time.Duration) invocationForTest {
	t.Helper()
	deadline := time.Now().Add(wait)
	for len(invocationsFor(buf.String(), lwi)) == 0 {
		if time.Now().After(deadline) {
			t.Fatalf("no invocation line for %s within %s:\n%s", lwi, wait, buf.String())
		}
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond) // room for a second line, if the code ever wrote one
	lines := invocationsFor(buf.String(), lwi)
	if len(lines) != 1 {
		t.Fatalf("%d invocation lines for %s, want exactly 1:\n%s", len(lines), lwi, buf.String())
	}
	return lines[0]
}

const delayUnary = `{"model":"m","messages":[{"role":"user","content":"hi"}]}`

// The fifth mode: it sleeps delay_ms and then answers exactly as a call with no
// injection would, only for the work item it was armed for. Another work item's
// call in the same run is neither slowed nor marked.
func TestDelay_AnswersAfterDelayForThatWorkItemOnly(t *testing.T) {
	ts, ledger := newServedTestServer(t, testConfig(), nil)
	const delayMs = 300
	mustInject(t, ts.URL, map[string]any{"mode": "delay", "lwi": "d-slow", "delay_ms": delayMs})

	start := time.Now()
	status, slow := doPost(t, ts.URL, []byte(delayUnary), map[string]string{"X-Logical-Work-Item-Id": "d-slow"})
	slowElapsed := time.Since(start)
	start = time.Now()
	status2, fast := doPost(t, ts.URL, []byte(delayUnary), map[string]string{"X-Logical-Work-Item-Id": "d-fast"})
	fastElapsed := time.Since(start)

	if status != http.StatusOK || status2 != http.StatusOK {
		t.Fatalf("statuses %d, %d, want 200, 200", status, status2)
	}
	if slowElapsed < delayMs*time.Millisecond {
		t.Errorf("the delayed call answered after %s, want at least %dms", slowElapsed, delayMs)
	}
	if fastElapsed >= delayMs*time.Millisecond {
		t.Errorf("the other work item's call took %s: the delay leaked past its work item", fastElapsed)
	}
	if !bytes.Equal(slow, fast) {
		t.Errorf("the delayed answer differs from a normal answer to the same body:\n%s\n---\n%s", slow, fast)
	}

	line := onlyInvocation(t, ledger, "d-slow", 2*time.Second)
	if line.Injection != "delay" || line.Outcome != "ok" || line.LatencyMs < delayMs {
		t.Errorf("delayed line = %+v, want injection delay, outcome ok, latency_ms >= %d", line, delayMs)
	}
	other := onlyInvocation(t, ledger, "d-fast", 2*time.Second)
	if other.Injection != "none" || other.Outcome != "ok" {
		t.Errorf("other work item's line = %+v, want injection none, outcome ok", other)
	}
}

// Keyed by count, it fires on that invocation and on no other, as the four
// older modes do.
func TestDelay_CountKeyedFiresOnlyOnThatInvocation(t *testing.T) {
	ts, ledger := newServedTestServer(t, testConfig(), nil)
	mustReset(t, ts.URL)
	mustInject(t, ts.URL, map[string]any{"mode": "delay", "at_count": 2, "delay_ms": 100})
	for _, lwi := range []string{"c-1", "c-2", "c-3"} {
		if status, _ := doPost(t, ts.URL, []byte(delayUnary), map[string]string{"X-Logical-Work-Item-Id": lwi}); status != http.StatusOK {
			t.Fatalf("%s: status %d", lwi, status)
		}
	}
	for lwi, want := range map[string]string{"c-1": "none", "c-2": "delay", "c-3": "none"} {
		if got := onlyInvocation(t, ledger, lwi, 2*time.Second); got.Injection != want || got.Outcome != "ok" {
			t.Errorf("%s: line = %+v, want injection %s, outcome ok", lwi, got, want)
		}
	}
}

// The fixture's own write deadline is set once, when the request header is
// read. A delay longer than it must still answer, and the one line reads ok.
// ReadTimeout is as short, so this also shows it does not end a call whose body
// has already been read.
func TestDelay_AnswerOutlivesTheServerWriteDeadline(t *testing.T) {
	cfg := testConfig()
	cfg.WriteTimeout = 300 * time.Millisecond
	cfg.ReadTimeout = 300 * time.Millisecond
	ts, ledger := newServedTestServer(t, cfg, nil)
	const delayMs = 900
	mustInject(t, ts.URL, map[string]any{"mode": "delay", "lwi": "d-long", "delay_ms": delayMs})

	status, body := doPost(t, ts.URL, []byte(delayUnary), map[string]string{"X-Logical-Work-Item-Id": "d-long"})
	if status != http.StatusOK || !strings.Contains(string(body), cfg.ResponseText) {
		t.Fatalf("status %d body %q, want 200 with the fixed answer", status, body)
	}
	line := onlyInvocation(t, ledger, "d-long", 2*time.Second)
	if line.Outcome != "ok" || line.LatencyMs < delayMs {
		t.Errorf("line = %+v, want outcome ok, latency_ms >= %d", line, delayMs)
	}
}

// A caller that goes away during the delay is recorded as gone, when it went,
// and never as ok: the sleep watches the request, so the line is written when
// the caller left rather than when the delay would have ended.
func TestDelay_CallerGoneMidDelayIsRecordedAsGone(t *testing.T) {
	ts, ledger := newServedTestServer(t, testConfig(), nil)
	const delayMs = 3000
	mustInject(t, ts.URL, map[string]any{"mode": "delay", "lwi": "d-gone", "delay_ms": delayMs})

	req, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(delayUnary))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("X-Logical-Work-Item-Id", "d-gone")
	client := &http.Client{Timeout: 200 * time.Millisecond, Transport: &http.Transport{DisableKeepAlives: true}}
	if resp, err := client.Do(req); err == nil {
		resp.Body.Close()
		t.Fatalf("the caller was answered (status %d) inside its own 200ms timeout", resp.StatusCode)
	}

	line := onlyInvocation(t, ledger, "d-gone", 5*time.Second)
	if line.Outcome != "client-gone" {
		t.Errorf("outcome = %q, want client-gone", line.Outcome)
	}
	if line.LatencyMs >= delayMs/2 {
		t.Errorf("latency_ms = %.1f: the line waited for the delay (%dms) instead of the caller leaving (~200ms)", line.LatencyMs, delayMs)
	}
}

// A write that fails is recorded as write-failed, through the chain main
// serves. The answer is small, so its bytes sit in net/http's buffer until the
// flush; the deadline is put in the past so that flush is what fails. The
// tracing wrapper drops the error of a flush made through it, which is why the
// fixture flushes on the innermost writer — this test is what would say if
// that stopped being true.
func TestDelay_WriteFailureIsRecorded(t *testing.T) {
	ts, ledger := newServedTestServer(t, testConfig(), func(s *server) {
		s.answerDeadline = func() time.Time { return time.Now().Add(-time.Second) }
	})
	for lwi, body := range map[string]string{
		"d-wfail":     delayUnary,
		"d-wfail-sse": `{"model":"m","stream":true,"messages":[{"role":"user","content":"hi"}]}`,
	} {
		mustInject(t, ts.URL, map[string]any{"mode": "delay", "lwi": lwi, "delay_ms": 50})
		req, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("X-Logical-Work-Item-Id", lwi)
		if resp, err := freshClient().Do(req); err == nil {
			b, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			t.Errorf("%s: the answer arrived (status %d, %q) although its write deadline had passed", lwi, resp.StatusCode, b)
		}
		if line := onlyInvocation(t, ledger, lwi, 2*time.Second); line.Outcome != "write-failed" {
			t.Errorf("%s: outcome = %q, want write-failed", lwi, line.Outcome)
		}
	}
}

// The answer keeps a write bound: WriteTimeout from the end of the delay, not
// none. The answer here is 64 MiB and the peer never reads, so the socket
// buffers fill and the write blocks; the bound is what ends it, as write-failed,
// about WriteTimeout after the delay. Without a bound the handler would block
// until the peer went away and no line would be written meanwhile.
func TestDelay_AnswerWriteIsStillBounded(t *testing.T) {
	cfg := testConfig()
	cfg.ResponseText = strings.Repeat("a", 64<<20)
	cfg.WriteTimeout = 300 * time.Millisecond
	ts, ledger := newServedTestServer(t, cfg, nil)
	const delayMs = 500
	mustInject(t, ts.URL, map[string]any{"mode": "delay", "lwi": "d-bound", "delay_ms": delayMs})

	conn, err := net.Dial("tcp", ts.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close() // after the assertions: until then this peer reads nothing
	req := "POST /v1/chat/completions HTTP/1.1\r\nHost: mockllm\r\nContent-Type: application/json\r\n" +
		"X-Logical-Work-Item-Id: d-bound\r\nContent-Length: " + strconv.Itoa(len(delayUnary)) + "\r\n\r\n" + delayUnary
	if _, err := io.WriteString(conn, req); err != nil {
		t.Fatal(err)
	}

	line := onlyInvocation(t, ledger, "d-bound", 5*time.Second)
	if line.Outcome != "write-failed" {
		t.Errorf("outcome = %q, want write-failed", line.Outcome)
	}
	if line.LatencyMs < delayMs+300 || line.LatencyMs > delayMs+3000 {
		t.Errorf("latency_ms = %.1f, want about delay (%dms) + WriteTimeout (300ms)", line.LatencyMs, delayMs)
	}
}

// waitOrGone's last check: a caller already gone when there is no delay to
// sleep is gone, not answered. On the timer path the same check covers the
// instant where the timer and the caller's leaving are both ready and select
// picks the timer, which a test cannot force.
func TestWaitOrGone(t *testing.T) {
	gone, cancel := context.WithCancel(context.Background())
	cancel()
	for _, c := range []struct {
		name string
		ctx  context.Context
		ms   int
		want bool
	}{
		{"no delay, caller there", context.Background(), 0, true},
		{"no delay, caller gone", gone, 0, false},
		{"delay, caller there", context.Background(), 5, true},
		{"delay, caller gone", gone, 1000, false},
	} {
		if got := waitOrGone(c.ctx, c.ms); got != c.want {
			t.Errorf("%s: waitOrGone = %v, want %v", c.name, got, c.want)
		}
	}
}

// On the wire, the delayed JSON answer is framed by its length, as a normal
// answer is (see unchanged_test.go's golden), and carries the same body.
func TestDelay_JSONAnswerIsLengthFramed(t *testing.T) {
	ts, _ := newServedTestServer(t, testConfig(), nil)
	mustInject(t, ts.URL, map[string]any{"mode": "delay", "lwi": "d-frame", "delay_ms": 50})
	addr := ts.Listener.Addr().String()
	delayed := rawExchange(t, addr, "d-frame", delayUnary, false)
	normal := rawExchange(t, addr, "d-frame-ref", delayUnary, false)
	head, body, _ := strings.Cut(delayed, "\r\n\r\n")
	_, refBody, _ := strings.Cut(normal, "\r\n\r\n")
	if !strings.HasPrefix(head, "HTTP/1.1 200 OK\r\n") || !strings.Contains(head, "\r\nContent-Length: 273\r\n") ||
		strings.Contains(head, "Transfer-Encoding") || body != refBody {
		t.Errorf("delayed answer:\n%s\nwant 200, Content-Length: 273, no Transfer-Encoding, and the body of\n%s", delayed, normal)
	}
}

// A streamed request answers with the same chunks as a normal streamed call.
func TestDelay_StreamedAnswer(t *testing.T) {
	ts, ledger := newServedTestServer(t, testConfig(), nil)
	mustInject(t, ts.URL, map[string]any{"mode": "delay", "lwi": "d-sse", "delay_ms": 200})
	body := []byte(`{"model":"m","stream":true,"messages":[{"role":"user","content":"hi"}]}`)
	status, got := doPost(t, ts.URL, body, map[string]string{"X-Logical-Work-Item-Id": "d-sse"})
	_, want := doPost(t, ts.URL, body, map[string]string{"X-Logical-Work-Item-Id": "d-sse-ref"})
	if status != http.StatusOK || !bytes.Equal(got, want) {
		t.Fatalf("status %d; streamed delay answer differs from a normal one:\n%s\n---\n%s", status, got, want)
	}
	if line := onlyInvocation(t, ledger, "d-sse", 2*time.Second); line.Outcome != "ok" || line.LatencyMs < 200 {
		t.Errorf("line = %+v, want outcome ok, latency_ms >= 200", line)
	}
}

// The control endpoint takes the new mode under the same rules as the other
// four, and still refuses a mode it does not know.
func TestInject_DelayModeValidation(t *testing.T) {
	ts, _ := newTestServer(t)
	for _, c := range []struct {
		body string
		code int
		msg  string
	}{
		{`{"mode":"delay","lwi":"x","delay_ms":10}`, http.StatusNoContent, ""},
		{`{"mode":"delay","at_count":1,"delay_ms":10}`, http.StatusNoContent, ""},
		{`{"mode":"delay","delay_ms":10}`, http.StatusBadRequest, "exactly one of at_count or lwi"},
		{`{"mode":"delay","lwi":"x","at_count":1}`, http.StatusBadRequest, "exactly one of at_count or lwi"},
		{`{"mode":"delay","at_count":0}`, http.StatusBadRequest, "at_count must be >= 1"},
		{`{"mode":"sleep","lwi":"x"}`, http.StatusBadRequest, "unknown mode"},
		{`{"mode":"","lwi":"x"}`, http.StatusBadRequest, "unknown mode"},
	} {
		code, got := injectResponse(t, ts.URL, c.body)
		if code != c.code || !strings.Contains(got, c.msg) {
			t.Errorf("inject %s: %d %q, want %d containing %q", c.body, code, got, c.code, c.msg)
		}
	}
}

// The mock's own server span for a delay call, through the chain main serves.
// Every delay call carries lab.injection=delay; the two outcomes where the
// answer did not leave also carry status Error, described by the outcome. The
// instrumentation still stamps http.response.status_code=200 beside that
// marking on all three: on client-gone nothing was written and 200 is its
// default; on write-failed the handler did write the header and the body it
// then failed to send, so ok and write-failed also carry the 273-byte body
// size the handler wrote. Both are asserted as measured, not hidden, and a
// reader tells what happened by the status and the ledger line, never by them.
func TestDelay_ServerSpanSaysWhatHappened(t *testing.T) {
	for _, c := range []struct {
		outcome string
		delayMs int
		tweak   func(*server)
		client  *http.Client
		code    codes.Code
		desc    string
		size    string // http.response.body.size as measured; "" is absent
	}{
		{"ok", 50, nil, freshClient(), codes.Unset, "", "273"},
		{"client-gone", 3000, nil,
			&http.Client{Timeout: 200 * time.Millisecond, Transport: &http.Transport{DisableKeepAlives: true}},
			codes.Error, "injected: delay: client-gone", ""},
		{"write-failed", 50, func(s *server) { s.answerDeadline = func() time.Time { return time.Now().Add(-time.Second) } },
			freshClient(), codes.Error, "injected: delay: write-failed", "273"},
	} {
		t.Run(c.outcome, func(t *testing.T) {
			previous := otelapi.GetTracerProvider()
			t.Cleanup(func() { otelapi.SetTracerProvider(previous) })
			sr := tracetest.NewSpanRecorder()
			otelapi.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr)))
			ts, ledger := newServedTestServer(t, testConfig(), c.tweak)
			mustInject(t, ts.URL, map[string]any{"mode": "delay", "lwi": "d-span", "delay_ms": c.delayMs})

			req, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(delayUnary))
			if err != nil {
				t.Fatal(err)
			}
			req.Header.Set("X-Logical-Work-Item-Id", "d-span")
			if resp, err := c.client.Do(req); err == nil {
				_, _ = io.ReadAll(resp.Body)
				resp.Body.Close()
			}
			if line := onlyInvocation(t, ledger, "d-span", 5*time.Second); line.Outcome != c.outcome {
				t.Fatalf("ledger outcome = %q, want %q", line.Outcome, c.outcome)
			}

			span := chatCompletionsSpan(t, sr)
			t.Logf("server span of a delay call that ended %s:\n%s", c.outcome, spanReading(span))
			if st := span.Status(); st.Code != c.code || st.Description != c.desc {
				t.Errorf("status: got %s %q, want %s %q", st.Code, st.Description, c.code, c.desc)
			}
			attrs := spanAttrs(span)
			if got := attrs["lab.injection"]; got != modeDelay {
				t.Errorf("lab.injection: got %q, want %q", got, modeDelay)
			}
			if got := attrs["http.response.status_code"]; got != "200" {
				t.Errorf("http.response.status_code beside the marking: got %q, measured %q at otelhttp v0.71.0", got, "200")
			}
			if got := attrs["http.response.body.size"]; got != c.size {
				t.Errorf("http.response.body.size beside the marking: got %q, measured %q at otelhttp v0.71.0", got, c.size)
			}
		})
	}
}
