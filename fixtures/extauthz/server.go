package main

import (
	"context"
	"encoding/json"
	"io"
	"sync"
	"time"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"
	rpcstatus "google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// decisionLine is one line of the decision ledger: one JSON object per check,
// written to stdout BEFORE the check is answered. The identity fields follow
// CLAUDE.md's convention; the rest is what the proxy sent and what was decided.
// The body itself is never written: its length is, and whether the proxy marked
// it partial.
type decisionLine struct {
	Ledger             string   `json:"ledger"`
	TS                 string   `json:"ts"`
	LogicalWorkItemID  string   `json:"logical_work_item_id"`
	MessageID          string   `json:"messageId"`
	TaskID             string   `json:"taskId"`
	JSONRPCID          string   `json:"jsonrpc_id"`
	RequestID          string   `json:"request_id"`
	HTTPMethod         string   `json:"http_method"`
	Path               string   `json:"path"`
	DecodedPath        string   `json:"decoded_path"`
	JSONRPCReach       string   `json:"jsonrpc_reach"`
	Host               string   `json:"host"`
	Protocol           string   `json:"protocol"`
	Binding            string   `json:"binding"`
	Operation          string   `json:"operation"`
	DecidedBy          string   `json:"decided_by"`
	BodyLen            int      `json:"body_len"`
	Size               int64    `json:"size"`
	Partial            bool     `json:"partial"`
	HeaderNames        []string `json:"header_names"`
	SourcePrincipal    string   `json:"source_principal"`
	UndecidableSetting string   `json:"undecidable_setting"`
	Decision           string   `json:"decision"`
	Reason             string   `json:"reason"`
}

type server struct {
	authv3.UnimplementedAuthorizationServer
	mu      sync.Mutex
	out     io.Writer
	setting string
}

func newServer(out io.Writer, setting string) *server {
	return &server{out: out, setting: setting}
}

// newGRPCServer is the server the fixture listens with: grpc-go's defaults, no
// interceptor, no health service. It dials nothing, so there is no client retry
// setting to disable.
func newGRPCServer(s *server) *grpc.Server {
	gs := grpc.NewServer()
	authv3.RegisterAuthorizationServer(gs, s)
	return gs
}

// Check answers one authorization check. It keeps no state between checks and
// caches nothing.
func (s *server) Check(_ context.Context, req *authv3.CheckRequest) (*authv3.CheckResponse, error) {
	attrs := req.GetAttributes()
	http := attrs.GetRequest().GetHttp()
	var d decision
	if http == nil {
		d = decision{Binding: "other"}
		d.undecidable(s.setting, "no-http-attributes")
	} else {
		d = decide(http, s.setting)
	}
	line := decisionLine{
		Ledger: "extauthz", TS: time.Now().UTC().Format(time.RFC3339Nano),
		LogicalWorkItemID: d.LogicalWorkItemID, MessageID: d.MessageID, TaskID: d.TaskID, JSONRPCID: d.JSONRPCID,
		RequestID: http.GetId(), HTTPMethod: http.GetMethod(), Path: http.GetPath(), DecodedPath: d.DecodedPath,
		JSONRPCReach: d.JSONRPCReach, Host: http.GetHost(),
		Protocol: http.GetProtocol(), Binding: d.Binding, Operation: d.Operation, DecidedBy: d.DecidedBy,
		BodyLen: d.BodyLen, Size: d.Size, Partial: d.Partial, HeaderNames: d.HeaderNames,
		SourcePrincipal: attrs.GetSource().GetPrincipal(), UndecidableSetting: s.setting,
		Decision: d.Decision, Reason: d.Reason,
	}
	if line.HeaderNames == nil {
		line.HeaderNames = []string{}
	}
	if err := s.write(line); err != nil {
		// No line, no answer: the proxy's failure mode decides a check the
		// ledger did not record. The write is tried once.
		return nil, status.Errorf(codes.Internal, "extauthz: ledger write failed: %v", err)
	}
	if d.Decision == "allow" {
		return &authv3.CheckResponse{Status: &rpcstatus.Status{Code: int32(codes.OK)}}, nil
	}
	return &authv3.CheckResponse{
		Status: &rpcstatus.Status{Code: int32(codes.PermissionDenied), Message: d.Reason},
		HttpResponse: &authv3.CheckResponse_DeniedResponse{DeniedResponse: &authv3.DeniedHttpResponse{
			Status: &typev3.HttpStatus{Code: typev3.StatusCode_Forbidden},
			Body:   "denied by the lab's extauthz fixture: " + d.Reason + "\n",
		}},
	}, nil
}

func (s *server) write(line decisionLine) error {
	b, err := json.Marshal(line)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err = s.out.Write(b)
	return err
}
