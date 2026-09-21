package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"iter"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"

	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
)

// Experiment B's two load-client modes. MODE=stream sends one
// SendStreamingMessage and MODE=subscribe one SubscribeToTask; each writes one
// client line per event and one line for how the stream ended. These tests stand
// up a scripted server that records every request it receives, so what went on
// the wire is counted, not inferred, and one test drives the modes against
// a2a-go's own server.

// rpcSeen is one POST as the scripted server received it.
type rpcSeen struct {
	method   string
	params   json.RawMessage
	id       json.RawMessage
	version  string // the A2A-Version header
	workItem string // the X-Logical-Work-Item-Id header
}

type scriptedServer struct {
	*httptest.Server
	mu    sync.Mutex
	gets  int
	posts []rpcSeen
}

func (s *scriptedServer) seen() (gets int, posts []rpcSeen) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.gets, append([]rpcSeen(nil), s.posts...)
}

// newScriptedServer serves an agent card advertising itself, which declares
// streaming when streaming is true, and hands every POST to answer.
func newScriptedServer(t *testing.T, streaming bool, answer func(w http.ResponseWriter, r *http.Request, rpc rpcSeen)) *scriptedServer {
	t.Helper()
	s := &scriptedServer{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "agent-card.json"):
			s.mu.Lock()
			s.gets++
			s.mu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(&a2a.AgentCard{
				Name: "scripted", Description: "a scripted receiver", Version: "0.0.1",
				Capabilities: a2a.AgentCapabilities{Streaming: streaming},
				SupportedInterfaces: []*a2a.AgentInterface{{
					URL: s.URL, ProtocolBinding: a2a.TransportProtocolJSONRPC, ProtocolVersion: a2a.Version,
				}},
			})
		case r.Method == http.MethodPost:
			raw, _ := io.ReadAll(r.Body)
			var req struct {
				Method string          `json:"method"`
				Params json.RawMessage `json:"params"`
				ID     json.RawMessage `json:"id"`
			}
			_ = json.Unmarshal(raw, &req)
			rpc := rpcSeen{method: req.Method, params: req.Params, id: req.ID,
				version: r.Header.Get("A2A-Version"), workItem: r.Header.Get("X-Logical-Work-Item-Id")}
			s.mu.Lock()
			s.posts = append(s.posts, rpc)
			s.mu.Unlock()
			answer(w, r, rpc)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

func sseStart(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.WriteHeader(http.StatusOK)
	w.(http.Flusher).Flush()
}

func sseEvent(t *testing.T, w http.ResponseWriter, id json.RawMessage, ev a2a.Event) {
	t.Helper()
	b, err := json.Marshal(a2a.StreamResponse{Event: ev})
	if err != nil {
		t.Errorf("marshalling %T: %v", ev, err)
		return
	}
	fmt.Fprintf(w, "data: {\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":%s}\n\n", id, b)
	w.(http.Flusher).Flush()
}

func sseRPCError(w http.ResponseWriter, id json.RawMessage, code int, msg string) {
	fmt.Fprintf(w, "data: {\"jsonrpc\":\"2.0\",\"id\":%s,\"error\":{\"code\":%d,\"message\":%q}}\n\n", id, code, msg)
	w.(http.Flusher).Flush()
}

func taskEvent(state a2a.TaskState) *a2a.Task {
	return &a2a.Task{ID: "task-1", ContextID: "ctx-1", Status: a2a.TaskStatus{State: state}}
}

func statusEvent(state a2a.TaskState) *a2a.TaskStatusUpdateEvent {
	return &a2a.TaskStatusUpdateEvent{TaskID: "task-1", ContextID: "ctx-1", Status: a2a.TaskStatus{State: state}}
}

func artifactEvent() *a2a.TaskArtifactUpdateEvent {
	return &a2a.TaskArtifactUpdateEvent{TaskID: "task-1", ContextID: "ctx-1",
		Artifact: &a2a.Artifact{ID: "a-1", Parts: a2a.ContentParts{a2a.NewTextPart("the answer")}}}
}

// theWholeTask answers a SendStreamingMessage the way the lab's executors do:
// submitted Task, working, the artifact, completed.
func theWholeTask(t *testing.T) func(http.ResponseWriter, *http.Request, rpcSeen) {
	return func(w http.ResponseWriter, _ *http.Request, rpc rpcSeen) {
		sseStart(w)
		sseEvent(t, w, rpc.id, taskEvent(a2a.TaskStateSubmitted))
		sseEvent(t, w, rpc.id, statusEvent(a2a.TaskStateWorking))
		sseEvent(t, w, rpc.id, artifactEvent())
		sseEvent(t, w, rpc.id, statusEvent(a2a.TaskStateCompleted))
	}
}

// runModeLines runs one process's worth of the mode against target with hc, and
// returns the exit status and the client lines it printed.
func runModeLines(t *testing.T, hc *http.Client, target string, m modeConfig) (int, []map[string]any) {
	t.Helper()
	var out bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	code := runMode(ctx, hc, runConfig{target: target, workItem: "lwi-b3", text: "hello", mode: m}, &out)
	var lines []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		if l == "" {
			continue
		}
		var line map[string]any
		if err := json.Unmarshal([]byte(l), &line); err != nil {
			t.Fatalf("client line is not JSON: %v: %s", err, l)
		}
		lines = append(lines, line)
	}
	return code, lines
}

