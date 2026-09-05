package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"

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

func sendThroughSDK(t *testing.T, ex a2asrv.AgentExecutor, out *bytes.Buffer) *a2a.Task {
	t.Helper()
	h := newExecutionLedger(a2asrv.NewHandler(ex), out)
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
	ex := newLabExecutor("worker", newModelClient(srv.URL+"/v1", "mock", "unused", httpclient.New(5*time.Second)), &out)
	task := sendThroughSDK(t, ex, &out)
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
	ex := newLabExecutor("worker", newModelClient(srv.URL+"/v1", "mock", "unused", httpclient.New(5*time.Second)), &out)
	task := sendThroughSDK(t, ex, &out)
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
	for _, raw := range strings.Split(strings.TrimSpace(ledger), "\n") {
		var l executionLine
		if err := json.Unmarshal([]byte(raw), &l); err != nil {
			t.Fatalf("bad line %q: %v", raw, err)
		}
		if l.Event == "state" {
			states = append(states, l.State)
		}
	}
	return states
}
