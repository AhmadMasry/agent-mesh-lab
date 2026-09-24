package main

import (
	"context"
	"net"
	"net/url"
	"strings"
	"sync"

	otelapi "go.opentelemetry.io/otel"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/stats"
	"google.golang.org/grpc/status"
)

// The gRPC binding's connection (CLIENT_BINDING=grpc), and what is recorded
// about it under rule 4 (CLAUDE.md), as the HTTP client's stale-connection
// replay is recorded in internal/httpclient (the author's ruling of 2026-09-24,
// the dated note on main).
//
// What grpc-go v1.83.2 retries, and what is turned off:
//
//   - Configured retries, from a service config: off. grpc.WithDisableRetry
//     turns them off "even if the service config enables them", and
//     grpc.WithDisableServiceConfig ignores any service config a resolver
//     returns, so none can name a retry policy (dialoptions.go).
//   - Transparent retries: NOT turn-off-able. WithDisableRetry "does not impact
//     transparent retries, which will happen automatically if no data is written
//     to the wire or if the RPC is unprocessed by the remote server"
//     (dialoptions.go l.678-681); stream.go l.708-720 re-sends an attempt whose
//     stream never started, or whose first attempt the server reported
//     unprocessed (REFUSED_STREAM, or a GOAWAY naming a lower stream), before
//     the disableRetry check. These are RECORDED instead: a stats handler counts
//     every attempt and every one grpc-go marks IsTransparentRetryAttempt, and
//     the client's line carries both. A repetition with a transparent attempt is
//     flagged in its entry, and the receiver's ingress ledger counts any
//     duplicate that reached it independently.
//
// Nothing else is set that could send again: no keepalive, no wait-for-ready,
// no load-balancing policy beyond the default pick-first.
type grpcCall struct {
	// authority is CLIENT_GRPC_AUTHORITY, "" when off.
	authority string
	workItem  string

	mu          sync.Mutex
	attempts    int
	transparent int
	code        *int
}

// grpcFacts is what a client line carries for a gRPC call, appended only when
// CLIENT_BINDING=grpc: a nil pointer adds no key.
type grpcFacts struct {
	// GRPCStatus is the status code the call ended with, from grpc-go's own End
	// event, -1 when no attempt ended (nothing was sent).
	GRPCStatus int `json:"grpc_status"`
	// GRPCAttempts counts every attempt grpc-go began for the call, the first
	// included; GRPCTransparentAttempts counts those it marked as transparent
	// retries. 1 and 0 is a call sent once.
	GRPCAttempts            int    `json:"grpc_attempts"`
	GRPCTransparentAttempts int    `json:"grpc_transparent_attempts"`
	GRPCAuthority           string `json:"grpc_authority,omitempty"`
}

func (g *grpcCall) facts() *grpcFacts {
	if g == nil {
		return nil
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	f := &grpcFacts{GRPCStatus: -1, GRPCAttempts: g.attempts, GRPCTransparentAttempts: g.transparent, GRPCAuthority: g.authority}
	if g.code != nil {
		f.GRPCStatus = *g.code
	}
	return f
}

func (g *grpcCall) dialOptions() []grpc.DialOption {
	opts := []grpc.DialOption{
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDisableRetry(),
		grpc.WithDisableServiceConfig(),
		grpc.WithStatsHandler(g),
		grpc.WithUnaryInterceptor(func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
			return invoker(g.identity(ctx), method, req, reply, cc, opts...)
		}),
		grpc.WithStreamInterceptor(func(ctx context.Context, desc *grpc.StreamDesc, cc *grpc.ClientConn, method string, streamer grpc.Streamer, opts ...grpc.CallOption) (grpc.ClientStream, error) {
			return streamer(g.identity(ctx), desc, cc, method, opts...)
		}),
	}
	if g.authority != "" {
		opts = append(opts, grpc.WithAuthority(g.authority))
	}
	return opts
}

// identity puts on the call what identityTransport puts on an HTTP request:
// the work item and the caller, as metadata, and the trace context, which the
// HTTP binding's transport injects and a gRPC call otherwise would not carry.
// a2a-go's gRPC transport builds the call's outgoing metadata from its service
// parameters (a2agrpc/v1/client.go l.263-271); these are appended to it.
func (g *grpcCall) identity(ctx context.Context) context.Context {
	ctx = metadata.AppendToOutgoingContext(ctx, "x-logical-work-item-id", g.workItem, "x-caller", "loadgen")
	carrier := metadataCarrier{}
	otelapi.GetTextMapPropagator().Inject(ctx, carrier)
	for k, v := range carrier {
		ctx = metadata.AppendToOutgoingContext(ctx, k, v)
	}
	return ctx
}

type metadataCarrier map[string]string

func (c metadataCarrier) Get(k string) string { return c[strings.ToLower(k)] }
func (c metadataCarrier) Set(k, v string)     { c[strings.ToLower(k)] = v }
func (c metadataCarrier) Keys() []string {
	out := make([]string, 0, len(c))
	for k := range c {
		out = append(out, k)
	}
	return out
}

// The stats.Handler: every attempt's Begin, and the status of the last End.
func (g *grpcCall) TagRPC(ctx context.Context, _ *stats.RPCTagInfo) context.Context { return ctx }
func (g *grpcCall) TagConn(ctx context.Context, _ *stats.ConnTagInfo) context.Context {
	return ctx
}
func (g *grpcCall) HandleConn(context.Context, stats.ConnStats) {}
func (g *grpcCall) HandleRPC(_ context.Context, s stats.RPCStats) {
	if !s.IsClient() {
		return
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	switch e := s.(type) {
	case *stats.Begin:
		g.attempts++
		if e.IsTransparentRetryAttempt {
			g.transparent++
		}
	case *stats.End:
		code := int(status.Code(e.Error))
		g.code = &code
	}
}

// grpcTarget is the gRPC target for TARGET_URL with CLIENT_DIAL=target: its host
// and port, the port being the scheme's default when the URL names none. ""
// when the URL names no host.
func grpcTarget(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil || u.Hostname() == "" {
		return ""
	}
	port := u.Port()
	if port == "" {
		port = "80"
		if u.Scheme == "https" {
			port = "443"
		}
	}
	return net.JoinHostPort(u.Hostname(), port)
}
