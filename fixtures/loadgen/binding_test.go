package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"

	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
)

// Follow-on D-2: CLIENT_BINDING, off meaning JSON-RPC. The invariant every
// existing row rests on is tested first: a receiver's card that lists REST and
// gRPC beside JSON-RPC -- in the worst order, REST first -- moves nothing the
// load client sends or records with the setting off.

// bindingServer serves a card listing three interfaces, REST first, and answers
// a JSON-RPC POST at "/" and a REST POST at /message:send or
// /tasks/{id}:subscribe. Every request is recorded.
type bindingServer struct {
	*httptest.Server
	mu       sync.Mutex
	requests []string // "METHOD path content-type"
	bodies   []string
}

func newBindingServer(t *testing.T) *bindingServer {
	t.Helper()
	s := &bindingServer{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		s.mu.Lock()
		s.requests = append(s.requests, r.Method+" "+r.URL.Path+" "+r.Header.Get("Accept"))
		s.bodies = append(s.bodies, string(raw))
		s.mu.Unlock()
		task := `{"id":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}`
		switch {
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "agent-card.json"):
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(&a2a.AgentCard{
				Name: "three-bindings", Description: "d", Version: "0.0.1",
				Capabilities: a2a.AgentCapabilities{Streaming: true},
				SupportedInterfaces: []*a2a.AgentInterface{
					{URL: s.URL + "/rest-base", ProtocolBinding: a2a.TransportProtocolHTTPJSON, ProtocolVersion: a2a.Version},
					{URL: "grpc-target.invalid:8081", ProtocolBinding: a2a.TransportProtocolGRPC, ProtocolVersion: a2a.Version},
					{URL: s.URL + "/jsonrpc-base", ProtocolBinding: a2a.TransportProtocolJSONRPC, ProtocolVersion: a2a.Version},
				},
			})
		case r.Method == http.MethodPost && r.URL.Path == "/jsonrpc-base":
			var req struct {
				ID json.RawMessage `json:"id"`
			}
			_ = json.Unmarshal(raw, &req)
			if strings.Contains(r.Header.Get("Accept"), "text/event-stream") {
				w.Header().Set("Content-Type", "text/event-stream")
				_, _ = fmt.Fprintf(w, "data: {\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":{\"task\":%s}}\n\n", req.ID, task)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = fmt.Fprintf(w, `{"jsonrpc":"2.0","id":%s,"result":{"task":%s}}`, req.ID, task)
		case r.Method == http.MethodPost && r.URL.Path == "/rest-base/message:send":
			w.Header().Set("Content-Type", "application/json")
			_, _ = fmt.Fprintf(w, `{"task":%s}`, task)
		case r.Method == http.MethodPost && (r.URL.Path == "/rest-base/message:stream" || strings.HasPrefix(r.URL.Path, "/rest-base/tasks/")):
			w.Header().Set("Content-Type", "text/event-stream")
			_, _ = fmt.Fprintf(w, "data: {\"task\":%s}\n\n", task)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func (s *bindingServer) seen() ([]string, []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.requests...), append([]string(nil), s.bodies...)
}

func runSendBinding(t *testing.T, target string, b bindingMode) (int, []map[string]any, []string) {
	t.Helper()
	var out bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	hc := instrument(httpclient.New(10*time.Second), "lwi-binding")
	code := send(ctx, hc, sendConfig{target: target, workItem: "lwi-binding", text: "hello", binding: b}, &out)
	var lines []map[string]any
	var raw []string
	for _, l := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		if l == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatalf("client line is not JSON: %v: %s", err, l)
		}
		lines = append(lines, m)
		raw = append(raw, l)
	}
	return code, lines, raw
}

func TestBinding_DefaultOff(t *testing.T) {
	t.Setenv("CLIENT_BINDING", "")
	b, err := bindingFromEnv()
	if err != nil || b != bindingJSONRPC {
		t.Fatalf("bindingFromEnv() = %q, %v, want JSON-RPC and no error", b, err)
	}
	t.Setenv("TARGET_URL", "http://x")
	t.Setenv("LWI", "w")
	c, _, err := configFromEnv()
	if err != nil || c.binding != bindingJSONRPC {
		t.Fatalf("configFromEnv binding = %q, %v", c.binding, err)
	}
}

func TestBinding_OnlyTheNamedValuesAreRead(t *testing.T) {
	t.Setenv("TARGET_URL", "http://x")
	t.Setenv("LWI", "w")
	t.Setenv("CLIENT_BINDING", "rest")
	if c, _, err := configFromEnv(); err != nil || c.binding != bindingREST {
		t.Errorf("rest: %q, %v", c.binding, err)
	}
	t.Setenv("CLIENT_BINDING", "grpc")
	if c, _, err := configFromEnv(); err != nil || c.binding != bindingGRPC {
		t.Errorf("grpc: %q, %v", c.binding, err)
	}
	for _, v := range []string{"REST", "Rest", " rest", "GRPC", "gRPC", "grpc ", "jsonrpc", "JSONRPC", "HTTP+JSON", "http", "h2c", "off", "${CLIENT_BINDING}"} {
		t.Setenv("CLIENT_BINDING", v)
		if _, _, err := configFromEnv(); err == nil || !strings.Contains(err.Error(), "CLIENT_BINDING") {
			t.Errorf("CLIENT_BINDING=%q: err = %v, want a refusal naming the setting", v, err)
		}
	}
}

// The invariant: off, a card listing REST first and gRPC second still gets
// ONE JSON-RPC POST, to the JSON-RPC interface's URL, and the line and the span
// name that URL, with no binding key on the line.
func TestBinding_OffAThreeBindingCardStillSendsJSONRPC(t *testing.T) {
	sr := spanRecorder(t)
	s := newBindingServer(t)
	code, lines, raw := runSendBinding(t, s.URL, bindingJSONRPC)
	if code != 0 {
		t.Fatalf("exit %d, lines %v", code, raw)
	}
	reqs, bodies := s.seen()
	if len(reqs) != 2 || !strings.HasPrefix(reqs[1], "POST /jsonrpc-base ") || !strings.Contains(bodies[1], `"jsonrpc":"2.0"`) ||
		!strings.Contains(bodies[1], `"method":"SendMessage"`) {
		t.Fatalf("requests = %v, want the card GET and one JSON-RPC SendMessage POST", reqs)
	}
	if got := lines[0]["dialled_url"]; got != s.URL+"/jsonrpc-base" {
		t.Errorf("dialled_url = %v, want the JSON-RPC interface's URL", got)
	}
	if _, ok := lines[0]["binding"]; ok {
		t.Errorf("the line carries a binding key with the setting off: %s", raw[0])
	}
	wantHost, wantPort := hostPort(t, s.URL)
	if host, port := invokeAgentAddress(t, sr); host != wantHost || port != wantPort {
		t.Errorf("invoke_agent span says %s:%d, want %s:%d", host, port, wantHost, wantPort)
	}
}

// The same in stream mode: one JSON-RPC POST asking for an event stream.
func TestBinding_OffAThreeBindingCardStillStreamsJSONRPC(t *testing.T) {
	s := newBindingServer(t)
	var out bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	code := runMode(ctx, streamClientForTest(), runConfig{target: s.URL, workItem: "lwi-b", text: "hello",
		mode: modeConfig{mode: modeStream}}, &out)
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out.String())
	}
	reqs, bodies := s.seen()
	if len(reqs) != 2 || !strings.HasPrefix(reqs[1], "POST /jsonrpc-base text/event-stream") ||
		!strings.Contains(bodies[1], `"method":"SendStreamingMessage"`) {
		t.Fatalf("requests = %v", reqs)
	}
	if strings.Contains(out.String(), `"binding"`) {
		t.Errorf("a line carries a binding key with the setting off: %s", out.String())
	}
}

