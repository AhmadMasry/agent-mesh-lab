package otel

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	otelapi "go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
	"go.opentelemetry.io/otel/trace"
)

// globalRecords says whether the global tracer provider records the spans it is
// asked for, which is what installing an SDK provider changes and what leaving
// the global alone preserves. It is read rather than compared against a fixed
// value because the global provider is process-wide: another test in this
// package installs one, and a test that asserted "not recording" would then be
// asserting the order the tests ran in.
func globalRecords() bool {
	_, span := otelapi.Tracer("internal/otel test").Start(context.Background(), "probe")
	recording := span.IsRecording()
	span.End()
	return recording
}

// recorder installs an in-memory tracer provider globally and returns the
// recorder behind it. otelhttp reads the global provider when a handler is
// built, which is how the lab binaries get theirs from Setup; a test does the
// same rather than reaching past the wiring under test.
func recorder(t *testing.T) *tracetest.SpanRecorder {
	t.Helper()
	sr := tracetest.NewSpanRecorder()
	otelapi.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr)))
	return sr
}

// attrs reads one span's attributes as strings, which is all the identity
// attributes are.
func attrs(span sdktrace.ReadOnlySpan) map[string]string {
	m := map[string]string{}
	for _, kv := range span.Attributes() {
		m[string(kv.Key)] = kv.Value.Emit()
	}
	return m
}

func TestSetup_NoEndpointIsNoop(t *testing.T) {
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "")

	before := globalRecords()
	shutdown, err := Setup(context.Background())
	if err != nil {
		t.Fatalf("Setup with no endpoint returned an error: %v", err)
	}
	if shutdown == nil {
		t.Fatal("Setup returned a nil shutdown function")
	}
	if err := shutdown(context.Background()); err != nil {
		t.Fatalf("the shutdown Setup returned with no endpoint set returned an error: %v", err)
	}
	if after := globalRecords(); after != before {
		t.Errorf("Setup changed the global tracer provider with no endpoint set: spans recording before=%v after=%v", before, after)
	}
}

func TestHandler_LiftsIdentityHeadersToSpanAttributes(t *testing.T) {
	sr := recorder(t)
	h := Handler("worker", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	req := httptest.NewRequest(http.MethodPost, "/", nil)
	req.Header.Set("X-Logical-Work-Item-Id", "lwi-1")
	req.Header.Set("X-A2A-Message-Id", "msg-1")
	req.Header.Set("X-A2A-Task-Id", "task-1")
	req.Header.Set("X-Caller", "loadgen")
	h.ServeHTTP(httptest.NewRecorder(), req)

	spans := sr.Ended()
	if len(spans) != 1 {
		t.Fatalf("spans ended: got %d, want 1", len(spans))
	}
	got := attrs(spans[0])
	want := map[string]string{
		"lab.work_item":  "lwi-1",
		"lab.message_id": "msg-1",
		"lab.task_id":    "task-1",
		"lab.caller":     "loadgen",
	}
	for key, value := range want {
		if got[key] != value {
			t.Errorf("span attribute %s: got %q, want %q", key, got[key], value)
		}
	}
}

func TestHandler_NoHeadersSetsNoLabAttributes(t *testing.T) {
	sr := recorder(t)
	h := Handler("worker", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))

	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/", nil))

	spans := sr.Ended()
	if len(spans) != 1 {
		t.Fatalf("spans ended: got %d, want 1", len(spans))
	}
	for key := range attrs(spans[0]) {
		if strings.HasPrefix(key, "lab.") {
			t.Errorf("a request carrying no identity header produced span attribute %q", key)
		}
	}
}

func TestTransport_InjectsTraceparent(t *testing.T) {
	// Setup installs this propagator in the lab binaries; the test states it
	// itself so that what it measures is the transport rather than the order
	// the tests in this package ran in.
	otelapi.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	recorder(t)

	arrived := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		arrived <- r.Header.Get("traceparent")
	}))
	defer srv.Close()

	ctx, span := otelapi.Tracer("internal/otel test").Start(context.Background(), "caller")
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL, nil)
	if err != nil {
		t.Fatalf("building the request: %v", err)
	}
	resp, err := (&http.Client{Transport: Transport(http.DefaultTransport)}).Do(req)
	if err != nil {
		t.Fatalf("sending the request: %v", err)
	}
	_ = resp.Body.Close()
	span.End()

	got := <-arrived
	if got == "" {
		t.Fatal("the request arrived carrying no traceparent header")
	}
	if traceID := span.SpanContext().TraceID().String(); !strings.Contains(got, traceID) {
		t.Errorf("traceparent %q does not name the caller's trace %s", got, traceID)
	}
}