func streamClientForTest() *http.Client {
	return instrument(streamHTTPClient(10*time.Second), "lwi-b3")
}

func linesOf(lines []map[string]any, kind string) []map[string]any {
	var out []map[string]any
	for _, l := range lines {
		if l["line"] == kind {
			out = append(out, l)
		}
	}
	return out
}

// theEnd returns the one end line, failing the test unless there is exactly one
// and it is the last line printed.
func theEnd(t *testing.T, lines []map[string]any) map[string]any {
	t.Helper()
	ends := linesOf(lines, "end")
	if len(ends) != 1 || len(lines) == 0 || lines[len(lines)-1]["line"] != "end" {
		t.Fatalf("want exactly one end line, printed last; got %d in %v", len(ends), lines)
	}
	return ends[0]
}

func wantField(t *testing.T, line map[string]any, key string, want any) {
	t.Helper()
	if got := line[key]; !reflect.DeepEqual(got, want) {
		t.Errorf("%s = %#v, want %#v (line %v)", key, got, want, line)
	}
}

// The switch is off unless the environment names a mode: unset and empty both
// leave the client sending the one SendMessage every earlier run sent. The Job
// template renders MODE and TASK_ID empty on every row that is not a B row, so
// this is the test that keeps those rows what they were.
func TestMode_DefaultOff(t *testing.T) {
	for _, set := range []bool{false, true} {
		if set {
			t.Setenv("MODE", "")
			t.Setenv("TASK_ID", "")
		} else {
			t.Setenv("MODE", "x")
			t.Setenv("TASK_ID", "x")
			unsetenv(t, "MODE")
			unsetenv(t, "TASK_ID")
		}
		m, err := modeFromEnv()
		if err != nil {
			t.Fatalf("set-empty=%v: %v", set, err)
		}
		if m.mode != modeUnary || m.taskID != "" {
			t.Errorf("set-empty=%v: got %+v, want the unary send and no task id", set, m)
		}
	}
}

func unsetenv(t *testing.T, k string) {
	t.Helper()
	if err := os.Unsetenv(k); err != nil {
		t.Fatal(err)
	}
}

// Two values are known. Anything else stops the Job before it sends, and so does
// a task id the mode cannot use or a subscription with none: each of them would
// otherwise run, send something, and be recorded as the row it was not.
func TestModeFromEnv_KnownValuesAndRefusals(t *testing.T) {
	t.Setenv("MODE", "stream")
	t.Setenv("TASK_ID", "")
	if m, err := modeFromEnv(); err != nil || m.mode != modeStream {
		t.Errorf("stream: got %+v, %v", m, err)
	}
	t.Setenv("MODE", "subscribe")
	t.Setenv("TASK_ID", "task-9")
	if m, err := modeFromEnv(); err != nil || m.mode != modeSubscribe || m.taskID != "task-9" {
		t.Errorf("subscribe: got %+v, %v", m, err)
	}
	for _, v := range []string{"Stream", "stream ", " subscribe", "resubscribe", "on", "unary", "1", "${MODE}"} {
		t.Setenv("MODE", v)
		t.Setenv("TASK_ID", "")
		_, err := modeFromEnv()
		if err == nil || !strings.Contains(err.Error(), fmt.Sprintf("%q", v)) {
			t.Errorf("MODE=%q: got %v, want a refusal that names the value", v, err)
		}
	}
	t.Setenv("MODE", "subscribe")
	t.Setenv("TASK_ID", "")
	if _, err := modeFromEnv(); err == nil {
		t.Errorf("MODE=subscribe with no TASK_ID was accepted")
	}
	for _, mode := range []string{"", "stream"} {
		t.Setenv("MODE", mode)
		t.Setenv("TASK_ID", "task-9")
		if _, err := modeFromEnv(); err == nil {
			t.Errorf("MODE=%q with TASK_ID set was accepted; only a subscription names a task", mode)
		}
	}
	t.Setenv("MODE", "subscribe")
	t.Setenv("TASK_ID", "${TASK_ID}")
	if _, err := modeFromEnv(); err == nil {
		t.Errorf("an unsubstituted TASK_ID placeholder was accepted as a task id")
	}
}

// Rule 4: a stream or a subscription is sent once, so neither mode runs with a
// retry knob on. The off values the Job template renders are accepted.
func TestMode_RetryKnobsAreRefusedOnAStreamOrASubscription(t *testing.T) {
	for _, mode := range []clientMode{modeStream, modeSubscribe} {
		if err := checkModeKnobs(mode, knobs{retryOn: httpclient.RetryOnTransport}); err != nil {
			t.Errorf("%s with every knob off: %v", mode, err)
		}
		if err := checkModeKnobs(mode, knobs{retries: 1, retryOn: httpclient.RetryOnTransport}); err == nil {
			t.Errorf("%s with CLIENT_RETRIES=1 was accepted", mode)
		}
		if err := checkModeKnobs(mode, knobs{sdkResend: true, retryOn: httpclient.RetryOnTransport}); err == nil {
			t.Errorf("%s with CLIENT_SDK_RESEND=on was accepted", mode)
		}
	}
	if err := checkModeKnobs(modeUnary, knobs{retries: 1, sdkResend: true}); err != nil {
		t.Errorf("the unary send keeps its A.2 knobs: %v", err)
	}
}

