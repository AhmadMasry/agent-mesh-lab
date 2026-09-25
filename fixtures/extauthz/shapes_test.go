package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"unicode/utf8"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
)

// Follow-on D-3b: every request shape of the routing reading, each with what
// the receivers dispatch, read from their source and pinned by their own
// handlers (the Go worker: agents/worker/mux_shapes_test.go; the Python
// orchestrator: the probe kept in the D-3b run directory). The fixture must
// refuse every shape either receiver dispatches as SubscribeToTask; a shape
// neither dispatches may be refused (the safe side) or allowed, and the
// expected decision here is the one the decision order gives.

const (
	grpcFrame   = "\x00\x00\x00\x00\x04\x12\x02t9" // SubscribeToTaskRequest{id: "t9"}, as a gRPC frame
	sendRESTMsg = `{"message":{"messageId":"m2","role":"ROLE_USER","parts":[{"text":"a"}],"metadata":{"logical_work_item_id":"lwi-3"}}}`
)

type shape struct {
	name                         string
	method, path, ctype, body    string
	size                         int64 // 0: len(body)
	goDispatches, pyDispatches   bool  // SubscribeToTask dispatched by the worker / the orchestrator
	want, reason, binding, reach string
}

func (s shape) req() *authv3.AttributeContext_HttpRequest {
	size := s.size
	if size == 0 {
		size = int64(len(s.body))
	}
	return httpReq(s.method, s.path, s.ctype, s.body, size, nil)
}

