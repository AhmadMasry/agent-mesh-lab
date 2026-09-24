package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"iter"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"

	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
)

// countingExecutor is completingExecutor with a count of how many times the SDK
// entered it, which is what "the handler is never called" is read from.
type countingExecutor struct {
	completingExecutor
	entered *atomic.Int32
}

func (c countingExecutor) Execute(ctx context.Context, execCtx *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	c.entered.Add(1)
	return c.completingExecutor.Execute(ctx, execCtx)
}

// The setting is off unless it names an operation, and off means the handler is
// built with no interceptor at all — checked on the handler main builds, the way
// MODEL_RETRIES' default is checked on the client's transport rather than by
// sending anything.
func TestRefuseOperation_DefaultOff(t *testing.T) {
	t.Setenv(refuseOperationEnv, "")
	got, err := refuseOperationFrom(os.Getenv(refuseOperationEnv))
	if got != "" || err != nil {
		t.Fatalf("empty setting = %q, %v; want off with no error", got, err)
	}
	h := newRequestHandler(completingExecutor{}, newLineWriter(io.Discard), got)
	ih, ok := h.RequestHandler.(*a2asrv.InterceptedHandler)
	if !ok {
		t.Fatalf("the SDK handler is %T, want *a2asrv.InterceptedHandler", h.RequestHandler)
	}
	if len(ih.Interceptors) != 0 {
		t.Errorf("with the setting off the handler carries %d interceptor(s), want 0", len(ih.Interceptors))
	}
}

func TestRefuseOperationFrom_TheThreeOperations(t *testing.T) {
	for _, op := range []string{"SendMessage", "SendStreamingMessage", "SubscribeToTask"} {
		got, err := refuseOperationFrom(op)
		if got != op || err != nil {
			t.Errorf("%q = %q, %v; want it accepted as itself", op, got, err)
		}
		h := newRequestHandler(completingExecutor{}, newLineWriter(io.Discard), got)
		if n := len(h.RequestHandler.(*a2asrv.InterceptedHandler).Interceptors); n != 1 {
			t.Errorf("%q built a handler with %d interceptor(s), want 1", op, n)
		}
	}
}

// Anything that is not one of the three is refused as a value, so that main
// stops instead of serving what a run meant to refuse. Other A2A operations are
// refused too: the Python receiver's refusal would not reach them.
func TestRefuseOperationFrom_AnythingElseIsRefused(t *testing.T) {
	for _, v := range []string{
		"GetTask", "CancelTask", "ListTasks", "GetExtendedAgentCard",
		"subscribetotask", "SUBSCRIBETOTASK", "subscribeToTask",
		" SubscribeToTask", "SubscribeToTask ", "SubscribeToTask\n",
		"tasks/resubscribe", "message/send", "SubscribeToTask,SendMessage",
		"${REFUSE_OPERATION}", "on", "yes", "true", "1", "*", "all", "off", " ",
	} {
		got, err := refuseOperationFrom(v)
		if err == nil || got != "" {
			t.Errorf("%q = %q, %v; want an error and no operation", v, got, err)
			continue
		}
		if !strings.Contains(err.Error(), refuseOperationEnv) {
			t.Errorf("%q: the error %q does not name the setting", v, err)
		}
	}
}

// outcome is what one request got from the handler, read the way the JSON-RPC
// transport reads it: the result, or the first error the sequence yields.
type outcome struct {
	err     error
	events  int
	entered int32
}

func runOp(t *testing.T, h a2asrv.RequestHandler, op string, entered *atomic.Int32) outcome {
	t.Helper()
	before := entered.Load()
	var o outcome
	switch op {
	case "SendMessage":
		_, o.err = h.SendMessage(context.Background(), streamingRequest("w-unary"))
	case "SendStreamingMessage":
		for ev, err := range h.SendStreamingMessage(context.Background(), streamingRequest("w-stream")) {
			if err != nil && o.err == nil {
				o.err = err
			}
			if ev != nil {
				o.events++
			}
		}
	case "SubscribeToTask":
		for ev, err := range h.SubscribeToTask(context.Background(), &a2a.SubscribeToTaskRequest{ID: "task-that-does-not-exist"}) {
			if err != nil && o.err == nil {
				o.err = err
			}
			if ev != nil {
				o.events++
			}
		}
	default:
		t.Fatalf("no such operation in this test: %s", op)
	}
	o.entered = entered.Load() - before
	return o
}

