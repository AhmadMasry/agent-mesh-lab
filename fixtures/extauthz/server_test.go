package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) lines(t *testing.T) []map[string]any {
	t.Helper()
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(b.buf.String()), "\n") {
		if l == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("ledger line is not JSON: %q", l)
		}
		out = append(out, m)
	}
	return out
}

// failingWriter fails every write and counts the calls.
type failingWriter struct {
	mu    sync.Mutex
	calls int
}

func (f *failingWriter) Write([]byte) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	return 0, errors.New("stdout closed")
}

func check(req *authv3.AttributeContext_HttpRequest) *authv3.CheckRequest {
	return &authv3.CheckRequest{Attributes: &authv3.AttributeContext{
		Source:  &authv3.AttributeContext_Peer{Principal: "spiffe://cluster.local/ns/agentgateway-ingress/sa/agentgateway-ingress"},
		Request: &authv3.AttributeContext_Request{Http: req},
	}}
}

func TestCheck_AllowIsOKAndDenyIs403WithTheReason(t *testing.T) {
	out := &lockedBuffer{}
	s := newServer(out, undecidableDeny)
	resp, err := s.Check(context.Background(), check(jsonrpcReq(sendBody)))
	if err != nil || resp.GetStatus().GetCode() != int32(codes.OK) || resp.GetDeniedResponse() != nil {
		t.Fatalf("send: %v %v", resp, err)
	}
	resp, err = s.Check(context.Background(), check(jsonrpcReq(subscribeBody)))
	if err != nil {
		t.Fatal(err)
	}
	if resp.GetStatus().GetCode() != int32(codes.PermissionDenied) {
		t.Errorf("subscribe status %v; want PERMISSION_DENIED", resp.GetStatus())
	}
	dr := resp.GetDeniedResponse()
	if dr == nil || dr.GetStatus().GetCode() != typev3.StatusCode_Forbidden || !strings.Contains(dr.GetBody(), "SubscribeToTask") {
		t.Errorf("denied response %v; want 403 naming the operation", dr)
	}
}

func TestCheck_OneLedgerLinePerCheckWithEveryField(t *testing.T) {
	out := &lockedBuffer{}
	s := newServer(out, undecidableDeny)
	r := jsonrpcReq(subscribeBody)
	r.Headers["x-logical-work-item-id"] = "lwi-2"
	if _, err := s.Check(context.Background(), check(r)); err != nil {
		t.Fatal(err)
	}
	lines := out.lines(t)
	if len(lines) != 1 {
		t.Fatalf("%d lines; want 1", len(lines))
	}
	l := lines[0]
	want := map[string]any{
		"ledger": "extauthz", "logical_work_item_id": "lwi-2", "messageId": "", "taskId": "t-9", "jsonrpc_id": "7",
		"request_id": "00-trace-span-01", "http_method": "POST", "path": "/", "host": "worker.lab.internal",
		"binding": "jsonrpc", "operation": "SubscribeToTask", "decided_by": "body.method",
		"body_len": float64(len(subscribeBody)), "size": float64(len(subscribeBody)), "partial": false,
		"source_principal":    "spiffe://cluster.local/ns/agentgateway-ingress/sa/agentgateway-ingress",
		"undecidable_setting": "deny", "decision": "deny", "reason": "operation:SubscribeToTask",
	}
	for k, v := range want {
		if l[k] != v {
			t.Errorf("%s = %#v; want %#v", k, l[k], v)
		}
	}
	names, _ := l["header_names"].([]any)
	var got []string
	for _, n := range names {
		got = append(got, n.(string))
	}
	wantNames := []string{":authority", ":method", ":path", ":scheme", "a2a-version", "content-type", "x-logical-work-item-id"}
	if !sort.StringsAreSorted(got) || strings.Join(got, ",") != strings.Join(wantNames, ",") {
		t.Errorf("header_names %v; want %v, sorted", got, wantNames)
	}
	if _, err := time.Parse(time.RFC3339Nano, l["ts"].(string)); err != nil {
		t.Errorf("ts %v: %v", l["ts"], err)
	}
	if _, ok := l["body"]; ok {
		t.Error("the ledger must not carry the body itself")
	}
}

// The ledger line is written before the answer: when the line cannot be written
// the check is answered with an error, never with an allow, and the write is
// tried once (no retry).
func TestCheck_NoLineNoAnswer(t *testing.T) {
	for _, body := range []string{sendBody, subscribeBody} {
		w := &failingWriter{}
		s := newServer(w, undecidableAllow)
		resp, err := s.Check(context.Background(), check(jsonrpcReq(body)))
		if status.Code(err) != codes.Internal || resp != nil {
			t.Errorf("resp %v err %v; want nil and INTERNAL", resp, err)
		}
		if w.calls != 1 {
			t.Errorf("%d write attempts; want exactly 1", w.calls)
		}
	}
}

func TestCheck_MissingAttributesIsUndecidable(t *testing.T) {
	out := &lockedBuffer{}
	s := newServer(out, undecidableDeny)
	resp, err := s.Check(context.Background(), &authv3.CheckRequest{})
	if err != nil || resp.GetStatus().GetCode() != int32(codes.PermissionDenied) {
		t.Fatalf("resp %v err %v", resp, err)
	}
	if l := out.lines(t); len(l) != 1 || l[0]["reason"] != "undecidable:no-http-attributes" {
		t.Errorf("lines %v", l)
	}
}

// Over a real gRPC connection, as the proxy calls it.
func TestCheck_OverGRPC(t *testing.T) {
	out := &lockedBuffer{}
	gs := newGRPCServer(newServer(out, undecidableDeny))
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = gs.Serve(ln) }()
	t.Cleanup(gs.Stop)
	conn, err := grpc.NewClient(ln.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close() }()
	c := authv3.NewAuthorizationClient(conn)
	// A body the size C-8's pads left after the proxy's limit: 2,097,152 bytes.
	big := `{"jsonrpc":"2.0","id":1,"method":"SubscribeToTask","params":{"id":"t","tenant":"` + strings.Repeat("a", 2097152) + `"}}`
	r := jsonrpcReq(big[:2097152])
	r.Size = -1
	resp, err := c.Check(context.Background(), check(r))
	if err != nil || resp.GetStatus().GetCode() != int32(codes.PermissionDenied) {
		t.Fatalf("resp %v err %v", resp, err)
	}
	l := out.lines(t)
	if len(l) != 1 || l[0]["body_len"] != float64(2097152) || l[0]["partial"] != true || l[0]["reason"] != "undecidable:partial-body" {
		t.Errorf("line %v", l)
	}
}
