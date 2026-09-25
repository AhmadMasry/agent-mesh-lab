package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"

	"github.com/AhmadMasry/agent-mesh-lab/internal/workermux"
)

// The one rule, the same as C-8's: refuse SubscribeToTask, allow everything
// else. D-3 read the operation from the shapes the SDK clients send; follow-on
// D-3b (the author's note of 2026-09-25) reads it from every shape either
// receiver dispatches. P is the path before its first "?", D is P
// percent-decoded as uvicorn decodes it (every valid %XX, invalid escapes kept,
// h11_impl.py l.204-205) and D1 is D less one trailing newline, because
// Starlette's route patterns end in "$", which Python lets match before a final
// newline. The order:
//
//  1. D or D1 ends in ":subscribe": SubscribeToTask on REST, by path, whatever
//     the HTTP method or content type. a2a-go dispatches it on GET, HEAD and POST
//     when the unescaped last segment ends so (a2asrv/rest.go l.53-54, l.211-236;
//     a GET pattern also takes HEAD), a2a-python on GET, HEAD and POST of
//     ^/tasks/[^/]+:subscribe$ on the decoded path (rest_routes.py l.75-114).
//  2. D's text after its last "/" is SubscribeToTask: SubscribeToTask on gRPC,
//     by path, whatever the content type. grpc-go takes the method from the
//     decoded URL path (handler_server.go l.419, server.go l.1825-1836),
//     grpc.aio from the raw :path, exactly (server.cc l.1774-1805).
//  3. A POST with D1 == "/", the orchestrator's JSON-RPC route: the body's
//     method, read strictly (jsonrpc below); what it cannot read is undecidable.
//  4. A POST the worker's own routing hands to its JSON-RPC handler, the
//     catch-all (internal/workermux, replayed here with Go's own ServeMux): the
//     body read as a2a-go reads it (goDecode). A syntax error is a body a2a-go
//     does not dispatch, so it adds nothing; a partial body whose first value
//     does not end inside what the proxy sent is undecidable.
//  5. Otherwise the operation the path names, as in D-3: gRPC by content type
//     and the method in the path, REST SendMessage and SendStreamingMessage by
//     path, everything else allowed. A REST path that names an operation reaches
//     neither receiver's JSON-RPC handler, so its body cannot select another
//     operation: the REST handler decodes it as a SendMessageRequest.
//
// Rule 4 applies the worker's routing to every host, the orchestrator's too: it
// can only add a refusal, never an allow, since rule 3 already reads everything
// the orchestrator hands to JSON-RPC.
//
// A body the strict reading cannot read is undecidable: no body, a body the
// proxy marked partial (size -1, ext_authz.rs l.307-310 and l.498), not JSON (a
// UTF-16 or UTF-32 body, which a2a-python reads, arrives as lossy UTF-8 and
// falls here), trailing data, a batch, a duplicate key at any depth, two keys
// that differ only in case (a2a-go folds case, a2a-python does not), no string
// method, or a top-level value that is not an object. One leading UTF-8 byte
// order mark is removed first: a2a-python reads through it, a2a-go rejects it.
// Undecidable requests are decided by the setting EXTAUTHZ_UNDECIDABLE, deny
// unless it says allow. Deny is the default because the rule is a refusal: a
// request the authorizer cannot read is one it cannot show is not the refused
// operation, and C-8 counted what failing open on an unreadable body lets
// through.

const (
	undecidableDeny  = "deny"
	undecidableAllow = "allow"

	jsonrpcPath = "/"
	utf8BOM     = "\xef\xbb\xbf"
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

// restSubscribeTask reads the task id from a decoded subscription path, for
// the ledger only; rule 1 is the suffix alone.
var restSubscribeTask = regexp.MustCompile(`^(?:/[^/]+)?/tasks/(.+):subscribe$`)

// decision is everything the fixture read and decided for one check; the
// ledger line is built from it.
type decision struct {
	LogicalWorkItemID string
	MessageID         string
	TaskID            string
	JSONRPCID         string
	DecodedPath       string
	JSONRPCReach      string
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
	method := r.GetMethod()
	path := decodePath(r.GetPath())
	path1 := strings.TrimSuffix(path, "\n")
	d.DecodedPath = path
	pyReach := method == "POST" && path1 == jsonrpcPath
	goReach := method == "POST" && reachesWorkerJSONRPC(r.GetPath())
	d.JSONRPCReach = map[[2]bool]string{{true, true}: "py+go", {true, false}: "py", {false, true}: "go", {false, false}: "none"}[[2]bool{pyReach, goReach}]
	last := path[strings.LastIndex(path, "/")+1:]

	switch {
	case strings.HasSuffix(path, ":subscribe") || strings.HasSuffix(path1, ":subscribe"):
		d.Binding, d.DecidedBy, d.Operation = "rest", "path", "SubscribeToTask"
		if m := restSubscribeTask.FindStringSubmatch(path1); m != nil {
			d.TaskID = m[1]
		}
		d.rule()
	case last == "SubscribeToTask":
		d.Binding, d.DecidedBy, d.Operation = "grpc", "path", "SubscribeToTask"
		d.rule()
	case pyReach:
		d.Binding = "jsonrpc"
		d.jsonrpc(r, setting)
	case goReach && d.goJSONRPC(r, setting):
	case strings.HasPrefix(header(r, "content-type"), "application/grpc"):
		d.Binding, d.DecidedBy, d.Operation = "grpc", "path", last
		d.rule()
	case method == "POST" && (path == "/message:send" || path == "/message:stream"):
		d.Binding, d.DecidedBy = "rest", "path"
		d.Operation = map[string]string{"/message:send": "SendMessage", "/message:stream": "SendStreamingMessage"}[path]
		d.restIdentity(r)
		d.rule()
	default:
		d.Binding, d.DecidedBy, d.Decision, d.Reason = "other", "path", "allow", "not-subscribe"
	}
	if d.LogicalWorkItemID == "" {
		d.LogicalWorkItemID = header(r, "x-logical-work-item-id")
	}
	return d
}

// decodePath is P, the path before its first "?", decoded as Python's
// urllib.parse.unquote decodes it for uvicorn: every %XX with two hex digits
// becomes its byte, anything else stays as written, and the bytes are read as
// UTF-8 with U+FFFD for what is not.
func decodePath(pathAndQuery string) string {
	p, _, _ := strings.Cut(pathAndQuery, "?")
	var b strings.Builder
	for i := 0; i < len(p); i++ {
		if p[i] == '%' && i+2 < len(p) && isHex(p[i+1]) && isHex(p[i+2]) {
			b.WriteByte(unhex(p[i+1])<<4 | unhex(p[i+2]))
			i += 2
			continue
		}
		b.WriteByte(p[i])
	}
	return strings.ToValidUTF8(b.String(), "\uFFFD")
}

func isHex(c byte) bool {
	return '0' <= c && c <= '9' || 'a' <= c && c <= 'f' || 'A' <= c && c <= 'F'
}

func unhex(c byte) byte {
	switch {
	case c <= '9':
		return c - '0'
	case c <= 'F':
		return c - 'A' + 10
	}
	return c - 'a' + 10
}

// workerRoutes is the worker's own routing (internal/workermux), each handler
// replaced by a marker. reachesWorkerJSONRPC asks it where a POST to the path
// would go, the way the worker's server builds the request URL from the request
// target (url.ParseRequestURI): a target Go cannot parse is answered 400 there
// and reaches nothing; a path Go's ServeMux cleans is answered with a redirect.
var workerRoutes = func() http.Handler {
	mark := func(name string) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.Header().Set(routeHeader, name) })
	}
	return workermux.NewRoot(mark("healthz"), mark("inject"), mark("reset"), workermux.NewA2A(mark("card"), mark("rest"), mark("jsonrpc")))
}()

