// Package workermux is the Go worker's HTTP routing, in one place, so that the
// worker serves it and the extauthz fixture replays it (follow-on D-3b, the
// author's note of 2026-09-25). The fixture asks this routing whether a request
// would reach the worker's JSON-RPC handler, whose body it then reads as a2a-go
// does; with one copy of the patterns, the fixture's answer cannot drift from
// what the worker serves.
//
// Both muxes are Go's own http.ServeMux, so path cleaning (a 307 to the cleaned
// path), segment-by-segment unescaping and the trailing-slash rules are the
// standard library's at the Go the binary is built with, not a copy of them.
package workermux

import "net/http"

// The root mux's patterns (agents/worker/main.go newRootMux): the readiness
// probe and the control endpoints in front of the ingress ledger, and
// everything else behind it. None carries a method.
const (
	HealthzPath       = "/healthz"
	ControlInjectPath = "/control/inject"
	ControlResetPath  = "/control/reset"
)

// The A2A mux's patterns (agents/worker/bindings.go newA2AMux).
const (
	// AgentCardPath is a2asrv.WellKnownAgentCardPath at a2a-go v2.5.0
	// (a2asrv/agentcard.go l.27); workermux_test.go holds the two equal. It is kept
	// here as a literal so that the fixture, which links no a2asrv, replays it.
	AgentCardPath = "/.well-known/agent-card.json"
	// JSONRPCPath is the JSON-RPC binding's pattern. In a ServeMux, "/" matches
	// every path no other pattern matches: the JSON-RPC handler is the
	// catch-all.
	JSONRPCPath = "/"
)

// RESTPaths are the path prefixes a2asrv.NewRESTHandler routes (a2a-go v2.5.0
// a2asrv/rest.go l.51-60), without the HTTP method: the REST handler's own mux
// answers a wrong method, and every other path stays with JSON-RPC.
var RESTPaths = []string{"/message:send", "/message:stream", "/tasks", "/tasks/", "/extendedAgentCard"}

// NewRoot is the root mux: healthz, inject and reset at their paths, and a2a
// (the ingress ledger with the A2A mux inside it) for everything else.
func NewRoot(healthz, inject, reset, a2a http.Handler) *http.ServeMux {
	root := http.NewServeMux()
	root.Handle(HealthzPath, healthz)
	root.Handle(ControlInjectPath, inject)
	root.Handle(ControlResetPath, reset)
	root.Handle(JSONRPCPath, a2a)
	return root
}

// NewA2A is the A2A mux: the agent card, the REST binding's paths and the
// JSON-RPC binding at "/".
func NewA2A(card, rest, jsonrpc http.Handler) *http.ServeMux {
	mux := http.NewServeMux()
	mux.Handle(AgentCardPath, card)
	for _, p := range RESTPaths {
		mux.Handle(p, rest)
	}
	mux.Handle(JSONRPCPath, jsonrpc)
	return mux
}