// http.Client.Timeout covers reading the body, so the unary client's would cut
// every stream at that bound by itself. The stream client has none and the
// request context is the bound; every transport setting is the one
// internal/httpclient records for every other client.
func TestStreamClient_HasNoOverallTimeoutAndTheSameTransport(t *testing.T) {
	got := streamHTTPClient(7 * time.Second)
	if got.Timeout != 0 {
		t.Errorf("Timeout = %v, want 0", got.Timeout)
	}
	tr, ok := got.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport is %T, want the plain *http.Transport httpclient.New builds", got.Transport)
	}
	want := httpclient.New(7 * time.Second).Transport.(*http.Transport)
	if tr.ResponseHeaderTimeout != want.ResponseHeaderTimeout || tr.ForceAttemptHTTP2 != want.ForceAttemptHTTP2 ||
		tr.DisableKeepAlives != want.DisableKeepAlives || tr.MaxIdleConns != want.MaxIdleConns ||
		tr.MaxIdleConnsPerHost != want.MaxIdleConnsPerHost || tr.IdleConnTimeout != want.IdleConnTimeout ||
		tr.TLSHandshakeTimeout != want.TLSHandshakeTimeout || tr.Proxy != nil ||
		tr.TLSNextProto == nil || len(tr.TLSNextProto) != 0 {
		t.Errorf("transport settings differ from httpclient.New's: %+v", tr)
	}
}

// The stream: one GET for the card, one POST, and that POST is the streaming
// operation with the work item in the message and in the header. Every event is
// a line, in order, and the end line says how the iteration ended.
func TestStream_OneSendOneLinePerEventThenTheEnd(t *testing.T) {
	srv := newScriptedServer(t, true, theWholeTask(t))
	code, lines := runModeLines(t, streamClientForTest(), srv.URL, modeConfig{mode: modeStream})
	if code != 0 {
		t.Errorf("exit status %d, want 0; lines %v", code, lines)
	}
	gets, posts := srv.seen()
	if gets != 1 || len(posts) != 1 {
		t.Fatalf("server saw %d GET and %d POST, want 1 and 1", gets, len(posts))
	}
	p := posts[0]
	if p.method != "SendStreamingMessage" || p.version != string(a2a.Version) || p.workItem != "lwi-b3" {
		t.Errorf("POST = method %q, A2A-Version %q, work-item header %q", p.method, p.version, p.workItem)
	}
	if !strings.Contains(string(p.params), `"logical_work_item_id":"lwi-b3"`) {
		t.Errorf("the message does not carry the work item: %s", p.params)
	}

	events := linesOf(lines, "event")
	want := []struct{ kind, state string }{
		{"task", "TASK_STATE_SUBMITTED"}, {"status-update", "TASK_STATE_WORKING"},
		{"artifact-update", ""}, {"status-update", "TASK_STATE_COMPLETED"},
	}
	if len(events) != len(want) {
		t.Fatalf("event lines = %d, want %d: %v", len(events), len(want), lines)
	}
	var messageID string
	for i, w := range want {
		e := events[i]
		wantField(t, e, "ledger", "client")
		wantField(t, e, "mode", "stream")
		wantField(t, e, "method", "SendStreamingMessage")
		wantField(t, e, "seq", float64(i+1))
		wantField(t, e, "kind", w.kind)
		wantField(t, e, "taskId", "task-1")
		wantField(t, e, "logical_work_item_id", "lwi-b3")
		if got, _ := e["state"].(string); got != w.state {
			t.Errorf("event %d state = %q, want %q", i+1, got, w.state)
		}
		if _, err := time.Parse(time.RFC3339Nano, e["ts"].(string)); err != nil {
			t.Errorf("event %d ts %v does not parse: %v", i+1, e["ts"], err)
		}
		if i == 0 {
			messageID, _ = e["messageId"].(string)
		} else {
			wantField(t, e, "messageId", messageID)
		}
	}
	if messageID == "" || !strings.Contains(string(p.params), messageID) {
		t.Errorf("messageId %q on the lines is not the one sent: %s", messageID, p.params)
	}

	end := theEnd(t, lines)
	wantField(t, end, "ledger", "client")
	wantField(t, end, "mode", "stream")
	wantField(t, end, "method", "SendStreamingMessage")
	wantField(t, end, "events", float64(4))
	wantField(t, end, "first_kind", "task")
	wantField(t, end, "first_state", "TASK_STATE_SUBMITTED")
	wantField(t, end, "first_task_id", "task-1")
	wantField(t, end, "last_kind", "status-update")
	wantField(t, end, "last_state", "TASK_STATE_COMPLETED")
	wantField(t, end, "taskId", "task-1")
	wantField(t, end, "messageId", messageID)
	wantField(t, end, "terminal_seen", true)
	wantField(t, end, "stream_end", "eof")
	wantField(t, end, "error", "")
	wantField(t, end, "http_status", float64(200))
	wantField(t, end, "content_type", "text/event-stream")
	wantField(t, end, "wire_error_code", float64(0))
	wantField(t, end, "wire_error_message", "")
	wantField(t, end, "posts", float64(1))
	wantField(t, end, "card_streaming", true)
	wantField(t, end, "a2a_version", string(a2a.Version))
	for _, k := range []string{"ts", "ts_sent"} {
		if _, err := time.Parse(time.RFC3339Nano, end[k].(string)); err != nil {
			t.Errorf("end %s %v does not parse: %v", k, end[k], err)
		}
	}
}