var threeOps = []string{"SendMessage", "SendStreamingMessage", "SubscribeToTask"}

// Each setting refuses its own operation and no other, and the executor is
// never entered for a refusal. With the setting off, nothing is refused: the
// SubscribeToTask names no task and gets the SDK's own task-not-found.
func TestRefuse_EachSettingRefusesOnlyItsOperation(t *testing.T) {
	for _, setting := range append([]string{""}, threeOps...) {
		for _, op := range threeOps {
			entered := &atomic.Int32{}
			h := newRequestHandler(countingExecutor{entered: entered}, newLineWriter(io.Discard), setting)
			o := runOp(t, h, op, entered)
			refused := errors.Is(o.err, a2a.ErrUnsupportedOperation)
			if want := op == setting; refused != want {
				t.Errorf("setting %q, %s: refused = %v (err %v), want %v", setting, op, refused, o.err, want)
				continue
			}
			if refused {
				if o.entered != 0 || o.events != 0 {
					t.Errorf("setting %q, %s refused but the executor was entered %d time(s) and %d event(s) left",
						setting, op, o.entered, o.events)
				}
				if !strings.Contains(o.err.Error(), op+" is refused by this agent ("+refuseOperationEnv+")") {
					t.Errorf("setting %q: the refusal reads %q", setting, o.err)
				}
				continue
			}
			switch op {
			case "SubscribeToTask":
				if !errors.Is(o.err, a2a.ErrTaskNotFound) {
					t.Errorf("setting %q, SubscribeToTask to no task: err %v, want the SDK's task-not-found", setting, o.err)
				}
			default:
				if o.err != nil || o.entered != 1 {
					t.Errorf("setting %q, %s: err %v, executor entered %d time(s); want served once", setting, op, o.err, o.entered)
				}
			}
		}
	}
}

// A refused request keeps its "received" line, because the execution ledger is
// outside the interceptor, and gains a "result" line carrying the refusal; a
// streamed operation's result line reads stream_end error, a unary one's none,
// as for any other error from the SDK.
func TestRefuse_ARefusedRequestsExecutionLines(t *testing.T) {
	for _, op := range threeOps {
		var out bytes.Buffer
		entered := &atomic.Int32{}
		h := newRequestHandler(countingExecutor{entered: entered}, newLineWriter(&out), op)
		runOp(t, h, op, entered)
		lines := executionLines(t, out.String())
		if len(lines) != 2 || lines[0].Event != "received" || lines[1].Event != "result" {
			t.Fatalf("%s refused: lines = %+v, want received then result", op, lines)
		}
		for _, l := range lines {
			if l.Method != op {
				t.Errorf("%s refused: a line names method %q", op, l.Method)
			}
		}
		res := lines[1]
		if !strings.Contains(res.Error, "this operation is not supported: "+op+" is refused by this agent") {
			t.Errorf("%s refused: result error = %q", op, res.Error)
		}
		wantEnd := execStreamEndError
		if op == "SendMessage" {
			wantEnd = ""
		}
		if res.StreamEnd != wantEnd || res.ResultKind != "" || res.State != "" {
			t.Errorf("%s refused: result = %+v, want stream_end %q and no result kind or state", op, res, wantEnd)
		}
		if op != "SubscribeToTask" && (lines[0].LogicalWorkItemID == "" || lines[0].MessageID == "") {
			t.Errorf("%s refused: received = %+v, want the message's identity", op, lines[0])
		}
	}
}

