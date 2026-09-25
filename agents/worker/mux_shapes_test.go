package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"iter"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
)

// Follow-on D-3b: what this receiver's own handler chain dispatches for each
// request shape the routing reading listed, pinned before the worker's two
// pattern sets moved to internal/workermux and held after it. The extauthz
// fixture replays the same pattern sets (fixtures/extauthz), so a change here is
// a change to what that fixture reads as reaching the JSON-RPC handler.

// dispatchRecorder is a RequestHandler that records which operation the SDK
// dispatched to it and answers each with an error, so nothing runs further.
type dispatchRecorder struct {
	a2asrv.RequestHandler
	mu  sync.Mutex
	got []string
}

func (d *dispatchRecorder) record(op string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.got = append(d.got, op)
}

func (d *dispatchRecorder) take() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	s := strings.Join(d.got, ",")
	d.got = nil
	if s == "" {
		return "-"
	}
	return s
}

func (d *dispatchRecorder) SubscribeToTask(_ context.Context, r *a2a.SubscribeToTaskRequest) iter.Seq2[a2a.Event, error] {
	d.record("SubscribeToTask(" + string(r.ID) + ")")
	return func(yield func(a2a.Event, error) bool) { yield(nil, a2a.ErrTaskNotFound) }
}

func (d *dispatchRecorder) SendMessage(context.Context, *a2a.SendMessageRequest) (a2a.SendMessageResult, error) {
	d.record("SendMessage")
	return nil, a2a.ErrInvalidParams
}

func (d *dispatchRecorder) GetTask(_ context.Context, r *a2a.GetTaskRequest) (*a2a.Task, error) {
	d.record("GetTask(" + string(r.ID) + ")")
	return nil, a2a.ErrTaskNotFound
}

const shapeSubscribeBody = `{"jsonrpc":"2.0","id":"1","method":"SubscribeToTask","params":{"id":"t9"}}`

// muxShapes8080 are the HTTP/1.1 shapes, each read by http.ReadRequest as the
// server reads a request line, with what this chain answered and dispatched.
var muxShapes8080 = []struct {
	method, target, contentType, body string
	status                            int
	dispatched                        string
}{
	// D-3's four.
	{"POST", "/x", "application/json", shapeSubscribeBody, 200, "SubscribeToTask(t9)"},
	{"POST", "/a2a/v1", "application/json", shapeSubscribeBody, 200, "SubscribeToTask(t9)"},
	{"POST", "/", "application/grpc", shapeSubscribeBody, 200, "SubscribeToTask(t9)"},
	{"POST", "/tasks/t9%3Asubscribe", "", "", 200, "SubscribeToTask(t9)"},
	// New shapes this receiver dispatches.
	{"POST", "/%0A", "application/json", shapeSubscribeBody, 200, "SubscribeToTask(t9)"},
	{"POST", "/message:send/", "application/json", shapeSubscribeBody, 200, "SubscribeToTask(t9)"},
	{"POST", "/lf.a2a.v1.A2AService/SendMessage", "application/grpc", shapeSubscribeBody, 200, "SubscribeToTask(t9)"},
	{"POST", "/tasks/t9:subscribe", "application/grpc", "", 200, "SubscribeToTask(t9)"},
	{"HEAD", "/tasks/t9:subscribe", "", "", 200, "SubscribeToTask(t9)"},
	{"POST", "/tasks/t9:%73ubscribe", "", "", 200, "SubscribeToTask(t9)"},
	{"POST", "/%74asks/t9:subscribe", "", "", 200, "SubscribeToTask(t9)"},
	{"POST", "/tasks/t9%3asubscribe", "", "", 200, "SubscribeToTask(t9)"},
	{"POST", "/", "application/json", `{"jsonrpc":"2.0","id":"1","METHOD":"SubscribeToTask","params":{"id":"t9"}}`, 200, "SubscribeToTask(t9)"},
	{"POST", "/", "application/json", `{"jsonrpc":"2.0","id":"1","method":"Subscribe\u0054oTask","params":{"id":"t9"}}`, 200, "SubscribeToTask(t9)"},
	{"POST", "/", "application/json", shapeSubscribeBody + ` trailing`, 200, "SubscribeToTask(t9)"},
	{"POST", "/tasks/a%2Fb:subscribe", "", "", 200, "SubscribeToTask(a/b)"},
	{"GET", "/tasks/t9:subscribe", "", "", 200, "SubscribeToTask(t9)"},
	{"POST", "/?x=1", "application/json", shapeSubscribeBody, 200, "SubscribeToTask(t9)"},
	{"POST", "/healthz/", "application/json", shapeSubscribeBody, 200, "SubscribeToTask(t9)"},
	{"POST", "/tenant/tasks/t9:subscribe", "application/json", shapeSubscribeBody, 200, "SubscribeToTask(t9)"},
	// Shapes this receiver does not dispatch as SubscribeToTask.
	{"POST", "/tasks%2Ft9:subscribe", "", "", 200, "-"},
	{"POST", "/tasks/t9:subscribe%0A", "", "", 400, "-"},
	{"POST", "/", "application/json", "\xef\xbb\xbf" + shapeSubscribeBody, 200, "-"},
	{"POST", "/", "application/json", "{\x00\"\x00", 200, "-"},
	{"POST", "/", "application/json", `{"jsonrpc":"2.0","id":"1","method":"subscribetotask","params":{"id":"t9"}}`, 200, "-"},
	{"POST", "/tasks/t9%253Asubscribe", "", "", 400, "-"},
	{"GET", "/tasks/t9%253Asubscribe", "", "", 404, "GetTask(t9%3Asubscribe)"},
	{"POST", "//tasks/t9:subscribe", "", "", 307, "-"},
	{"POST", "/tasks/./t9:subscribe", "", "", 307, "-"},
	{"POST", "//", "application/json", shapeSubscribeBody, 307, "-"},
	{"POST", "/tasks/t9:subscribe/", "", "", 404, "-"},
	{"POST", "/tasks/t9:Subscribe", "", "", 400, "-"},
	{"POST", "/Tasks/t9:subscribe", "", "", 200, "-"},
	{"POST", "/tenant/tasks/t9:subscribe", "", "", 200, "-"},
	{"PUT", "/tasks/t9:subscribe", "", "", 405, "-"},
	{"POST", "/message:send", "application/json", shapeSubscribeBody, 400, "SendMessage"},
	{"POST", "/message%3Asend", "application/json", shapeSubscribeBody, 400, "SendMessage"},
}

