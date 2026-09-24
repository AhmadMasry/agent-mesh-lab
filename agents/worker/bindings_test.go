package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2aclient"
	a2agrpc "github.com/a2aproject/a2a-go/v2/a2agrpc/v1"
	a2apb "github.com/a2aproject/a2a-go/v2/a2apb/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/structpb"
)

// Follow-on D-2: the worker serves JSON-RPC and REST on one port and gRPC on
// another, the card lists all three with JSON-RPC first, and the ingress
// ledger records a REST or gRPC arrival, with its operation read from the
// path, before the SDK sees it.

// servedAgent is port 8080's chain and port 8081's chain over one request
// handler and one ledger stream, as main assembles them.
type servedAgent struct {
	out      *syncBuffer
	http     *httptest.Server
	grpcAddr string
}

func serveAgent(t *testing.T, refuse string) *servedAgent {
	t.Helper()
	out := &syncBuffer{}
	lw := newLineWriter(out)
	handler := newRequestHandler(completingExecutor{}, lw, refuse)
	inj := newInjector()
	a := &servedAgent{out: out}
	// The card is built for the addresses the test servers draw.
	httpSrv := httptest.NewUnstartedServer(nil)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	a.grpcAddr = ln.Addr().String()
	card := buildCard("worker", "http://"+httpSrv.Listener.Addr().String(), a.grpcAddr)
	httpSrv.Config.Handler = newServerHandler("worker", newA2AMux(card, handler), lw, inj)
	httpSrv.Start()
	a.http = httpSrv
	gsrv := newGRPCServer(a.grpcAddr, newServerHandler("worker", newGRPCHandler(handler), lw, inj))
	go func() { _ = gsrv.Serve(ln) }()
	t.Cleanup(func() {
		httpSrv.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = gsrv.Shutdown(ctx)
	})
	return a
}

func (a *servedAgent) card(t *testing.T) *a2a.AgentCard {
	t.Helper()
	resp, err := http.Get(a.http.URL + "/.well-known/agent-card.json")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	var card a2a.AgentCard
	if err := json.NewDecoder(resp.Body).Decode(&card); err != nil {
		t.Fatal(err)
	}
	return &card
}

// lines returns every ledger line written so far but the card fetches
// ingress lines, decoded, with the ingress lines' raw text.
func (a *servedAgent) lines(t *testing.T) (ingress []ingressLine, raw []string, exec []executionLine) {
	t.Helper()
	for _, l := range rawLines(a.out.String()) {
		var probe struct {
			Ledger string `json:"ledger"`
		}
		_ = json.Unmarshal([]byte(l), &probe)
		switch probe.Ledger {
		case "ingress":
			var il ingressLine
			if err := json.Unmarshal([]byte(l), &il); err != nil {
				t.Fatal(err)
			}
			// The test's own card fetches are counted by the ledger as any
			// delivery is; they are left out here so indexes name requests.
			if il.Method == "GET /.well-known/agent-card.json" {
				continue
			}
			ingress = append(ingress, il)
			raw = append(raw, l)
		case "execution":
			var el executionLine
			_ = json.Unmarshal([]byte(l), &el)
			exec = append(exec, el)
		}
	}
	return ingress, raw, exec
}

