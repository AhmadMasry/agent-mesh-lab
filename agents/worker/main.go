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

	// Timeouts recorded in the findings entry; the model client's response-header
	// timeout is 60s, the model call as a whole is bounded by the client Timeout.
	modelHTTP := httpclient.New(60 * time.Second)
	executor := newLabExecutor(name, newModelClient(modelBase, modelName, modelKey, modelHTTP), os.Stdout)
	handler := newExecutionLedger(a2asrv.NewHandler(executor), os.Stdout)

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

	mux := http.NewServeMux()
	mux.Handle(a2asrv.WellKnownAgentCardPath, a2asrv.NewStaticAgentCardHandler(card))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok\n")) })
	mux.Handle("/", a2asrv.NewJSONRPCHandler(handler))

	srv := &http.Server{
		Addr:              listen,
		Handler:           newIngressMiddleware(mux, os.Stdout),
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
	log.Printf("worker %q listening on %s; card at %s; model %s", name, listen, a2asrv.WellKnownAgentCardPath, modelBase)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
