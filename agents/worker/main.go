// Command worker is the Go agent (Agent B by default): an a2a-go JSON-RPC
// server whose executor makes one model call per message, wrapped by the
// pre-dispatch ingress ledger and the execution ledger. It contains no retry
// logic anywhere.
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"

	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
	"github.com/AhmadMasry/agent-mesh-lab/internal/workermux"
)

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// modelTimeout is the model client's overall timeout (MODEL_TIMEOUT_S, default 60 s).
// The baseline's delay-then-close run lowers it so a repetition does not take a minute.
// It is also the ceiling on the mock's delay mode: a delay_ms at or past it ends
// with this client closing the connection. The mock records such a call as
// client-gone when its caller leaves directly (measured in fixtures/mockllm's
// tests); through agw-central, the path this client takes, Experiment B-3
// measures it (fixtures/mockllm/injection.go, modeDelay, has the ceilings).
func modelTimeout() time.Duration {
	if v, err := strconv.Atoi(os.Getenv("MODEL_TIMEOUT_S")); err == nil && v > 0 {
		return time.Duration(v) * time.Second
	}
	return 60 * time.Second
}

// modelRetries is how many times the model call is re-sent (MODEL_RETRIES,
// default 0, which is no retry at all). It is the worker's only retry knob and
// it exists for one measurement: the A.3 row that asks what a retry between the
// agent and the model duplicates. Anything that is not a positive integer leaves
// it off, so a typo in a run script cannot add a retry nobody asked for.
func modelRetries() int {
	if v, err := strconv.Atoi(os.Getenv("MODEL_RETRIES")); err == nil && v > 0 {
		return v
	}
	return 0
}

// newModelHTTPClient builds the model client this process's environment asks
// for: the lab's no-retry client unless MODEL_RETRIES asked for more, and then
// the same client with its transport wrapped so the same bytes are re-sent.
//
// The mode is transport+503 rather than the transport-error-only default for the
// reason A.2 recorded: the failures this lab injects between the agent and the
// model reach the caller through an agentgateway waypoint, which answers 503 for
// an upstream that went away, so a transport-error-only retry would never
// re-send on this path.
func newModelHTTPClient(timeout time.Duration) *http.Client {
	if n := modelRetries(); n > 0 {
		return httpclient.NewRetryingOn(timeout, n, httpclient.RetryOnTransportOr503)
	}
	return httpclient.New(timeout)
}

// newRootMux puts everything A2A (card and JSON-RPC) behind the ingress ledger
// and leaves the readiness probe and the control endpoints in front of it, so
// neither probe traffic nor arming a work item ever appears as a delivery. None
// of these patterns carries a method: a wrong method reaches the handler's own
// 405 instead of falling through to the A2A handler and being counted.
func newRootMux(a2a http.Handler, lw *lineWriter, inj *injector, opts ...ingressOption) *http.ServeMux {
	healthz := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		_, _ = w.Write([]byte("ok\n"))
	})
	return workermux.NewRoot(healthz, http.HandlerFunc(inj.handleInject), http.HandlerFunc(inj.handleReset),
		newIngressMiddleware(a2a, lw, inj, opts...))
}

// buildCard is this agent's card. It declares streaming because this handler
// serves both streaming operations: a2asrv.NewHandler without
// WithCapabilityChecks serves SendStreamingMessage and SubscribeToTask whatever
// the card says (a2a-go v2.5.0, a2asrv/handler.go l.341, l.362), and a client
// built from a card that does not declare it sends a unary SendMessage instead
// (a2aclient/client.go l.109-118). Undeclared-but-served is the pairing A2A
// v1.0 forbids (specification v1.0.1 l.574), and it is what this receiver had.
//
// It lists the three bindings this agent serves (bindings.go), JSON-RPC FIRST.
// The order is load-bearing: a2a-go's client factory, with no
// PreferredTransports, keeps the card's order among the interfaces it can use
// (a2aclient/factory.go l.175-225, a stable sort on version then client
// preference), and its defaults can use JSON-RPC and REST (l.62-64), so a card
// that listed REST first would move a default client off JSON-RPC.
// TestCard_DefaultClientStaysOnJSONRPC holds it. The lab's own clients do not
// rely on it (the load client registers JSON-RPC only unless CLIENT_BINDING
// says otherwise, and the orchestrator's a2a-python client uses JSON-RPC only),
// but a card is read by clients the lab did not write.
func buildCard(name, publicURL, grpcURL string) *a2a.AgentCard {
	return &a2a.AgentCard{
		Name:         name,
		Description:  "agent-mesh-lab agent: one model call per message",
		Version:      "0.0.0",
		Capabilities: a2a.AgentCapabilities{Streaming: true},
		SupportedInterfaces: []*a2a.AgentInterface{
			a2a.NewAgentInterface(publicURL, a2a.TransportProtocolJSONRPC),
			a2a.NewAgentInterface(publicURL, a2a.TransportProtocolHTTPJSON),
			a2a.NewAgentInterface(grpcURL, a2a.TransportProtocolGRPC),
		},
		DefaultInputModes:  []string{"text/plain"},
		DefaultOutputModes: []string{"text/plain"},
		Skills: []a2a.AgentSkill{{
			ID:          "answer",
			Name:        "answer",
			Description: "returns the model's answer to the message text",
			Tags:        []string{"lab"},
		}},
	}
}