// waitLines waits until the ledger holds n ingress lines.
func (a *servedAgent) waitLines(t *testing.T, n int) ([]ingressLine, []string, []executionLine) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		in, raw, ex := a.lines(t)
		if len(in) >= n || time.Now().After(deadline) {
			return in, raw, ex
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func messageWithWorkItem(lwi string) *a2a.Message {
	m := a2a.NewMessage(a2a.MessageRoleUser, a2a.NewTextPart("hello"))
	m.Metadata = map[string]any{"logical_work_item_id": lwi}
	return m
}

func postLines(lines []ingressLine) []ingressLine {
	var out []ingressLine
	for _, l := range lines {
		if !strings.HasPrefix(l.Method, "GET ") {
			out = append(out, l)
		}
	}
	return out
}

func TestCard_ListsTheThreeBindingsJSONRPCFirst(t *testing.T) {
	card := buildCard("worker", "http://worker.lab.svc.cluster.local:8080", "worker.lab.svc.cluster.local:8081")
	got := make([]string, 0, len(card.SupportedInterfaces))
	for _, i := range card.SupportedInterfaces {
		got = append(got, string(i.ProtocolBinding)+" "+i.URL+" "+string(i.ProtocolVersion))
	}
	want := []string{
		"JSONRPC http://worker.lab.svc.cluster.local:8080 1.0",
		"HTTP+JSON http://worker.lab.svc.cluster.local:8080 1.0",
		"GRPC worker.lab.svc.cluster.local:8081 1.0",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("interfaces:\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

// The invariant every existing row rests on: a client built from this card
// with a2a-go's DEFAULT factory (JSON-RPC and REST registered, no preference)
// still sends JSON-RPC. The control beside it shows the card's order is what
// decides: the same factory over the same interfaces with REST listed first
// sends REST.
func TestCard_DefaultClientStaysOnJSONRPC(t *testing.T) {
	a := serveAgent(t, "")
	card := a.card(t)
	client, err := a2aclient.NewFromCard(context.Background(), card)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.SendMessage(context.Background(), &a2a.SendMessageRequest{Message: messageWithWorkItem("lwi-default")}); err != nil {
		t.Fatal(err)
	}
	in, raw, _ := a.waitLines(t, 2)
	posts := postLines(in)
	if len(posts) != 2 || posts[0].Method != "SendMessage" || posts[0].Binding != "" || posts[0].ID == "" {
		t.Fatalf("default client's delivery = %+v, want one JSON-RPC SendMessage with an id and no binding", posts)
	}
	for _, l := range raw {
		if strings.Contains(l, `"binding"`) {
			t.Errorf("a JSON-RPC line carries a binding key: %s", l)
		}
	}

	// The control: REST first, same factory.
	b := serveAgent(t, "")
	reordered := b.card(t)
	reordered.SupportedInterfaces = []*a2a.AgentInterface{reordered.SupportedInterfaces[1], reordered.SupportedInterfaces[0], reordered.SupportedInterfaces[2]}
	client2, err := a2aclient.NewFromCard(context.Background(), reordered)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client2.SendMessage(context.Background(), &a2a.SendMessageRequest{Message: messageWithWorkItem("lwi-control")}); err != nil {
		t.Fatal(err)
	}
	in2, _, _ := b.waitLines(t, 2)
	if p := postLines(in2); len(p) != 2 || p[0].Binding != bindingREST {
		t.Errorf("control: with REST listed first the default client sent %+v, want REST", p)
	}
}

// A REST SendMessage and a REST SubscribeToTask: the arrival line names the
// binding and the operation from the path, the execution ledger counts the
// dispatch as it counts a JSON-RPC one, and the lines pair.
func TestREST_ArrivalsAreLedgeredBeforeDispatch(t *testing.T) {
	a := serveAgent(t, "")
	card := a.card(t)
	client, err := a2aclient.NewFromEndpoints(context.Background(), []*a2a.AgentInterface{card.SupportedInterfaces[1]},
		a2aclient.WithDefaultsDisabled(), a2aclient.WithRESTTransport(nil))
	if err != nil {
		t.Fatal(err)
	}
	msg := messageWithWorkItem("lwi-rest")
	res, err := client.SendMessage(context.Background(), &a2a.SendMessageRequest{Message: msg})
	if err != nil {
		t.Fatal(err)
	}
	task, ok := res.(*a2a.Task)
	if !ok || task.Status.State != a2a.TaskStateCompleted {
		t.Fatalf("result = %#v, want a completed task", res)
	}
	in, _, exec := a.waitLines(t, 2)
	if len(in) != 2 {
		t.Fatalf("ingress lines = %d, want 2", len(in))
	}
	arr, resp := in[0], in[1]
	if arr.Phase != "arrival" || arr.Binding != bindingREST || arr.Method != "SendMessage" || arr.MessageID != msg.ID ||
		arr.LogicalWorkItemID != "lwi-rest" || arr.LWISource != "" || arr.ID != "" {
		t.Errorf("arrival = %+v", arr)
	}
	if resp.Phase != "response" || resp.Binding != bindingREST || resp.Status == nil || *resp.Status != 200 || resp.GRPCStatus != nil {
		t.Errorf("response = %+v", resp)
	}
	var received, results int
	for _, e := range exec {
		if e.Event == "received" && e.Method == "SendMessage" && e.MessageID == msg.ID {
			received++
		}
		if e.Event == "result" && e.Method == "SendMessage" {
			results++
		}
	}
	if received != 1 || results != 1 {
		t.Errorf("execution ledger: received %d, result %d, want 1 and 1", received, results)
	}

	// SubscribeToTask on a task that does not exist, by POST and by GET, with
	// the work item in the header as the load client sends it.
	for _, method := range []string{http.MethodPost, http.MethodGet} {
		before, _, _ := a.lines(t)
		req, _ := http.NewRequest(method, a.http.URL+"/tasks/no-such-task:subscribe", nil)
		req.Header.Set("X-Logical-Work-Item-Id", "lwi-rest-sub")
		req.Header.Set("A2A-Version", "1.0")
		r, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.Copy(io.Discard, r.Body)
		_ = r.Body.Close()
		after, _, _ := a.waitLines(t, len(before)+2)
		got := after[len(before)]
		if got.Binding != bindingREST || got.Method != "SubscribeToTask" || got.TaskID != "no-such-task" ||
			got.LogicalWorkItemID != "lwi-rest-sub" || got.LWISource != "header" || got.A2AVersion != "1.0" {
			t.Errorf("%s subscribe arrival = %+v", method, got)
		}
	}
}

func grpcClient(t *testing.T, addr string) a2apb.A2AServiceClient {
	t.Helper()
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithDisableRetry())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return a2apb.NewA2AServiceClient(conn)
}

// A gRPC SendMessage and a gRPC SubscribeToTask, through the SDK's own gRPC
// client and a raw stub: the arrival line names the binding and the operation
// from the :path, reads the identity out of the protobuf, and the response
// line carries the gRPC status the server sent.
func TestGRPC_ArrivalsAreLedgeredBeforeDispatch(t *testing.T) {
	a := serveAgent(t, "")
	card := a.card(t)
	client, err := a2aclient.NewFromEndpoints(context.Background(), []*a2a.AgentInterface{card.SupportedInterfaces[2]},
		a2aclient.WithDefaultsDisabled(), a2agrpc.WithGRPCTransport(grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithDisableRetry()))
	if err != nil {
		t.Fatal(err)
	}
	msg := messageWithWorkItem("lwi-grpc")
	res, err := client.SendMessage(context.Background(), &a2a.SendMessageRequest{Message: msg})
	if err != nil {
		t.Fatal(err)
	}
	if task, ok := res.(*a2a.Task); !ok || task.Status.State != a2a.TaskStateCompleted {
		t.Fatalf("result = %#v, want a completed task", res)
	}
	in, _, exec := a.waitLines(t, 2)
	if len(in) != 2 {
		t.Fatalf("ingress lines = %d, want 2: %+v", len(in), in)
	}
	arr, resp := in[0], in[1]
	if arr.Binding != bindingGRPC || arr.Method != "SendMessage" || arr.MessageID != msg.ID ||
		arr.LogicalWorkItemID != "lwi-grpc" || arr.LWISource != "" || arr.ID != "" ||
		!strings.HasPrefix(arr.ContentType, "application/grpc") || arr.BodyLen == 0 {
		t.Errorf("arrival = %+v", arr)
	}
	if resp.Status == nil || *resp.Status != 200 || resp.GRPCStatus == nil || *resp.GRPCStatus != int(codes.OK) || resp.StreamEnd != "" {
		t.Errorf("response = %+v, want 200, grpc_status 0, no stream_end", resp)
	}
	var received int
	for _, e := range exec {
		if e.Event == "received" && e.Method == "SendMessage" && e.MessageID == msg.ID {
			received++
		}
	}
	if received != 1 {
		t.Errorf("execution received lines = %d, want 1", received)
	}

	// SubscribeToTask for a task that does not exist, the work item in the
	// metadata as the load client sends it.
	stub := grpcClient(t, a.grpcAddr)
	ctx := metadata.AppendToOutgoingContext(context.Background(), "x-logical-work-item-id", "lwi-grpc-sub", "a2a-version", "1.0")
	stream, err := stub.SubscribeToTask(ctx, &a2apb.SubscribeToTaskRequest{Id: "no-such-task"})
	if err != nil {
		t.Fatal(err)
	}
	_, err = stream.Recv()
	if status.Code(err) != codes.NotFound {
		t.Errorf("subscribe error = %v, want NotFound", err)
	}
	in, _, _ = a.waitLines(t, 4)
	if len(in) != 4 {
		t.Fatalf("ingress lines = %d, want 4", len(in))
	}
	sub, subResp := in[2], in[3]
	if sub.Binding != bindingGRPC || sub.Method != "SubscribeToTask" || sub.TaskID != "no-such-task" ||
		sub.LogicalWorkItemID != "lwi-grpc-sub" || sub.LWISource != "header" || sub.A2AVersion != "1.0" {
		t.Errorf("subscribe arrival = %+v", sub)
	}
	if subResp.GRPCStatus == nil || *subResp.GRPCStatus != int(codes.NotFound) || subResp.StreamEnd == "" || subResp.TSEnd == "" {
		t.Errorf("subscribe response = %+v, want grpc_status 5 and a stream end", subResp)
	}
}

// The body a gRPC SendMessage arrives with is read for its identity even from
// a stub the SDK did not write: the metadata Struct carries the work item.
func TestGRPC_ArrivalReadsTheWorkItemFromTheMessageMetadata(t *testing.T) {
	a := serveAgent(t, "")
	stub := grpcClient(t, a.grpcAddr)
	md, _ := structpb.NewStruct(map[string]any{"logical_work_item_id": "lwi-stub"})
	_, err := stub.SendMessage(context.Background(), &a2apb.SendMessageRequest{Message: &a2apb.Message{
		MessageId: "m-stub", Role: a2apb.Role_ROLE_USER, Metadata: md,
		Parts: []*a2apb.Part{{Content: &a2apb.Part_Text{Text: "hello"}}}}})
	if err != nil {
		t.Fatal(err)
	}
	in, _, _ := a.waitLines(t, 2)
	if len(in) < 1 || in[0].MessageID != "m-stub" || in[0].LogicalWorkItemID != "lwi-stub" || in[0].Method != "SendMessage" {
		t.Errorf("arrival = %+v", in)
	}
}

// REFUSE_OPERATION sits under all three bindings: the refused operation is
// refused on REST and on gRPC as on JSON-RPC, after its arrival was counted,
// and the operation not named is served.
func TestRefuse_HoldsOnRESTAndGRPC(t *testing.T) {
	a := serveAgent(t, "SendMessage")
	card := a.card(t)
	rest, err := a2aclient.NewFromEndpoints(context.Background(), []*a2a.AgentInterface{card.SupportedInterfaces[1]},
		a2aclient.WithDefaultsDisabled(), a2aclient.WithRESTTransport(nil))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := rest.SendMessage(context.Background(), &a2a.SendMessageRequest{Message: messageWithWorkItem("lwi-r1")}); err == nil {
		t.Errorf("REST SendMessage was served with REFUSE_OPERATION=SendMessage")
	}
	stub := grpcClient(t, a.grpcAddr)
	_, err = stub.SendMessage(context.Background(), &a2apb.SendMessageRequest{Message: &a2apb.Message{
		MessageId: "m-r2", Role: a2apb.Role_ROLE_USER, Parts: []*a2apb.Part{{Content: &a2apb.Part_Text{Text: "x"}}}}})
	if status.Code(err) != codes.FailedPrecondition {
		t.Errorf("gRPC SendMessage error = %v, want FailedPrecondition (UnsupportedOperationError, spec §5.4)", err)
	}
	in, _, exec := a.waitLines(t, 4)
	var arrivals int
	for _, l := range in {
		if l.Phase == "arrival" && l.Method == "SendMessage" {
			arrivals++
		}
	}
	if arrivals != 2 {
		t.Errorf("SendMessage arrivals = %d, want 2 (one per binding)", arrivals)
	}
	for _, e := range exec {
		if e.Event == "execute" {
			t.Errorf("an execute line with the operation refused: %+v", e)
		}
	}
}