var shapes = []shape{
	// D-3's four, which D-3's fixture allowed.
	{"xp /x", "POST", "/x", "application/json", subscribeBody, 0, true, false, "deny", "operation:SubscribeToTask", "jsonrpc", "go"},
	{"xa /a2a/v1", "POST", "/a2a/v1", "application/json", subscribeBody, 0, true, false, "deny", "operation:SubscribeToTask", "jsonrpc", "go"},
	{"xg / as application/grpc", "POST", "/", "application/grpc", subscribeBody, 0, true, true, "deny", "operation:SubscribeToTask", "jsonrpc", "py+go"},
	{"xr %3A", "POST", "/tasks/t9%3Asubscribe", "", "", 0, true, true, "deny", "operation:SubscribeToTask", "rest", "none"},
	// New shapes D-3's fixture allowed.
	{"xn /%0A", "POST", "/%0A", "application/json", subscribeBody, 0, true, true, "deny", "operation:SubscribeToTask", "jsonrpc", "py+go"},
	{"xt /message:send/", "POST", "/message:send/", "application/json", subscribeBody, 0, true, false, "deny", "operation:SubscribeToTask", "jsonrpc", "go"},
	{"xm gRPC SendMessage path, JSON-RPC body", "POST", "/lf.a2a.v1.A2AService/SendMessage", "application/grpc", subscribeBody, 0, true, false, "deny", "operation:SubscribeToTask", "jsonrpc", "go"},
	{"xc REST subscribe as application/grpc", "POST", "/tasks/t9:subscribe", "application/grpc", "", 0, true, true, "deny", "operation:SubscribeToTask", "rest", "none"},
	{"xh HEAD", "HEAD", "/tasks/t9:subscribe", "", "", 0, true, true, "deny", "operation:SubscribeToTask", "rest", "none"},
	{"xl %73", "POST", "/tasks/t9:%73ubscribe", "", "", 0, true, true, "deny", "operation:SubscribeToTask", "rest", "none"},
	{"xl2 %74", "POST", "/%74asks/t9:subscribe", "", "", 0, true, true, "deny", "operation:SubscribeToTask", "rest", "none"},
	{"xl3 %3a", "POST", "/tasks/t9%3asubscribe", "", "", 0, true, true, "deny", "operation:SubscribeToTask", "rest", "none"},
	{"xs /tasks%2F", "POST", "/tasks%2Ft9:subscribe", "", "", 0, false, true, "deny", "operation:SubscribeToTask", "rest", "go"},
	{"xe :subscribe%0A", "POST", "/tasks/t9:subscribe%0A", "", "", 0, false, true, "deny", "operation:SubscribeToTask", "rest", "none"},
	{"xe2 GET :subscribe%0A", "GET", "/tasks/t9:subscribe%0A", "", "", 0, false, true, "deny", "operation:SubscribeToTask", "rest", "none"},
	{"gp gRPC %54", "POST", "/lf.a2a.v1.A2AService/Subscribe%54oTask", "application/grpc", grpcFrame, 0, true, false, "deny", "operation:SubscribeToTask", "grpc", "go"},
	{"gs gRPC %2F", "POST", "/lf.a2a.v1.A2AService%2FSubscribeToTask", "application/grpc", grpcFrame, 0, true, false, "deny", "operation:SubscribeToTask", "grpc", "go"},
	{"xb BOM", "POST", "/", "application/json", "\xef\xbb\xbf" + subscribeBody, 0, false, true, "deny", "operation:SubscribeToTask", "jsonrpc", "py+go"},
	{"x16 UTF-16LE", "POST", "/", "application/json", utf16le(subscribeBody), 0, false, true, "deny", "undecidable:not-json", "jsonrpc", "py+go"},
	// New shapes D-3's fixture already refused.
	{"gq gRPC ?x=1", "POST", "/lf.a2a.v1.A2AService/SubscribeToTask?x=1", "application/grpc", grpcFrame, 0, true, false, "deny", "operation:SubscribeToTask", "grpc", "go"},
	{"xu METHOD", "POST", "/", "application/json", `{"jsonrpc":"2.0","id":"1","METHOD":"SubscribeToTask","params":{"id":"t9"}}`, 0, true, false, "deny", "operation:SubscribeToTask", "jsonrpc", "py+go"},
	{"xq \\u0054", "POST", "/", "application/json", `{"jsonrpc":"2.0","id":"1","method":"Subscribe\u0054oTask","params":{"id":"t9"}}`, 0, true, true, "deny", "operation:SubscribeToTask", "jsonrpc", "py+go"},
	{"xi a%2Fb", "POST", "/tasks/a%2Fb:subscribe", "", "", 0, true, false, "deny", "operation:SubscribeToTask", "rest", "none"},
	{"rg GET", "GET", "/tasks/t9:subscribe", "", "", 0, true, true, "deny", "operation:SubscribeToTask", "rest", "none"},
	{"xk /?x=1", "POST", "/?x=1", "application/json", subscribeBody, 0, true, true, "deny", "operation:SubscribeToTask", "jsonrpc", "py+go"},
	// Also dispatched, read in the review of the shapes: Go reads the first value of a body with trailing data (the
	// strict reading cannot, so it is undecidable, deny); /tenant/... and /healthz/ fall to the worker's catch-all.
	{"trailing data at /x", "POST", "/x", "application/json", subscribeBody + " trailing", 0, true, false, "deny", "operation:SubscribeToTask", "jsonrpc", "go"},
	{"/healthz/", "POST", "/healthz/", "application/json", subscribeBody, 0, true, false, "deny", "operation:SubscribeToTask", "jsonrpc", "go"},
	{"tenant with a JSON-RPC body", "POST", "/tenant/tasks/t9:subscribe", "application/json", subscribeBody, 0, true, false, "deny", "operation:SubscribeToTask", "rest", "go"},
	// Rule 4 on a body the proxy cut (size -1): a first value that ends inside what was sent is the value a2a-go reads
	// from the whole body; one that does not is undecidable.
	{"partial at /x, first value unfinished", "POST", "/x", "application/json", subscribeBody[:30], -1, true, false, "deny", "undecidable:partial-body", "jsonrpc", "go"},
	{"partial at /x, first value complete", "POST", "/x", "application/json", subscribeBody + " {", -1, true, false, "deny", "operation:SubscribeToTask", "jsonrpc", "go"},
	// Not dispatched as SubscribeToTask by either receiver.
	{"%253A POST", "POST", "/tasks/t9%253Asubscribe", "", "", 0, false, false, "allow", "not-subscribe", "other", "none"},
	{"%253A GET", "GET", "/tasks/t9%253Asubscribe", "", "", 0, false, false, "allow", "not-subscribe", "other", "none"},
	{"//tasks", "POST", "//tasks/t9:subscribe", "", "", 0, false, false, "deny", "operation:SubscribeToTask", "rest", "none"},
	{"/tasks/./", "POST", "/tasks/./t9:subscribe", "", "", 0, false, false, "deny", "operation:SubscribeToTask", "rest", "none"},
	{"trailing slash", "POST", "/tasks/t9:subscribe/", "", "", 0, false, false, "allow", "not-subscribe", "other", "none"},
	{":Subscribe", "POST", "/tasks/t9:Subscribe", "", "", 0, false, false, "allow", "not-subscribe", "other", "none"},
	{"/Tasks/ no body", "POST", "/Tasks/t9:subscribe", "", "", 0, false, false, "deny", "operation:SubscribeToTask", "rest", "go"},
	{"PUT", "PUT", "/tasks/t9:subscribe", "", "", 0, false, false, "deny", "operation:SubscribeToTask", "rest", "none"},
	{"%0A%0A", "POST", "/tasks/t9:subscribe%0A%0A", "", "", 0, false, false, "allow", "not-subscribe", "other", "none"},
	{"lower-case method value", "POST", "/", "application/json", `{"jsonrpc":"2.0","id":"1","method":"subscribetotask","params":{"id":"t9"}}`, 0, false, false, "allow", "operation:subscribetotask", "jsonrpc", "py+go"},
	{"// JSON-RPC", "POST", "//", "application/json", subscribeBody, 0, false, false, "allow", "not-subscribe", "other", "none"},
	{"gRPC //", "POST", "//lf.a2a.v1.A2AService/SubscribeToTask", "application/grpc", grpcFrame, 0, false, false, "deny", "operation:SubscribeToTask", "grpc", "none"},
	{"gRPC trailing slash", "POST", "/lf.a2a.v1.A2AService/SubscribeToTask/", "application/grpc", grpcFrame, 0, false, false, "allow", "operation:", "grpc", "go"},
	{"gRPC %0A", "POST", "/lf.a2a.v1.A2AService/SubscribeToTask%0A", "application/grpc", grpcFrame, 0, false, false, "allow", "operation:SubscribeToTask\n", "grpc", "go"},
	{"gRPC lower-case", "POST", "/lf.a2a.v1.A2AService/subscribetotask", "application/grpc", grpcFrame, 0, false, false, "allow", "operation:subscribetotask", "grpc", "go"},
	// The operations the rows send, allowed.
	{"JSON-RPC SendMessage", "POST", "/", "application/json", sendBody, 0, false, false, "allow", "operation:SendMessage", "jsonrpc", "py+go"},
	{"REST SendMessage", "POST", "/message:send", "application/json", sendRESTMsg, 0, false, false, "allow", "operation:SendMessage", "rest", "none"},
	{"REST SendMessage, %3A", "POST", "/message%3Asend", "application/json", sendRESTMsg, 0, false, false, "allow", "operation:SendMessage", "rest", "none"},
	{"REST SendMessage with a JSON-RPC body", "POST", "/message:send", "application/json", subscribeBody, 0, false, false, "allow", "operation:SendMessage", "rest", "none"},
	{"gRPC SendMessage", "POST", "/lf.a2a.v1.A2AService/SendMessage", "application/grpc", "\x00\x00\x00\x00\x05\x0a\x03abc", 0, false, false, "allow", "operation:SendMessage", "grpc", "go"},
	{"gRPC SendMessage, partial", "POST", "/lf.a2a.v1.A2AService/SendMessage", "application/grpc", "\x00\x00\x20\x00\x05\x0a\x03abc", -1, false, false, "allow", "operation:SendMessage", "grpc", "go"},
	{"REST SendMessage, partial", "POST", "/message:send", "application/json", sendRESTMsg[:40], -1, false, false, "allow", "operation:SendMessage", "rest", "none"},
	{"card GET", "GET", "/.well-known/agent-card.json", "", "", 0, false, false, "allow", "not-subscribe", "other", "none"},
}

