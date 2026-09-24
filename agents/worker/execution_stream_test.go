package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"

	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
)

func executionEvents(lines []executionLine, event string) []executionLine {
	var out []executionLine
	for _, l := range lines {
		if l.Event == event {
			out = append(out, l)
		}
	}
	return out
}

func streamingRequest(workItem string) *a2a.SendMessageRequest {
	msg := a2a.NewMessage(a2a.MessageRoleUser, a2a.NewTextPart("lwi:"+workItem+" hi"))
	msg.ID = "msg-" + workItem
	msg.Metadata = map[string]any{"logical_work_item_id": workItem}
	return &a2a.SendMessageRequest{Message: msg}
}

// A streamed request is dispatched and recorded like a unary one, and every
// event that left is a line of its own.
func TestExecutionLedger_StreamedSendRecordsWhatWasDelivered(t *testing.T) {
	var out bytes.Buffer
	h := newExecutionLedger(a2asrv.NewHandler(completingExecutor{}), newLineWriter(&out))

	var events int
	for ev, err := range h.SendStreamingMessage(context.Background(), streamingRequest("w-stream")) {
		if err != nil {
			t.Fatalf("event %d: %v", events, err)
		}
		if ev == nil {
			t.Fatalf("event %d is nil", events)
		}
		events++
	}

	lines := executionLines(t, out.String())
	received := executionEvents(lines, "received")
	delivered := executionEvents(lines, "delivered")
	result := executionEvents(lines, "result")
	if len(received) != 1 || len(result) != 1 {
		t.Fatalf("received=%d result=%d, want 1 and 1: %s", len(received), len(result), out.String())
	}
	if received[0].Method != "SendStreamingMessage" || received[0].LogicalWorkItemID != "w-stream" {
		t.Errorf("received = %+v", received[0])
	}
	if len(delivered) != events {
		t.Errorf("delivered lines = %d, events the caller saw = %d", len(delivered), events)
	}
	if delivered[0].ResultKind != "task" || delivered[0].TaskID == "" {
		t.Errorf("first delivered line = %+v, want the Task the stream opens with", delivered[0])
	}
	if result[0].StreamEnd != execStreamEndComplete || result[0].ResultKind != "task" {
		t.Errorf("result = %+v, want stream_end complete", result[0])
	}
	// The state on a streamed result line is the submitted Task the stream
	// opened with, not the task's final state: a Task object is sent once and
	// the transitions after it are status updates. A reader that wants the final
	// state reads the executor's state lines.
	if result[0].State != string(a2a.TaskStateSubmitted) {
		t.Errorf("result state = %q, want the first Task's state %q", result[0].State, a2a.TaskStateSubmitted)
	}
	// The executor writes the Task's state lines from inside the execution. A
	// wrapper that wrote them too would count every transition twice as soon as
	// a second stream read the same task.
	if states := executionEvents(lines, "state"); len(states) != 0 {
		t.Errorf("the wrapper wrote %d state lines; the executor owns those", len(states))
	}
}

// The consumer stops reading mid-stream. The result line is still written, and
// it says the stream ended at the consumer's end.
func TestExecutionLedger_StreamCutByTheConsumerRecordsConsumerGone(t *testing.T) {
	var out bytes.Buffer
	h := newExecutionLedger(a2asrv.NewHandler(completingExecutor{}), newLineWriter(&out))

	for range h.SendStreamingMessage(context.Background(), streamingRequest("w-cut")) {
		break // the cut: nothing here reconnects or re-sends
	}

	lines := executionLines(t, out.String())
	result := executionEvents(lines, "result")
	if len(result) != 1 {
		t.Fatalf("result lines = %d, want 1: %s", len(result), out.String())
	}
	if result[0].StreamEnd != execStreamEndConsumerGone {
		t.Errorf("result = %+v, want stream_end %s", result[0], execStreamEndConsumerGone)
	}
	// In process there is no request context to cancel and the SDK yields
	// nothing, so this line carries no error — the same shape the Python
	// receiver writes for a cut stream. Over a socket the same ending carries
	// the cancellation the SDK answers a cut with; that shape is pinned in
	// TestSubscribeToTask_IsACountedArrivalAndReattachesToTheRunningTask.
	if result[0].Error != "" {
		t.Errorf("a consumer-gone line carries error %q", result[0].Error)
	}
	if len(executionEvents(lines, "delivered")) != 1 {
		t.Errorf("delivered lines = %d, want the one event the consumer took", len(executionEvents(lines, "delivered")))
	}
}

