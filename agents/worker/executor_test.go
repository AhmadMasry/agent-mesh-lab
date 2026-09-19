package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
	otelapi "go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
)

// fakeModel answers like the mock model: fixed text, or a status code when told to fail.
type fakeModel struct {
	calls   atomic.Int32
	headers chan http.Header
	bodies  chan map[string]any
	status  int
}

func newFakeModel(status int) (*fakeModel, *httptest.Server) {
	f := &fakeModel{headers: make(chan http.Header, 8), bodies: make(chan map[string]any, 8), status: status}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.calls.Add(1)
		f.headers <- r.Header.Clone()
		var body map[string]any
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &body)
		f.bodies <- body
		if f.status != http.StatusOK {
			w.WriteHeader(f.status)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"chatcmpl-x","object":"chat.completion","created":1,"model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"the fixed answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`))
	}))
	return f, srv
}

func TestModelClient_SendsIdentityHeadersAndReturnsText(t *testing.T) {
	f, srv := newFakeModel(http.StatusOK)
	defer srv.Close()
	mc := newModelClient(srv.URL+"/v1", "mock", "unused", httpclient.New(5*time.Second))
	text, err := mc.complete(context.Background(), identity{WorkItem: "w1", MessageID: "m1", TaskID: "t1", Caller: "worker"}, "lwi:w1 hi")
	if err != nil || text != "the fixed answer" {
		t.Fatalf("complete: %q, %v", text, err)
	}
	h := <-f.headers
	for k, want := range map[string]string{"X-Logical-Work-Item-Id": "w1", "X-A2A-Message-Id": "m1", "X-A2A-Task-Id": "t1", "X-Caller": "worker", "Authorization": "Bearer unused"} {
		if got := h.Get(k); got != want {
			t.Errorf("header %s = %q, want %q", k, got, want)
		}
	}
	body := <-f.bodies
	if body["model"] != "mock" || body["stream"] == true {
		t.Errorf("body = %v", body)
	}
}

func TestModelClient_DoesNotRetryOn500(t *testing.T) {
	f, srv := newFakeModel(http.StatusInternalServerError)
	defer srv.Close()
	mc := newModelClient(srv.URL+"/v1", "mock", "unused", httpclient.New(5*time.Second))
	if _, err := mc.complete(context.Background(), identity{WorkItem: "w1"}, "x"); err == nil {
		t.Fatalf("want an error on 500")
	}
	if n := f.calls.Load(); n != 1 {
		t.Fatalf("model called %d times, want exactly 1", n)
	}
}

func sendThroughSDK(t *testing.T, ex a2asrv.AgentExecutor, lw *lineWriter) *a2a.Task {
	t.Helper()
	h := newExecutionLedger(a2asrv.NewHandler(ex), lw)
	msg := a2a.NewMessage(a2a.MessageRoleUser, a2a.NewTextPart("lwi:w1 hi"))
	msg.ID = "msg-1"
	msg.Metadata = map[string]any{"logical_work_item_id": "w1"}
	res, err := h.SendMessage(context.Background(), &a2a.SendMessageRequest{Message: msg})
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	task, ok := res.(*a2a.Task)
	if !ok {
		t.Fatalf("result is %T, want *a2a.Task", res)
	}
	return task
}

func TestExecutor_CompletesTaskWithModelTextAndRecordsStates(t *testing.T) {
	f, srv := newFakeModel(http.StatusOK)
	defer srv.Close()
	var out bytes.Buffer
	lw := newLineWriter(&out)
	ex := newLabExecutor("worker", newModelClient(srv.URL+"/v1", "mock", "unused", httpclient.New(5*time.Second)), lw)
	task := sendThroughSDK(t, ex, lw)
	if task.Status.State != a2a.TaskStateCompleted {
		t.Fatalf("state = %s, want completed", task.Status.State)
	}
	if len(task.Artifacts) != 1 || len(task.Artifacts[0].Parts) != 1 || task.Artifacts[0].Parts[0].Content != a2a.Text("the fixed answer") {
		t.Errorf("artifacts = %+v, want one text artifact with the model text", task.Artifacts)
	}
	if n := f.calls.Load(); n != 1 {
		t.Errorf("model called %d times, want 1", n)
	}
	h := <-f.headers
	if h.Get("X-A2A-Task-Id") != string(task.ID) || h.Get("X-A2A-Message-Id") != "msg-1" || h.Get("X-Logical-Work-Item-Id") != "w1" {
		t.Errorf("identity headers on the model call = %v", h)
	}
	states := stateSequence(t, out.String())
	if strings.Join(states, ",") != "TASK_STATE_SUBMITTED,TASK_STATE_WORKING,TASK_STATE_COMPLETED" {
		t.Errorf("state lines = %v", states)
	}
}

func TestExecutor_FailsTaskOnModelErrorWithoutRetry(t *testing.T) {
	f, srv := newFakeModel(http.StatusInternalServerError)
	defer srv.Close()
	var out bytes.Buffer
	lw := newLineWriter(&out)
	ex := newLabExecutor("worker", newModelClient(srv.URL+"/v1", "mock", "unused", httpclient.New(5*time.Second)), lw)
	task := sendThroughSDK(t, ex, lw)
	if task.Status.State != a2a.TaskStateFailed {
		t.Fatalf("state = %s, want failed", task.Status.State)
	}
	if task.Status.Message == nil || len(task.Status.Message.Parts) == 0 {
		t.Errorf("failed task carries no error message")
	}
	if n := f.calls.Load(); n != 1 {
		t.Errorf("model called %d times, want exactly 1", n)
	}
	states := stateSequence(t, out.String())
	if strings.Join(states, ",") != "TASK_STATE_SUBMITTED,TASK_STATE_WORKING,TASK_STATE_FAILED" {
		t.Errorf("state lines = %v", states)
	}
}

func stateSequence(t *testing.T, ledger string) []string {
	t.Helper()
	var states []string
	for _, l := range executionLines(t, ledger) {
		if l.Event == "state" {
			states = append(states, l.State)
		}
	}
	return states
}

// executionLines parses every execution ledger line in order.
func executionLines(t *testing.T, ledger string) []executionLine {
	t.Helper()
	var lines []executionLine
	for _, raw := range strings.Split(strings.TrimSpace(ledger), "\n") {
		if raw == "" {
			continue
		}
		var l executionLine
		if err := json.Unmarshal([]byte(raw), &l); err != nil {
			t.Fatalf("bad line %q: %v", raw, err)
		}
		lines = append(lines, l)
	}
	return lines
}

// "Dispatched" must mean the executor ran, not that the SDK accepted the
// request, so the executor writes its own entry line before the first Task
// state it emits. The executor gets its own writer here so the assertion is
// about what the executor wrote, not about the wrapper's lines around it.
func TestExecute_WritesExecuteLineBeforeSubmittedState(t *testing.T) {
	f, srv := newFakeModel(http.StatusOK)
	defer srv.Close()
	var exOut, wrapOut bytes.Buffer
	ex := newLabExecutor("worker", newModelClient(srv.URL+"/v1", "mock", "unused", httpclient.New(5*time.Second)), newLineWriter(&exOut))
	h := newExecutionLedger(a2asrv.NewHandler(ex), newLineWriter(&wrapOut))
	msg := a2a.NewMessage(a2a.MessageRoleUser, a2a.NewTextPart("lwi:w1 hi"))
	msg.ID = "msg-1"
	msg.Metadata = map[string]any{"logical_work_item_id": "w1"}
	res, err := h.SendMessage(context.Background(), &a2a.SendMessageRequest{Message: msg})
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	task, ok := res.(*a2a.Task)
	if !ok {
		t.Fatalf("result is %T, want *a2a.Task", res)
	}
	if n := f.calls.Load(); n != 1 {
		t.Errorf("model called %d times, want 1", n)
	}
	lines := executionLines(t, exOut.String())
	if len(lines) < 2 {
		t.Fatalf("executor wrote %d lines, want at least an execute line and a state line: %q", len(lines), exOut.String())
	}
	first := lines[0]
	if first.Event != "execute" {
		t.Fatalf("first executor line is event %q, want execute: %q", first.Event, exOut.String())
	}
	if first.MessageID != "msg-1" || first.LogicalWorkItemID != "w1" {
		t.Errorf("execute line identity = %+v, want messageId msg-1 and work item w1", first)
	}
	if first.TaskID != string(task.ID) || first.ContextID != task.ContextID {
		t.Errorf("execute line task/context = %q/%q, want %q/%q", first.TaskID, first.ContextID, task.ID, task.ContextID)
	}
	if lines[1].Event != "state" || lines[1].State != string(a2a.TaskStateSubmitted) {
		t.Errorf("second executor line = %+v, want the submitted state line", lines[1])
	}
	if n := len(executeLines(lines)); n != 1 {
		t.Errorf("execute lines = %d, want exactly 1", n)
	}
}

func executeLines(lines []executionLine) []executionLine {
	var out []executionLine
	for _, l := range lines {
		if l.Event == "execute" {
			out = append(out, l)
		}
	}
	return out
}

// TestModelClient_EmitsAChatSpanCarryingTheEndpointsCounts is the worker's half
// of the GenAI semantic conventions: internal/otel states what the span says,
// this states that the model client puts one around its call and reads the
// endpoint's own answer onto it. The conventions' names and rules are quoted in
// internal/otel/otel.go beside the document revision they were read from.
func TestModelClient_EmitsAChatSpanCarryingTheEndpointsCounts(t *testing.T) {
	// The provider is process-wide, so it is put back afterwards: without this
	// every later test in this package would record spans it never asked for.
	// internal/otel/otel_test.go documents the same hazard.
	previous := otelapi.GetTracerProvider()
	t.Cleanup(func() { otelapi.SetTracerProvider(previous) })
	sr := tracetest.NewSpanRecorder()
	otelapi.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr)))

	f, srv := newFakeModel(http.StatusOK)
	defer srv.Close()
	mc := newModelClient(srv.URL+"/v1", "mock", "unused", httpclient.New(5*time.Second))

	text, err := mc.complete(context.Background(), identity{WorkItem: "w1", MessageID: "m1", TaskID: "t1", Caller: "worker"}, "hi")
	if err != nil || text != "the fixed answer" {
		t.Fatalf("complete: %q, %v", text, err)
	}
	// The span is around the call, not an extra call: the endpoint saw one request.
	if got := f.calls.Load(); got != 1 {
		t.Fatalf("requests that reached the endpoint: got %d, want 1", got)
	}

	var chat sdktrace.ReadOnlySpan
	for _, span := range sr.Ended() {
		if span.Name() == "chat mock" {
			chat = span
		}
	}
	if chat == nil {
		t.Fatalf("no span named %q; spans ended: %v", "chat mock", spanNames(sr.Ended()))
	}
	got := map[string]string{}
	for _, kv := range chat.Attributes() {
		got[string(kv.Key)] = kv.Value.Emit()
	}
	want := map[string]string{
		"gen_ai.operation.name": "chat",
		"gen_ai.provider.name":  "openai",
		"gen_ai.request.model":  "mock",
		// The fake answers the same shape the mock does; these are its values.
		"gen_ai.response.id":             "chatcmpl-x",
		"gen_ai.response.model":          "mock",
		"gen_ai.response.finish_reasons": `["stop"]`,
		"gen_ai.usage.input_tokens":      "1",
		"gen_ai.usage.output_tokens":     "1",
		"lab.work_item":                  "w1",
		"lab.message_id":                 "m1",
		"lab.task_id":                    "t1",
		"lab.caller":                     "worker",
	}
	for key, value := range want {
		if got[key] != value {
			t.Errorf("chat span attribute %s: got %q, want %q", key, got[key], value)
		}
	}
	// server.address and server.port name the endpoint this client was built for,
	// which the test server picks a port for at random.
	host, port, err := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	if err != nil {
		t.Fatalf("reading the test server's address: %v", err)
	}
	if got["server.address"] != host || got["server.port"] != port {
		t.Errorf("chat span server.address/server.port: got %q and %q, want %q and %q",
			got["server.address"], got["server.port"], host, port)
	}
}

// TestModelClient_AFailedCallRecordsTheStatusAsErrorType states what the
// conventions ask of error.type -- "the error code returned by the Generative AI
// provider", with `500` among their example values -- rather than what the Go
// error happens to be.
func TestModelClient_AFailedCallRecordsTheStatusAsErrorType(t *testing.T) {
	previous := otelapi.GetTracerProvider()
	t.Cleanup(func() { otelapi.SetTracerProvider(previous) })
	sr := tracetest.NewSpanRecorder()
	otelapi.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr)))

	_, srv := newFakeModel(http.StatusServiceUnavailable)
	defer srv.Close()
	mc := newModelClient(srv.URL+"/v1", "mock", "unused", httpclient.New(5*time.Second))

	_, err := mc.complete(context.Background(), identity{WorkItem: "w1", Caller: "worker"}, "hi")
	if err == nil {
		t.Fatal("a 503 from the endpoint returned no error")
	}
	// The message the call has always failed with, unchanged.
	if err.Error() != "model call: status 503" {
		t.Errorf("error text: got %q, want %q", err.Error(), "model call: status 503")
	}

	var chat sdktrace.ReadOnlySpan
	for _, span := range sr.Ended() {
		if span.Name() == "chat mock" {
			chat = span
		}
	}
	if chat == nil {
		t.Fatalf("no span named %q; spans ended: %v", "chat mock", spanNames(sr.Ended()))
	}
	for _, kv := range chat.Attributes() {
		if string(kv.Key) == "error.type" {
			if kv.Value.Emit() != "503" {
				t.Errorf("error.type: got %q, want %q", kv.Value.Emit(), "503")
			}
			return
		}
	}
	t.Error("the failed chat span carries no error.type")
}

// chatSpanOf is the one `chat mock` span a recorder holds, with its attributes
// read as strings.
func chatSpanOf(t *testing.T, sr *tracetest.SpanRecorder) (sdktrace.ReadOnlySpan, map[string]string) {
	t.Helper()
	var chat sdktrace.ReadOnlySpan
	for _, span := range sr.Ended() {
		if span.Name() == "chat mock" {
			chat = span
		}
	}
	if chat == nil {
		t.Fatalf("no span named %q; spans ended: %v", "chat mock", spanNames(sr.Ended()))
	}
	attrs := map[string]string{}
	for _, kv := range chat.Attributes() {
		attrs[string(kv.Key)] = kv.Value.Emit()
	}
	return chat, attrs
}

// TestModelClient_AFailedCallsSpanStatusIsTheReturnedErrorsText pins what the
// author decided on 2026-09-19 to KEEP: the chat span of a failed model call
// carries status Error with a description equal, byte for byte, to the text of
// the error the call returned, beside error.type = the status. The description is
// what lets a reader match a trace to the ledgers, which carry the same text (the
// test below this one). Nothing here changes behaviour; before this test only
// internal/otel pinned a description, and only for an error made by hand.
func TestModelClient_AFailedCallsSpanStatusIsTheReturnedErrorsText(t *testing.T) {
	for _, status := range []int{http.StatusServiceUnavailable, http.StatusInternalServerError} {
		previous := otelapi.GetTracerProvider()
		t.Cleanup(func() { otelapi.SetTracerProvider(previous) })
		sr := tracetest.NewSpanRecorder()
		otelapi.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr)))

		_, srv := newFakeModel(status)
		mc := newModelClient(srv.URL+"/v1", "mock", "unused", httpclient.New(5*time.Second))
		_, err := mc.complete(context.Background(), identity{WorkItem: "w1", Caller: "worker"}, "hi")
		srv.Close()
		if err == nil {
			t.Fatalf("a %d from the endpoint returned no error", status)
		}
		want := "model call: status " + strconv.Itoa(status)
		if err.Error() != want {
			t.Errorf("error text: got %q, want %q", err.Error(), want)
		}

		chat, attrs := chatSpanOf(t, sr)
		if st := chat.Status(); st.Code != codes.Error || st.Description != err.Error() {
			t.Errorf("chat span status: got %s %q, want Error and the returned error's text %q", st.Code, st.Description, err.Error())
		}
		if got := attrs["error.type"]; got != strconv.Itoa(status) {
			t.Errorf("error.type: got %q, want %q", got, strconv.Itoa(status))
		}
	}
}

// TestExecutor_AFailedModelCallReadsTheSameInTheTraceAndTheLedger is the reason
// the description is kept: the execution ledger's FAILED state line and the chat
// span's status description are the same text, so a row of one finds the other.
func TestExecutor_AFailedModelCallReadsTheSameInTheTraceAndTheLedger(t *testing.T) {
	previous := otelapi.GetTracerProvider()
	t.Cleanup(func() { otelapi.SetTracerProvider(previous) })
	sr := tracetest.NewSpanRecorder()
	otelapi.SetTracerProvider(sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(sr)))

	_, srv := newFakeModel(http.StatusServiceUnavailable)
	defer srv.Close()
	var out bytes.Buffer
	lw := newLineWriter(&out)
	ex := newLabExecutor("worker", newModelClient(srv.URL+"/v1", "mock", "unused", httpclient.New(5*time.Second)), lw)
	if task := sendThroughSDK(t, ex, lw); task.Status.State != a2a.TaskStateFailed {
		t.Fatalf("state = %s, want failed", task.Status.State)
	}

	var ledgerText string
	for _, l := range executionLines(t, out.String()) {
		if l.Event == "state" && l.State == string(a2a.TaskStateFailed) {
			ledgerText = l.Error
		}
	}
	if ledgerText != "model call: status 503" {
		t.Fatalf("execution ledger FAILED line error: got %q, want %q", ledgerText, "model call: status 503")
	}
	chat, _ := chatSpanOf(t, sr)
	if st := chat.Status(); st.Code != codes.Error || st.Description != ledgerText {
		t.Errorf("chat span status: got %s %q, want Error and the ledger's text %q", st.Code, st.Description, ledgerText)
	}
}

func spanNames(spans []sdktrace.ReadOnlySpan) []string {
	names := make([]string, 0, len(spans))
	for _, span := range spans {
		names = append(names, span.Name())
	}
	return names
}