// On: the one request goes to the REST interface's path, and the line says so.
func TestBinding_RESTSendsOnePOSTToMessageSend(t *testing.T) {
	s := newBindingServer(t)
	code, lines, raw := runSendBinding(t, s.URL, bindingREST)
	if code != 0 {
		t.Fatalf("exit %d, lines %v", code, raw)
	}
	reqs, bodies := s.seen()
	if len(reqs) != 2 || !strings.HasPrefix(reqs[1], "POST /rest-base/message:send ") || strings.Contains(bodies[1], "jsonrpc") ||
		!strings.Contains(bodies[1], `"messageId"`) {
		t.Fatalf("requests = %v, bodies %v", reqs, bodies)
	}
	if lines[0]["binding"] != "rest" || lines[0]["dialled_url"] != s.URL+"/rest-base" || lines[0]["state"] != "TASK_STATE_COMPLETED" {
		t.Errorf("line = %s", raw[0])
	}
}

func TestBinding_RESTSubscribePostsToTheTasksPath(t *testing.T) {
	s := newBindingServer(t)
	var out bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	code := runMode(ctx, streamClientForTest(), runConfig{target: s.URL, workItem: "lwi-b", text: "hello",
		mode: modeConfig{mode: modeSubscribe, taskID: "task-9"}, binding: bindingREST}, &out)
	if code != 0 {
		t.Fatalf("exit %d: %s", code, out.String())
	}
	reqs, bodies := s.seen()
	if len(reqs) != 2 || reqs[1] != "POST /rest-base/tasks/task-9:subscribe text/event-stream" || bodies[1] != "" {
		t.Fatalf("requests = %v, bodies = %q", reqs, bodies)
	}
	if !strings.Contains(out.String(), `"binding":"rest"`) || !strings.Contains(out.String(), `"posts":1`) {
		t.Errorf("end line = %s", out.String())
	}
}

