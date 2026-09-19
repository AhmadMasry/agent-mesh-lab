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
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strconv"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	otelapi "go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
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

// labInjection is the span attribute naming the failure injection a lab fixture
// fired on a request, spelled as the fixture's own mode name.
const labInjection = "lab.injection"

// MarkInjection marks the server span of the request in ctx as one a lab fixture
// ended by closing its connection on command, instead of answering it. It sets
// lab.injection=<mode> and status Error with the description "injected: <mode>",
// or "injected: <mode> failed: <closeErr>" when the close did not happen.
//
// It exists because the HTTP instrumentation cannot see such a close. Measured on
// 2026-09-19 (experiments/runs/2026-09-19-failed-model-call/, and again in
// fixtures/mockllm/span_test.go): the mock's span for a request it closed by
// injection read http.response.status_code=200 with status Unset, while the proxy
// in front of it answered 503. Read from otelhttp at v0.71.0: its response-writer
// wrapper starts at http.StatusOK "in case the Handler doesn't write anything"
// (internal/request/resp_writer_wrapper.go l.40) and the handler hooks Header,
// Write, WriteHeader and Flush but not Hijack (handler.go l.164-177), so a
// connection taken through http.Hijacker leaves that default in place and it is
// stamped on the span after the handler returns (handler.go l.191-201).
//
// The instrumentation still stamps its 200 beside this marking, and sets status
// Unset after the handler returns; the SDK keeps the Error set here because a
// later, lower status is ignored (sdk/trace/span.go l.220 at v1.46.0). So a
// reader tells an injected close by this status and attribute, never by the
// status code. Nothing on the wire and no ledger line changes; with no tracer
// provider installed the span is non-recording and this does nothing.
func MarkInjection(ctx context.Context, mode string, closeErr error) {
	span := trace.SpanFromContext(ctx)
	span.SetAttributes(attribute.String(labInjection, mode))
	description := "injected: " + mode
	if closeErr != nil {
		description += " failed: " + closeErr.Error()
	}
	span.SetStatus(codes.Error, description)
}

// Transport wraps a RoundTripper so an outbound request is a client span and
// carries the trace context to whatever answers it. It adds no retry and no
// header of the lab's own: base is used exactly as the caller built it, which is
// how internal/httpclient's recorded settings stay the settings that apply.
func Transport(base http.RoundTripper) http.RoundTripper {
	return otelhttp.NewTransport(base)
}

// --- GenAI and agent semantic conventions ------------------------------------
//
// The two spans below are the lab's model call and its agent-to-agent call,
// named and attributed as the OpenTelemetry GenAI semantic conventions describe
// them. Those conventions live in their own repository,
// open-telemetry/semantic-conventions-genai, and every name and rule used here
// was read from docs/gen-ai/gen-ai-spans.md and docs/gen-ai/gen-ai-agent-spans.md
// at commit c88d504ab3d9879f8e50d3cc87e69775e11db234 (versions.yaml,
// genai-semantic-conventions). Both pages read **Status: Development**.
//
// Go has no such instrumentation to install: opentelemetry-go-contrib carries no
// GenAI, LLM or agent instrumentation at v0.71.0, and a2a-go v2.5.0 has no
// OpenTelemetry dependency at all, so these helpers are written by hand. The
// Python agent gets the same two operations from a package instead -- the model
// call from opentelemetry-instrumentation-openai-v2, the agent call from an
// explicit span in its own forward path -- and findings.md counts the asymmetry.
//
// What they do not do: they start and end a span and set attributes on it. They
// call nothing, retry nothing and change no request. A caller that forgets them
// loses a span and nothing else.

