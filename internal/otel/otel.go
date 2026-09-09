// Package otel is the OpenTelemetry wiring for the lab's Go binaries: one Setup
// per process, one Handler wrapper per server, one Transport wrapper per client.
// It is deliberately small. The Python agent is instrumented by the OpenTelemetry
// distro installed in its own image and started by opentelemetry-instrument, and
// neither language's instrumentation touches an executor, a ledger or a retry path.
//
// What it exists to do, beyond starting and ending spans: an A2A request carries
// the logical work item only inside Message.metadata, where no HTTP
// instrumentation can see it. Every lab client therefore also sends the four
// identity headers, and Handler copies whichever of them arrived onto the server
// span as lab.work_item, lab.message_id, lab.task_id and lab.caller. The Python
// instrumentation records the same headers under its own attribute names, and the
// collector's transform processor joins the two spellings, so one query reads a
// whole work item.
//
// Versions are pinned in versions.yaml under otel-go (v1.46.0: go.opentelemetry.io/otel,
// its sdk, and the OTLP HTTP trace exporter) and otel-go-contrib (v0.71.0: otelhttp).
package otel

import (
	"context"
	"net/http"
	"os"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	otelapi "go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

// identityHeaders is the header-to-attribute mapping every lab server span gets.
// The header names are the ones the lab already puts on model calls and, from
// this gate on, on every A2A request a lab client sends.
var identityHeaders = []struct{ header, attribute string }{
	{"X-Logical-Work-Item-Id", "lab.work_item"},
	{"X-A2A-Message-Id", "lab.message_id"},
	{"X-A2A-Task-Id", "lab.task_id"},
	{"X-Caller", "lab.caller"},
}

// Setup installs the process's tracer provider and propagators, and returns the
// function that flushes and stops it.
//
// With OTEL_EXPORTER_OTLP_ENDPOINT unset it installs nothing at all and returns
// a shutdown that does nothing: a binary run outside the cluster, or in a unit
// test, then emits no spans and needs no collector. With the variable set, spans
// go to that endpoint over OTLP HTTP, the sampler is always-on (this lab counts
// hops, so a sampled-away hop would read as a missing one), and the propagators
// are W3C trace context and baggage, matching what the Instrumentation resource
// gives the Python agent.
//
// The exporter reads its own configuration from the environment
// (OTEL_EXPORTER_OTLP_ENDPOINT and its siblings) and the resource reads
// OTEL_SERVICE_NAME, so a binary names itself in its Deployment rather than in
// code. On an error the returned shutdown is still safe to call, so a caller can
// defer it before deciding what to do about the error.
func Setup(ctx context.Context) (func(context.Context) error, error) {
	noop := func(context.Context) error { return nil }
	if os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") == "" {
		return noop, nil
	}
	exporter, err := otlptracehttp.New(ctx)
	if err != nil {
		return noop, err
	}
	provider := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(resource.Default()),
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)
	otelapi.SetTracerProvider(provider)
	otelapi.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	return provider.Shutdown, nil
}

// Handler wraps an http.Handler so every request it serves is a span named after
// the operation, carrying whichever identity headers arrived. A header that is
// absent sets no attribute, so a probe or a control request is distinguishable
// from a work item's request by what its span does not carry.
//
// With no tracer provider installed the span is non-recording and the
// attributes go nowhere, which is what a binary started without an OTLP
// endpoint does.
func Handler(name string, next http.Handler) http.Handler {
	return otelhttp.NewHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if kv := identityAttributes(r.Header); len(kv) > 0 {
			trace.SpanFromContext(r.Context()).SetAttributes(kv...)
		}
		next.ServeHTTP(w, r)
	}), name)
}

// identityAttributes reads the identity headers that are present.
func identityAttributes(header http.Header) []attribute.KeyValue {
	var kv []attribute.KeyValue
	for _, h := range identityHeaders {
		if value := header.Get(h.header); value != "" {
			kv = append(kv, attribute.String(h.attribute, value))
		}
	}
	return kv
}

// Transport wraps a RoundTripper so an outbound request is a client span and
// carries the trace context to whatever answers it. It adds no retry and no
// header of the lab's own: base is used exactly as the caller built it, which is
// how internal/httpclient's recorded settings stay the settings that apply.
func Transport(base http.RoundTripper) http.RoundTripper {
	return otelhttp.NewTransport(base)
}
