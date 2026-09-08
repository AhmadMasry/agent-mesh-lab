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
)

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// modelTimeout is the model client's overall timeout (MODEL_TIMEOUT_S, default 60 s).
// The baseline's delay-then-close run lowers it so a repetition does not take a minute.
func modelTimeout() time.Duration {
	if v, err := strconv.Atoi(os.Getenv("MODEL_TIMEOUT_S")); err == nil && v > 0 {
		return time.Duration(v) * time.Second
	}
	return 60 * time.Second
}

// newRootMux puts everything A2A (card and JSON-RPC) behind the ingress ledger
// and leaves the readiness probe and the control endpoints in front of it, so
// neither probe traffic nor arming a work item ever appears as a delivery. None
// of these patterns carries a method: a wrong method reaches the handler's own
// 405 instead of falling through to the A2A handler and being counted.
func newRootMux(a2a http.Handler, lw *lineWriter, inj *injector) *http.ServeMux {
	root := http.NewServeMux()
	root.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		_, _ = w.Write([]byte("ok\n"))
	})
	root.HandleFunc("/control/inject", inj.handleInject)
	root.HandleFunc("/control/reset", inj.handleReset)
	root.Handle("/", newIngressMiddleware(a2a, lw, inj))
	return root
}

func main() {
	name := getenv("AGENT_NAME", "worker")
	modelBase := getenv("MODEL_BASE_URL", "http://mockllm.lab.svc.cluster.local:8080/v1")
	modelName := getenv("MODEL_NAME", "mock")
	modelKey := getenv("MODEL_API_KEY", "unused")
	publicURL := getenv("PUBLIC_URL", "http://worker.lab.svc.cluster.local:8080")
	listen := getenv("LISTEN_ADDR", ":8080")
	if os.Getenv("DOWNSTREAM_A2A_URL") != "" {
		log.Fatal("worker: DOWNSTREAM_A2A_URL is set but forward mode is not implemented in this gate")
	}

	// Timeouts recorded in the findings entry; the model call as a whole is bounded
	// by the client Timeout (MODEL_TIMEOUT_S), which is also the response-header timeout.
	modelHTTP := httpclient.New(modelTimeout())
	ledger := newLineWriter(os.Stdout)
	executor := newLabExecutor(name, newModelClient(modelBase, modelName, modelKey, modelHTTP), ledger)
	handler := newExecutionLedger(a2asrv.NewHandler(executor), ledger)

	card := &a2a.AgentCard{
		Name:        name,
		Description: "agent-mesh-lab agent: one model call per message",
		Version:     "0.0.0",
		SupportedInterfaces: []*a2a.AgentInterface{
			a2a.NewAgentInterface(publicURL, a2a.TransportProtocolJSONRPC),
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

	a2aMux := http.NewServeMux()
	a2aMux.Handle(a2asrv.WellKnownAgentCardPath, a2asrv.NewStaticAgentCardHandler(card))
	a2aMux.Handle("/", a2asrv.NewJSONRPCHandler(handler))
	inj := newInjector()
	root := newRootMux(a2aMux, ledger, inj)

	srv := &http.Server{
		Addr:              listen,
		Handler:           root,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      120 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()
	log.Printf("worker %q listening on %s; card at %s; model %s (timeout %s)", name, listen, a2asrv.WellKnownAgentCardPath, modelBase, modelTimeout())
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
