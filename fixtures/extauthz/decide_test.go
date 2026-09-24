package main

import (
	"strings"
	"testing"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
)

// httpReq builds the AttributeContext_HttpRequest agentgateway v1.5.0 sends
// (crates/agentgateway/src/http/ext_authz.rs l.475-503): lower-case header
// names, pseudo-headers included when no header list is set, the body as a
// string, and size the body's length, or -1 when the body is partial.
func httpReq(method, path, contentType, body string, size int64, extra map[string]string) *authv3.AttributeContext_HttpRequest {
	h := map[string]string{":method": method, ":path": path, ":authority": "worker.lab.internal", ":scheme": "http"}
	if contentType != "" {
		h["content-type"] = contentType
	}
	for k, v := range extra {
		h[k] = v
	}
	return &authv3.AttributeContext_HttpRequest{
		Id: "00-trace-span-01", Method: method, Path: path, Host: "worker.lab.internal",
		Scheme: "http", Protocol: "HTTP/1.1", Headers: h, Body: body, Size: size,
	}
}

func jsonrpcReq(body string) *authv3.AttributeContext_HttpRequest {
	return httpReq("POST", "/", "application/json", body, int64(len(body)), map[string]string{"a2a-version": "1.0"})
}

const (
	sendBody = `{"jsonrpc":"2.0","id":"r1","method":"SendMessage","params":{"message":{"messageId":"m1","role":"ROLE_USER",` +
		`"parts":[{"text":"hi"}],"metadata":{"logical_work_item_id":"lwi-1"}}}}`
	subscribeBody = `{"jsonrpc":"2.0","id":7,"method":"SubscribeToTask","params":{"id":"t-9"}}`
)

func TestDecide_JSONRPC_ByTheBodysMethod(t *testing.T) {
	for _, tc := range []struct {
		name, body, want, op string
	}{
		{"send allowed", sendBody, "allow", "SendMessage"},
		{"subscribe refused", subscribeBody, "deny", "SubscribeToTask"},
		{"streaming allowed", strings.Replace(sendBody, "SendMessage", "SendStreamingMessage", 1), "allow", "SendStreamingMessage"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			d := decide(jsonrpcReq(tc.body), undecidableDeny)
			if d.Decision != tc.want || d.Binding != "jsonrpc" || d.Operation != tc.op || d.DecidedBy != "body.method" {
				t.Errorf("got %+v; want %s, jsonrpc, %s, body.method", d, tc.want, tc.op)
			}
		})
	}
}

func TestDecide_JSONRPC_IdentityFromTheBodyAndTheHeader(t *testing.T) {
	d := decide(jsonrpcReq(sendBody), undecidableDeny)
	if d.LogicalWorkItemID != "lwi-1" || d.MessageID != "m1" || d.TaskID != "" || d.JSONRPCID != `"r1"` {
		t.Errorf("send identity %+v", d)
	}
	r := jsonrpcReq(subscribeBody)
	r.Headers["x-logical-work-item-id"] = "lwi-2"
	d = decide(r, undecidableDeny)
	if d.LogicalWorkItemID != "lwi-2" || d.TaskID != "t-9" || d.JSONRPCID != "7" || d.MessageID != "" {
		t.Errorf("subscribe identity %+v", d)
	}
}