// A body that ends cleanly before any terminal event raises nothing in the SDK:
// its reader stops, and the iteration just ends. The end line is what says so.
func TestStream_AQuietEndWithoutATerminalEventIsSaidSo(t *testing.T) {
	srv := newScriptedServer(t, true, func(w http.ResponseWriter, _ *http.Request, rpc rpcSeen) {
		sseStart(w)
		sseEvent(t, w, rpc.id, taskEvent(a2a.TaskStateSubmitted))
		sseEvent(t, w, rpc.id, statusEvent(a2a.TaskStateWorking))
	})
	code, lines := runModeLines(t, streamClientForTest(), srv.URL, modeConfig{mode: modeStream})
	if code != 3 {
		t.Errorf("exit status %d, want 3: the stream ended without a terminal event", code)
	}
	end := theEnd(t, lines)
	wantField(t, end, "events", float64(2))
	wantField(t, end, "terminal_seen", false)
	wantField(t, end, "stream_end", "eof")
	wantField(t, end, "error", "")
	wantField(t, end, "last_state", "TASK_STATE_WORKING")
}

// cutAfterTask sends the submitted Task and then drops the connection in the
// middle of the chunked body, with no terminating chunk.
func cutAfterTask(t *testing.T) func(http.ResponseWriter, *http.Request, rpcSeen) {
	return func(w http.ResponseWriter, _ *http.Request, rpc rpcSeen) {
		sseStart(w)
		sseEvent(t, w, rpc.id, taskEvent(a2a.TaskStateWorking))
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Errorf("hijack: %v", err)
			return
		}
		_ = conn.Close()
	}
}

// A transport cut is an error at the client, recorded with its text, and it is
// the end: the stream mode sends nothing after it, neither the stream again nor
// a subscription.
func TestStream_ACutIsAnErrorAndNothingIsSentAfterIt(t *testing.T) {
	srv := newScriptedServer(t, true, cutAfterTask(t))
	code, lines := runModeLines(t, streamClientForTest(), srv.URL, modeConfig{mode: modeStream})
	if code != 3 {
		t.Errorf("exit status %d, want 3", code)
	}
	end := theEnd(t, lines)
	wantField(t, end, "events", float64(1))
	wantField(t, end, "terminal_seen", false)
	wantField(t, end, "stream_end", "error")
	if msg, _ := end["error"].(string); msg == "" {
		t.Errorf("a cut stream recorded no error text")
	}
	if _, posts := srv.seen(); len(posts) != 1 {
		t.Errorf("server saw %d POSTs, want exactly 1: %+v", len(posts), posts)
	}
}

// The unary client's Timeout would end a stream at that bound by itself; the
// stream client's context is its only bound. Both halves are shown against the
// same server: a stream that outlives a 300 ms Timeout completes on the stream
// client and is cut on the unary one.
func TestStream_OutlivesTheUnaryClientTimeout(t *testing.T) {
	slow := func(w http.ResponseWriter, _ *http.Request, rpc rpcSeen) {
		sseStart(w)
		sseEvent(t, w, rpc.id, taskEvent(a2a.TaskStateWorking))
		time.Sleep(800 * time.Millisecond)
		sseEvent(t, w, rpc.id, statusEvent(a2a.TaskStateCompleted))
	}
	srv := newScriptedServer(t, true, slow)
	code, lines := runModeLines(t, instrument(streamHTTPClient(300*time.Millisecond), "lwi-b3"), srv.URL, modeConfig{mode: modeStream})
	end := theEnd(t, lines)
	if code != 0 || end["stream_end"] != "eof" || end["terminal_seen"] != true {
		t.Errorf("stream client: exit %d, end %v; want the stream to complete past 300 ms", code, end)
	}

	control := newScriptedServer(t, true, slow)
	_, lines = runModeLines(t, instrument(httpclient.New(300*time.Millisecond), "lwi-b3"), control.URL, modeConfig{mode: modeStream})
	end = theEnd(t, lines)
	if end["stream_end"] != "error" {
		t.Errorf("unary client: end %v; want the 300 ms Timeout to cut it, or this test cannot tell the two apart", end)
	}
}