const routeHeader = "X-Extauthz-Route"

func reachesWorkerJSONRPC(pathAndQuery string) bool {
	u, err := url.ParseRequestURI(pathAndQuery)
	if err != nil {
		return false
	}
	w := routeRecorder{http.Header{}}
	workerRoutes.ServeHTTP(w, &http.Request{Method: "POST", URL: u, RequestURI: pathAndQuery, Host: "worker", Header: http.Header{}, Body: http.NoBody})
	return w.h.Get(routeHeader) == "jsonrpc"
}

// routeRecorder keeps the header a marker sets and discards everything else
// (a redirect's or a 404's body).
type routeRecorder struct{ h http.Header }

func (w routeRecorder) Header() http.Header         { return w.h }
func (w routeRecorder) Write(b []byte) (int, error) { return len(b), nil }
func (w routeRecorder) WriteHeader(int)             {}

// a2agoRequest is the shape a2a-go v2.5.0's JSON-RPC handler decodes a request
// into (internal/jsonrpc/jsonrpc.go l.218-223).
type a2agoRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
	ID      any             `json:"id"`
}

// goDecode reads a body as a2a-go's JSON-RPC handler does (a2asrv/jsonrpc.go
// l.63-67): one json.Decoder, the first value only, into the handler's struct.
// An error is a body the handler answers with an error and does not dispatch.
func goDecode(body []byte) (string, error) {
	var req a2agoRequest
	err := json.NewDecoder(bytes.NewReader(body)).Decode(&req)
	return req.Method, err
}

// goJSONRPC is rule 4. It reports whether it decided; when it did not, the body
// adds nothing and rule 5 names the operation from the path.
func (d *decision) goJSONRPC(r *authv3.AttributeContext_HttpRequest, setting string) bool {
	body := []byte(r.GetBody())
	m, err := goDecode(body)
	switch {
	case d.Partial && (errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF)):
		d.Binding = "jsonrpc"
		d.undecidable(setting, "partial-body")
		return true
	case err != nil || m == "":
		return false
	}
	d.Binding, d.DecidedBy, d.Operation = "jsonrpc", "body.method", m
	var b jsonrpcBody
	_ = json.NewDecoder(bytes.NewReader(body)).Decode(&b)
	d.identity(b)
	d.rule()
	return true
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
	body := []byte(strings.TrimPrefix(r.GetBody(), utf8BOM))
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
	d.identity(b)
	var m string
	if json.Unmarshal(b.Method, &m) != nil || m == "" {
		d.undecidable(setting, "no-method")
		return
	}
	d.Operation, d.DecidedBy = m, "body.method"
	d.rule()
}

func (d *decision) identity(b jsonrpcBody) {
	if len(b.ID) > 0 {
		d.JSONRPCID = string(b.ID)
	}
	d.MessageID = b.Params.Message.MessageID
	d.TaskID = b.Params.Message.TaskID
	if b.Params.ID != "" {
		d.TaskID = b.Params.ID
	}
	d.LogicalWorkItemID, _ = b.Params.Message.Metadata["logical_work_item_id"].(string)
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
		var seen []string
		for dec.More() {
			k, err := dec.Token()
			if err != nil {
				return err
			}
			key, ok := k.(string)
			if !ok {
				return errors.New("object key is not a string")
			}
			for _, k := range seen {
				// Case-folded: a2a-go matches member names without case,
				// a2a-python exactly, so two spellings are read differently.
				if strings.EqualFold(k, key) {
					return errDuplicateKey
				}
			}
			seen = append(seen, key)
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