// normalized drops what differs between any two runs — stamps and the ids the
// SDK mints — and keeps every other field of every line, in order.
func normalized(t *testing.T, text string) []executionLine {
	t.Helper()
	lines := executionLines(t, text)
	for i := range lines {
		lines[i].TS = ""
		if lines[i].TaskID != "" && lines[i].TaskID != "task-that-does-not-exist" {
			lines[i].TaskID = "<task>"
		}
		if lines[i].ContextID != "" {
			lines[i].ContextID = "<context>"
		}
	}
	return lines
}

// A refusal changes no ledger line of an operation it does not refuse: every
// setting's lines for the other two operations equal the lines with it off,
// field for field, stamps and minted ids aside.
func TestRefuse_LedgerUnchangedForOperationsNotRefused(t *testing.T) {
	off := map[string][]executionLine{}
	for _, op := range threeOps {
		var out bytes.Buffer
		entered := &atomic.Int32{}
		runOp(t, newRequestHandler(countingExecutor{entered: entered}, newLineWriter(&out), ""), op, entered)
		off[op] = normalized(t, out.String())
		if len(off[op]) == 0 {
			t.Fatalf("%s with the setting off wrote no lines", op)
		}
	}
	for _, setting := range threeOps {
		for _, op := range threeOps {
			if op == setting {
				continue
			}
			var out bytes.Buffer
			entered := &atomic.Int32{}
			runOp(t, newRequestHandler(countingExecutor{entered: entered}, newLineWriter(&out), setting), op, entered)
			got := normalized(t, out.String())
			a, _ := json.Marshal(got)
			b, _ := json.Marshal(off[op])
			if !bytes.Equal(a, b) {
				t.Errorf("setting %q changed %s's lines:\n got %s\nwant %s", setting, op, a, b)
			}
		}
	}
}

// servedWorker is the chain main serves, with a real executor and a fake model.
func servedWorker(t *testing.T, refuse string) (*httptest.Server, *syncBuffer, *fakeModel) {
	t.Helper()
	f, model := newFakeModel(http.StatusOK)
	t.Cleanup(model.Close)
	out := &syncBuffer{}
	lw := newLineWriter(out)
	executor := newLabExecutor("worker", newModelClient(model.URL+"/v1", "mock", "unused", httpclient.New(10*time.Second)), lw)
	a2aMux := http.NewServeMux()
	a2aMux.Handle(a2asrv.WellKnownAgentCardPath, a2asrv.NewStaticAgentCardHandler(buildCard("worker", "http://worker", "worker:8081")))
	a2aMux.Handle("/", a2asrv.NewJSONRPCHandler(newRequestHandler(executor, lw, refuse)))
	srv := httptest.NewServer(labotel.Handler("worker", newRootMux(a2aMux, lw, newInjector())))
	t.Cleanup(srv.Close)
	return srv, out, f
}

// wireAnswer is what a client reads back: the HTTP status and content type, and
// the JSON-RPC error of the one body or of the first SSE event.
type wireAnswer struct {
	status      int
	contentType string
	code        float64
	message     string
	result      bool
}

func post(t *testing.T, url, body string) wireAnswer {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, url, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("A2A-Version", "1.0")
	resp, err := httpclient.New(10 * time.Second).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	a := wireAnswer{status: resp.StatusCode, contentType: resp.Header.Get("Content-Type")}
	var payload []byte
	if strings.HasPrefix(a.contentType, "text/event-stream") {
		sc := bufio.NewScanner(resp.Body)
		sc.Buffer(make([]byte, 1<<20), 1<<20)
		for sc.Scan() {
			if strings.HasPrefix(sc.Text(), "data: ") {
				payload = []byte(strings.TrimPrefix(sc.Text(), "data: "))
				break
			}
		}
	} else {
		payload, _ = io.ReadAll(resp.Body)
	}
	var env map[string]any
	if err := json.Unmarshal(payload, &env); err != nil {
		t.Fatalf("answer is not JSON: %q", payload)
	}
	if e, ok := env["error"].(map[string]any); ok {
		a.code, _ = e["code"].(float64)
		a.message, _ = e["message"].(string)
	}
	_, a.result = env["result"]
	return a
}