// --- GenAI and agent semantic conventions ------------------------------------
//
// These tests state what the conventions ask for, so a later change to the
// helpers that stops satisfying them fails here rather than in a cluster run.
// The attribute names and the naming rules are quoted in otel.go beside the
// document they were read from.

func TestModelCall_NamesAndAttributesFollowTheConventions(t *testing.T) {
	sr := recorder(t)

	_, span := ModelCall(context.Background(), "mock", "http://mockllm.lab.svc.cluster.local:8080/v1",
		Identity{WorkItem: "w1", MessageID: "m1", TaskID: "t1", Caller: "worker"})
	span.Response(ModelResponse{ID: "chatcmpl-x", Model: "mock", FinishReasons: []string{"stop"}, InputTokens: 12, OutputTokens: 6})
	span.End(nil)

	spans := sr.Ended()
	if len(spans) != 1 {
		t.Fatalf("spans ended: got %d, want 1", len(spans))
	}
	if got := spans[0].Name(); got != "chat mock" {
		t.Errorf("span name: got %q, want %q", got, "chat mock")
	}
	if got := spans[0].SpanKind(); got != trace.SpanKindClient {
		t.Errorf("span kind: got %v, want %v", got, trace.SpanKindClient)
	}
	got := attrs(spans[0])
	want := map[string]string{
		"gen_ai.operation.name":          "chat",
		"gen_ai.provider.name":           "openai",
		"gen_ai.request.model":           "mock",
		"gen_ai.response.id":             "chatcmpl-x",
		"gen_ai.response.model":          "mock",
		"gen_ai.response.finish_reasons": `["stop"]`,
		"gen_ai.usage.input_tokens":      "12",
		"gen_ai.usage.output_tokens":     "6",
		"server.address":                 "mockllm.lab.svc.cluster.local",
		"server.port":                    "8080",
		"lab.work_item":                  "w1",
		"lab.message_id":                 "m1",
		"lab.task_id":                    "t1",
		"lab.caller":                     "worker",
	}
	for key, value := range want {
		if got[key] != value {
			t.Errorf("span attribute %s: got %q, want %q", key, got[key], value)
		}
	}
	if spans[0].Status().Code != codes.Unset {
		t.Errorf("a call that did not fail carries status %v", spans[0].Status().Code)
	}
}

// statusErr is an error that knows the status a server answered with, the shape
// the worker's model client supplies. It exists here so the test states what the
// conventions ask of error.type rather than what the helper happens to do.
type statusErr struct{ status int }

func (e *statusErr) Error() string   { return "model call: status " + strconv.Itoa(e.status) }
func (e *statusErr) StatusCode() int { return e.status }

func TestModelCall_FailureRecordsErrorTypeAndStatus(t *testing.T) {
	sr := recorder(t)

	_, span := ModelCall(context.Background(), "mock", "http://mockllm:8080/v1", Identity{WorkItem: "w1"})
	span.End(fmt.Errorf("model call: %w", &statusErr{status: 503}))

	spans := sr.Ended()
	if len(spans) != 1 {
		t.Fatalf("spans ended: got %d, want 1", len(spans))
	}
	// The conventions: error.type SHOULD match "the error code returned by the
	// Generative AI provider or the client library, the canonical name of
	// exception that occurred, or another low-cardinality error identifier",
	// with `500` among the example values. A status the server answered with is
	// that error code, and a wrapper around it must not hide it.
	if got := attrs(spans[0])["error.type"]; got != "503" {
		t.Errorf("error.type for a status the server answered with: got %q, want %q", got, "503")
	}
	if st := spans[0].Status(); st.Code != codes.Error || st.Description != "model call: model call: status 503" {
		t.Errorf("status: got %v %q, want Error and the error's text", st.Code, st.Description)
	}
}