// An error the SDK yielded is its own ending. a2a-go's own consumer stops
// reading the moment one arrives (internal/sse writes the error and returns),
// so recording that refusal as consumer-gone would file every server error as a
// lost transport — the distinction B is about. The consumer here does what the
// SDK's does: it stops on the error. The error is a real one from this version:
// a streaming send naming a task the store does not hold.
func TestExecutionLedger_ErrorFromTheSDKIsNotACutStream(t *testing.T) {
	var out bytes.Buffer
	h := newExecutionLedger(a2asrv.NewHandler(completingExecutor{}), newLineWriter(&out))

	req := streamingRequest("w-error")
	req.Message.TaskID = "no-such-task"
	var seen error
	for _, err := range h.SendStreamingMessage(context.Background(), req) {
		if err != nil {
			seen = err
			break // what the SSE consumer does with an error
		}
	}
	if seen == nil {
		t.Fatal("the sequence yielded no error")
	}

	lines := executionLines(t, out.String())
	result := executionEvents(lines, "result")
	if len(result) != 1 {
		t.Fatalf("result lines = %d, want 1: %s", len(result), out.String())
	}
	if result[0].StreamEnd != execStreamEndError {
		t.Errorf("result = %+v, want stream_end %s", result[0], execStreamEndError)
	}
	if result[0].Error == "" {
		t.Errorf("an error line carries no error text: %+v", result[0])
	}
	t.Logf("a2a-go v2.5.0 yielded, and the ledger recorded: %q", result[0].Error)
}

// A unary send's lines are what they were: no delivered lines, no stream_end.
func TestExecutionLedger_UnarySendIsUnchanged(t *testing.T) {
	var out bytes.Buffer
	h := newExecutionLedger(a2asrv.NewHandler(completingExecutor{}), newLineWriter(&out))
	if _, err := h.SendMessage(context.Background(), streamingRequest("w-unary")); err != nil {
		t.Fatal(err)
	}
	lines := executionLines(t, out.String())
	if len(executionEvents(lines, "delivered")) != 0 {
		t.Errorf("a unary send wrote delivered lines: %s", out.String())
	}
	result := executionEvents(lines, "result")
	if len(result) != 1 || result[0].StreamEnd != "" {
		t.Errorf("result = %+v, want one line with no stream_end", result)
	}
	if !strings.Contains(out.String(), `"event":"result"`) || strings.Contains(out.String(), `"stream_end"`) {
		t.Errorf("unary lines carry a stream ending: %s", out.String())
	}
}

