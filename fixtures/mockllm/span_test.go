package main

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
	"time"

	otelapi "go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
)

// newTracedTestServer is newTestServer with the handler wrapped the way main
// wraps it (labotel.Handler around the mux, after configureHTTPServer), and an
// in-memory span recorder installed as the global tracer provider, which is where
// otelhttp reads its provider from when the handler is built. The provider is
// process-wide, so the previous one is put back afterwards.
func newTracedTestServer(t *testing.T) (*httptest.Server, *syncBuffer, *tracetest.SpanRecorder) {
	t.Helper()
	previous := otelapi.GetTracerProvider()
	t.Cleanup(func() { otelapi.SetTracerProvider(previous) })
	sr := tracetest.NewSpanRecorder()
	otelapi.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr)))

	ledger := &syncBuffer{}
	s := newServer(testConfig(), ledger)
	ts := httptest.NewUnstartedServer(nil)
	s.configureHTTPServer(ts.Config)
	ts.Config.Handler = labotel.Handler("mockllm", ts.Config.Handler)
	ts.Start()
	t.Cleanup(ts.Close)
	return ts, ledger, sr
}

func spanAttrs(span sdktrace.ReadOnlySpan) map[string]string {
	m := map[string]string{}
	for _, kv := range span.Attributes() {
		m[string(kv.Key)] = kv.Value.Emit()
	}
	return m
}

// chatCompletionsSpan waits for the server span of the one chat-completions
// request a test sent. A wait is needed for the reason lastInvocationLine gives:
// the client sees its connection die before the handler goroutine returns, and
// the span ends only after that.
func chatCompletionsSpan(t *testing.T, sr *tracetest.SpanRecorder) sdktrace.ReadOnlySpan {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		for _, span := range sr.Ended() {
			if spanAttrs(span)["url.path"] == "/v1/chat/completions" {
				return span
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("no ended span for /v1/chat/completions within the timeout; spans ended: %d", len(sr.Ended()))
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

// TestInjectedClose_ServerSpanReading drives the two injections that end a request
// with no response through the handler as main wraps it, and states what the mock's
// own server span says about such a request.
//
// BEFORE, measured by this test on 2026-09-19T16:50:47Z against the mock as it was
// (and on the cluster the same day, experiments/runs/2026-09-19-failed-model-call/:
// the mock's span row read 200 while the proxy in front of it answered 503), for
// both modes alike:
//
//	status.code=Unset  status.description=""  http.response.status_code=200
//	no lab.injection, no error attribute, events=0
//
// so the span of a request that got no response read as a clean 200. The cause is
// the instrumentation's, read at otelhttp v0.71.0: labotel.MarkInjection's comment
// has the lines. AFTER, asserted below: status Error with the description
// "injected: <mode>" and lab.injection=<mode>.
//
// What the marking does NOT change is asserted too, rather than left out: the
// instrumentation still stamps http.response.status_code=200 on that span, beside
// the Error status. No response was sent, so that 200 is not a status the mock
// answered with; a reader tells an injected close by the status and lab.injection.
// Both full readings are kept verbatim in
// experiments/runs/2026-09-19-mock-span-on-injected-close/.
//
// The invocation ledger line is what it was (rule 5): the same injection and
// outcome values server_test.go's two close-mode tests read.
func TestInjectedClose_ServerSpanReading(t *testing.T) {
	for _, tc := range []struct {
		mode    string
		inject  map[string]any
		outcome string
	}{
		{modeClose, map[string]any{"mode": modeClose, "lwi": "span-close-1"}, "closed"},
		{modeDelayThenClose, map[string]any{"mode": modeDelayThenClose, "lwi": "span-close-1", "delay_ms": 10}, "delayed-close"},
	} {
		t.Run(tc.mode, func(t *testing.T) {
			ts, ledger, sr := newTracedTestServer(t)
			mustInject(t, ts.URL, tc.inject)

			body := []byte(`{"model":"m","messages":[{"role":"user","content":"hi"}]}`)
			req, err := http.NewRequest(http.MethodPost, ts.URL+"/v1/chat/completions", bytes.NewReader(body))
			if err != nil {
				t.Fatalf("build request: %v", err)
			}
			req.Header.Set("X-Logical-Work-Item-Id", "span-close-1")
			resp, err := freshClient().Do(req)
			if err == nil {
				resp.Body.Close()
				t.Fatalf("expected a connection error, got response status %d", resp.StatusCode)
			}

			line := lastInvocationLine(t, ledger)
			if line.Injection != tc.mode || line.Outcome != tc.outcome {
				t.Fatalf("invocation line: got injection %q outcome %q, want %q and %q", line.Injection, line.Outcome, tc.mode, tc.outcome)
			}

			span := chatCompletionsSpan(t, sr)
			t.Logf("server span of a request the mock closed by injection (%s):\n%s", tc.mode, spanReading(span))

			if st := span.Status(); st.Code != codes.Error || st.Description != "injected: "+tc.mode {
				t.Errorf("status: got %s %q, want Error %q", st.Code, st.Description, "injected: "+tc.mode)
			}
			attrs := spanAttrs(span)
			if got := attrs["lab.injection"]; got != tc.mode {
				t.Errorf("lab.injection: got %q, want %q", got, tc.mode)
			}
			// Measured, not wished for: at otelhttp v0.71.0 the instrumentation's
			// default is still stamped beside the marking. If a later version stops
			// stamping it this fails, and the comment above and MarkInjection's are
			// then what to re-read.
			if got := attrs["http.response.status_code"]; got != "200" {
				t.Errorf("http.response.status_code beside the marking: got %q, measured %q at otelhttp v0.71.0", got, "200")
			}
		})
	}
}

// When the connection cannot be taken the injection did not close anything, and
// net/http answers the empty 200 a handler that wrote nothing gets. The ledger has
// always called that "closed-error"; the span says the same thing in its own
// words, so an armed close that did not happen never reads as one that did. A
// ResponseRecorder is not an http.Hijacker, which is what makes the close fail.
func TestInjectedClose_ThatCouldNotCloseSaysSoOnTheSpan(t *testing.T) {
	previous := otelapi.GetTracerProvider()
	t.Cleanup(func() { otelapi.SetTracerProvider(previous) })
	sr := tracetest.NewSpanRecorder()
	otelapi.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr)))

	ledger := &syncBuffer{}
	s := newServer(testConfig(), ledger)
	s.injection = &injectionConfig{Mode: modeClose, LWI: "span-close-2"}
	h := labotel.Handler("mockllm", s.mux)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions",
		strings.NewReader(`{"model":"m","messages":[{"role":"user","content":"hi"}]}`))
	req.Header.Set("X-Logical-Work-Item-Id", "span-close-2")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)

	if line := lastInvocationLine(t, ledger); line.Injection != modeClose || line.Outcome != "closed-error" {
		t.Fatalf("invocation line: got injection %q outcome %q, want %q and %q", line.Injection, line.Outcome, modeClose, "closed-error")
	}
	span := chatCompletionsSpan(t, sr)
	want := "injected: close failed: " + errNotHijackable.Error()
	if st := span.Status(); st.Code != codes.Error || st.Description != want {
		t.Errorf("status: got %s %q, want Error %q", st.Code, st.Description, want)
	}
	if got := spanAttrs(span)["lab.injection"]; got != modeClose {
		t.Errorf("lab.injection: got %q, want %q", got, modeClose)
	}
}