// The card says whether the agent streams, and at a2a-go v2.5.0 the client sends
// a plain SendMessage to one that does not, with no error. The mode does not
// hide it: the end line carries what the card said, and the one POST is what
// the SDK sent.
func TestStream_ACardThatDoesNotStreamIsRecorded(t *testing.T) {
	srv := newScriptedServer(t, false, func(w http.ResponseWriter, _ *http.Request, rpc rpcSeen) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":` + string(rpc.id) +
			`,"result":{"task":{"id":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}}`))
	})
	_, lines := runModeLines(t, streamClientForTest(), srv.URL, modeConfig{mode: modeStream})
	end := theEnd(t, lines)
	wantField(t, end, "card_streaming", false)
	_, posts := srv.seen()
	if len(posts) != 1 || posts[0].method != "SendMessage" {
		t.Errorf("posts = %+v, want the one SendMessage the SDK sends to a card without streaming", posts)
	}
}

// subscribeAnswer answers a SubscribeToTask as a2a-go and a2a-python do for a
// running task: the Task as it stands, then what happens next.
func subscribeAnswer(t *testing.T) func(http.ResponseWriter, *http.Request, rpcSeen) {
	return func(w http.ResponseWriter, _ *http.Request, rpc rpcSeen) {
		sseStart(w)
		sseEvent(t, w, rpc.id, taskEvent(a2a.TaskStateWorking))
		sseEvent(t, w, rpc.id, artifactEvent())
		sseEvent(t, w, rpc.id, statusEvent(a2a.TaskStateCompleted))
	}
}

// The subscription: exactly one SubscribeToTask, for the task it was given, with
// the work item in the header (the request has no Message to carry it). The
// first event is recorded, and so is everything to the end.
func TestSubscribe_ExactlyOneSubscribeToTaskForTheGivenTask(t *testing.T) {
	srv := newScriptedServer(t, true, subscribeAnswer(t))
	code, lines := runModeLines(t, streamClientForTest(), srv.URL, modeConfig{mode: modeSubscribe, taskID: "task-1"})
	if code != 0 {
		t.Errorf("exit status %d, want 0; lines %v", code, lines)
	}
	_, posts := srv.seen()
	if len(posts) != 1 {
		t.Fatalf("server saw %d POSTs, want exactly 1: %+v", len(posts), posts)
	}
	p := posts[0]
	if p.method != "SubscribeToTask" || p.version != string(a2a.Version) || p.workItem != "lwi-b3" {
		t.Errorf("POST = method %q, A2A-Version %q, work-item header %q", p.method, p.version, p.workItem)
	}
	var params struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(p.params, &params); err != nil || params.ID != "task-1" {
		t.Errorf("params = %s, want the id task-1", p.params)
	}
	events := linesOf(lines, "event")
	if len(events) != 3 {
		t.Fatalf("event lines = %d, want 3: %v", len(events), lines)
	}
	wantField(t, events[0], "mode", "subscribe")
	wantField(t, events[0], "method", "SubscribeToTask")
	wantField(t, events[0], "kind", "task")
	wantField(t, events[0], "state", "TASK_STATE_WORKING")
	wantField(t, events[0], "taskId", "task-1")
	wantField(t, events[0], "messageId", "")
	end := theEnd(t, lines)
	wantField(t, end, "mode", "subscribe")
	wantField(t, end, "requested_task_id", "task-1")
	wantField(t, end, "taskId", "task-1")
	wantField(t, end, "first_kind", "task")
	wantField(t, end, "first_state", "TASK_STATE_WORKING")
	wantField(t, end, "first_task_id", "task-1")
	wantField(t, end, "last_state", "TASK_STATE_COMPLETED")
	wantField(t, end, "terminal_seen", true)
	wantField(t, end, "stream_end", "eof")
	wantField(t, end, "posts", float64(1))
	wantField(t, end, "messageId", "")
}

// Rule 4 for the subscription: however its one request ends -- a stream cut
// after the first event, or a status the SDK refuses -- nothing is sent after it.
// The second Job of a B row is a separate stimulus, sent once; this process
// never is one.
func TestSubscribe_NothingIsSentAfterTheOneRequestHoweverItEnds(t *testing.T) {
	for name, answer := range map[string]func(http.ResponseWriter, *http.Request, rpcSeen){
		"cut after the first event": cutAfterTask(t),
		"503": func(w http.ResponseWriter, _ *http.Request, _ rpcSeen) {
			w.WriteHeader(http.StatusServiceUnavailable)
		},
		"quiet end, no terminal event": func(w http.ResponseWriter, _ *http.Request, rpc rpcSeen) {
			sseStart(w)
			sseEvent(t, w, rpc.id, taskEvent(a2a.TaskStateWorking))
		},
	} {
		t.Run(name, func(t *testing.T) {
			srv := newScriptedServer(t, true, answer)
			code, lines := runModeLines(t, streamClientForTest(), srv.URL, modeConfig{mode: modeSubscribe, taskID: "task-1"})
			if code != 3 {
				t.Errorf("exit status %d, want 3", code)
			}
			// Give a would-be second request time to arrive before counting.
			time.Sleep(200 * time.Millisecond)
			if _, posts := srv.seen(); len(posts) != 1 {
				t.Errorf("server saw %d POSTs, want exactly 1: %+v", len(posts), posts)
			}
			end := theEnd(t, lines)
			wantField(t, end, "posts", float64(1))
			if name == "503" {
				wantField(t, end, "http_status", float64(503))
				wantField(t, end, "stream_end", "error")
				wantField(t, end, "events", float64(0))
			}
		})
	}
}