func TestShapes_EveryDispatchedSubscribeIsRefused(t *testing.T) {
	for _, s := range shapes {
		t.Run(s.name, func(t *testing.T) {
			d := decide(s.req(), undecidableDeny)
			if (s.goDispatches || s.pyDispatches) && d.Decision != "deny" {
				t.Errorf("a receiver dispatches it and the fixture allows it: %+v", d)
			}
			if d.Decision != s.want || d.Reason != s.reason || d.Binding != s.binding || d.JSONRPCReach != s.reach {
				t.Errorf("got %s %q binding %q reach %q; want %s %q %q %q (%+v)", d.Decision, d.Reason, d.Binding, d.JSONRPCReach, s.want, s.reason, s.binding, s.reach, d)
			}
		})
	}
}

// Every shape the rules decide by path or by a readable body is decided the same
// under allow: only the undecidable set follows the setting.
func TestShapes_OnlyTheUndecidableFollowTheSetting(t *testing.T) {
	for _, s := range shapes {
		d, a := decide(s.req(), undecidableDeny), decide(s.req(), undecidableAllow)
		if d.DecidedBy == "setting" {
			if a.Decision != "allow" || a.Reason != d.Reason {
				t.Errorf("%s: under allow %+v", s.name, a)
			}
			continue
		}
		if a.Decision != d.Decision || a.Reason != d.Reason {
			t.Errorf("%s: deny setting %s %s, allow setting %s %s", s.name, d.Decision, d.Reason, a.Decision, a.Reason)
		}
	}
}