func TestErrorType_WithoutAStatusNamesTheDeepestError(t *testing.T) {
	// No status to report, so the conventions' second option applies: the
	// canonical name of the error that occurred. A wrapper's own type names
	// nothing, so the chain is followed to its end.
	inner := errors.New("connection reset by peer")
	for _, tc := range []struct {
		name string
		err  error
		want string
	}{
		{"a bare error", inner, "*errors.errorString"},
		{"a wrapped error", fmt.Errorf("model call: %w", inner), "*errors.errorString"},
		{"twice wrapped", fmt.Errorf("outer: %w", fmt.Errorf("model call: %w", inner)), "*errors.errorString"},
	} {
		if got := errorTypeOf(tc.err); got != tc.want {
			t.Errorf("errorTypeOf(%s): got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestServerAttributes_ReadTheEndpointTheClientDials(t *testing.T) {
	for _, tc := range []struct {
		url     string
		address string
		port    string
	}{
		{"http://mockllm.lab.svc.cluster.local:8080/v1", "mockllm.lab.svc.cluster.local", "8080"},
		// A port the URL omits is the scheme's default, which is what the client dials.
		{"http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local", "agentgateway-ingress.agentgateway-ingress.svc.cluster.local", "80"},
		{"https://example.test/v1", "example.test", "443"},
	} {
		got := map[string]string{}
		for _, kv := range serverAttributes(tc.url) {
			got[string(kv.Key)] = kv.Value.Emit()
		}
		if got["server.address"] != tc.address || got["server.port"] != tc.port {
			t.Errorf("serverAttributes(%q): got address=%q port=%q, want %q and %q",
				tc.url, got["server.address"], got["server.port"], tc.address, tc.port)
		}
	}
	// Nothing to read is nothing set, rather than a guess.
	for _, url := range []string{"", "not a url", "/v1"} {
		if kv := serverAttributes(url); len(kv) != 0 {
			t.Errorf("serverAttributes(%q) set %d attribute(s), want none", url, len(kv))
		}
	}
}

// serverAttrs reads serverAttributes' result as strings, keyed by attribute.
func serverAttrs(rawURL string) map[string]string {
	got := map[string]string{}
	for _, kv := range serverAttributes(rawURL) {
		got[string(kv.Key)] = kv.Value.Emit()
	}
	return got
}

// A URL without a port is dialled on its scheme's default, so that is the port
// recorded; a scheme with no default leaves server.address alone rather than a
// guessed number. A colon with nothing after it names no port either.
func TestServerAttributes_AURLWithoutAPort(t *testing.T) {
	for _, tc := range []struct{ url, address, port string }{
		{"http://worker.lab.svc.cluster.local/", "worker.lab.svc.cluster.local", "80"},
		{"https://example.test", "example.test", "443"},
		{"http://example.test:/v1", "example.test", "80"},
		{"grpc://example.test/v1", "example.test", ""},
	} {
		got := serverAttrs(tc.url)
		if got["server.address"] != tc.address || got["server.port"] != tc.port {
			t.Errorf("serverAttributes(%q): got address=%q port=%q, want %q and %q",
				tc.url, got["server.address"], got["server.port"], tc.address, tc.port)
		}
	}
}

// A bad port never becomes server.port, and nothing panics (a panic fails the
// test). url.Parse refuses a port that is not all digits, so such a URL sets no
// attribute at all; what it lets through is any string of digits, and one that is
// not a TCP server port -- above 65535, however long, or 0 -- sets server.address
// alone. 65535 is the last port that is recorded. The Python agent's
// test_a_bad_port_leaves_server_port_unset reads the same inputs.
func TestServerAttributes_AURLWithABadPort(t *testing.T) {
	for _, tc := range []struct{ url, address string }{
		{"http://example.test:abc/v1", ""},
		{"http://[::1]:x/v1", ""},
		{"http://h:99999/", "h"},
		{"https://h:70000/", "h"},
		{"http://example.test:65536/v1", "example.test"},
		{"http://example.test:99999999999999999999999/v1", "example.test"},
		{"http://example.test:0/v1", "example.test"},
	} {
		got := serverAttrs(tc.url)
		if port, ok := got["server.port"]; ok {
			t.Errorf("serverAttributes(%q) set server.port=%q, want it unset", tc.url, port)
		}
		if got["server.address"] != tc.address {
			t.Errorf("serverAttributes(%q): got address=%q, want %q", tc.url, got["server.address"], tc.address)
		}
	}
	if got := serverAttrs("http://example.test:65535/v1"); got["server.port"] != "65535" {
		t.Errorf("serverAttributes with port 65535: got server.port=%q, want 65535", got["server.port"])
	}
}

func TestModelCall_HTTPClientSpanIsItsChild(t *testing.T) {
	otelapi.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	sr := recorder(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) }))
	defer srv.Close()

	ctx, span := ModelCall(context.Background(), "mock", srv.URL, Identity{WorkItem: "w1"})
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, srv.URL, nil)
	if err != nil {
		t.Fatalf("building the request: %v", err)
	}
	resp, err := (&http.Client{Transport: Transport(http.DefaultTransport)}).Do(req)
	if err != nil {
		t.Fatalf("sending the request: %v", err)
	}
	_ = resp.Body.Close()
	span.End(nil)

	spans := sr.Ended()
	if len(spans) != 2 {
		t.Fatalf("spans ended: got %d, want 2 (the chat span and the HTTP client span)", len(spans))
	}
	// The HTTP client span ends first, so it is spans[0] and the chat span is spans[1].
	if parent, chat := spans[0].Parent().SpanID(), spans[1].SpanContext().SpanID(); parent != chat {
		t.Errorf("the HTTP client span's parent is %s, want the chat span %s", parent, chat)
	}
}

