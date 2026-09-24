package main

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"

	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
)

// taskIDOf reads the task id out of a JSON-RPC result carrying a Task. a2a-go
// v2.5.0 names the event inside the result — {"result":{"task":{…}}} for a Task,
// {"result":{"statusUpdate":{…}}} for a status update — so the id sits one level
// in.
func taskIDOf(t *testing.T, payload map[string]any) string {
	t.Helper()
	result, ok := payload["result"].(map[string]any)
	if !ok {
		t.Fatalf("event carries no result: %v", payload)
	}
	task, ok := result["task"].(map[string]any)
	if !ok {
		t.Fatalf("event carries no task: %v", result)
	}
	id, _ := task["id"].(string)
	if id == "" {
		t.Fatalf("the task carries no id: %v", task)
	}
	return id
}

// newBlockingModel is a model endpoint that holds every answer until release is
// called. Cleanup releases whatever is still waiting before the server closes,
// so a failed assertion ends the test instead of hanging its cleanup on a
// request that can never finish.
func newBlockingModel(t *testing.T) (baseURL string, calls chan struct{}, release func()) {
	t.Helper()
	held := make(chan struct{})
	calls = make(chan struct{}, 8)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls <- struct{}{}
		<-held
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"id":"chatcmpl-x","object":"chat.completion","created":1,"model":"mock","choices":[{"index":0,"message":{"role":"assistant","content":"the fixed answer"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}`))
	}))
	t.Cleanup(srv.Close)
	release = sync.OnceFunc(func() { close(held) })
	t.Cleanup(release)
	return srv.URL, calls, release
}

// awaitModelCall waits for the model endpoint to have been entered.
func awaitModelCall(t *testing.T, calls chan struct{}) {
	t.Helper()
	select {
	case <-calls:
	case <-time.After(10 * time.Second):
		t.Fatal("the model was never called")
	}
}

// subscribeBody is the request A2A v1.0 specifies for a resubscription
// (specification v1.0.1 §9.4.6): a task id, no Message.
func subscribeBody(taskID string) string {
	return fmt.Sprintf(`{"jsonrpc":"2.0","method":"SubscribeToTask","params":{"id":%q},"id":"sub-1"}`, taskID)
}

// A resubscription onto a task whose execution is over: whatever the SDK
// answers, the ledger holds the arrival and the answer. What a2a-go v2.5.0
// answers for a finished task is a cluster row of its own (B-3); here the
// assertion is that the ledger records it rather than losing the delivery.
func TestExecutionLedger_SubscribeToAFinishedTaskIsStillRecorded(t *testing.T) {
	var out bytes.Buffer
	h := newExecutionLedger(a2asrv.NewHandler(completingExecutor{}), newLineWriter(&out))
	res, err := h.SendMessage(context.Background(), streamingRequest("w-finished"))
	if err != nil {
		t.Fatal(err)
	}
	task := res.(*a2a.Task)

	var events int
	var lastErr error
	for _, err := range h.SubscribeToTask(context.Background(), &a2a.SubscribeToTaskRequest{ID: task.ID}) {
		if err != nil {
			lastErr = err
		}
		events++
	}

	lines := executionLines(t, out.String())
	received := executionEvents(lines, "received")
	if len(received) != 2 || received[1].Method != "SubscribeToTask" {
		t.Fatalf("received lines = %+v, want a second one for SubscribeToTask", received)
	}
	if received[1].TaskID != string(task.ID) || received[1].MessageID != "" || received[1].LogicalWorkItemID != "" {
		t.Errorf("received = %+v, want the taskId alone: the request carries no Message", received[1])
	}
	result := executionEvents(lines, "result")
	if len(result) != 2 {
		t.Fatalf("result lines = %d, want one per request: %s", len(result), out.String())
	}
	if lastErr == nil || result[1].Error == "" {
		t.Errorf("the SDK answered %v and the ledger recorded error %q; want both non-empty", lastErr, result[1].Error)
	}
	// The ending is the server's error, not a lost transport: this consumer read
	// the sequence to its end and went nowhere.
	if result[1].StreamEnd != execStreamEndError {
		t.Errorf("result = %+v, want stream_end %s", result[1], execStreamEndError)
	}
	if events != 1 {
		t.Errorf("the sequence yielded %d times, want one error and nothing else", events)
	}
	t.Logf("a2a-go v2.5.0 answered a resubscription to a finished task with: %v", lastErr)
}

// The shape B needs, end to end over HTTP: a stream is cut mid-flight, one
// SubscribeToTask names the task it left, and both deliveries are counted with
// the identity a message-less request can carry.
func TestSubscribeToTask_IsACountedArrivalAndReattachesToTheRunningTask(t *testing.T) {
	modelURL, modelCalls, release := newBlockingModel(t)

	out := &syncBuffer{}
	lw := newLineWriter(out)
	executor := newLabExecutor("worker", newModelClient(modelURL+"/v1", "mock", "unused", httpclient.New(30*time.Second)), lw)
	a2aMux := http.NewServeMux()
	a2aMux.Handle(a2asrv.WellKnownAgentCardPath, a2asrv.NewStaticAgentCardHandler(buildCard("worker", "http://worker", "worker:8081")))
	a2aMux.Handle("/", a2asrv.NewJSONRPCHandler(newExecutionLedger(a2asrv.NewHandler(executor), lw)))
	srv := httptest.NewServer(labotel.Handler("worker", newRootMux(a2aMux, lw, newInjector())))
	defer srv.Close()

	stream := dialStream(t, srv.Listener.Addr().String(), a2aStreamingMessageBody, "")
	taskID := taskIDOf(t, stream.next(t))
	stream.next(t) // the working status
	awaitModelCall(t, modelCalls)
	stream.close()

	// One resubscription, on a new connection, while the task is still running.
	// The load client sets this header on every request it sends.
	resub := dialStream(t, srv.Listener.Addr().String(), subscribeBody(taskID),
		"X-Logical-Work-Item-Id: go-stream\r\n")
	defer resub.close()
	if got := taskIDOf(t, resub.next(t)); got != taskID {
		t.Errorf("the resubscription's first event names task %s, want %s", got, taskID)
	}

	release()
	lines := waitForExecutionLines(t, out, func(lines []executionLine) bool {
		for _, l := range lines {
			if l.Event == "state" && l.State == string(a2a.TaskStateCompleted) {
				return true
			}
		}
		return false
	})

	// The execution ledger: two requests received, one execution, one Task.
	received := executionEvents(lines, "received")
	if len(received) != 2 || received[0].Method != "SendStreamingMessage" || received[1].Method != "SubscribeToTask" {
		t.Fatalf("received = %+v, want one line per request", received)
	}
	if received[1].TaskID != taskID {
		t.Errorf("the resubscription's line names task %q, want %q", received[1].TaskID, taskID)
	}
	if n := len(executionEvents(lines, "execute")); n != 1 {
		t.Errorf("execute lines = %d, want 1: a resubscription starts no execution", n)
	}
	// The cut stream's own ending, over a socket. Measured at this version, the
	// cut reaches the handler as an error — a2a-go cancels the request context
	// when the SSE handler returns and the subscription yields
	// `queue read failed: context canceled` — so this is the line that would
	// read "error", and the distinction B needs would be lost, if the ending
	// were decided by the presence of an error rather than by the context.
	var sendResults []executionLine
	for _, l := range executionEvents(lines, "result") {
		if l.Method == "SendStreamingMessage" {
			sendResults = append(sendResults, l)
		}
	}
	if len(sendResults) != 1 || sendResults[0].StreamEnd != execStreamEndConsumerGone {
		t.Fatalf("the streamed send's result = %+v, want one line reading stream_end %s",
			sendResults, execStreamEndConsumerGone)
	}
	if !strings.Contains(sendResults[0].Error, "context canceled") {
		t.Errorf("the cut stream's error text = %q, want the cancellation this SDK answers a cut with",
			sendResults[0].Error)
	}
	if len(modelCalls) != 0 {
		t.Errorf("the model was called %d more times", len(modelCalls))
	}

	// The ingress ledger: two arrivals, the second one collectable by the work
	// item only because the header carried it, and the line says so.
	var arrivals []ingressLine
	for _, l := range ingressLines(t, out.String()) {
		if l.Ledger == "ingress" && l.Phase == "arrival" {
			arrivals = append(arrivals, l)
		}
	}
	if len(arrivals) != 2 {
		t.Fatalf("ingress arrivals = %d, want 2: %q", len(arrivals), out.String())
	}
	if arrivals[1].Method != "SubscribeToTask" || arrivals[1].TaskID != taskID {
		t.Errorf("second arrival = %+v", arrivals[1])
	}
	if arrivals[1].LogicalWorkItemID != "go-stream" || arrivals[1].LWISource != "header" {
		t.Errorf("second arrival's work item = %q from %q, want go-stream from header",
			arrivals[1].LogicalWorkItemID, arrivals[1].LWISource)
	}
	if arrivals[0].LogicalWorkItemID != "go-stream" || arrivals[0].LWISource != "" {
		t.Errorf("first arrival = %+v, want the work item from the body", arrivals[0])
	}
}