// Over the wire, as main serves it: the refused request still arrives at the
// ingress ledger — it is written before the SDK sees the request — and gets
// -32004 with the refusal's text; the model is never called for it; and the
// operations not refused are served and call the model once each.
func TestRefuse_OverTheWire(t *testing.T) {
	for _, tc := range []struct {
		setting, body, op string
		stream            bool
	}{
		{"SubscribeToTask", a2aSubscribeToTaskBody, "SubscribeToTask", true},
		{"SendStreamingMessage", a2aStreamingMessageBody, "SendStreamingMessage", true},
		{"SendMessage", a2aGoSendMessageBody, "SendMessage", false},
	} {
		t.Run(tc.setting, func(t *testing.T) {
			srv, out, model := servedWorker(t, tc.setting)
			a := post(t, srv.URL+"/", tc.body)
			if a.code != -32004 || !strings.Contains(a.message, tc.op+" is refused by this agent (REFUSE_OPERATION)") || a.result {
				t.Fatalf("answer = %+v, want JSON-RPC -32004 with the refusal's text and no result", a)
			}
			if a.status != http.StatusOK {
				t.Errorf("HTTP status = %d, want 200: the refusal is a JSON-RPC error", a.status)
			}
			if got := strings.HasPrefix(a.contentType, "text/event-stream"); got != tc.stream {
				t.Errorf("content type %q; streamed = %v, want %v", a.contentType, got, tc.stream)
			}
			resp := waitForIngressResponse(t, out)
			var arrivals []ingressLine
			for _, l := range ingressLines(t, out.String()) {
				if l.Ledger == "ingress" && l.Phase == "arrival" {
					arrivals = append(arrivals, l)
				}
			}
			if len(arrivals) != 1 || arrivals[0].Method != tc.op {
				t.Fatalf("arrivals = %+v, want one for %s", arrivals, tc.op)
			}
			if resp.Method != tc.op || statusOf(t, resp) != http.StatusOK {
				t.Errorf("ingress response = %+v", resp)
			}
			lines := executionLines(t, out.String())
			if len(executionEvents(lines, "received")) != 1 || len(executionEvents(lines, "result")) != 1 ||
				len(executionEvents(lines, "execute")) != 0 || len(executionEvents(lines, "state")) != 0 {
				t.Errorf("execution lines = %+v, want received and result only", lines)
			}
			if n := model.calls.Load(); n != 0 {
				t.Errorf("model calls = %d, want 0", n)
			}

			// The other unary or streamed send, on the same server, is served.
			other := a2aGoSendMessageBody
			if tc.op == "SendMessage" {
				other = a2aStreamingMessageBody
			}
			if b := post(t, srv.URL+"/", other); b.code != 0 || !b.result {
				t.Errorf("the operation not refused got %+v", b)
			}
			deadline := time.Now().Add(10 * time.Second)
			for model.calls.Load() != 1 && time.Now().Before(deadline) {
				time.Sleep(10 * time.Millisecond)
			}
			if n := model.calls.Load(); n != 1 {
				t.Errorf("model calls after the operation not refused = %d, want 1", n)
			}
		})
	}
}