func TestInvokeAgent_NamesAndAttributesFollowTheConventions(t *testing.T) {
	sr := recorder(t)

	_, span := InvokeAgent(context.Background(),
		Agent{Name: "worker", Version: "0.1.0", Description: "the downstream agent", URL: "http://worker.lab.svc.cluster.local:8080"},
		Identity{WorkItem: "w1", MessageID: "m1", Caller: "loadgen"})
	span.Conversation("ctx-1")
	span.End(nil)

	spans := sr.Ended()
	if len(spans) != 1 {
		t.Fatalf("spans ended: got %d, want 1", len(spans))
	}
	if got := spans[0].Name(); got != "invoke_agent worker" {
		t.Errorf("span name: got %q, want %q", got, "invoke_agent worker")
	}
	if got := spans[0].SpanKind(); got != trace.SpanKindClient {
		t.Errorf("span kind: got %v, want %v", got, trace.SpanKindClient)
	}
	got := attrs(spans[0])
	want := map[string]string{
		"gen_ai.operation.name":    "invoke_agent",
		"gen_ai.provider.name":     "a2a",
		"gen_ai.agent.name":        "worker",
		"gen_ai.agent.version":     "0.1.0",
		"gen_ai.agent.description": "the downstream agent",
		"gen_ai.conversation.id":   "ctx-1",
		"server.address":           "worker.lab.svc.cluster.local",
		"server.port":              "8080",
		"lab.work_item":            "w1",
		"lab.message_id":           "m1",
		"lab.caller":               "loadgen",
	}
	for key, value := range want {
		if got[key] != value {
			t.Errorf("span attribute %s: got %q, want %q", key, got[key], value)
		}
	}
	if _, ok := got["gen_ai.agent.id"]; ok {
		t.Error("gen_ai.agent.id is set, but an A2A v1.0 AgentCard carries no agent identifier")
	}
}

func TestInvokeAgent_WithoutANameOrAConversationSetsNeither(t *testing.T) {
	sr := recorder(t)

	_, span := InvokeAgent(context.Background(), Agent{}, Identity{WorkItem: "w1"})
	span.Conversation("")
	span.End(nil)

	spans := sr.Ended()
	if len(spans) != 1 {
		t.Fatalf("spans ended: got %d, want 1", len(spans))
	}
	if got := spans[0].Name(); got != "invoke_agent" {
		t.Errorf("span name with no agent name: got %q, want %q", got, "invoke_agent")
	}
	for _, key := range []string{"gen_ai.agent.name", "gen_ai.agent.version", "gen_ai.agent.description",
		"gen_ai.conversation.id", "server.address", "server.port"} {
		if _, ok := attrs(spans[0])[key]; ok {
			t.Errorf("attribute %s is set although nothing was available for it", key)
		}
	}
}

func TestSpans_EndTwiceKeepsTheFirstOutcome(t *testing.T) {
	sr := recorder(t)

	_, span := InvokeAgent(context.Background(), Agent{Name: "worker"}, Identity{WorkItem: "w1"})
	span.End(errors.New("send failed"))
	span.End(nil)

	spans := sr.Ended()
	if len(spans) != 1 {
		t.Fatalf("spans ended: got %d, want 1", len(spans))
	}
	if st := spans[0].Status(); st.Code != codes.Error {
		t.Errorf("status after a second End(nil): got %v, want it to stay Error", st.Code)
	}
}