// GenAI attribute and value names, spelled out rather than taken from a library
// constant, because the document above is where the lab read them and a
// constant would point at whichever revision a module happens to carry.
const (
	genAIOperationName    = "gen_ai.operation.name"
	genAIProviderName     = "gen_ai.provider.name"
	genAIRequestModel     = "gen_ai.request.model"
	genAIResponseID       = "gen_ai.response.id"
	genAIResponseModel    = "gen_ai.response.model"
	genAIFinishReasons    = "gen_ai.response.finish_reasons"
	genAIInputTokens      = "gen_ai.usage.input_tokens"
	genAIOutputTokens     = "gen_ai.usage.output_tokens"
	genAIAgentName        = "gen_ai.agent.name"
	genAIAgentVersion     = "gen_ai.agent.version"
	genAIAgentDescription = "gen_ai.agent.description"
	genAIConversation     = "gen_ai.conversation.id"
	serverAddress         = "server.address"
	serverPort            = "server.port"
	errorType             = "error.type"

	operationChat        = "chat"
	operationInvokeAgent = "invoke_agent"

	// The two provider names are choices, and are recorded as such. The
	// conventions list sixteen well-known values for gen_ai.provider.name and
	// say "If one of them applies, then the respective value MUST be used;
	// otherwise, a custom value MAY be used". None of the sixteen names this
	// lab's mock model endpoint, and none names an A2A agent. The attribute
	// "acts as a discriminator that identifies the GenAI telemetry format flavor
	// specific to that provider", so each leg is named for the flavor its other
	// attributes follow:
	//
	//   providerOpenAI  the model leg. Its flavor is OpenAI's chat-completions
	//                   API, and `openai` is the value the official Python
	//                   instrumentation was measured to emit against this same
	//                   mock endpoint, so the two agents' chat spans compare.
	//   providerA2A     the agent leg. A custom value, because no well-known one
	//                   applies and the flavor is A2A's: the agent name and
	//                   version come from an AgentCard and the conversation id
	//                   from a Task's contextId.
	//
	// versions.yaml, genai-provider-name, has the sentences and the measurement.
	providerOpenAI = "openai"
	providerA2A    = "a2a"
)

// Identity is the work item a span belongs to: the same four values every ledger
// line carries and every lab client sends as headers. The spans below are
// created by lab code rather than by an HTTP instrumentation, so they set these
// themselves; without them a span would be outside the one-query-per-work-item
// property the collector's transform gives the rest of the trace.
type Identity struct {
	WorkItem  string
	MessageID string
	TaskID    string
	Caller    string
}

func (id Identity) attributes() []attribute.KeyValue {
	var kv []attribute.KeyValue
	for _, pair := range []struct{ key, value string }{
		{"lab.work_item", id.WorkItem},
		{"lab.message_id", id.MessageID},
		{"lab.task_id", id.TaskID},
		{"lab.caller", id.Caller},
	} {
		if pair.value != "" {
			kv = append(kv, attribute.String(pair.key, pair.value))
		}
	}
	return kv
}

// serverAttributes reads server.address and server.port off the URL the client
// was configured to dial. Both spans below carry them: the conventions mark
// server.address Recommended and server.port Conditionally Required "If
// `server.address` is set."
//
// The note beside each says the value "SHOULD represent the server address
// behind any intermediaries, for example proxies, if it's available". What is
// available to a lab client is the URL it was told to dial and nothing more, and
// in this lab that is usually an intermediary's: MODEL_BASE_URL names
// model.lab.internal:8080, the external-looking host the egress waypoint fronts,
// and the mock behind it is never named to the caller; an agent card can
// advertise the agentgateway ingress, and a client sent there never learns the
// agent's own address. Where the card names the agent's own Service, as the
// worker's does, the address is the agent's. Nothing is inferred either way:
// what is recorded is what the client dialled. findings.md says which leg is
// which.
//
// A URL that does not parse, or that names no host, sets neither attribute
// rather than a guess. A port absent from the URL is the scheme's default,
// which is what the client itself will dial.
//
// server.address alone, with no server.port, is what two cases leave: a scheme
// with no default port and no port in the URL, and a port that is not a TCP
// server port. url.Parse has already refused a port that is not all digits, so
// the second case is a string of digits above 65535, however long, which reading
// it as a 16-bit unsigned number refuses, or 0, which no server listens on. The
// Python agent's forward.py _server_attributes gives the same answers.
func serverAttributes(rawURL string) []attribute.KeyValue {
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Hostname() == "" {
		return nil
	}
	address := attribute.String(serverAddress, parsed.Hostname())
	port := parsed.Port()
	if port == "" {
		switch parsed.Scheme {
		case "http":
			port = "80"
		case "https":
			port = "443"
		}
	}
	n, err := strconv.ParseUint(port, 10, 16)
	if err != nil || n == 0 {
		return []attribute.KeyValue{address}
	}
	return []attribute.KeyValue{address, attribute.Int(serverPort, int(n))}
}