// The undecidable cases: what the fixture cannot read a JSON-RPC method from.
// Each is decided by the setting, deny by default.
var undecidable = []struct {
	name, reason string
	req          func() *authv3.AttributeContext_HttpRequest
}{
	{"no body", "undecidable:no-body", func() *authv3.AttributeContext_HttpRequest { return jsonrpcReq("") }},
	{"partial body", "undecidable:partial-body", func() *authv3.AttributeContext_HttpRequest {
		r := jsonrpcReq(subscribeBody[:30])
		r.Size = -1
		return r
	}},
	// A partial body is undecidable even when the prefix it carries would parse:
	// the fixture does not read a method from a body the proxy marked partial.
	{"partial body that parses", "undecidable:partial-body", func() *authv3.AttributeContext_HttpRequest {
		r := jsonrpcReq(subscribeBody)
		r.Size = -1
		return r
	}},
	{"not json", "undecidable:not-json", func() *authv3.AttributeContext_HttpRequest { return jsonrpcReq(`{"jsonrpc":"2.0",`) }},
	{"trailing data", "undecidable:not-json", func() *authv3.AttributeContext_HttpRequest { return jsonrpcReq(subscribeBody + `{}`) }},
	{"batch", "undecidable:batch", func() *authv3.AttributeContext_HttpRequest { return jsonrpcReq(`[` + subscribeBody + `]`) }},
	{"duplicate method key", "undecidable:duplicate-key", func() *authv3.AttributeContext_HttpRequest {
		return jsonrpcReq(`{"jsonrpc":"2.0","id":1,"method":"SendMessage","method":"SubscribeToTask","params":{"id":"t"}}`)
	}},
	{"duplicate key reversed", "undecidable:duplicate-key", func() *authv3.AttributeContext_HttpRequest {
		return jsonrpcReq(`{"jsonrpc":"2.0","id":1,"method":"SubscribeToTask","method":"SendMessage","params":{"id":"t"}}`)
	}},
	{"duplicate key nested", "undecidable:duplicate-key", func() *authv3.AttributeContext_HttpRequest {
		return jsonrpcReq(`{"jsonrpc":"2.0","id":1,"method":"SendMessage","params":{"message":{"messageId":"a","messageId":"b"}}}`)
	}},
	{"no method", "undecidable:no-method", func() *authv3.AttributeContext_HttpRequest { return jsonrpcReq(`{"jsonrpc":"2.0","id":1}`) }},
	{"method not a string", "undecidable:no-method", func() *authv3.AttributeContext_HttpRequest {
		return jsonrpcReq(`{"jsonrpc":"2.0","id":1,"method":["SubscribeToTask"]}`)
	}},
	{"top-level string", "undecidable:not-an-object", func() *authv3.AttributeContext_HttpRequest { return jsonrpcReq(`"SubscribeToTask"`) }},
}

func TestDecide_Undecidable_DeniedByDefault(t *testing.T) {
	for _, tc := range undecidable {
		t.Run(tc.name, func(t *testing.T) {
			d := decide(tc.req(), undecidableDeny)
			if d.Decision != "deny" || d.Reason != tc.reason || d.DecidedBy != "setting" || d.Binding != "jsonrpc" {
				t.Errorf("got %+v; want deny, %s, setting", d, tc.reason)
			}
		})
	}
}

func TestDecide_Undecidable_AllowedWhenSet(t *testing.T) {
	for _, tc := range undecidable {
		t.Run(tc.name, func(t *testing.T) {
			d := decide(tc.req(), undecidableAllow)
			if d.Decision != "allow" || d.Reason != tc.reason || d.DecidedBy != "setting" {
				t.Errorf("got %+v; want allow, %s, setting", d, tc.reason)
			}
		})
	}
}

func TestDecide_PartialMarkAndLengths(t *testing.T) {
	r := jsonrpcReq(subscribeBody[:30])
	r.Size = -1
	d := decide(r, undecidableDeny)
	if !d.Partial || d.BodyLen != 30 || d.Size != -1 {
		t.Errorf("got partial %v body_len %d size %d; want true, 30, -1", d.Partial, d.BodyLen, d.Size)
	}
	d = decide(jsonrpcReq(sendBody), undecidableDeny)
	if d.Partial || d.BodyLen != len(sendBody) || d.Size != int64(len(sendBody)) {
		t.Errorf("got partial %v body_len %d size %d", d.Partial, d.BodyLen, d.Size)
	}
}

func TestDecide_REST_ByThePath(t *testing.T) {
	for _, tc := range []struct {
		name, method, path, body, want, op, task string
	}{
		{"POST subscribe refused", "POST", "/tasks/t-1:subscribe", "", "deny", "SubscribeToTask", "t-1"},
		{"GET subscribe refused", "GET", "/tasks/t-2:subscribe", "", "deny", "SubscribeToTask", "t-2"},
		{"tenant-prefixed subscribe refused", "POST", "/tenant-a/tasks/t-3:subscribe", "", "deny", "SubscribeToTask", "t-3"},
		{"subscribe with a query refused", "GET", "/tasks/t-4:subscribe?x=1", "", "deny", "SubscribeToTask", "t-4"},
		{"send allowed", "POST", "/message:send", `{"message":{"messageId":"m2","metadata":{"logical_work_item_id":"lwi-3"}}}`, "allow", "SendMessage", ""},
		{"cancel allowed", "POST", "/tasks/t-5:cancel", "", "allow", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := httpReq(tc.method, tc.path, "application/json", tc.body, int64(len(tc.body)), nil)
			d := decide(r, undecidableDeny)
			if d.Decision != tc.want || d.Operation != tc.op || d.TaskID != tc.task || d.DecidedBy != "path" {
				t.Errorf("got %+v; want %s op %q task %q by path", d, tc.want, tc.op, tc.task)
			}
			if tc.op != "" && d.Binding != "rest" {
				t.Errorf("binding %q; want rest", d.Binding)
			}
		})
	}
	d := decide(httpReq("POST", "/message:send", "application/json", `{"message":{"messageId":"m2","metadata":{"logical_work_item_id":"lwi-3"}}}`, 70, nil), undecidableDeny)
	if d.MessageID != "m2" || d.LogicalWorkItemID != "lwi-3" {
		t.Errorf("REST send identity %+v", d)
	}
}