// For a card with one interface -- every card before D-2 -- the reading is the
// one it always was, and for several interfaces of the binding it is left to
// the SDK, as it was.
func TestAgentFromCard_OneInterfacePerBindingKeepsTheJSONRPCURL(t *testing.T) {
	one := &a2a.AgentCard{SupportedInterfaces: []*a2a.AgentInterface{{URL: "http://a", ProtocolBinding: a2a.TransportProtocolJSONRPC}}}
	if got := agentFromCard(one, a2a.TransportProtocolJSONRPC).URL; got != "http://a" {
		t.Errorf("one interface: %q", got)
	}
	two := &a2a.AgentCard{SupportedInterfaces: []*a2a.AgentInterface{
		{URL: "http://a", ProtocolBinding: a2a.TransportProtocolJSONRPC},
		{URL: "http://b", ProtocolBinding: a2a.TransportProtocolJSONRPC}}}
	if got := agentFromCard(two, a2a.TransportProtocolJSONRPC).URL; got != "" {
		t.Errorf("two JSON-RPC interfaces: %q, want empty", got)
	}
	if got := agentFromCard(one, a2a.TransportProtocolHTTPJSON).URL; got != "" {
		t.Errorf("no REST interface: %q, want empty", got)
	}
}

// What a JSON-RPC client line reads once the receiver's card lists three
// bindings, against the line for the one-interface card every row before D-2
// was sent from, the same server and URL: byte for byte the same but for the
// two keys that record the card's interfaces themselves (advertised_urls and
// card_protocol_versions, three entries where there was one) and the two
// stamps every line differs in (ts, messageId). dialled_url and the span's
// server.address and server.port are the same.
func TestBinding_OffTheJSONRPCLineDiffersOnlyInTheCardsOwnKeys(t *testing.T) {
	s := newBindingServer(t)
	one := newRecordingServer(t, http.StatusOK, func() *a2a.AgentCard {
		return &a2a.AgentCard{Name: "three-bindings", Description: "d", Version: "0.0.1",
			Capabilities: a2a.AgentCapabilities{Streaming: true},
			SupportedInterfaces: []*a2a.AgentInterface{{URL: s.URL + "/jsonrpc-base", ProtocolBinding: a2a.TransportProtocolJSONRPC,
				ProtocolVersion: a2a.Version}}}
	})
	sr := spanRecorder(t)
	_, _, rawOne := runSendBinding(t, one.URL, bindingJSONRPC)
	hostOne, portOne := invokeAgentAddress(t, sr)
	sr2 := spanRecorder(t)
	_, _, rawThree := runSendBinding(t, s.URL, bindingJSONRPC)
	hostThree, portThree := invokeAgentAddress(t, sr2)
	if hostOne != hostThree || portOne != portThree {
		t.Errorf("span address %s:%d with one interface, %s:%d with three", hostOne, portOne, hostThree, portThree)
	}
	var a, b map[string]json.RawMessage
	_ = json.Unmarshal([]byte(rawOne[0]), &a)
	_ = json.Unmarshal([]byte(rawThree[0]), &b)
	if n := strings.Count(keyOrder(t, rawOne[0]), ","); n+1 != 12 {
		t.Fatalf("key reading found %d keys in %s", n+1, rawOne[0])
	}
	if keyOrder(t, rawOne[0]) != keyOrder(t, rawThree[0]) {
		t.Errorf("key order differs:\n%s\n%s", rawOne[0], rawThree[0])
	}
	differ := map[string]bool{}
	for k := range a {
		if string(a[k]) != string(b[k]) {
			differ[k] = true
		}
	}
	want := map[string]bool{"ts": true, "messageId": true, "advertised_urls": true, "card_protocol_versions": true}
	if len(differ) != len(want) {
		t.Errorf("keys that differ = %v, want exactly %v\n%s\n%s", differ, want, rawOne[0], rawThree[0])
	}
	for k := range differ {
		if !want[k] {
			t.Errorf("key %s differs: %s vs %s", k, a[k], b[k])
		}
	}
	if string(a["dialled_url"]) != string(b["dialled_url"]) {
		t.Errorf("dialled_url differs")
	}
}

func keyOrder(t *testing.T, line string) string {
	t.Helper()
	dec := json.NewDecoder(strings.NewReader(line))
	var keys []string
	depth := 0
	for {
		tok, err := dec.Token()
		if err != nil {
			break
		}
		switch v := tok.(type) {
		case json.Delim:
			if v == '{' || v == '[' {
				depth++
			} else {
				depth--
			}
		case string:
			if depth == 1 {
				keys = append(keys, v)
				var skip json.RawMessage
				if err := dec.Decode(&skip); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	return strings.Join(keys, ",")
}
