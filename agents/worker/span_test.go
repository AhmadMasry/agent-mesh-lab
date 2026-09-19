package main

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	otelapi "go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
)

// tracedWorker is the root mux wrapped the way main wraps it (labotel.Handler
// around newRootMux, so the control endpoints and the ingress middleware are both
// inside the tracing handler), with an in-memory span recorder installed as the
// global tracer provider, which is where otelhttp reads its provider from when the
// handler is built. The provider is process-wide, so the previous one is put back
// afterwards. The A2A handler behind the ledger answers 200 and counts its calls.
type tracedWorker struct {
	handler http.Handler
	ledger  *syncBuffer
	spans   *tracetest.SpanRecorder
	a2a     *atomic.Int32
}

func newTracedWorker(t *testing.T) tracedWorker {
	t.Helper()
	previous := otelapi.GetTracerProvider()
	t.Cleanup(func() { otelapi.SetTracerProvider(previous) })
	sr := tracetest.NewSpanRecorder()
	otelapi.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr)))

	out := &syncBuffer{}
	calls := &atomic.Int32{}
	a2a := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { calls.Add(1); w.WriteHeader(http.StatusOK) })
	root := newRootMux(a2a, newLineWriter(out), newInjector())
	return tracedWorker{handler: labotel.Handler("worker", root), ledger: out, spans: sr, a2a: calls}
}

// noReplayClient has keep-alives off, so net/http cannot replay a request on a
// connection it found dead (it only retries reused connections): one send is one
// delivery, which is what the close-after-read row counts.
func noReplayClient() *http.Client {
	return &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{DisableKeepAlives: true}}
}

// armOverHTTP arms through the control endpoint of the served mux, as a run
// script does.
func armOverHTTP(t *testing.T, base, mode, lwi string) {
	t.Helper()
	resp, err := noReplayClient().Post(base+"/control/inject", "application/json",
		strings.NewReader(fmt.Sprintf(`{"mode":%q,"lwi":%q}`, mode, lwi)))
	if err != nil {
		t.Fatalf("arm %s: %v", mode, err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("arm %s: status = %d, want 204", mode, resp.StatusCode)
	}
}

// armInProcess arms through the same routed control endpoint for the rows that
// need a ResponseWriter of their own and so cannot go over a real connection.
func armInProcess(t *testing.T, h http.Handler, mode, lwi string) {
	t.Helper()
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/control/inject",
		strings.NewReader(fmt.Sprintf(`{"mode":%q,"lwi":%q}`, mode, lwi))))
	if w.Code != http.StatusNoContent {
		t.Fatalf("arm %s: status = %d, want 204", mode, w.Code)
	}
}

func spanAttrs(span sdktrace.ReadOnlySpan) map[string]string {
	m := map[string]string{}
	for _, kv := range span.Attributes() {
		m[string(kv.Key)] = kv.Value.Emit()
	}
	return m
}