// main stops at start on a value it cannot refuse, and names the setting; it
// starts with a value it can. Run as a child process of this test binary, the
// way the process is run.
func TestMain_RefuseOperationIsReadAtStart(t *testing.T) {
	if os.Getenv("WORKER_MAIN_CHILD") == "1" {
		main()
		return
	}
	run := func(value string) (*exec.Cmd, *syncBuffer) {
		cmd := exec.Command(os.Args[0], "-test.run=^TestMain_RefuseOperationIsReadAtStart$")
		cmd.Env = append(os.Environ(), "WORKER_MAIN_CHILD=1", refuseOperationEnv+"="+value,
			"LISTEN_ADDR=127.0.0.1:0", "OTEL_EXPORTER_OTLP_ENDPOINT=", "OTEL_SDK_DISABLED=true")
		stderr := &syncBuffer{}
		cmd.Stderr = stderr
		cmd.Stdout = io.Discard
		return cmd, stderr
	}

	for _, v := range []string{"GetTask", "subscribetotask", "SubscribeToTask "} {
		cmd, stderr := run(v)
		done := make(chan error, 1)
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		go func() { done <- cmd.Wait() }()
		select {
		case err := <-done:
			if err == nil {
				t.Errorf("%q: the process exited 0, want a failure", v)
			}
			if !strings.Contains(stderr.String(), refuseOperationEnv) || strings.Contains(stderr.String(), "listening") {
				t.Errorf("%q: stderr = %q, want the setting named and no listening line", v, stderr.String())
			}
		case <-time.After(10 * time.Second):
			_ = cmd.Process.Kill()
			t.Errorf("%q: the process was still running after 10 s, want it stopped at start", v)
		}
	}

	// A value it can refuse: the process starts, says so, and the handler it
	// serves refuses that operation — main passes the setting on, not only reads it.
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	_ = l.Close()
	cmd, stderr := run("SubscribeToTask")
	cmd.Env = append(cmd.Env, "LISTEN_ADDR="+addr)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	deadline := time.Now().Add(10 * time.Second)
	for !strings.Contains(stderr.String(), "listening") && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !strings.Contains(stderr.String(), `REFUSE_OPERATION="SubscribeToTask"`) {
		t.Fatalf("stderr = %q, want a listening line naming the setting's value", stderr.String())
	}
	var a wireAnswer
	for {
		conn, err := net.Dial("tcp", addr)
		if err == nil {
			_ = conn.Close()
			a = post(t, "http://"+addr+"/", a2aSubscribeToTaskBody)
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the process never accepted a connection on %s", addr)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if a.code != -32004 || !strings.Contains(a.message, "SubscribeToTask is refused by this agent") {
		t.Errorf("the started process answered a SubscribeToTask with %+v, want -32004 and the refusal", a)
	}
}

// The ingress ledger's lines and the model call the executor makes are the same,
// field for field, for an operation the setting does not refuse as with the
// setting off — stamps, the client's port and the ids the SDK mints aside.
func TestRefuse_IngressLinesAndModelCallUnchangedForOperationsNotRefused(t *testing.T) {
	read := func(setting string) (ingress []map[string]any, model []map[string]string) {
		srv, out, f := servedWorker(t, setting)
		for _, body := range []string{a2aGoSendMessageBody, a2aStreamingMessageBody} {
			if a := post(t, srv.URL+"/", body); a.code != 0 || !a.result {
				t.Fatalf("setting %q: %+v", setting, a)
			}
			h := <-f.headers
			<-f.bodies
			model = append(model, map[string]string{
				"work-item": h.Get("X-Logical-Work-Item-Id"), "message": h.Get("X-A2A-Message-Id"),
				"task-set": map[bool]string{true: "yes", false: "no"}[h.Get("X-A2A-Task-Id") != ""],
				"caller":   h.Get("X-Caller"), "content-type": h.Get("Content-Type"),
			})
		}
		deadline := time.Now().Add(10 * time.Second)
		for {
			ingress = nil
			for _, raw := range strings.Split(strings.TrimSpace(out.String()), "\n") {
				var m map[string]any
				if json.Unmarshal([]byte(raw), &m) != nil || m["ledger"] != "ingress" {
					continue
				}
				for _, k := range []string{"ts_arrival", "ts_end", "remote"} {
					if _, ok := m[k]; ok {
						m[k] = "<masked>"
					}
				}
				ingress = append(ingress, m)
			}
			if len(ingress) == 4 || time.Now().After(deadline) {
				return ingress, model
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	offIngress, offModel := read("")
	onIngress, onModel := read("SubscribeToTask")
	a, _ := json.Marshal(offIngress)
	b, _ := json.Marshal(onIngress)
	if len(offIngress) != 4 || !bytes.Equal(a, b) {
		t.Errorf("ingress lines differ with SubscribeToTask refused:\n off %s\n  on %s", a, b)
	}
	c, _ := json.Marshal(offModel)
	d, _ := json.Marshal(onModel)
	if !bytes.Equal(c, d) {
		t.Errorf("model calls differ with SubscribeToTask refused:\n off %s\n  on %s", c, d)
	}
}