// httpStatusError is implemented by an error that knows the HTTP status a server
// answered with. It is an interface rather than a concrete type so that any
// package can supply one without importing this one.
type httpStatusError interface{ StatusCode() int }

// errorTypeOf is the value the conventions ask for in error.type: "the error
// code returned by the Generative AI provider or the client library, the
// canonical name of exception that occurred, or another low-cardinality error
// identifier", whose example values include `500`.
//
// So: the status code as a string when the failure was a status the server
// answered with, which is the error code the provider returned; otherwise the
// canonical name of the error that occurred, taken from the deepest error in the
// chain, because a wrapper's type (`*fmt.wrapError`) names nothing while the
// error it wraps does.
func errorTypeOf(err error) string {
	var status httpStatusError
	if errors.As(err, &status) {
		return strconv.Itoa(status.StatusCode())
	}
	root := err
	for {
		next := errors.Unwrap(root)
		if next == nil {
			break
		}
		root = next
	}
	return fmt.Sprintf("%T", root)
}

func tracer() trace.Tracer {
	return otelapi.Tracer("github.com/AhmadMasry/agent-mesh-lab/internal/otel")
}

// end is what both spans below do when they finish: record the outcome and end.
// A second call does nothing, because the OpenTelemetry SDK ignores SetStatus,
// SetAttributes and End on a span that has ended; a caller may therefore end a
// span where the error is known and again on a shared way out.
func end(span trace.Span, err error) {
	if err != nil {
		span.SetAttributes(attribute.String(errorType, errorTypeOf(err)))
		span.SetStatus(codes.Error, err.Error())
	}
	span.End()
}

// ModelSpan is one model call's span, from ModelCall.
type ModelSpan struct{ span trace.Span }

// ModelCall starts the client span for one call to a model, and returns the
// context that call must use so the HTTP client span Transport creates lands
// under it. baseURL is the endpoint the call is configured to reach, and is
// read only for server.address and server.port.
//
// Per the conventions: the span name is "{gen_ai.operation.name}
// {gen_ai.request.model}", the kind is CLIENT ("It's RECOMMENDED to use CLIENT
// kind when the GenAI system being instrumented usually runs in a different
// process than its client"), and gen_ai.operation.name and gen_ai.provider.name
// are Required while gen_ai.request.model is Conditionally Required "If
// available".
func ModelCall(ctx context.Context, model, baseURL string, id Identity) (context.Context, *ModelSpan) {
	attrs := []attribute.KeyValue{
		attribute.String(genAIOperationName, operationChat),
		attribute.String(genAIProviderName, providerOpenAI),
	}
	if model != "" {
		attrs = append(attrs, attribute.String(genAIRequestModel, model))
	}
	attrs = append(attrs, serverAttributes(baseURL)...)
	attrs = append(attrs, id.attributes()...)

	name := operationChat
	if model != "" {
		name = operationChat + " " + model
	}
	ctx, span := tracer().Start(ctx, name, trace.WithSpanKind(trace.SpanKindClient), trace.WithAttributes(attrs...))
	return ctx, &ModelSpan{span: span}
}

// ModelResponse is what a model's answer contributes to its span. Every field
// here is Recommended on the inference span; a field the answer did not carry
// is left out rather than filled in.
type ModelResponse struct {
	ID            string
	Model         string
	FinishReasons []string
	InputTokens   int
	OutputTokens  int
}