// deliverySpan waits for the server span of the one A2A delivery a test sent: the
// span whose url.path is "/", which the arming request's span (/control/inject) is
// not. A wait is needed for the reason waitForIngressLines gives: the client sees
// its connection die before the handler goroutine returns, and the span ends only
// after that.
func deliverySpan(t *testing.T, sr *tracetest.SpanRecorder) sdktrace.ReadOnlySpan {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		for _, span := range sr.Ended() {
			if spanAttrs(span)["url.path"] == "/" {
				return span
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("no ended span for the delivery within the timeout; spans ended: %d", len(sr.Ended()))
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// spanReading is one span written out in full, attributes in key order, so a
// reading can be kept and compared as text.
func spanReading(span sdktrace.ReadOnlySpan) string {
	var b strings.Builder
	fmt.Fprintf(&b, "name=%s\nkind=%s\nstatus.code=%s\nstatus.description=%q\n",
		span.Name(), span.SpanKind(), span.Status().Code, span.Status().Description)
	attrs := spanAttrs(span)
	keys := make([]string, 0, len(attrs))
	for k := range attrs {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	b.WriteString("attributes:\n")
	for _, k := range keys {
		fmt.Fprintf(&b, "  %s=%s\n", k, attrs[k])
	}
	fmt.Fprintf(&b, "events=%d\n", len(span.Events()))
	return b.String()
}

// TestInjectedCloseAfterRead_ServerSpanReading drives an armed close-after-read
// delivery over a real connection through the handler as main wraps it, and states
// what the worker's own server span says about a delivery whose connection the
// worker took and closed.
//
// BEFORE, measured by this test on 2026-09-19T18:41:05Z against the worker as it
// was (and on the cluster the same day: in experiments/runs/
// 2026-09-19-route-keyed-attribution/fixture-rows/r1-go-http/a3m-r1-go-http-fu18f-01/
// the worker's 80 µs `POST /` row of spans.csv reads 200 for the delivery whose
// ingress.jsonl response line reads status 0, injection close-after-read):
//
//	status.code=Unset  status.description=""  http.response.status_code=200
//	no lab.injection, no error attribute, events=0
//
// so the span of a delivery that got no response read as a clean 200, the shape
// fixtures/mockllm/span_test.go measured for the mock. The cause is the
// instrumentation's, read at otelhttp v0.71.0: labotel.MarkInjection's comment has
// the lines. AFTER, asserted below: status Error with the description
// "injected: close-after-read" and lab.injection=close-after-read.
//
// What the marking does NOT change is asserted too, rather than left out: the
// instrumentation still stamps http.response.status_code=200 on that span, beside
// the Error status. No response was sent, so that 200 is not a status the worker
// answered with; a reader tells an injected close by the status and lab.injection.
// Both full readings are kept verbatim in
// experiments/runs/2026-09-19-worker-span-on-injected-close/.
//
// The ingress ledger lines are what they were (rule 5): an arrival line, then a
// response line with an explicit status 0 and the injection named.
func TestInjectedCloseAfterRead_ServerSpanReading(t *testing.T) {
	tw := newTracedWorker(t)
	srv := httptest.NewServer(tw.handler)
	defer srv.Close()
	armOverHTTP(t, srv.URL, modeCloseAfterRead, "go-dump")

	resp, err := noReplayClient().Post(srv.URL+"/", "application/json", strings.NewReader(a2aGoSendMessageBody))
	if err == nil {
		_ = resp.Body.Close()
		t.Fatalf("want a transport error, got status %d", resp.StatusCode)
	}
	if n := tw.a2a.Load(); n != 0 {
		t.Errorf("the A2A handler was invoked %d times, want 0", n)
	}

	lines := waitForIngressLines(t, tw.ledger, 2)
	t.Logf("ingress ledger, close-after-read taken and closed:\n%s", tw.ledger.String())
	if len(lines) != 2 || lines[0].Phase != "arrival" || lines[0].Injection != "" {
		t.Errorf("arrival = %+v (of %d lines)", lines[0], len(lines))
	}
	if lines[1].Phase != "response" || statusOf(t, lines[1]) != 0 || lines[1].Injection != modeCloseAfterRead {
		t.Errorf("response = %+v, want phase response, status 0, injection close-after-read", lines[1])
	}

	span := deliverySpan(t, tw.spans)
	t.Logf("server span of a delivery the worker closed by injection (close-after-read):\n%s", spanReading(span))

	want := "injected: " + modeCloseAfterRead
	if st := span.Status(); st.Code != codes.Error || st.Description != want {
		t.Errorf("status: got %s %q, want Error %q", st.Code, st.Description, want)
	}
	attrs := spanAttrs(span)
	if got := attrs["lab.injection"]; got != modeCloseAfterRead {
		t.Errorf("lab.injection: got %q, want %q", got, modeCloseAfterRead)
	}
	// Measured, not wished for: at otelhttp v0.71.0 the instrumentation's
	// default is still stamped beside the marking. If a later version stops
	// stamping it this fails, and the comment above and MarkInjection's are
	// then what to re-read.
	if got := attrs["http.response.status_code"]; got != "200" {
		t.Errorf("http.response.status_code beside the marking: got %q, measured %q at otelhttp v0.71.0", got, "200")
	}
}

// closeFailsWriter is a ResponseWriter whose connection can be taken and whose
// close then fails, which a real connection does not do on command.
type closeFailsWriter struct{ *httptest.ResponseRecorder }

func (closeFailsWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return closeFailsConn{}, nil, nil
}

type closeFailsConn struct{ net.Conn }

var errCloseFailed = errors.New("close failed on command")

func (closeFailsConn) Close() error { return errCloseFailed }

// The connection was taken, so no response is possible and the ledger records
// status 0 as for any taken connection; the span says the close that was asked for
// failed, in the helper's words. Nothing was written, so the instrumentation sets
// its 200 and status Unset here too, and the SDK keeps the Error set before it.
func TestInjectedCloseAfterRead_TakenButNotClosedSaysSoOnTheSpan(t *testing.T) {
	tw := newTracedWorker(t)
	armInProcess(t, tw.handler, modeCloseAfterRead, "go-dump")

	w := closeFailsWriter{httptest.NewRecorder()}
	tw.handler.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody)))
	if n := tw.a2a.Load(); n != 0 {
		t.Errorf("the A2A handler was invoked %d times, want 0", n)
	}

	lines := ingressLines(t, tw.ledger.String())
	t.Logf("ingress ledger, close-after-read taken but not closed:\n%s", tw.ledger.String())
	if len(lines) != 2 || lines[1].Phase != "response" || statusOf(t, lines[1]) != 0 || lines[1].Injection != modeCloseAfterRead {
		t.Fatalf("lines = %+v, want a response line with status 0 and injection close-after-read", lines)
	}

	span := deliverySpan(t, tw.spans)
	t.Logf("server span of a close-after-read that took the connection and could not close it:\n%s", spanReading(span))

	want := "injected: " + modeCloseAfterRead + " failed: " + errCloseFailed.Error()
	if st := span.Status(); st.Code != codes.Error || st.Description != want {
		t.Errorf("status: got %s %q, want Error %q", st.Code, st.Description, want)
	}
	attrs := spanAttrs(span)
	if got := attrs["lab.injection"]; got != modeCloseAfterRead {
		t.Errorf("lab.injection: got %q, want %q", got, modeCloseAfterRead)
	}
	if got := attrs["http.response.status_code"]; got != "200" {
		t.Errorf("http.response.status_code beside the marking: got %q, measured %q at otelhttp v0.71.0", got, "200")
	}
}

// When the connection cannot be taken the worker answers 500, and that span is
// left exactly as it read before the marking existed: status Error with no
// description and http.response.status_code=500, both the instrumentation's own
// reading of a real answer, and NO lab.injection. The injection is still named
// where it always was, on the ledger's response line beside the 500.
//
// This is where the worker departs from the mock, which marks a failed close too.
// The mock's failed close answers an empty 200, so the instrumentation sets Unset
// and the helper's "failed: <err>" survives. Here it would not: measured on
// 2026-09-19T18:41:20Z with the marking made unconditional, this span read
// lab.injection=close-after-read beside status Error "" and 500, the description
// replaced by the instrumentation's Error for a 5xx (reading-notes.txt in the run
// directory has the lines). A marking with no "failed" text on a connection that
// was never closed would half-claim a close, so there is none. A ResponseRecorder
// is not an http.Hijacker, which is what makes the hijack fail.
func TestInjectedCloseAfterRead_ThatCouldNotHijackIsNotMarked(t *testing.T) {
	tw := newTracedWorker(t)
	armInProcess(t, tw.handler, modeCloseAfterRead, "go-dump")

	w := httptest.NewRecorder()
	tw.handler.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody)))
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want the 500 the worker answers when it cannot take the connection", w.Code)
	}
	if n := tw.a2a.Load(); n != 0 {
		t.Errorf("the A2A handler was invoked %d times, want 0", n)
	}

	lines := ingressLines(t, tw.ledger.String())
	t.Logf("ingress ledger, close-after-read that could not hijack:\n%s", tw.ledger.String())
	if len(lines) != 2 || lines[1].Phase != "response" || statusOf(t, lines[1]) != http.StatusInternalServerError || lines[1].Injection != modeCloseAfterRead {
		t.Fatalf("lines = %+v, want a response line with status 500 and injection close-after-read", lines)
	}

	span := deliverySpan(t, tw.spans)
	t.Logf("server span of a close-after-read that could not take the connection:\n%s", spanReading(span))

	attrs := spanAttrs(span)
	if _, ok := attrs["lab.injection"]; ok {
		t.Errorf("lab.injection is set on a delivery whose connection was never taken")
	}
	if st := span.Status(); st.Code != codes.Error || st.Description != "" {
		t.Errorf("status: got %s %q, want Error and no description, as the instrumentation reads a 500", st.Code, st.Description)
	}
	if got := attrs["http.response.status_code"]; got != "500" {
		t.Errorf("http.response.status_code: got %q, want %q", got, "500")
	}
}