// A REST subscription is refused by its path whatever its body: an absent or
// partial body does not make it undecidable, and the setting does not apply.
func TestDecide_REST_SubscribeRefusedUnderAllowToo(t *testing.T) {
	r := httpReq("POST", "/tasks/t-1:subscribe", "application/json", "", -1, nil)
	d := decide(r, undecidableAllow)
	if d.Decision != "deny" || d.DecidedBy != "path" {
		t.Errorf("got %+v; want deny by path", d)
	}
}

func TestDecide_GRPC_ByThePath(t *testing.T) {
	for _, tc := range []struct {
		path, want, op string
	}{
		{"/lf.a2a.v1.A2AService/SubscribeToTask", "deny", "SubscribeToTask"},
		{"/lf.a2a.v1.A2AService/SendMessage", "allow", "SendMessage"},
		{"/lf.a2a.v1.A2AService/SendStreamingMessage", "allow", "SendStreamingMessage"},
		{"/other.pkg.Svc/SubscribeToTask", "deny", "SubscribeToTask"},
	} {
		t.Run(tc.path, func(t *testing.T) {
			// The body is a gRPC frame, forwarded as lossy UTF-8; it is not read.
			r := httpReq("POST", tc.path, "application/grpc", "\x00\x00\x00\x00\x05��", 7, map[string]string{"x-logical-work-item-id": "lwi-g"})
			r.Protocol = "HTTP/2"
			d := decide(r, undecidableDeny)
			if d.Decision != tc.want || d.Binding != "grpc" || d.Operation != tc.op || d.DecidedBy != "path" || d.LogicalWorkItemID != "lwi-g" {
				t.Errorf("got %+v; want %s grpc %s by path", d, tc.want, tc.op)
			}
		})
	}
	// A gRPC SubscribeToTask is refused by its path under allow too.
	r := httpReq("POST", "/lf.a2a.v1.A2AService/SubscribeToTask", "application/grpc+proto", "", -1, nil)
	if d := decide(r, undecidableAllow); d.Decision != "deny" {
		t.Errorf("grpc+proto subscribe under allow: %+v", d)
	}
}

func TestDecide_EverythingElseAllowed(t *testing.T) {
	for _, r := range []*authv3.AttributeContext_HttpRequest{
		httpReq("GET", "/.well-known/agent-card.json", "", "", 0, nil),
		httpReq("GET", "/", "", "", 0, nil),
		httpReq("GET", "/tasks/t-1", "", "", 0, nil),
	} {
		d := decide(r, undecidableDeny)
		if d.Decision != "allow" || d.Reason != "not-subscribe" || d.Binding != "other" {
			t.Errorf("%s %s: %+v; want allow not-subscribe other", r.Method, r.Path, d)
		}
	}
}

// JSON-RPC is recognised by a POST to the JSON-RPC path and not by its content
// type: a POST to / without one is still read as JSON-RPC.
func TestDecide_JSONRPC_WithoutAContentType(t *testing.T) {
	r := httpReq("POST", "/", "", subscribeBody, int64(len(subscribeBody)), nil)
	if d := decide(r, undecidableDeny); d.Decision != "deny" || d.Binding != "jsonrpc" {
		t.Errorf("got %+v", d)
	}
}

func TestParseUndecidable(t *testing.T) {
	for in, want := range map[string]string{"": undecidableDeny, "deny": undecidableDeny, "allow": undecidableAllow} {
		got, err := parseUndecidable(in)
		if err != nil || got != want {
			t.Errorf("parseUndecidable(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"Allow", "open", "1", "true"} {
		if _, err := parseUndecidable(in); err == nil {
			t.Errorf("parseUndecidable(%q): no error; an unknown value must refuse to start", in)
		}
	}
}