// a2a-python answers a refused SubscribeToTask with a plain JSON body, not an
// event stream, and a2a-go's SSE reader skips every line that is not "data:",
// so the SDK yields nothing and raises nothing. The code and the text are read
// from the bytes the SDK read, which is the only place they exist at the client.
func TestSubscribe_ARefusalInPlainJSONIsRecordedFromTheWire(t *testing.T) {
	srv := newScriptedServer(t, true, func(w http.ResponseWriter, _ *http.Request, rpc rpcSeen) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":` + string(rpc.id) +
			`,"error":{"code":-32602,"message":"Task task-1 is in terminal state: 3"}}`))
	})
	code, lines := runModeLines(t, streamClientForTest(), srv.URL, modeConfig{mode: modeSubscribe, taskID: "task-1"})
	if code != 3 {
		t.Errorf("exit status %d, want 3", code)
	}
	end := theEnd(t, lines)
	wantField(t, end, "events", float64(0))
	wantField(t, end, "error", "")
	wantField(t, end, "stream_end", "eof")
	wantField(t, end, "content_type", "application/json")
	wantField(t, end, "http_status", float64(200))
	wantField(t, end, "wire_error_code", float64(-32602))
	wantField(t, end, "wire_error_message", "Task task-1 is in terminal state: 3")
}

// a2a-go answers the same refusal inside the event stream, where its client
// does see it. The wire code and text are recorded beside the SDK's error.
func TestSubscribe_ARefusalAsAnEventIsRecordedFromTheWire(t *testing.T) {
	srv := newScriptedServer(t, true, func(w http.ResponseWriter, _ *http.Request, rpc rpcSeen) {
		sseStart(w)
		sseRPCError(w, rpc.id, -32001, "task not found: no active execution")
	})
	code, lines := runModeLines(t, streamClientForTest(), srv.URL, modeConfig{mode: modeSubscribe, taskID: "task-1"})
	if code != 3 {
		t.Errorf("exit status %d, want 3", code)
	}
	end := theEnd(t, lines)
	wantField(t, end, "events", float64(0))
	wantField(t, end, "stream_end", "error")
	wantField(t, end, "content_type", "text/event-stream")
	wantField(t, end, "wire_error_code", float64(-32001))
	wantField(t, end, "wire_error_message", "task not found: no active execution")
	if msg, _ := end["error"].(string); !strings.Contains(msg, "task not found: no active execution") {
		t.Errorf("error = %q, want the SDK's error carrying the wire text", msg)
	}
}

// The unary send is what it was: MODE unset goes through runMode to the same
// SendMessage and the same one line, with no key of the stream lines on it.
func TestMode_UnsetSendsTheUnaryMessageAndItsLine(t *testing.T) {
	target, advertised := twoServers(t, http.StatusOK, a2a.Version)
	var out bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	code := runMode(ctx, instrument(httpclient.New(10*time.Second), "lwi-b3"),
		runConfig{target: target.URL, workItem: "lwi-b3", text: "hello", mode: modeConfig{mode: modeUnary}}, &out)
	if code != 0 {
		t.Fatalf("exit status %d: %s", code, out.String())
	}
	if p := advertised.count(http.MethodPost); p != 1 {
		t.Errorf("advertised server saw %d POSTs, want 1", p)
	}
	raw := strings.TrimSpace(out.String())
	if strings.Count(raw, "\n") != 0 {
		t.Fatalf("want one line, got %q", raw)
	}
	var line map[string]any
	if err := json.Unmarshal([]byte(raw), &line); err != nil {
		t.Fatal(err)
	}
	var keys []string
	for k := range line {
		keys = append(keys, k)
	}
	want := []string{"a2a_version", "advertised_urls", "attempt", "card_protocol_versions", "dialled_url", "ledger",
		"logical_work_item_id", "messageId", "result_kind", "state", "taskId", "ts"}
	if !sameSet(keys, want) {
		t.Errorf("unary line keys = %v, want %v", keys, want)
	}
}

func sameSet(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	seen := map[string]int{}
	for _, x := range a {
		seen[x]++
	}
	for _, x := range b {
		seen[x]--
	}
	for _, n := range seen {
		if n != 0 {
			return false
		}
	}
	return true
}

// gatedExecutor is an a2a-go executor shaped like the lab's: a submitted Task,
// working, then it waits for release before the artifact and completed. Each
// execution sends its task id on started.
type gatedExecutor struct {
	started chan a2a.TaskID
	release chan struct{}
	entered chan struct{}
}

