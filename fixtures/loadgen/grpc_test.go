package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"iter"
	"net"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	a2agrpc "github.com/a2aproject/a2a-go/v2/a2agrpc/v1"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
	"golang.org/x/net/http2"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"

	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
)

// Follow-on D-2: CLIENT_BINDING=grpc and CLIENT_GRPC_AUTHORITY, and the
// recording of grpc-go's transparent retries (grpc.go).

type completing struct{}

func (completing) Execute(_ context.Context, ec *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) {
		if !yield(a2a.NewSubmittedTask(ec, ec.Message), nil) {
			return
		}
		yield(a2a.NewStatusUpdateEvent(ec, a2a.TaskStateCompleted, nil), nil)
	}
}

func (completing) Cancel(_ context.Context, ec *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) {
		yield(a2a.NewStatusUpdateEvent(ec, a2a.TaskStateCanceled, nil), nil)
	}
}

// grpcSeen is one call the test's gRPC server received.
type grpcSeen struct {
	method string
	md     metadata.MD
}

// grpcAgent serves, on ONE h2c port as the agentgateway ingress does on its
// port 80, the agent card over HTTP/1.1 and the A2A gRPC service over HTTP/2.
// The card advertises advertisedGRPC as its gRPC interface.
type grpcAgent struct {
	url  string // http://127.0.0.1:port
	addr string // 127.0.0.1:port
	mu   sync.Mutex
	seen []grpcSeen
}

func newGRPCAgent(t *testing.T, advertisedGRPC func(addr string) string) *grpcAgent {
	t.Helper()
	a := &grpcAgent{}
	gs := grpc.NewServer(
		grpc.UnaryInterceptor(func(ctx context.Context, req any, info *grpc.UnaryServerInfo, h grpc.UnaryHandler) (any, error) {
			md, _ := metadata.FromIncomingContext(ctx)
			a.mu.Lock()
			a.seen = append(a.seen, grpcSeen{info.FullMethod, md})
			a.mu.Unlock()
			return h(ctx, req)
		}),
		grpc.StreamInterceptor(func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, h grpc.StreamHandler) error {
			md, _ := metadata.FromIncomingContext(ss.Context())
			a.mu.Lock()
			a.seen = append(a.seen, grpcSeen{info.FullMethod, md})
			a.mu.Unlock()
			return h(srv, ss)
		}))
	a2agrpc.NewHandler(a2asrv.NewHandler(completing{})).RegisterWith(gs)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	a.addr = ln.Addr().String()
	a.url = "http://" + a.addr
	card := func() *a2a.AgentCard {
		return &a2a.AgentCard{Name: "grpc-agent", Description: "d", Version: "0.0.1",
			Capabilities: a2a.AgentCapabilities{Streaming: true},
			SupportedInterfaces: []*a2a.AgentInterface{
				{URL: a.url + "/jsonrpc", ProtocolBinding: a2a.TransportProtocolJSONRPC, ProtocolVersion: a2a.Version},
				{URL: a.url, ProtocolBinding: a2a.TransportProtocolHTTPJSON, ProtocolVersion: a2a.Version},
				{URL: advertisedGRPC(a.addr), ProtocolBinding: a2a.TransportProtocolGRPC, ProtocolVersion: a2a.Version},
			}}
	}
	var protocols http.Protocols
	protocols.SetHTTP1(true)
	protocols.SetUnencryptedHTTP2(true)
	srv := &http.Server{Protocols: &protocols, Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor == 2 && strings.HasPrefix(r.Header.Get("Content-Type"), "application/grpc") {
			gs.ServeHTTP(w, r)
			return
		}
		if strings.HasSuffix(r.URL.Path, "agent-card.json") {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(card())
			return
		}
		http.NotFound(w, r)
	})}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })
	return a
}

func (a *grpcAgent) calls() []grpcSeen {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]grpcSeen(nil), a.seen...)
}

func runGRPC(t *testing.T, c runConfig) (int, []map[string]any, string) {
	t.Helper()
	var out bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	c.workItem = "lwi-grpc"
	c.text = "hello"
	hc := instrument(httpclient.New(10*time.Second), c.workItem)
	if c.mode.mode != modeUnary {
		hc = streamClientForTest()
	}
	code := runMode(ctx, hc, c, &out)
	var lines []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("line is not JSON: %v: %s", err, l)
		}
		lines = append(lines, m)
	}
	return code, lines, out.String()
}