// Response records what the model answered. The two token counts are written
// even when they are zero, because "the model reported none" and "the response
// carried no usage block" are the same number here and the lab's mock always
// reports both.
func (s *ModelSpan) Response(r ModelResponse) {
	if s == nil {
		return
	}
	if r.ID != "" {
		s.span.SetAttributes(attribute.String(genAIResponseID, r.ID))
	}
	if r.Model != "" {
		s.span.SetAttributes(attribute.String(genAIResponseModel, r.Model))
	}
	if len(r.FinishReasons) > 0 {
		s.span.SetAttributes(attribute.StringSlice(genAIFinishReasons, r.FinishReasons))
	}
	s.span.SetAttributes(
		attribute.Int(genAIInputTokens, r.InputTokens),
		attribute.Int(genAIOutputTokens, r.OutputTokens),
	)
}

// End records the outcome and ends the span.
func (s *ModelSpan) End(err error) {
	if s == nil {
		return
	}
	end(s.span, err)
}

// AgentSpan is one agent-to-agent call's span, from InvokeAgent.
type AgentSpan struct{ span trace.Span }

// Agent is what the caller knows about the agent it is about to invoke, which
// in this lab is whatever the resolved AgentCard said. Every field is optional:
// one the card did not carry sets no attribute.
//
// URL is the interface URL the client will dial, read only for server.address
// and server.port. A lab card advertises exactly one interface, so the caller
// has one URL to give; a card advertising several would need the client's own
// choice of interface rather than any of them.
type Agent struct {
	Name        string
	Version     string
	Description string
	URL         string
}

// InvokeAgent starts the client span for one call to a remote agent, and returns
// the context that call must use.
//
// Per the conventions' invoke agent client span, which "Describes GenAI agent
// invocation over a remote service": gen_ai.operation.name SHOULD be
// `invoke_agent`, the span name SHOULD be "invoke_agent {gen_ai.agent.name} if
// gen_ai.agent.name is readily available" and "When gen_ai.agent.name is not
// available, it SHOULD be invoke_agent", and the kind SHOULD be CLIENT.
// gen_ai.agent.name, gen_ai.agent.version and gen_ai.agent.description are each
// Conditionally Required "When available." and come from the resolved agent
// card, which carries all three. gen_ai.agent.id is not set: it is
// Conditionally Required "If applicable", and an A2A v1.0 AgentCard carries no
// agent identifier -- a2a-go's a2a.AgentCard has Name, Version and Description
// and no id field.
//
// One span covers one logical invocation, including whatever the A.2 resend
// knobs then put on the wire: the conventions say a span "SHOULD cover the
// duration of the logical operation with all retries", and it keeps this
// instrumentation outside the knobs' code paths.
func InvokeAgent(ctx context.Context, agent Agent, id Identity) (context.Context, *AgentSpan) {
	attrs := []attribute.KeyValue{
		attribute.String(genAIOperationName, operationInvokeAgent),
		attribute.String(genAIProviderName, providerA2A),
	}
	for _, pair := range []struct{ key, value string }{
		{genAIAgentName, agent.Name},
		{genAIAgentVersion, agent.Version},
		{genAIAgentDescription, agent.Description},
	} {
		if pair.value != "" {
			attrs = append(attrs, attribute.String(pair.key, pair.value))
		}
	}
	attrs = append(attrs, serverAttributes(agent.URL)...)
	attrs = append(attrs, id.attributes()...)

	name := operationInvokeAgent
	if agent.Name != "" {
		name = operationInvokeAgent + " " + agent.Name
	}
	ctx, span := tracer().Start(ctx, name, trace.WithSpanKind(trace.SpanKindClient), trace.WithAttributes(attrs...))
	return ctx, &AgentSpan{span: span}
}

// Conversation records the A2A contextId as gen_ai.conversation.id, which is
// Conditionally Required "If and only if the instrumented library has one
// readily available". A2A gives one back on the Task, so it is set when the
// answer carried one and left unset otherwise: the conventions are explicit that
// "a new UUID, a trace identifier, or a hash of request content SHOULD NOT be
// used as a fallback value".
func (s *AgentSpan) Conversation(contextID string) {
	if s == nil || contextID == "" {
		return
	}
	s.span.SetAttributes(attribute.String(genAIConversation, contextID))
}

// End records the outcome and ends the span.
func (s *AgentSpan) End(err error) {
	if s == nil {
		return
	}
	end(s.span, err)
}