func (e *gatedExecutor) Execute(_ context.Context, execCtx *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) {
		e.entered <- struct{}{}
		if execCtx.StoredTask == nil {
			if !yield(a2a.NewSubmittedTask(execCtx, execCtx.Message), nil) {
				return
			}
		}
		if !yield(a2a.NewStatusUpdateEvent(execCtx, a2a.TaskStateWorking, nil), nil) {
			return
		}
		e.started <- execCtx.TaskID
		<-e.release
		if !yield(a2a.NewArtifactEvent(execCtx, a2a.NewTextPart("the answer")), nil) {
			return
		}
		yield(a2a.NewStatusUpdateEvent(execCtx, a2a.TaskStateCompleted, nil), nil)
	}
}

func (e *gatedExecutor) Cancel(_ context.Context, execCtx *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) {
		yield(a2a.NewStatusUpdateEvent(execCtx, a2a.TaskStateCanceled, nil), nil)
	}
}

// Against a2a-go's own server, the shape of a B-3 row in one test: a stream
// whose Task is held running, a subscription sent while it runs (its first
// event the Task, working, with the same task id, and no second execution),
// then a subscription after the Task finished. What the server answers for the
// last one is the terminal-task row's reading at a2a-go v2.5.0 in process.
func TestModes_AgainstTheA2AGoServer(t *testing.T) {
	exec := &gatedExecutor{started: make(chan a2a.TaskID, 2), release: make(chan struct{}), entered: make(chan struct{}, 4)}
	var srvURL string
	mux := http.NewServeMux()
	mux.Handle(a2asrv.WellKnownAgentCardPath, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		a2asrv.NewStaticAgentCardHandler(&a2a.AgentCard{
			Name: "sdk", Description: "a2a-go server", Version: "0.0.1",
			Capabilities:        a2a.AgentCapabilities{Streaming: true},
			SupportedInterfaces: []*a2a.AgentInterface{a2a.NewAgentInterface(srvURL, a2a.TransportProtocolJSONRPC)},
		}).ServeHTTP(w, r)
	}))
	mux.Handle("/", a2asrv.NewJSONRPCHandler(a2asrv.NewHandler(exec)))
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	srvURL = srv.URL
	released := sync.OnceFunc(func() { close(exec.release) })
	t.Cleanup(released)

	type result struct {
		code  int
		lines []map[string]any
	}
	streamDone := make(chan result, 1)
	go func() {
		code, lines := runModeLines(t, streamClientForTest(), srv.URL, modeConfig{mode: modeStream})
		streamDone <- result{code, lines}
	}()
	var taskID a2a.TaskID
	select {
	case taskID = <-exec.started:
	case <-time.After(10 * time.Second):
		t.Fatal("the stream's task never started")
	}

	subDone := make(chan result, 1)
	go func() {
		code, lines := runModeLines(t, streamClientForTest(), srv.URL, modeConfig{mode: modeSubscribe, taskID: string(taskID)})
		subDone <- result{code, lines}
	}()
	// The subscription's first event is written when it attaches; the task is
	// released only after that, so the Task it reports is the running one.
	time.Sleep(300 * time.Millisecond)
	released()

	var stream, sub result
	for _, ch := range []struct {
		name string
		c    chan result
		into *result
	}{{"stream", streamDone, &stream}, {"subscription", subDone, &sub}} {
		select {
		case *ch.into = <-ch.c:
		case <-time.After(10 * time.Second):
			t.Fatalf("the %s never ended", ch.name)
		}
	}
	if len(exec.entered) != 1 {
		t.Errorf("executor entered %d times, want 1: a subscription starts no execution", len(exec.entered))
	}
	se := theEnd(t, stream.lines)
	if stream.code != 0 || se["terminal_seen"] != true || se["taskId"] != string(taskID) {
		t.Errorf("stream: exit %d, end %v", stream.code, se)
	}
	// The first event is the Task as the server's store holds it. In process that
	// store can still read submitted when the executor has already yielded
	// working -- measured here: first_state submitted, then working as an event --
	// so either non-terminal state is the running Task. On the cluster the second
	// Job starts seconds later and the row records which one it got.
	sb := theEnd(t, sub.lines)
	firstState, _ := sb["first_state"].(string)
	if sub.code != 0 || sb["first_kind"] != "task" || a2a.TaskState(firstState).Terminal() || firstState == "" ||
		sb["first_task_id"] != string(taskID) || sb["terminal_seen"] != true || sb["last_state"] != "TASK_STATE_COMPLETED" {
		t.Errorf("subscription: exit %d, end %v", sub.code, sb)
	}

	code, lines := runModeLines(t, streamClientForTest(), srv.URL, modeConfig{mode: modeSubscribe, taskID: string(taskID)})
	end := theEnd(t, lines)
	if code != 3 || end["events"] != float64(0) || end["wire_error_code"] != float64(-32001) {
		t.Errorf("subscription to the finished task: exit %d, end %v; want no event and the wire code -32001", code, end)
	}
	if msg, _ := end["wire_error_message"].(string); msg == "" {
		t.Errorf("the wire text of the refusal was not recorded: %v", end)
	}
}

