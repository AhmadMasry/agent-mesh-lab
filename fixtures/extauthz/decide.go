package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strings"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
)

// The one rule, the same as C-8's: refuse SubscribeToTask, allow everything
// else. Which field decides it depends on the binding the request is on:
//
//   - gRPC (content-type application/grpc...): the method in the request path,
//     /<package>.<Service>/<Method>. The body is not read: agentgateway v1.5.0
//     forwards it as lossy UTF-8 of the protobuf frame
//     (crates/agentgateway/src/http/ext_authz.rs l.442-455).
//   - REST: the path, /tasks/{id}:subscribe, with or without a tenant segment
//     before it, on GET or POST (a2a-go v2.5.0 routes both).
//   - JSON-RPC (a POST to the JSON-RPC path): the "method" member of the body.
//     The body is present only when the policy sets forwardBody.
//   - anything else (the agent card, REST SendMessage, GetTask, ...): allowed,
//     decided by the path, which names no subscription.
//
// A JSON-RPC request whose method cannot be read is undecidable: no body, a
// body the proxy marked partial (size -1, ext_authz.rs l.307-310 and l.498),
// not JSON, trailing data, a batch, a duplicate key at any depth, no string
// method, or a top-level value that is not an object. Those are decided by the
// setting EXTAUTHZ_UNDECIDABLE, deny unless it says allow. Deny is the default
// because the rule is a refusal: a request the authorizer cannot read is one it
// cannot show is not the refused operation, and C-8 counted what failing open
// on an unreadable body lets through.

const (
	undecidableDeny  = "deny"
	undecidableAllow = "allow"

	jsonrpcPath = "/"
)

func parseUndecidable(v string) (string, error) {
	switch v {
	case "", undecidableDeny:
		return undecidableDeny, nil
	case undecidableAllow:
		return undecidableAllow, nil
	}
	return "", fmt.Errorf("EXTAUTHZ_UNDECIDABLE=%q: want deny or allow", v)
}

// restSubscribe matches /tasks/{id}:subscribe and /{tenant}/tasks/{id}:subscribe.
var restSubscribe = regexp.MustCompile(`^(?:/[^/]+)?/tasks/([^/]+):subscribe$`)

// decision is everything the fixture read and decided for one check; the
// ledger line is built from it.
type decision struct {
	LogicalWorkItemID string
	MessageID         string
	TaskID            string
	JSONRPCID         string
	Binding           string
	Operation         string
	DecidedBy         string
	BodyLen           int
	Size              int64
	Partial           bool
	HeaderNames       []string
	Decision          string
	Reason            string
}

func decide(r *authv3.AttributeContext_HttpRequest, setting string) decision {
	d := decision{BodyLen: len(r.GetBody()), Size: r.GetSize(), Partial: r.GetSize() == -1}
	for k := range r.GetHeaders() {
		d.HeaderNames = append(d.HeaderNames, k)
	}
	sort.Strings(d.HeaderNames)
	path, _, _ := strings.Cut(r.GetPath(), "?")
	method := r.GetMethod()

	switch {
	case strings.HasPrefix(header(r, "content-type"), "application/grpc"):
		d.Binding, d.DecidedBy = "grpc", "path"
		if i := strings.LastIndex(path, "/"); i >= 0 {
			d.Operation = path[i+1:]
		}
		d.rule()
	case restSubscribe.MatchString(path) && (method == "GET" || method == "POST"):
		d.Binding, d.DecidedBy, d.Operation = "rest", "path", "SubscribeToTask"
		d.TaskID = restSubscribe.FindStringSubmatch(path)[1]
		d.rule()
	case method == "POST" && (path == "/message:send" || path == "/message:stream"):
		d.Binding, d.DecidedBy = "rest", "path"
		d.Operation = map[string]string{"/message:send": "SendMessage", "/message:stream": "SendStreamingMessage"}[path]
		d.restIdentity(r)
		d.rule()
	case method == "POST" && path == jsonrpcPath:
		d.Binding = "jsonrpc"
		d.jsonrpc(r, setting)
	default:
		d.Binding, d.DecidedBy, d.Decision, d.Reason = "other", "path", "allow", "not-subscribe"
	}
	if d.LogicalWorkItemID == "" {
		d.LogicalWorkItemID = header(r, "x-logical-work-item-id")
	}
	return d
}

