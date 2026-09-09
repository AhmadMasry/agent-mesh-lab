package otel

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	otelapi "go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"
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
