// Command mockllm is a controllable, OpenAI-compatible chat-completions
// endpoint for the agent-mesh-lab experiments. It answers deterministically
// (fixed text, fixed latency, an id derived from the request hash), injects
// failures on command, and writes one invocation-ledger line per call to
// stdout. It makes no outbound HTTP calls of its own, so there is no client
// retry setting to disable here.
package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
)

const (
	defaultResponseText = "This is the mockllm fixed response."
	defaultLatencyMs    = 200

	// Explicit http.Server timeouts, chosen for this fixture and recorded
	// in findings.md. Generous relative to the configurable latency and
	// delay_ms values used in Gate 1 runs (hundreds of milliseconds), so a
	// deliberately slow response is never mistaken for a hung server.
	readHeaderTimeout = 5 * time.Second
	readTimeout       = 10 * time.Second
	writeTimeout      = 10 * time.Second
	idleTimeout       = 60 * time.Second

	listenAddr = ":8080"
)

func main() {
	// Tracing, if OTEL_EXPORTER_OTLP_ENDPOINT names a collector; nothing at all
	// otherwise. The deferred shutdown flushes whatever the batch processor is
	// still holding when the server stops. This adds no outbound call of the
	// fixture's own beyond the span export, so there is still no client retry
	// setting here to disable.
	otelShutdown, err := labotel.Setup(context.Background())
	if err != nil {
		log.Fatalf("mockllm: tracing setup: %v", err)
	}
	defer func() {
		flushCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := otelShutdown(flushCtx); err != nil {
			log.Printf("mockllm: tracing shutdown: %v", err)
		}
	}()

	cfg := Config{
		ResponseText:      getEnv("MOCKLLM_RESPONSE_TEXT", defaultResponseText),
		LatencyMs:         getEnvInt("MOCKLLM_LATENCY_MS", defaultLatencyMs),
		ReadHeaderTimeout: readHeaderTimeout,
		ReadTimeout:       readTimeout,
		WriteTimeout:      writeTimeout,
		IdleTimeout:       idleTimeout,
	}

	s := newServer(cfg, os.Stdout)

	httpServer := &http.Server{
		Addr:              listenAddr,
		ReadHeaderTimeout: cfg.ReadHeaderTimeout,
		ReadTimeout:       cfg.ReadTimeout,
		WriteTimeout:      cfg.WriteTimeout,
		IdleTimeout:       cfg.IdleTimeout,
	}
	s.configureHTTPServer(httpServer)
	// Wrapped here rather than inside configureHTTPServer, so the connection
	// tracking that stale mode depends on stays exactly as the tests exercise it.
	httpServer.Handler = labotel.Handler("mockllm", httpServer.Handler)

	log.Printf("mockllm: listening on %s (latency_ms=%d, response_text_len=%d)",
		httpServer.Addr, cfg.LatencyMs, len(cfg.ResponseText))
	if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("mockllm: server error: %v", err)
	}
}

func getEnv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getEnvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