// The card is read back the way a client reads it: over HTTP, from the SDK's
// own card handler.
func TestCard_DeclaresStreaming(t *testing.T) {
	srv := httptest.NewServer(a2asrv.NewStaticAgentCardHandler(buildCard("worker", "http://worker.lab.svc.cluster.local:8080", "worker.lab.svc.cluster.local:8081")))
	defer srv.Close()
	resp, err := srv.Client().Get(srv.URL + a2asrv.WellKnownAgentCardPath)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = resp.Body.Close() }()
	var card struct {
		Capabilities struct {
			Streaming bool `json:"streaming"`
		} `json:"capabilities"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&card); err != nil {
		t.Fatal(err)
	}
	if !card.Capabilities.Streaming {
		t.Errorf("the served card does not declare streaming")
	}
}

// sseReader reads SSE data blocks from a connection the test opened itself, so
// the test decides when the stream is cut.
type sseReader struct {
	conn net.Conn
	r    *bufio.Reader
}

func dialStream(t *testing.T, addr, body string, header string) *sseReader {
	t.Helper()
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	req := "POST / HTTP/1.1\r\nHost: worker\r\nContent-Type: application/json\r\n" + header +
		fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(body), body)
	if _, err := io.WriteString(conn, req); err != nil {
		t.Fatal(err)
	}
	if err := conn.SetReadDeadline(time.Now().Add(10 * time.Second)); err != nil {
		t.Fatal(err)
	}
	return &sseReader{conn: conn, r: bufio.NewReader(conn)}
}

// next returns the JSON payload of the next SSE data block.
func (s *sseReader) next(t *testing.T) map[string]any {
	t.Helper()
	for {
		text, err := s.r.ReadString('\n')
		if err != nil {
			t.Fatalf("reading the stream: %v", err)
		}
		if !strings.HasPrefix(text, "data: ") {
			continue
		}
		var payload map[string]any
		if err := json.Unmarshal([]byte(strings.TrimSpace(strings.TrimPrefix(text, "data: "))), &payload); err != nil {
			t.Fatalf("SSE payload is not JSON: %v (%q)", err, text)
		}
		return payload
	}
}

func (s *sseReader) close() { _ = s.conn.Close() }

// waitForIngressResponse polls for the ingress ledger's response line, which
// this process writes onto the same stream as the execution ledger's lines.
func waitForIngressResponse(t *testing.T, buf *syncBuffer) ingressLine {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		for _, l := range ingressLines(t, buf.String()) {
			if l.Ledger == "ingress" && l.Phase == "response" {
				return l
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("no ingress response line: %q", buf.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// waitForExecutionLines polls until n lines are present: the execution ledger's
// later lines are written by the detached execution, after the client is gone.
func waitForExecutionLines(t *testing.T, buf *syncBuffer, want func([]executionLine) bool) []executionLine {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		lines := executionLines(t, buf.String())
		if want(lines) {
			return lines
		}
		if time.Now().After(deadline) {
			t.Fatalf("the ledger never reached the wanted shape: %q", buf.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// The whole chain, as main assembles it: the tracing handler, the ingress
// ledger, the SDK's JSON-RPC handler and the execution ledger around a real
// executor whose model call the test holds open. The stream is cut while the
// model call is in flight, and the Task is then counted to completion — from
// the executor's own state lines, not inferred from a stream that stopped.
func TestStreamedRequest_TaskContinuesAfterTheClientIsGone(t *testing.T) {
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
	// The Task and the working status reach the client through the ledger's
	// recorder and the tracing handler: flushed events do arrive.
	first := stream.next(t)
	if first["result"] == nil {
		t.Fatalf("first event is not a JSON-RPC result: %v", first)
	}
	stream.next(t)
	awaitModelCall(t, modelCalls)

	// The cut, with the model call still in flight.
	stream.close()
	if response := waitForIngressResponse(t, out); response.StreamEnd != streamEndClientGone {
		t.Errorf("ingress response = %+v, want stream_end %s", response, streamEndClientGone)
	}

	// The model answers after the client is gone.
	release()
	lines := waitForExecutionLines(t, out, func(lines []executionLine) bool {
		for _, l := range lines {
			if l.Event == "state" && l.State == string(a2a.TaskStateCompleted) {
				return true
			}
		}
		return false
	})

	states := executionEvents(lines, "state")
	if len(states) != 3 {
		t.Errorf("state lines = %d, want submitted, working and completed: %+v", len(states), states)
	}
	completed := states[len(states)-1]
	if completed.State != string(a2a.TaskStateCompleted) || completed.TaskID == "" {
		t.Errorf("last state = %+v", completed)
	}
	// One dispatch, one model call: the cut stream started nothing again.
	if n := len(executionEvents(lines, "execute")); n != 1 {
		t.Errorf("execute lines = %d, want 1", n)
	}
	if len(modelCalls) != 0 {
		t.Errorf("the model was called %d more times after the cut", len(modelCalls))
	}
	result := executionEvents(lines, "result")
	if len(result) != 1 || result[0].StreamEnd != execStreamEndConsumerGone {
		t.Errorf("result = %+v, want one line reading stream_end %s", result, execStreamEndConsumerGone)
	}
}
