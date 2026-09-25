package main

import (
	"net/http"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	a2agrpc "github.com/a2aproject/a2a-go/v2/a2agrpc/v1"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
	"google.golang.org/grpc"

	"github.com/AhmadMasry/agent-mesh-lab/internal/workermux"
)

// The three A2A v1.0 bindings this agent serves (follow-on D-2, the author's
// notes of 2026-09-24), each from the SDK's own server for it and each over the
// one transport-agnostic request handler, so the execution ledger and the
// REFUSE_OPERATION interceptor sit under all three alike:
//
//	JSON-RPC  a2asrv.NewJSONRPCHandler      port 8080, POST /
//	REST      a2asrv.NewRESTHandler         port 8080, POST /message:send,
//	                                        POST /message:stream,
//	                                        GET|POST /tasks/{id}:subscribe, ...
//	gRPC      a2agrpc.NewHandler on a       port 8081 (GRPC_LISTEN_ADDR),
//	          grpc.Server, served through   HTTP/2 over cleartext only,
//	          its ServeHTTP                 /lf.a2a.v1.A2AService/<Method>
//
// Why REST shares 8080 with JSON-RPC: both are HTTP/1.1 JSON over the same
// handler chain, and the SDK's REST paths are disjoint from JSON-RPC's single
// "/" (a2a-go v2.5.0 a2asrv/rest.go l.51-60), so one port serves both and the
// routes that already carry 8080 carry REST unchanged.
//
// Why gRPC has a port of its own: gRPC is HTTP/2 with prior knowledge, and the
// port that carries it is marked kubernetes.io/h2c on the Service so that
// agentgateway speaks HTTP/2 to it (port_is_http2, agentgateway v1.5.0
// crates/agentgateway/src/proxy/httpproxy.rs l.3114). Port 8080's Service entry
// is left exactly as it was, so nothing that reaches 8080 today is spoken to
// differently.
//
// Why ServeHTTP and not grpc.Server.Serve: ServeHTTP puts the gRPC server
// inside this process's net/http handler chain, so the pre-dispatch ingress
// ledger reads a gRPC request at the same HTTP boundary, with the same code, as
// a JSON-RPC or REST one, before the SDK sees it (CLAUDE.md rule 5). grpc-go
// v1.83.2 marks ServeHTTP EXPERIMENTAL and says it "uses Go's HTTP/2 server
// implementation which is totally separate from grpc-go's HTTP/2 server.
// Performance and features may vary" (server.go l.1114-1122); that is recorded,
// not hidden.

// newA2AMux is the handler set port 8080 serves inside the ingress ledger: the
// agent card, the REST binding's paths and the JSON-RPC binding at "/". The
// patterns are internal/workermux's, which the extauthz fixture replays
// (follow-on D-3b).
func newA2AMux(card *a2a.AgentCard, handler a2asrv.RequestHandler) *http.ServeMux {
	return workermux.NewA2A(a2asrv.NewStaticAgentCardHandler(card), a2asrv.NewRESTHandler(handler), a2asrv.NewJSONRPCHandler(handler))
}

// newGRPCHandler is the gRPC binding: the SDK's A2AService registered on a
// grpc.Server that this process serves through ServeHTTP. No server option is
// set; the server has no retry of any kind to turn off.
func newGRPCHandler(handler a2asrv.RequestHandler) *grpc.Server {
	s := grpc.NewServer()
	a2agrpc.NewHandler(handler).RegisterWith(s)
	return s
}

// newGRPCServer is port 8081's http.Server: HTTP/2 over cleartext with prior
// knowledge only, which is what a gRPC client and agentgateway's HTTP/2
// upstream speak. Its timeouts are port 8080's, and a streamed gRPC response
// has its write deadline lifted as an SSE one does (ingress.go, streamed).
func newGRPCServer(addr string, handler http.Handler) *http.Server {
	var protocols http.Protocols
	protocols.SetUnencryptedHTTP2(true)
	return &http.Server{
		Addr:              addr,
		Handler:           handler,
		Protocols:         &protocols,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      120 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
}