// The marking belongs to an injected close and to nothing else. The three other
// ways a call can end each have a row, and each carries no lab.injection: a call
// served normally; an injected http500, which answers, and which the
// instrumentation already reads as Error from the 500; and an injected stale,
// which answers 200 like a normal call and whose connection close comes later,
// from connState, once the connection goes idle and outside any request's span.
// stale is the row where a wrong marking would be most plausible, since it too
// ends in a connection close; the review of 2026-09-19 found that without it a
// marking added to the stale branch passed this whole package, and
// experiments/runs/2026-09-19-mock-span-on-injected-close/ keeps this test
// passing on the code as it is and failing on that change.
func TestInjectedClose_MarkingIsAbsentFromEveryOtherCall(t *testing.T) {
	for _, tc := range []struct {
		name   string
		inject map[string]any
		status int
		code   codes.Code
	}{
		{"served normally", nil, http.StatusOK, codes.Unset},
		{"injected http500", map[string]any{"mode": modeHTTP500, "lwi": "span-other-1"}, http.StatusInternalServerError, codes.Error},
		{"injected stale", map[string]any{"mode": modeStale, "lwi": "span-other-1"}, http.StatusOK, codes.Unset},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ts, _, sr := newTracedTestServer(t)
			if tc.inject != nil {
				mustInject(t, ts.URL, tc.inject)
			}
			body := []byte(`{"model":"m","messages":[{"role":"user","content":"hi"}]}`)
			status, _ := doPost(t, ts.URL, body, map[string]string{"X-Logical-Work-Item-Id": "span-other-1"})
			if status != tc.status {
				t.Fatalf("got status %d, want %d", status, tc.status)
			}
			span := chatCompletionsSpan(t, sr)
			if _, ok := spanAttrs(span)["lab.injection"]; ok {
				t.Errorf("lab.injection is set on a call that was not an injected close")
			}
			if st := span.Status(); st.Code != tc.code || st.Description != "" {
				t.Errorf("status: got %s %q, want %s and no description", st.Code, st.Description, tc.code)
			}
		})
	}
}