func TestGRPC_OneCallToTheAdvertisedTargetWithTheIdentityAndOneAttempt(t *testing.T) {
	a := newGRPCAgent(t, func(addr string) string { return addr })
	code, lines, raw := runGRPC(t, runConfig{target: a.url, binding: bindingGRPC})
	if code != 0 {
		t.Fatalf("exit %d: %s", code, raw)
	}
	calls := a.calls()
	if len(calls) != 1 || calls[0].method != "/lf.a2a.v1.A2AService/SendMessage" {
		t.Fatalf("calls = %+v, want one SendMessage", calls)
	}
	md := calls[0].md
	for k, want := range map[string]string{"x-logical-work-item-id": "lwi-grpc", "x-caller": "loadgen", "a2a-version": "1.0"} {
		if got := md.Get(k); len(got) != 1 || got[0] != want {
			t.Errorf("metadata %s = %v, want [%s]", k, got, want)
		}
	}
	if got := md.Get(":authority"); len(got) != 1 || got[0] != a.addr {
		t.Errorf(":authority = %v, want the dialled %s", got, a.addr)
	}
	l := lines[0]
	if l["binding"] != "grpc" || l["dialled_url"] != a.addr || l["grpc_status"] != float64(0) ||
		l["grpc_attempts"] != float64(1) || l["grpc_transparent_attempts"] != float64(0) || l["state"] != "TASK_STATE_COMPLETED" {
		t.Errorf("line = %s", raw)
	}
	if _, ok := l["grpc_authority"]; ok {
		t.Errorf("grpc_authority on the line with the setting off: %s", raw)
	}
}

func TestGRPC_TheAuthoritySettingNamesTheCallsAuthorityAndDialTargetTheTargetsPort(t *testing.T) {
	// The card advertises a gRPC target nobody listens on; CLIENT_DIAL=target
	// sends the call to TARGET_URL's host and port instead, naming the
	// authority CLIENT_GRPC_AUTHORITY gives.
	a := newGRPCAgent(t, func(string) string { return "grpc-advertised.invalid:8081" })
	code, lines, raw := runGRPC(t, runConfig{target: a.url, binding: bindingGRPC, dial: dialTarget,
		grpcAuthority: "worker-grpc.lab.internal"})
	if code != 0 {
		t.Fatalf("exit %d: %s", code, raw)
	}
	calls := a.calls()
	if len(calls) != 1 {
		t.Fatalf("calls = %d", len(calls))
	}
	if got := calls[0].md.Get(":authority"); len(got) != 1 || got[0] != "worker-grpc.lab.internal" {
		t.Errorf(":authority = %v", got)
	}
	if lines[0]["dialled_url"] != a.addr || lines[0]["grpc_authority"] != "worker-grpc.lab.internal" {
		t.Errorf("line = %s", raw)
	}
}

func TestGRPC_SubscribeRecordsTheStatusAndOneAttempt(t *testing.T) {
	a := newGRPCAgent(t, func(addr string) string { return addr })
	code, lines, raw := runGRPC(t, runConfig{target: a.url, binding: bindingGRPC, mode: modeConfig{mode: modeSubscribe, taskID: "no-such-task"}})
	if code == 0 {
		t.Fatalf("exit 0 for a subscription to a missing task: %s", raw)
	}
	end := lines[len(lines)-1]
	if end["line"] != "end" || end["method"] != "SubscribeToTask" || end["grpc_status"] != float64(5) ||
		end["grpc_attempts"] != float64(1) || end["stream_end"] != "error" || end["binding"] != "grpc" {
		t.Errorf("end = %s", raw)
	}
	if calls := a.calls(); len(calls) != 1 || calls[0].method != "/lf.a2a.v1.A2AService/SubscribeToTask" {
		t.Errorf("calls = %+v", calls)
	}
}

// goawayFirst is a TCP front for the gRPC agent: the FIRST connection is
// answered by a bare HTTP/2 speaker that, on the first HEADERS frame, sends a
// GOAWAY naming stream 0 as the last it processed and closes -- the server
// telling the client that stream was never processed. Every later connection
// is relayed to the agent. grpc-go retries such an attempt transparently
// (stream.go l.717-720), and that is the attempt the recorder must count.
func goawayFirst(t *testing.T, upstream string) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go func() {
		first := true
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			if first {
				first = false
				go func(c net.Conn) {
					defer func() { _ = c.Close() }()
					preface := make([]byte, len(http2.ClientPreface))
					if _, err := io.ReadFull(c, preface); err != nil {
						return
					}
					fr := http2.NewFramer(c, c)
					_ = fr.WriteSettings()
					for {
						f, err := fr.ReadFrame()
						if err != nil {
							return
						}
						switch f := f.(type) {
						case *http2.SettingsFrame:
							if !f.IsAck() {
								_ = fr.WriteSettingsAck()
							}
						case *http2.HeadersFrame:
							_ = fr.WriteGoAway(0, http2.ErrCodeNo, nil)
							time.Sleep(50 * time.Millisecond)
							return
						}
					}
				}(c)
				continue
			}
			go func(c net.Conn) {
				u, err := net.Dial("tcp", upstream)
				if err != nil {
					_ = c.Close()
					return
				}
				go func() { _, _ = io.Copy(u, c); _ = u.Close() }()
				_, _ = io.Copy(c, u)
				_ = c.Close()
			}(c)
		}
	}()
	return ln.Addr().String()
}