func TestDecodedPath(t *testing.T) {
	for in, want := range map[string]string{
		"/":                           "/",
		"/tasks/t9%3Asubscribe":       "/tasks/t9:subscribe",
		"/tasks/t9%3asubscribe?x=%41": "/tasks/t9:subscribe",
		"/%74asks%2Ft9":               "/tasks/t9",
		"/%0A":                        "/\n",
		"/tasks/t9%253A":              "/tasks/t9%3A",
		"/x%zz%4":                     "/x%zz%4",
		"/%ff":                        "/�",
	} {
		if got := decodePath(in); got != want {
			t.Errorf("decodePath(%q) = %q; want %q", in, got, want)
		}
	}
	d := decide(httpReq("POST", "/tasks/t9%3Asubscribe?x=1", "", "", 0, nil), undecidableDeny)
	if d.DecodedPath != "/tasks/t9:subscribe" || d.TaskID != "t9" {
		t.Errorf("decoded %q task %q", d.DecodedPath, d.TaskID)
	}
}

// The strict reading on "/" treats two member names that differ only in case as
// a duplicate: a2a-go folds case (it read SubscribeToTask from the second
// spelling), a2a-python does not.
func TestJSONRPC_CaseFoldedDuplicateIsUndecidable(t *testing.T) {
	for _, b := range []string{
		`{"jsonrpc":"2.0","id":"1","method":"SendMessage","METHOD":"SubscribeToTask","params":{"id":"t9"}}`,
		`{"jsonrpc":"2.0","id":"1","METHOD":"SubscribeToTask","method":"SendMessage","params":{"id":"t9"}}`,
		`{"jsonrpc":"2.0","id":"1","method":"SendMessage","params":{"message":{"messageId":"a","MessageID":"b"}}}`,
	} {
		d := decide(jsonrpcReq(b), undecidableDeny)
		if d.Decision != "deny" || d.Reason != "undecidable:duplicate-key" {
			t.Errorf("%s: %+v", b, d)
		}
	}
}

// Rule 4 reads the body as a2a-go's JSON-RPC handler does: one json.Decoder,
// the first value, into the handler's own struct shape.
func TestGoDecoder_ReadsAsA2AGo(t *testing.T) {
	for _, tc := range []struct {
		body, method string
		ok           bool
	}{
		{subscribeBody, "SubscribeToTask", true},
		{subscribeBody + "garbage", "SubscribeToTask", true},
		{subscribeBody + subscribeBody, "SubscribeToTask", true},
		{`{"METHOD":"SubscribeToTask"}`, "SubscribeToTask", true},
		{`{"method":"SendMessage","METHOD":"SubscribeToTask"}`, "SubscribeToTask", true},
		{`{"METHOD":"SubscribeToTask","method":"SendMessage"}`, "SendMessage", true},
		{"[" + subscribeBody + "]", "", false},
		{"\xef\xbb\xbf" + subscribeBody, "", false},
		{grpcFrame, "", false},
		{"", "", false},
	} {
		m, err := goDecode([]byte(tc.body))
		if (err == nil) != tc.ok || m != tc.method {
			t.Errorf("%q: %q %v; want %q ok=%v", tc.body, m, err, tc.method, tc.ok)
		}
	}
}