func (d *decision) rule() {
	if d.Operation == "SubscribeToTask" {
		d.Decision, d.Reason = "deny", "operation:SubscribeToTask"
		return
	}
	d.Decision, d.Reason = "allow", "operation:"+d.Operation
}

func (d *decision) undecidable(setting, why string) {
	d.DecidedBy, d.Decision, d.Reason = "setting", setting, "undecidable:"+why
}

// jsonrpcBody is the part of a JSON-RPC request the fixture reads: the method,
// and the identity fields of SendMessage, SendStreamingMessage and
// SubscribeToTask (params.id).
type jsonrpcBody struct {
	ID     json.RawMessage `json:"id"`
	Method json.RawMessage `json:"method"`
	Params struct {
		ID      string      `json:"id"`
		Message messageView `json:"message"`
	} `json:"params"`
}

type messageView struct {
	MessageID string         `json:"messageId"`
	TaskID    string         `json:"taskId"`
	Metadata  map[string]any `json:"metadata"`
}

func (d *decision) jsonrpc(r *authv3.AttributeContext_HttpRequest, setting string) {
	body := []byte(r.GetBody())
	switch {
	case d.Partial:
		d.undecidable(setting, "partial-body")
		return
	case len(bytes.TrimSpace(body)) == 0:
		d.undecidable(setting, "no-body")
		return
	}
	switch err := scan(body); {
	case errors.Is(err, errDuplicateKey):
		d.undecidable(setting, "duplicate-key")
		return
	case err != nil:
		d.undecidable(setting, "not-json")
		return
	}
	switch bytes.TrimSpace(body)[0] {
	case '[':
		d.undecidable(setting, "batch")
		return
	case '{':
	default:
		d.undecidable(setting, "not-an-object")
		return
	}
	var b jsonrpcBody
	// The scan has shown one well-formed object with no repeated key, so this
	// decode cannot pick between two values; its error is only a type mismatch
	// in a field the fixture reads for identity.
	_ = json.Unmarshal(body, &b)
	if len(b.ID) > 0 {
		d.JSONRPCID = string(b.ID)
	}
	d.MessageID = b.Params.Message.MessageID
	d.TaskID = b.Params.Message.TaskID
	if b.Params.ID != "" {
		d.TaskID = b.Params.ID
	}
	d.LogicalWorkItemID, _ = b.Params.Message.Metadata["logical_work_item_id"].(string)
	var m string
	if json.Unmarshal(b.Method, &m) != nil || m == "" {
		d.undecidable(setting, "no-method")
		return
	}
	d.Operation, d.DecidedBy = m, "body.method"
	d.rule()
}

func (d *decision) restIdentity(r *authv3.AttributeContext_HttpRequest) {
	var b struct {
		Message messageView `json:"message"`
	}
	if d.Partial || json.Unmarshal([]byte(r.GetBody()), &b) != nil {
		return
	}
	d.MessageID, d.TaskID = b.Message.MessageID, b.Message.TaskID
	d.LogicalWorkItemID, _ = b.Message.Metadata["logical_work_item_id"].(string)
}

func header(r *authv3.AttributeContext_HttpRequest, name string) string {
	for k, v := range r.GetHeaders() {
		if strings.EqualFold(k, name) {
			return v
		}
	}
	return ""
}

var errDuplicateKey = errors.New("duplicate key")

// scan walks the whole document token by token and fails on malformed JSON,
// on data after the first value, and on any object that names one key twice.
// encoding/json's Unmarshal keeps the last of two equal keys without saying so,
// which is exactly the ambiguity the duplicate-key probe is about.
func scan(body []byte) error {
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()
	if err := scanValue(dec); err != nil {
		return err
	}
	if _, err := dec.Token(); err != io.EOF {
		return errors.New("data after the first value")
	}
	return nil
}

func scanValue(dec *json.Decoder) error {
	tok, err := dec.Token()
	if err != nil {
		return err
	}
	switch tok {
	case json.Delim('{'):
		seen := map[string]bool{}
		for dec.More() {
			k, err := dec.Token()
			if err != nil {
				return err
			}
			key, ok := k.(string)
			if !ok {
				return errors.New("object key is not a string")
			}
			if seen[key] {
				return errDuplicateKey
			}
			seen[key] = true
			if err := scanValue(dec); err != nil {
				return err
			}
		}
		_, err = dec.Token()
		return err
	case json.Delim('['):
		for dec.More() {
			if err := scanValue(dec); err != nil {
				return err
			}
		}
		_, err = dec.Token()
		return err
	}
	return nil
}