func TestGRPC_ATransparentRetryIsRecorded(t *testing.T) {
	var front string
	a := newGRPCAgent(t, func(string) string { return front })
	front = goawayFirst(t, a.addr)
	code, lines, raw := runGRPC(t, runConfig{target: a.url, binding: bindingGRPC})
	if code != 0 {
		t.Fatalf("exit %d: %s", code, raw)
	}
	l := lines[0]
	if l["grpc_attempts"] != float64(2) || l["grpc_transparent_attempts"] != float64(1) || l["grpc_status"] != float64(0) {
		t.Errorf("line = %s, want 2 attempts, 1 transparent, status 0", raw)
	}
	if calls := a.calls(); len(calls) != 1 {
		t.Errorf("the agent received %d calls, want 1: the first attempt never reached it", len(calls))
	}
}

func TestGRPCAuthority_DefaultOffAndRefusals(t *testing.T) {
	t.Setenv("TARGET_URL", "http://x")
	t.Setenv("LWI", "w")
	t.Setenv("CLIENT_BINDING", "grpc")
	t.Setenv("CLIENT_GRPC_AUTHORITY", "")
	if c, _, err := configFromEnv(); err != nil || c.grpcAuthority != "" || c.binding != bindingGRPC {
		t.Fatalf("off: %+v, %v", c, err)
	}
	t.Setenv("CLIENT_GRPC_AUTHORITY", "worker-grpc.lab.internal")
	if c, _, err := configFromEnv(); err != nil || c.grpcAuthority != "worker-grpc.lab.internal" {
		t.Fatalf("on: %q, %v", c.grpcAuthority, err)
	}
	for _, v := range []string{"Worker-grpc.lab.internal", "worker:8081", "http://worker", "10.0.0.1", "${CLIENT_GRPC_AUTHORITY}", "*.lab.internal"} {
		t.Setenv("CLIENT_GRPC_AUTHORITY", v)
		if _, _, err := configFromEnv(); err == nil || !strings.Contains(err.Error(), "CLIENT_GRPC_AUTHORITY") {
			t.Errorf("%q: err = %v", v, err)
		}
	}
	for _, b := range []string{"", "rest"} {
		t.Setenv("CLIENT_BINDING", b)
		t.Setenv("CLIENT_GRPC_AUTHORITY", "worker-grpc.lab.internal")
		if _, _, err := configFromEnv(); err == nil || !strings.Contains(err.Error(), "CLIENT_GRPC_AUTHORITY") {
			t.Errorf("binding %q with the authority set: err = %v", b, err)
		}
	}
}

func TestGRPCTarget(t *testing.T) {
	for in, want := range map[string]string{
		"http://agentgateway-ingress.agentgateway-ingress.svc.cluster.local": "agentgateway-ingress.agentgateway-ingress.svc.cluster.local:80",
		"http://127.0.0.1:9000":  "127.0.0.1:9000",
		"https://example.test":   "example.test:443",
		"not a url with no host": "",
	} {
		if got := grpcTarget(in); got != want {
			t.Errorf("grpcTarget(%q) = %q, want %q", in, got, want)
		}
	}
}

// Configured retries are off even when a service config asks for them: the
// dial options, given a default service config with a retry policy on
// UNAVAILABLE, make one attempt against a server that answers UNAVAILABLE.
func TestGRPC_ConfiguredRetriesAreOffEvenWhenAServiceConfigAsks(t *testing.T) {
	var calls int
	var mu sync.Mutex
	gs := grpc.NewServer(grpc.UnknownServiceHandler(func(any, grpc.ServerStream) error {
		mu.Lock()
		calls++
		mu.Unlock()
		return status.Error(codes.Unavailable, "try again")
	}))
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = gs.Serve(ln) }()
	t.Cleanup(gs.Stop)
	g := &grpcCall{workItem: "w"}
	opts := append(g.dialOptions(), grpc.WithDefaultServiceConfig(`{"methodConfig":[{"name":[{}],"retryPolicy":{
		"maxAttempts":4,"initialBackoff":"0.01s","maxBackoff":"0.01s","backoffMultiplier":1,"retryableStatusCodes":["UNAVAILABLE"]}}]}`))
	conn, err := grpc.NewClient(ln.Addr().String(), opts...)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close() }()
	err = conn.Invoke(context.Background(), "/x.Y/Z", &emptypb.Empty{}, &emptypb.Empty{})
	if status.Code(err) != codes.Unavailable {
		t.Fatalf("err = %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if f := g.facts(); calls != 1 || f.GRPCAttempts != 1 || f.GRPCTransparentAttempts != 0 {
		t.Errorf("server calls %d, attempts %d, transparent %d; want 1, 1, 0", calls, f.GRPCAttempts, f.GRPCTransparentAttempts)
	}
}
