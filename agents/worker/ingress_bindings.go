package main

import (
	"encoding/binary"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	a2apb "github.com/a2aproject/a2a-go/v2/a2apb/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/structpb"
)

// The ingress ledger's reading of the REST and gRPC bindings (follow-on D-2).
// The operation comes from the path, as each binding carries it, and never from
// the SDK: the arrival line is written before the SDK sees the request.

const (
	bindingREST = "rest"
	bindingGRPC = "grpc"

	// grpcServicePrefix is the A2A v1.0 gRPC service's path prefix: package
	// lf.a2a.v1, service A2AService (specification/a2a.proto at 3303592, l.3
	// and l.19; a2a-go v2.5.0 a2apb/v1/a2av1_grpc.pb.go l.25-35).
	grpcServicePrefix = "/lf.a2a.v1.A2AService/"
)

// grpcStreamingOperations are the A2AService's server-streaming methods.
var grpcStreamingOperations = map[string]bool{"SendStreamingMessage": true, "SubscribeToTask": true}

// isGRPC says a request is on the gRPC binding: HTTP/2 with a gRPC content
// type, the test grpc-go's own ServeHTTP applies (server.go l.1107-1108).
func isGRPC(r *http.Request) bool {
	return r.ProtoMajor == 2 && strings.HasPrefix(r.Header.Get("Content-Type"), "application/grpc")
}

// restOperation maps a REST request to its A2A operation by method and path, the
// routes a2asrv.NewRESTHandler serves (a2a-go v2.5.0 a2asrv/rest.go l.51-60 and
// l.211-236): SubscribeToTask answers both GET and POST on /tasks/{id}:subscribe,
// as the SDK does, since the specification says POST (§5.3, §11.3) and the
// proto's http annotation says GET (a2a.proto l.76-80). taskID is the id the
// path names, where it names one.
func restOperation(method, path string) (op, taskID string, ok bool) {
	switch {
	case method == http.MethodPost && path == "/message:send":
		return "SendMessage", "", true
	case method == http.MethodPost && path == "/message:stream":
		return "SendStreamingMessage", "", true
	case method == http.MethodGet && path == "/tasks":
		return "ListTasks", "", true
	case method == http.MethodGet && path == "/extendedAgentCard":
		return "GetExtendedAgentCard", "", true
	}
	rest, found := strings.CutPrefix(path, "/tasks/")
	if !found || rest == "" {
		return "", "", false
	}
	if id, sub, hasSub := strings.Cut(rest, "/"); hasSub {
		// /tasks/{id}/pushNotificationConfigs[/{configId}]
		if !strings.HasPrefix(sub, "pushNotificationConfigs") {
			return "", "", false
		}
		_, configID, hasConfig := strings.Cut(sub, "/")
		switch {
		case method == http.MethodPost && !hasConfig:
			return "CreateTaskPushNotificationConfig", id, true
		case method == http.MethodGet && !hasConfig:
			return "ListTaskPushNotificationConfigs", id, true
		case method == http.MethodGet && configID != "":
			return "GetTaskPushNotificationConfig", id, true
		case method == http.MethodDelete && configID != "":
			return "DeleteTaskPushNotificationConfig", id, true
		}
		return "", "", false
	}
	if id, found := strings.CutSuffix(rest, ":subscribe"); found && (method == http.MethodPost || method == http.MethodGet) {
		return "SubscribeToTask", id, true
	}
	if id, found := strings.CutSuffix(rest, ":cancel"); found && method == http.MethodPost {
		return "CancelTask", id, true
	}
	if method == http.MethodGet && !strings.Contains(rest, ":") {
		return "GetTask", rest, true
	}
	return "", "", false
}

// restBody is the tolerant view of a REST request body: a SendMessageRequest's
// JSON form, as a2a-go's REST client writes it (a2aclient/rest.go l.285-296,
// the a2a.SendMessageRequest's json tags).
type restBody struct {
	Message struct {
		MessageID string         `json:"messageId"`
		TaskID    string         `json:"taskId"`
		ContextID string         `json:"contextId"`
		Metadata  map[string]any `json:"metadata"`
	} `json:"message"`
}

func fillREST(line *ingressLine, r *http.Request, op, taskID string, body []byte) {
	line.Binding = bindingREST
	line.Method = op
	line.TaskID = taskID
	var b restBody
	if len(body) > 0 && json.Unmarshal(body, &b) == nil {
		line.MessageID = b.Message.MessageID
		if line.TaskID == "" {
			line.TaskID = b.Message.TaskID
		}
		line.ContextID = b.Message.ContextID
		if v, ok := b.Message.Metadata["logical_work_item_id"].(string); ok {
			line.LogicalWorkItemID = v
		}
	}
	workItemFromHeader(line, r)
}

// fillGRPC reads the operation from the gRPC path and the identity from the one
// request message, which for every A2AService method is one length-prefixed
// frame (a 1-byte compressed flag, a 4-byte big-endian length, the protobuf
// bytes). A compressed or truncated frame is left unread: the line keeps the
// operation, the hash and the length.
func fillGRPC(line *ingressLine, r *http.Request, body []byte) {
	line.Binding = bindingGRPC
	op, found := strings.CutPrefix(r.URL.Path, grpcServicePrefix)
	if !found || op == "" || strings.Contains(op, "/") {
		line.Method = r.Method + " " + r.URL.Path
		workItemFromHeader(line, r)
		return
	}
	line.Method = op
	if payload, ok := grpcFrame(body); ok {
		switch op {
		case "SendMessage", "SendStreamingMessage":
			var req a2apb.SendMessageRequest
			if proto.Unmarshal(payload, &req) == nil && req.GetMessage() != nil {
				m := req.GetMessage()
				line.MessageID = m.GetMessageId()
				line.TaskID = m.GetTaskId()
				line.ContextID = m.GetContextId()
				line.LogicalWorkItemID = structString(m.GetMetadata(), "logical_work_item_id")
			}
		case "SubscribeToTask":
			var req a2apb.SubscribeToTaskRequest
			if proto.Unmarshal(payload, &req) == nil {
				line.TaskID = req.GetId()
			}
		case "GetTask":
			var req a2apb.GetTaskRequest
			if proto.Unmarshal(payload, &req) == nil {
				line.TaskID = req.GetId()
			}
		case "CancelTask":
			var req a2apb.CancelTaskRequest
			if proto.Unmarshal(payload, &req) == nil {
				line.TaskID = req.GetId()
			}
		}
	}
	workItemFromHeader(line, r)
}

func grpcFrame(body []byte) ([]byte, bool) {
	if len(body) < 5 || body[0] != 0 {
		return nil, false
	}
	n := binary.BigEndian.Uint32(body[1:5])
	if uint64(len(body)-5) < uint64(n) {
		return nil, false
	}
	return body[5 : 5+n], true
}

func structString(s *structpb.Struct, key string) string {
	if s == nil {
		return ""
	}
	return s.GetFields()[key].GetStringValue()
}

// grpcStatusOf reads the grpc-status the gRPC server set once its handler
// returned: grpc-go's ServeHTTP writes it as a trailer, declared or prefixed.
func grpcStatusOf(h http.Header) int {
	for _, k := range []string{"Grpc-Status", http.TrailerPrefix + "Grpc-Status"} {
		if v := h.Get(k); v != "" {
			if n, err := strconv.Atoi(v); err == nil {
				return n
			}
		}
	}
	return -1
}