// main's opening refuses what the helpers refuse: the refusals are wired in, not
// only written. Each case is one that must stop the Job before it sends.
func TestConfigFromEnv_RefusalsAreWiredIn(t *testing.T) {
	base := map[string]string{"TARGET_URL": "http://t.example:8080", "LWI": "lwi-1", "CLIENT_DIAL": "",
		"MODE": "", "TASK_ID": "", "CLIENT_RETRIES": "", "CLIENT_SDK_RESEND": "", "CLIENT_RETRY_ON": "", "TEXT": ""}
	setAll := func(over map[string]string) {
		for k, v := range base {
			t.Setenv(k, v)
		}
		for k, v := range over {
			t.Setenv(k, v)
		}
	}
	setAll(nil)
	c, k, err := configFromEnv()
	if err != nil || c.mode.mode != modeUnary || c.text != "hello" || k.retries != 0 {
		t.Fatalf("defaults: %+v %+v %v", c, k, err)
	}
	setAll(map[string]string{"MODE": "subscribe", "TASK_ID": "task-9", "CLIENT_DIAL": "target"})
	if c, _, err := configFromEnv(); err != nil || c.mode.mode != modeSubscribe || c.mode.taskID != "task-9" || c.dial != dialTarget {
		t.Errorf("subscribe: %+v %v", c, err)
	}
	for name, over := range map[string]map[string]string{
		"no target":                {"TARGET_URL": ""},
		"no work item":             {"LWI": ""},
		"unknown dial":             {"CLIENT_DIAL": "ingress"},
		"unknown mode":             {"MODE": "streaming"},
		"subscribe without a task": {"MODE": "subscribe"},
		"a task without subscribe": {"TASK_ID": "task-9"},
		"stream with a retry":      {"MODE": "stream", "CLIENT_RETRIES": "1"},
		"subscribe with a resend":  {"MODE": "subscribe", "TASK_ID": "task-9", "CLIENT_SDK_RESEND": "on"},
		"placeholder left in MODE": {"MODE": "${MODE}"},
		"placeholder left in TASK": {"MODE": "subscribe", "TASK_ID": "${TASK_ID}"},
	} {
		setAll(over)
		if _, _, err := configFromEnv(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

// The unary send keeps the knobs' client, 90 s Timeout included; the two B modes
// get the stream client, whatever the knobs say (they cannot say anything:
// configFromEnv refuses a retry knob with either mode).
func TestHTTPClientFor(t *testing.T) {
	if hc := httpClientFor(modeUnary, knobs{}, 90*time.Second); hc.Timeout != 90*time.Second {
		t.Errorf("unary Timeout = %v, want 90s", hc.Timeout)
	}
	if _, plain := httpClientFor(modeUnary, knobs{retries: 1}, time.Second).Transport.(*http.Transport); plain {
		t.Errorf("unary with CLIENT_RETRIES=1 lost its retrying client")
	}
	for _, m := range []clientMode{modeStream, modeSubscribe} {
		hc := httpClientFor(m, knobs{}, 90*time.Second)
		if hc.Timeout != 0 {
			t.Errorf("%s Timeout = %v, want 0", m, hc.Timeout)
		}
		if tr, ok := hc.Transport.(*http.Transport); !ok || tr.ResponseHeaderTimeout != 90*time.Second {
			t.Errorf("%s transport = %T, want the plain transport with a 90s header timeout", m, hc.Transport)
		}
	}
}

// The observer counts every POST and keeps the first one's status, type and
// bytes; it counts no GET, and a body longer than it keeps still reads whole.
func TestWireObserver_CountsEveryPostAndKeepsTheFirst(t *testing.T) {
	big := strings.Repeat("x", maxObservedBody+1024)
	n := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			return
		}
		n++
		if n == 1 {
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"first"}}` + big))
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusTeapot)
	}))
	t.Cleanup(srv.Close)
	obs := &wireObserver{base: http.DefaultTransport}
	hc := &http.Client{Transport: obs}
	if r, err := hc.Get(srv.URL); err == nil {
		_ = r.Body.Close()
	}
	for i := 0; i < 2; i++ {
		r, err := hc.Post(srv.URL, "application/json", strings.NewReader("{}"))
		if err != nil {
			t.Fatal(err)
		}
		got, _ := io.ReadAll(r.Body)
		_ = r.Body.Close()
		if i == 0 && len(got) != len(big)+len(`{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"first"}}`) {
			t.Errorf("the caller read %d bytes through the observer, want the whole body", len(got))
		}
	}
	posts, status, ct := obs.facts()
	if posts != 2 || status != 200 || ct != "application/json" {
		t.Errorf("facts = %d posts, status %d, %q; want 2, 200 and the first answer's type", posts, status, ct)
	}
	if len(obs.body.Bytes()) != maxObservedBody {
		t.Errorf("kept %d bytes, want the cap %d", len(obs.body.Bytes()), maxObservedBody)
	}
	// The kept prefix holds the error object, followed by bytes that make the
	// whole prefix invalid JSON: the plain-JSON reading is of the whole body, so a
	// body past the cap reads as no error rather than as a wrong one.
	if code, msg := obs.wireError(); code != 0 || msg != "" {
		t.Errorf("wireError on a truncated non-JSON prefix = %d %q, want none", code, msg)
	}
}
