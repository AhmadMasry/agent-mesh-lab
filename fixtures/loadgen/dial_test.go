package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	otelapi "go.opentelemetry.io/otel"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
)

// CLIENT_DIAL=target is the one knob that changes WHERE this client sends. It
// exists for the A.3 rows that address the Python receiver's Service: that
// receiver's card advertises the agentgateway ingress, so a client that does what
// an A2A client does resolves the card at the Service and then POSTs to the
// ingress. These tests stand two servers up for that: `target`, which serves the
// card, and `advertised`, the other address the card names. Each records every
// request it receives, so where the GET and the POST landed is counted, not
// inferred.

type seen struct {
	method  string
	path    string
	version string // the A2A-Version header, as it arrived
}

type recordingServer struct {
	*httptest.Server
	mu       sync.Mutex
	requests []seen
}

func (s *recordingServer) count(method string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, r := range s.requests {
		if r.method == method {
			n++
		}
	}
	return n
}

func (s *recordingServer) posts() []seen {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []seen
	for _, r := range s.requests {
		if r.method == http.MethodPost {
			out = append(out, r)
		}
	}
	return out
}

// newRecordingServer answers a POST with postStatus; on 200 the body is a
// completed Task in the JSON-RPC shape a2a-go v2 reads. card is called on a GET of
// the well-known path and may be nil for a server that serves no card.
func newRecordingServer(t *testing.T, postStatus int, card func() *a2a.AgentCard) *recordingServer {
	t.Helper()
	s := &recordingServer{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		s.requests = append(s.requests, seen{method: r.Method, path: r.URL.Path, version: r.Header.Get("A2A-Version")})
		s.mu.Unlock()
		switch {
		case r.Method == http.MethodGet && card != nil && strings.HasSuffix(r.URL.Path, "agent-card.json"):
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(card())
		case r.Method == http.MethodPost:
			raw, _ := io.ReadAll(r.Body)
			var req struct {
				ID json.RawMessage `json:"id"`
			}
			_ = json.Unmarshal(raw, &req)
			if postStatus != http.StatusOK {
				w.WriteHeader(postStatus)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":` + string(req.ID) +
				`,"result":{"task":{"id":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

// twoServers is the lab's shape in miniature: the card is served at `target` and
// advertises `advertised`, with the protocol version and tenant given.
func twoServers(t *testing.T, postStatus int, version a2a.ProtocolVersion) (target, advertised *recordingServer) {
	t.Helper()
	advertised = newRecordingServer(t, postStatus, nil)
	target = newRecordingServer(t, postStatus, func() *a2a.AgentCard {
		return &a2a.AgentCard{
			Name:        "receiver-under-test",
			Description: "a card that advertises another server",
			Version:     "0.0.1",
			SupportedInterfaces: []*a2a.AgentInterface{{
				URL:             advertised.URL,
				ProtocolBinding: a2a.TransportProtocolJSONRPC,
				ProtocolVersion: version,
			}},
		}
	})
	return target, advertised
}

func spanRecorder(t *testing.T) *tracetest.SpanRecorder {
	t.Helper()
	previous := otelapi.GetTracerProvider()
	sr := tracetest.NewSpanRecorder()
	otelapi.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr)))
	t.Cleanup(func() { otelapi.SetTracerProvider(previous) })
	return sr
}

// invokeAgentAddress reads server.address and server.port off the one
// invoke_agent span the send opened.
func invokeAgentAddress(t *testing.T, sr *tracetest.SpanRecorder) (address string, port int64) {
	t.Helper()
	found := 0
	for _, s := range sr.Ended() {
		if !strings.HasPrefix(s.Name(), "invoke_agent") {
			continue
		}
		found++
		for _, kv := range s.Attributes() {
			switch string(kv.Key) {
			case "server.address":
				address = kv.Value.AsString()
			case "server.port":
				port = kv.Value.AsInt64()
			}
		}
	}
	if found != 1 {
		t.Fatalf("invoke_agent spans: got %d, want 1", found)
	}
	return address, port
}

func hostPort(t *testing.T, raw string) (string, int64) {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parsing %q: %v", raw, err)
	}
	host, p, err := net.SplitHostPort(u.Host)
	if err != nil {
		t.Fatalf("splitting %q: %v", u.Host, err)
	}
	n, err := strconv.ParseInt(p, 10, 64)
	if err != nil {
		t.Fatalf("port %q: %v", p, err)
	}
	return host, n
}

// runSend is the send main() makes, with the lab's no-retry client, and returns
// the exit status and the client ledger lines it printed.
func runSend(t *testing.T, target string, dial dialMode) (int, []map[string]any, []string) {
	t.Helper()
	var out bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	hc := instrument(httpclient.New(10*time.Second), "lwi-dial")
	code := send(ctx, hc, sendConfig{target: target, workItem: "lwi-dial", text: "hello", dial: dial}, &out)
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

func stringsOf(t *testing.T, v any) []string {
	t.Helper()
	list, ok := v.([]any)
	if !ok {
		t.Fatalf("got %T (%v), want a JSON array", v, v)
	}
	out := make([]string, 0, len(list))
	for _, x := range list {
		out = append(out, x.(string))
	}
	return out
}

// Unset, the client does what it did on every run before the knob existed: the
// card GET goes to the target and the POST to the server the card advertises.
func TestDial_UnsetPostsToTheAdvertisedServer(t *testing.T) {
	sr := spanRecorder(t)
	target, advertised := twoServers(t, http.StatusOK, a2a.Version)

	code, lines, _ := runSend(t, target.URL, dialAdvertised)
	if code != 0 {
		t.Fatalf("exit status %d, want 0; lines: %v", code, lines)
	}
	if g, p := target.count(http.MethodGet), target.count(http.MethodPost); g != 1 || p != 0 {
		t.Errorf("target: %d GET and %d POST, want 1 and 0", g, p)
	}
	if g, p := advertised.count(http.MethodGet), advertised.count(http.MethodPost); g != 0 || p != 1 {
		t.Errorf("advertised: %d GET and %d POST, want 0 and 1", g, p)
	}
	if len(lines) != 1 {
		t.Fatalf("client lines: got %d, want 1", len(lines))
	}
	if got := stringsOf(t, lines[0]["advertised_urls"]); len(got) != 1 || got[0] != advertised.URL {
		t.Errorf("advertised_urls = %v, want [%s]", got, advertised.URL)
	}
	if got := lines[0]["dialled_url"]; got != advertised.URL {
		t.Errorf("dialled_url = %v, want the advertised %s", got, advertised.URL)
	}
	wantHost, wantPort := hostPort(t, advertised.URL)
	if host, port := invokeAgentAddress(t, sr); host != wantHost || port != wantPort {
		t.Errorf("invoke_agent span says %s:%d, want the advertised %s:%d", host, port, wantHost, wantPort)
	}
}

// Set, the card is still resolved at the target -- the GET stays, and so does
// what the line records about the card -- and the POST goes to the target. The
// advertised server receives nothing. The span and the ledger line say what the
// wire did, not what the card said.
func TestDial_TargetPostsToTheTargetAndStillResolvesTheCard(t *testing.T) {
	sr := spanRecorder(t)
	target, advertised := twoServers(t, http.StatusOK, a2a.Version)

	code, lines, _ := runSend(t, target.URL, dialTarget)
	if code != 0 {
		t.Fatalf("exit status %d, want 0; lines: %v", code, lines)
	}
	if g, p := target.count(http.MethodGet), target.count(http.MethodPost); g != 1 || p != 1 {
		t.Errorf("target: %d GET and %d POST, want 1 and 1", g, p)
	}
	if g, p := advertised.count(http.MethodGet), advertised.count(http.MethodPost); g != 0 || p != 0 {
		t.Errorf("advertised: %d GET and %d POST, want 0 and 0", g, p)
	}
	for _, p := range target.posts() {
		if p.version != string(a2a.Version) {
			t.Errorf("A2A-Version on the POST = %q, want the card's %q", p.version, a2a.Version)
		}
	}
	if len(lines) != 1 {
		t.Fatalf("client lines: got %d, want 1", len(lines))
	}
	line := lines[0]
	if got := stringsOf(t, line["card_protocol_versions"]); len(got) != 1 || got[0] != string(a2a.Version) {
		t.Errorf("card_protocol_versions = %v, want [%s]: the card is still resolved and recorded", got, a2a.Version)
	}
	if got := stringsOf(t, line["advertised_urls"]); len(got) != 1 || got[0] != advertised.URL {
		t.Errorf("advertised_urls = %v, want [%s]: what the card said is kept beside what was dialled", got, advertised.URL)
	}
	if got := line["dialled_url"]; got != target.URL {
		t.Errorf("dialled_url = %v, want the target %s", got, target.URL)
	}
	if line["state"] != "TASK_STATE_COMPLETED" || line["result_kind"] != "task" {
		t.Errorf("result = %v/%v, want task/TASK_STATE_COMPLETED", line["result_kind"], line["state"])
	}
	wantHost, wantPort := hostPort(t, target.URL)
	if host, port := invokeAgentAddress(t, sr); host != wantHost || port != wantPort {
		t.Errorf("invoke_agent span says %s:%d, want the dialled %s:%d", host, port, wantHost, wantPort)
	}
}

// The card's entries are copied with their URL replaced and nothing else: the
// binding, the tenant and the protocol version stay what the card advertised.
// a2a.NewAgentInterface would not do -- it stamps the SDK's own protocol version,
// which would hide a 0.x card from rule 7's record -- and neither would writing
// through the card's own pointers, which would change what the line records as
// advertised.
func TestDial_TheCopyKeepsEverythingButTheURL(t *testing.T) {
	card := &a2a.AgentCard{
		Name: "n", Version: "v", Description: "d",
		SupportedInterfaces: []*a2a.AgentInterface{
			{URL: "http://advertised.example:80", ProtocolBinding: a2a.TransportProtocolJSONRPC, Tenant: "tenant-a", ProtocolVersion: "0.3"},
			{URL: "http://other.example:81", ProtocolBinding: a2a.TransportProtocolJSONRPC, Tenant: "tenant-b", ProtocolVersion: "1.0"},
		},
	}
	got := cardToDial(card, dialTarget, "http://target.example:8080")

	if got == card {
		t.Fatalf("the card itself was returned; the client has to be built from a copy")
	}
	if got.Name != "n" || got.Version != "v" || got.Description != "d" {
		t.Errorf("name/version/description = %q/%q/%q, want them as the card has them", got.Name, got.Version, got.Description)
	}
	if len(got.SupportedInterfaces) != 2 {
		t.Fatalf("interfaces: got %d, want 2", len(got.SupportedInterfaces))
	}
	for i, want := range []struct {
		tenant  string
		version a2a.ProtocolVersion
	}{{"tenant-a", "0.3"}, {"tenant-b", "1.0"}} {
		e := got.SupportedInterfaces[i]
		if e == card.SupportedInterfaces[i] {
			t.Errorf("entry %d is the card's own pointer, not a copy", i)
		}
		if e.URL != "http://target.example:8080" {
			t.Errorf("entry %d URL = %q, want the target", i, e.URL)
		}
		if e.ProtocolBinding != a2a.TransportProtocolJSONRPC || e.Tenant != want.tenant || e.ProtocolVersion != want.version {
			t.Errorf("entry %d = %+v, want binding JSONRPC, tenant %q and protocol version %q as advertised", i, *e, want.tenant, want.version)
		}
	}
	if card.SupportedInterfaces[0].URL != "http://advertised.example:80" || card.SupportedInterfaces[1].URL != "http://other.example:81" {
		t.Errorf("the resolved card was written through: %+v %+v", *card.SupportedInterfaces[0], *card.SupportedInterfaces[1])
	}
	if same := cardToDial(card, dialAdvertised, "http://target.example:8080"); same != card {
		t.Errorf("with the knob unset the client must be built from the resolved card itself, as it always was")
	}
}

// A card that advertises 0.x is refused by a2a-go v2.5.0 before anything is sent
// ("no compatible transports"), and the knob must not change that. The header on
// a request that IS sent cannot show it: at this version the header is the
// registered transport's version whenever the card's major version matches, so a
// 1.x card reads 1.0 on the wire whoever stamped the entry. What does show it is
// this: if the copy stamped the SDK's version on the entry, the 0.3 card below
// would be sent to.
func TestDial_ACardAdvertising0xIsRefusedEitherWay(t *testing.T) {
	for _, dial := range []dialMode{dialAdvertised, dialTarget} {
		t.Run("dial="+string(dial), func(t *testing.T) {
			spanRecorder(t)
			target, advertised := twoServers(t, http.StatusOK, "0.3")

			code, lines, _ := runSend(t, target.URL, dial)
			if code != 3 {
				t.Errorf("exit status %d, want 3", code)
			}
			if n := target.count(http.MethodPost) + advertised.count(http.MethodPost); n != 0 {
				t.Errorf("%d POST(s) were sent to a card advertising 0.3; want 0", n)
			}
			if len(lines) != 1 {
				t.Fatalf("client lines: got %d, want 1", len(lines))
			}
			if msg, _ := lines[0]["error"].(string); !strings.HasPrefix(msg, "create client:") {
				t.Errorf("error = %q, want it to start with %q", msg, "create client:")
			}
			if got := stringsOf(t, lines[0]["card_protocol_versions"]); len(got) != 1 || got[0] != "0.3" {
				t.Errorf("card_protocol_versions = %v, want [0.3]: a 0.x card is recorded, not papered over", got)
			}
		})
	}
}

// Rule 4: the knob moves the address and adds no second send. A 503 from the
// target is one POST, a failed Job and nothing on the advertised server.
func TestDial_TargetSendsOnceWhateverTheAnswer(t *testing.T) {
	spanRecorder(t)
	target, advertised := twoServers(t, http.StatusServiceUnavailable, a2a.Version)

	code, lines, _ := runSend(t, target.URL, dialTarget)
	if code != 3 {
		t.Errorf("exit status %d, want 3", code)
	}
	if p := target.count(http.MethodPost); p != 1 {
		t.Errorf("target received %d POSTs, want exactly 1", p)
	}
	if n := advertised.count(http.MethodGet) + advertised.count(http.MethodPost); n != 0 {
		t.Errorf("the advertised server received %d request(s), want 0: there is no falling back to it", n)
	}
	if len(lines) != 1 || lines[0]["attempt"] != float64(1) {
		t.Errorf("client lines = %v, want one line at attempt 1", lines)
	}
}

// legacyLine is the client line as it was before the two URL keys were appended
// (the struct at the parent commit, field for field).
type legacyLine struct {
	Ledger               string   `json:"ledger"`
	TS                   string   `json:"ts"`
	Attempt              int      `json:"attempt"`
	LogicalWorkItemID    string   `json:"logical_work_item_id"`
	MessageID            string   `json:"messageId"`
	TaskID               string   `json:"taskId"`
	ResultKind           string   `json:"result_kind"`
	State                string   `json:"state"`
	A2AVersion           string   `json:"a2a_version"`
	CardProtocolVersions []string `json:"card_protocol_versions"`
	Error                string   `json:"error,omitempty"`
}

// The two new keys are appended. Every key the line had keeps its name, its
// place and its bytes, with and without an error, so whatever read the line before
// reads the same prefix now.
func TestClientLine_ExistingKeysAreUnchangedByteForByte(t *testing.T) {
	for _, errText := range []string{"", "create client: no compatible transports found"} {
		old := legacyLine{
			Ledger: "client", TS: "2026-09-19T20:00:00.000000001Z", Attempt: 1, LogicalWorkItemID: "lwi-1",
			MessageID: "m-1", TaskID: "t-1", ResultKind: "task", State: "TASK_STATE_COMPLETED",
			A2AVersion: "1.0", CardProtocolVersions: []string{"1.0"}, Error: errText,
		}
		now := clientLine{
			Ledger: old.Ledger, TS: old.TS, Attempt: old.Attempt, LogicalWorkItemID: old.LogicalWorkItemID,
			MessageID: old.MessageID, TaskID: old.TaskID, ResultKind: old.ResultKind, State: old.State,
			A2AVersion: old.A2AVersion, CardProtocolVersions: old.CardProtocolVersions, Error: old.Error,
			AdvertisedURLs: []string{"http://advertised.example"}, DialledURL: "http://target.example:8080",
		}
		was, _ := json.Marshal(old)
		is, _ := json.Marshal(now)
		want := string(was[:len(was)-1]) + `,"advertised_urls":["http://advertised.example"],"dialled_url":"http://target.example:8080"}`
		if string(is) != want {
			t.Errorf("with error %q the line is\n  %s\nwant the earlier line with the two keys appended\n  %s", errText, is, want)
		}
	}
}

// One documented value. Anything else stops the Job before it sends: a typo that
// fell back to the advertised URL would send the row's work items through the
// ingress and be recorded as a row that addressed the Service.
func TestDialFromEnv(t *testing.T) {
	t.Setenv("CLIENT_DIAL", "")
	if got, err := dialFromEnv(); err != nil || got != dialAdvertised {
		t.Errorf("unset: got %q, %v; want the advertised URL and no error", got, err)
	}
	t.Setenv("CLIENT_DIAL", "target")
	if got, err := dialFromEnv(); err != nil || got != dialTarget {
		t.Errorf("target: got %q, %v; want dialTarget and no error", got, err)
	}
	for _, v := range []string{"on", "Target", "target ", " target", "card", "service", "1", "${CLIENT_DIAL}"} {
		t.Setenv("CLIENT_DIAL", v)
		got, err := dialFromEnv()
		if err == nil {
			t.Errorf("CLIENT_DIAL=%q was accepted as %q; only the exact value \"target\" is", v, got)
			continue
		}
		if !strings.Contains(err.Error(), strconv.Quote(v)) || !strings.Contains(err.Error(), `"target"`) {
			t.Errorf("CLIENT_DIAL=%q: the refusal %q must name the value it was given and the one it knows", v, err)
		}
	}
}