// The marking belongs to a taken connection and to nothing else. The two other
// ways a delivery ends here each have a row, and each carries no lab.injection: a
// delivery served normally, and an injected http503-before-dispatch, which is a
// real answer and which the instrumentation already reads as Error from the 503
// (as found: status Error with no description, http.response.status_code=503).
// The 503 row is where a wrong marking would be most plausible, since it is the
// other injection in the same switch; the run directory keeps this test passing on
// the code as it is and failing on a copy with the marking added to that branch.
func TestInjectedCloseAfterRead_MarkingIsAbsentFromEveryOtherDelivery(t *testing.T) {
	for _, tc := range []struct {
		name      string
		mode      string
		status    int
		code      codes.Code
		injection string
	}{
		{"served normally", "", http.StatusOK, codes.Unset, ""},
		{"injected http503-before-dispatch", modeHTTP503BeforeDispatch, http.StatusServiceUnavailable, codes.Error, modeHTTP503BeforeDispatch},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tw := newTracedWorker(t)
			srv := httptest.NewServer(tw.handler)
			defer srv.Close()
			if tc.mode != "" {
				armOverHTTP(t, srv.URL, tc.mode, "go-dump")
			}
			resp, err := noReplayClient().Post(srv.URL+"/", "application/json", strings.NewReader(a2aGoSendMessageBody))
			if err != nil {
				t.Fatalf("post: %v", err)
			}
			_ = resp.Body.Close()
			if resp.StatusCode != tc.status {
				t.Fatalf("got status %d, want %d", resp.StatusCode, tc.status)
			}
			lines := waitForIngressLines(t, tw.ledger, 2)
			t.Logf("ingress ledger, %s:\n%s", tc.name, tw.ledger.String())
			if len(lines) != 2 || lines[1].Phase != "response" || statusOf(t, lines[1]) != tc.status || lines[1].Injection != tc.injection {
				t.Errorf("lines = %+v, want a response line with status %d and injection %q", lines, tc.status, tc.injection)
			}

			span := deliverySpan(t, tw.spans)
			t.Logf("server span of a delivery that was not an injected close (%s):\n%s", tc.name, spanReading(span))
			attrs := spanAttrs(span)
			if _, ok := attrs["lab.injection"]; ok {
				t.Errorf("lab.injection is set on a delivery that was not an injected close")
			}
			if st := span.Status(); st.Code != tc.code || st.Description != "" {
				t.Errorf("status: got %s %q, want %s and no description", st.Code, st.Description, tc.code)
			}
			if got, want := attrs["http.response.status_code"], fmt.Sprint(tc.status); got != want {
				t.Errorf("http.response.status_code: got %q, want %q", got, want)
			}
		})
	}
}