// newServerHandler is the whole handler chain this process serves, in the order
// the order matters in: the write-deadline lift outermost, then the tracing
// instrumentation, then the root mux with the ingress ledger inside it.
//
// It is a function, and not four lines inside main, because the order is a
// property worth asserting. http.Server.WriteTimeout bounds a whole response
// and is set when the request's header is read, so a stream that outlives it is
// cut by this receiver — and cut in exactly the shape a lost transport has, the
// observation Experiment B is built on. The lift removes that bound for a
// streamed response only, and it can only be taken at the outermost handler,
// where the ResponseWriter is still net/http's own. Both halves of that
// sentence are tested against this function: a stream past the deadline
// completes, and a unary response past the deadline does not.
func newServerHandler(name string, a2aHandler http.Handler, lw *lineWriter, inj *injector, opts ...ingressOption) http.Handler {
	return newWriteDeadlineLift(labotel.Handler(name, newRootMux(a2aHandler, lw, inj, opts...)))
}

func main() {
	name := getenv("AGENT_NAME", "worker")
	modelBase := getenv("MODEL_BASE_URL", "http://mockllm.lab.svc.cluster.local:8080/v1")
	modelName := getenv("MODEL_NAME", "mock")
	modelKey := getenv("MODEL_API_KEY", "unused")
	publicURL := getenv("PUBLIC_URL", "http://worker.lab.svc.cluster.local:8080")
	listen := getenv("LISTEN_ADDR", ":8080")
	// The gRPC binding's port and the address the card gives for it: a gRPC
	// target, host:port with no scheme, which is what a2a-go's gRPC client
	// dials (a2agrpc/v1/client.go l.37, grpc.NewClient(iface.URL)).
	grpcListen := getenv("GRPC_LISTEN_ADDR", ":8081")
	grpcPublic := getenv("PUBLIC_GRPC_URL", "worker.lab.svc.cluster.local:8081")
	if os.Getenv("DOWNSTREAM_A2A_URL") != "" {
		log.Fatal("worker: DOWNSTREAM_A2A_URL is set but forward mode is not implemented in this gate")
	}
	// Read before anything else starts: a value that is not an operation this
	// agent can refuse stops the process here, rather than serving everything.
	refuse, err := refuseOperationFrom(os.Getenv(refuseOperationEnv))
	if err != nil {
		log.Fatalf("worker: %v", err)
	}
	// The same for the ledger's header reading: a value that is not "on" stops
	// the process here, rather than serving with the reading off.
	headersOn, err := ledgerHeadersFrom(os.Getenv(ledgerHeadersEnv))
	if err != nil {
		log.Fatalf("worker: %v", err)
	}

	// Tracing, if OTEL_EXPORTER_OTLP_ENDPOINT names a collector; nothing at all
	// otherwise. The deferred shutdown flushes whatever the batch processor is
	// still holding when the server stops.
	otelShutdown, err := labotel.Setup(context.Background())
	if err != nil {
		log.Fatalf("worker: tracing setup: %v", err)
	}
	defer func() {
		flushCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := otelShutdown(flushCtx); err != nil {
			log.Printf("worker: tracing shutdown: %v", err)
		}
	}()

	// Timeouts recorded in the findings entry; the model call as a whole is bounded
	// by the client Timeout (MODEL_TIMEOUT_S), which is also the response-header timeout.
	// The transport is wrapped so the model call is a client span carrying the
	// trace context onward; internal/httpclient's own settings are untouched by
	// the wrap, and no retry is added by it. Whether there is a retry underneath
	// is MODEL_RETRIES' decision alone, taken before the wrap, so the span covers
	// every attempt the client makes, as the load client's does.
	modelHTTP := newModelHTTPClient(modelTimeout())
	modelHTTP.Transport = labotel.Transport(modelHTTP.Transport)
	ledger := newLineWriter(os.Stdout)
	executor := newLabExecutor(name, newModelClient(modelBase, modelName, modelKey, modelHTTP), ledger)
	handler := newRequestHandler(executor, ledger, refuse)

	card := buildCard(name, publicURL, grpcPublic)

	a2aMux := newA2AMux(card, handler)
	inj := newInjector()

	srv := &http.Server{
		Addr:              listen,
		Handler:           newServerHandler(name, a2aMux, ledger, inj, withHeaderReading(headersOn)),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      120 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	// The gRPC binding's server: the same chain as port 8080 (write-deadline
	// lift, tracing, root mux, ingress ledger), with the SDK's gRPC server in
	// place of the card, REST and JSON-RPC handlers.
	grpcSrv := newGRPCServer(grpcListen, newServerHandler(name, newGRPCHandler(handler), ledger, inj, withHeaderReading(headersOn)))

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
		_ = grpcSrv.Shutdown(shutdownCtx)
	}()
	log.Printf("worker %q listening on %s (JSON-RPC, REST) and %s (gRPC, h2c); card at %s; model %s (timeout %s, MODEL_RETRIES=%d, %s=%q, %s=%q)", name, listen, grpcListen, a2asrv.WellKnownAgentCardPath, modelBase, modelTimeout(), modelRetries(), refuseOperationEnv, refuse, ledgerHeadersEnv, os.Getenv(ledgerHeadersEnv))
	// Either listener failing stops the process: an agent that serves one
	// binding and not the other would make every comparison between them
	// silently one-sided.
	errs := make(chan error, 2)
	go func() { errs <- srv.ListenAndServe() }()
	go func() { errs <- grpcSrv.ListenAndServe() }()
	for range 2 {
		if err := <-errs; err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
	}
}