// The controller's condition 2: agentgateway sends the body as lossy UTF-8
// (ext_authz.rs l.442-455), a2a-go reads the original bytes. For every body
// with invalid bytes inserted at any position, inside a string or outside one,
// a2a-go's decoder gives the same answer to the only question rule 4 asks -- does
// it decode, and is the method SubscribeToTask -- on the original and on the lossy
// text. Two lossy forms bracket the proxy's: one U+FFFD per invalid byte, and
// one per run (strings.ToValidUTF8); Rust's from_utf8_lossy replaces each
// maximal ill-formed subpart, which lies between the two.
func TestGoDecoder_LossyUTF8DoesNotChangeTheAnswer(t *testing.T) {
	answer := func(b []byte) string {
		m, err := goDecode(b)
		if err != nil {
			return "no-dispatch"
		}
		return "method=" + map[bool]string{true: "SubscribeToTask", false: "other"}[m == "SubscribeToTask"]
	}
	perByte := func(b []byte) []byte {
		var out bytes.Buffer
		for len(b) > 0 {
			r, n := utf8.DecodeRune(b)
			if r == utf8.RuneError && n == 1 {
				out.WriteString("�")
			} else {
				out.Write(b[:n])
			}
			b = b[n:]
		}
		return out.Bytes()
	}
	perRun := func(b []byte) []byte { return []byte(strings.ToValidUTF8(string(b), "�")) }
	checked := 0
	for _, base := range []string{subscribeBody, sendBody} {
		for _, bad := range []string{"\xff", "\xc3", "\xed\xa0\x80", "\xe2\x82", "\xff\xfe"} {
			for i := 0; i <= len(base); i++ {
				orig := []byte(base[:i] + bad + base[i:])
				want := answer(orig)
				for _, lossy := range [][]byte{perByte(orig), perRun(orig)} {
					if got := answer(lossy); got != want {
						t.Errorf("insert %q at %d: original %s, lossy %s", bad, i, want, got)
					}
				}
				checked++
			}
		}
	}
	// Inside the method's own string the method is no longer SubscribeToTask on
	// either side; outside any string both are a syntax error.
	if a := answer([]byte(strings.Replace(subscribeBody, "SubscribeToTask", "Subscribe\xffToTask", 1))); a != "method=other" {
		t.Errorf("invalid byte inside the method: %s", a)
	}
	if a := answer([]byte(strings.Replace(subscribeBody, `,"method"`, `,`+"\xff"+`"method"`, 1))); a != "no-dispatch" {
		t.Errorf("invalid byte outside a string: %s", a)
	}
	t.Logf("%d bodies, each against two lossy forms", checked)
}

// The ledger line carries the path as received and as decoded, and which
// receivers' JSON-RPC handler the request would reach.
func TestLedger_DecodedPathAndReach(t *testing.T) {
	out := &lockedBuffer{}
	s := newServer(out, undecidableDeny)
	if _, err := s.Check(t.Context(), check(httpReq("POST", "/tasks/t9%3Asubscribe", "", "", 0, nil))); err != nil {
		t.Fatal(err)
	}
	l := out.lines(t)[0]
	if l["path"] != "/tasks/t9%3Asubscribe" || l["decoded_path"] != "/tasks/t9:subscribe" || l["jsonrpc_reach"] != "none" {
		t.Errorf("path %v decoded_path %v jsonrpc_reach %v", l["path"], l["decoded_path"], l["jsonrpc_reach"])
	}
	var raw map[string]json.RawMessage
	_ = json.Unmarshal(mustMarshal(t, l), &raw)
	if _, ok := raw["decoded_path"]; !ok {
		t.Error("no decoded_path")
	}
}

func mustMarshal(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func utf16le(s string) string {
	var b strings.Builder
	for _, c := range []byte(s) {
		b.WriteByte(c)
		b.WriteByte(0)
	}
	return b.String()
}
