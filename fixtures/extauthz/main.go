// Command extauthz is the lab's external-authorization fixture: a gRPC server
// of envoy.service.auth.v3.Authorization/Check, the protocol agentgateway v1.5.0
// calls by default (crates/agentgateway/src/http/ext_authz.rs l.148-155 and
// l.568). It answers each check by one rule -- refuse SubscribeToTask, allow
// everything else -- read from what the proxy sends (decide.go), and writes one
// decision-ledger line per check to stdout before it answers (server.go).
//
// Added by the author's note of 2026-09-24, which widens rule 6 for this one
// fixture. It has no retry, no cache and no state beyond its ledger, and it
// makes no outbound call.
package main

import (
	"log"
	"net"
	"os"
)

const listenAddr = ":9000"

func main() {
	setting, err := parseUndecidable(os.Getenv("EXTAUTHZ_UNDECIDABLE"))
	if err != nil {
		log.Fatalf("extauthz: %v", err)
	}
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("extauthz: listen %s: %v", listenAddr, err)
	}
	log.Printf("extauthz listening on %s (gRPC envoy.service.auth.v3.Authorization); EXTAUTHZ_UNDECIDABLE=%s; JSON-RPC path %s", listenAddr, setting, jsonrpcPath)
	if err := newGRPCServer(newServer(os.Stdout, setting)).Serve(ln); err != nil {
		log.Fatalf("extauthz: serve: %v", err)
	}
}