func TestMux_8080_WhatEachShapeDispatches(t *testing.T) {
	rec := &dispatchRecorder{}
	var out syncBuffer
	h := newServerHandler("worker", newA2AMux(buildCard("worker", "http://worker", "worker:8081"), rec), newLineWriter(&out), newInjector())
	for _, tc := range muxShapes8080 {
		t.Run(tc.method+" "+tc.target, func(t *testing.T) {
			raw := fmt.Sprintf("%s %s HTTP/1.1\r\nHost: worker.lab.internal\r\nA2A-Version: 1.0\r\n", tc.method, tc.target)
			if tc.contentType != "" {
				raw += "Content-Type: " + tc.contentType + "\r\n"
			}
			raw += fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(tc.body), tc.body)
			req, err := http.ReadRequest(bufio.NewReader(strings.NewReader(raw)))
			if err != nil {
				t.Fatal(err)
			}
			w := httptest.NewRecorder()
			h.ServeHTTP(w, req)
			if got := rec.take(); w.Code != tc.status || got != tc.dispatched {
				t.Errorf("status %d dispatched %s; want %d %s", w.Code, got, tc.status, tc.dispatched)
			}
		})
	}
}

// The gRPC port: each :path as net/http's HTTP/2 server turns it into the
// request URL (url.ParseRequestURI, go1.27.1 net/http/internal/httpcommon
// l.611), a SubscribeToTaskRequest{id: "t9"} frame for body.
func TestMux_8081_WhatEachGRPCPathDispatches(t *testing.T) {
	rec := &dispatchRecorder{}
	var out syncBuffer
	h := newServerHandler("worker", newGRPCHandler(rec), newLineWriter(&out), newInjector())
	pb := []byte{0x12, 0x02, 't', '9'} // field 2, id (a2apb/v1 a2av1.pb.go l.3263)
	frame := make([]byte, 5+len(pb))
	binary.BigEndian.PutUint32(frame[1:5], uint32(len(pb)))
	copy(frame[5:], pb)
	for _, tc := range []struct {
		path, dispatched string
		status           int
	}{
		{"/lf.a2a.v1.A2AService/SubscribeToTask", "SubscribeToTask(t9)", 200},
		{"/lf.a2a.v1.A2AService/Subscribe%54oTask", "SubscribeToTask(t9)", 200},
		{"/lf.a2a.v1.A2AService%2FSubscribeToTask", "SubscribeToTask(t9)", 200},
		{"/lf.a2a.v1.A2AService/SubscribeToTask?x=1", "SubscribeToTask(t9)", 200},
		{"//lf.a2a.v1.A2AService/SubscribeToTask", "-", 307},
		{"/lf.a2a.v1.A2AService/SubscribeToTask/", "-", 200},
		{"/lf.a2a.v1.A2AService/SubscribeToTask%0A", "-", 200},
		{"/lf.a2a.v1.A2AService/subscribetotask", "-", 200},
	} {
		t.Run(tc.path, func(t *testing.T) {
			u, err := url.ParseRequestURI(tc.path)
			if err != nil {
				t.Fatal(err)
			}
			req := (&http.Request{Method: "POST", URL: u, Proto: "HTTP/2.0", ProtoMajor: 2, RequestURI: tc.path, Host: "worker-grpc.lab.internal",
				Header: http.Header{"Content-Type": {"application/grpc"}, "Te": {"trailers"}}, ContentLength: -1,
				Body: io.NopCloser(bytes.NewReader(frame))}).WithContext(context.Background())
			w := httptest.NewRecorder()
			h.ServeHTTP(w, req)
			if got := rec.take(); w.Code != tc.status || got != tc.dispatched {
				t.Errorf("status %d dispatched %s; want %d %s", w.Code, got, tc.status, tc.dispatched)
			}
		})
	}
}
