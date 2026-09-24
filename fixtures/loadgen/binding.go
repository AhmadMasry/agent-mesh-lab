package main

import (
	"fmt"
	"net/http"
	"os"
	"strings"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2aclient"
	a2agrpc "github.com/a2aproject/a2a-go/v2/a2agrpc/v1"

	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
)

// CLIENT_BINDING (follow-on D-2, the author's notes of 2026-09-24) says which
// A2A binding this process's one request is sent on. It is not a retry knob and
// adds no send:
//
//   - unset or empty         JSON-RPC, as every run before it: the factory has
//     no default transports and the one JSON-RPC transport, over the lab's HTTP
//     client (TestBinding_DefaultOff).
//   - CLIENT_BINDING=rest    the same, with the one REST (HTTP+JSON) transport
//     in its place, over the same HTTP client.
//   - CLIENT_BINDING=grpc    the one gRPC transport (a2agrpc.WithGRPCTransport),
//     over a grpc-go connection built by grpcCall.dialOptions (grpc.go), which says
//     what grpc-go retries and what is recorded. The card is still resolved over
//     HTTP with the lab's HTTP client, as on the other bindings; only the RPC
//     is gRPC. With CLIENT_DIAL=target the RPC is sent to TARGET_URL's host and
//     port.
//
// Any other value is refused before anything is sent: a binding dropped to
// JSON-RPC would run a row on the binding it was meant to compare against, and
// record it as the other.
//
// Only one transport is ever registered, so which binding is used never depends
// on the order the receiver's card lists its interfaces in: a card listing
// several is read for the one interface of the binding asked for.
type bindingMode string

const (
	bindingJSONRPC bindingMode = ""
	bindingREST    bindingMode = "rest"
	bindingGRPC    bindingMode = "grpc"
)

func bindingFromEnv() (bindingMode, error) {
	switch v := os.Getenv("CLIENT_BINDING"); v {
	case "":
		return bindingJSONRPC, nil
	case string(bindingREST):
		return bindingREST, nil
	case string(bindingGRPC):
		return bindingGRPC, nil
	default:
		return "", fmt.Errorf("CLIENT_BINDING=%q is not a value this client knows; it is %q, %q or unset, and nothing was sent", v, string(bindingREST), string(bindingGRPC))
	}
}

// protocol is the card's name for the binding.
func (b bindingMode) protocol() a2a.TransportProtocol {
	switch b {
	case bindingREST:
		return a2a.TransportProtocolHTTPJSON
	case bindingGRPC:
		return a2a.TransportProtocolGRPC
	}
	return a2a.TransportProtocolJSONRPC
}

// factoryOptions are the a2aclient options for the binding: no default
// transports, and the one transport of the binding -- over hc for JSON-RPC and
// REST, over a gRPC connection built with g's dial options for gRPC.
func (b bindingMode) factoryOptions(hc *http.Client, g *grpcCall) []a2aclient.FactoryOption {
	switch b {
	case bindingREST:
		return []a2aclient.FactoryOption{a2aclient.WithDefaultsDisabled(), a2aclient.WithRESTTransport(hc)}
	case bindingGRPC:
		return []a2aclient.FactoryOption{a2aclient.WithDefaultsDisabled(), a2agrpc.WithGRPCTransport(g.dialOptions()...)}
	}
	return []a2aclient.FactoryOption{a2aclient.WithDefaultsDisabled(), a2aclient.WithJSONRPCTransport(hc)}
}

// grpcAuthorityFromEnv reads CLIENT_GRPC_AUTHORITY, the :authority the gRPC
// call names (the author's extension of the Host setting to the gRPC rows, the
// dated note of 2026-09-24). Empty is off: the call names the host it dials,
// as grpc-go does. A value that is not a bare host name, or a value with any
// binding but gRPC, is refused before anything is sent.
func grpcAuthorityFromEnv(b bindingMode) (string, error) {
	v := os.Getenv("CLIENT_GRPC_AUTHORITY")
	if v == "" {
		return "", nil
	}
	if b != bindingGRPC {
		return "", fmt.Errorf("CLIENT_GRPC_AUTHORITY=%q is set, but CLIENT_BINDING=%q sends no gRPC call; nothing was sent", v, string(b))
	}
	if !bareHostName(v) {
		return "", fmt.Errorf("CLIENT_GRPC_AUTHORITY=%q is not a bare host name; nothing was sent", v)
	}
	return v, nil
}

// spanAgent is the agent the invoke_agent span is given. For JSON-RPC and REST
// it is agentFromCard's, unchanged. A gRPC interface's URL is a gRPC target,
// host:port with no scheme, which the span's URL reading would not parse as a
// host; it is given the scheme "grpc" so server.address and server.port read
// the host and port the call dials. The line records the target as the card
// gave it.
func spanAgent(agent labotel.Agent, protocol a2a.TransportProtocol) labotel.Agent {
	if protocol == a2a.TransportProtocolGRPC && agent.URL != "" && !strings.Contains(agent.URL, "://") {
		agent.URL = "grpc://" + agent.URL
	}
	return agent
}

// newGRPCCall is the gRPC call's recorder for a process on the gRPC binding,
// nil on every other binding, where it adds nothing to any line.
func newGRPCCall(b bindingMode, authority, workItem string) *grpcCall {
	if b != bindingGRPC {
		return nil
	}
	return &grpcCall{authority: authority, workItem: workItem}
}
