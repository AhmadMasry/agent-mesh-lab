package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Recorded on 2026-09-05 from the a2a-go v2.5.0 client against a request-dump
// listener (see the Task 4 report). Only the ids differ between runs.
const a2aGoSendMessageBody = `{"jsonrpc":"2.0","method":"SendMessage","params":{"message":{"messageId":"01a06f19-cf55-7daf-af2b-a251c81a0375","metadata":{"logical_work_item_id":"go-dump"},"parts":[{"text":"lwi:go-dump hello"}],"role":"ROLE_USER"}},"id":"66f3ae4b-47df-4346-8fdb-0aacc23d7869"}`

// Hand-written in the pre-1.0 (0.3) JSON-RPC shape: snake-free field names,
// method message/send, numeric id, kind-tagged parts.
const v03MessageSendBody = `{"jsonrpc":"2.0","id":7,"method":"message/send","params":{"message":{"messageId":"m-03","role":"user","parts":[{"kind":"text","text":"lwi:x hi"}],"metadata":{"logical_work_item_id":"x"}}}}`

func sha(b string) string {
	h := sha256.Sum256([]byte(b))
	return hex.EncodeToString(h[:])
}

func TestParseIngress_A2AGoSendMessageBody(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody))
	r.Header.Set("A2A-Version", "1.0")
	r.Header.Set("Content-Type", "application/json")
	line := parseIngress(r, []byte(a2aGoSendMessageBody))
	if line.Method != "SendMessage" {
		t.Errorf("method = %q, want SendMessage", line.Method)
	}
	if line.ID != "66f3ae4b-47df-4346-8fdb-0aacc23d7869" {
		t.Errorf("id = %q", line.ID)
	}
	if line.MessageID != "01a06f19-cf55-7daf-af2b-a251c81a0375" {
		t.Errorf("messageId = %q", line.MessageID)
	}
	if line.LogicalWorkItemID != "go-dump" {
		t.Errorf("logical_work_item_id = %q", line.LogicalWorkItemID)
	}
	if line.TaskID != "" {
		t.Errorf("taskId = %q, want empty", line.TaskID)
	}
	if line.A2AVersion != "1.0" {
		t.Errorf("a2a_version = %q, want 1.0", line.A2AVersion)
	}
	if line.BodySHA256 != sha(a2aGoSendMessageBody) || line.BodyLen != len(a2aGoSendMessageBody) {
		t.Errorf("body hash/len = %s/%d", line.BodySHA256, line.BodyLen)
	}
	if line.Ledger != "ingress" || line.TSArrival == "" || line.ContentType != "application/json" {
		t.Errorf("ledger/ts/content_type = %q/%q/%q", line.Ledger, line.TSArrival, line.ContentType)
	}
}

func TestParseIngress_ZeroPointThreeBodyIsCountedToo(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(v03MessageSendBody))
	line := parseIngress(r, []byte(v03MessageSendBody))
	if line.Method != "message/send" || line.ID != "7" || line.MessageID != "m-03" || line.LogicalWorkItemID != "x" {
		t.Errorf("got method=%q id=%q messageId=%q lwi=%q", line.Method, line.ID, line.MessageID, line.LogicalWorkItemID)
	}
	if line.A2AVersion != "" {
		t.Errorf("a2a_version = %q, want empty when the header is absent", line.A2AVersion)
	}
}

func TestParseIngress_NonJSONRPCRequestStillCounted(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/.well-known/agent-card.json", nil)
	line := parseIngress(r, nil)
	if line.Method != "GET /.well-known/agent-card.json" || line.ID != "" || line.MessageID != "" || line.BodyLen != 0 {
		t.Errorf("got %+v", line)
	}
}

func TestIngressMiddleware_PassesBodyThroughUnchangedAndRecordsStatus(t *testing.T) {
	var seen []byte
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
	})
	var out bytes.Buffer
	h := newIngressMiddleware(next, newLineWriter(&out), newInjector())
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody))
	r.Header.Set("A2A-Version", "1.0")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if string(seen) != a2aGoSendMessageBody {
		t.Fatalf("downstream body differs from the wire body")
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("want an arrival line and a response line, got %d: %q", len(lines), out.String())
	}
	var arrival, response ingressLine
	if err := json.Unmarshal([]byte(lines[0]), &arrival); err != nil {
		t.Fatalf("arrival line is not JSON: %v", err)
	}
	if err := json.Unmarshal([]byte(lines[1]), &response); err != nil {
		t.Fatalf("response line is not JSON: %v", err)
	}
	if arrival.Phase != "arrival" || arrival.Status != nil || arrival.MessageID == "" || arrival.Ledger != "ingress" {
		t.Errorf("arrival = %+v", arrival)
	}
	if response.Phase != "response" || statusOf(t, response) != http.StatusCreated || response.MessageID != arrival.MessageID || response.TSArrival != arrival.TSArrival || response.BodySHA256 != arrival.BodySHA256 {
		t.Errorf("response = %+v", response)
	}
}

// The arrival line must exist even when the handler never returns normally: it is
// written before dispatch, so a delivery is counted the moment it is read.
func TestIngressMiddleware_ArrivalLineIsWrittenBeforeDispatch(t *testing.T) {
	var out bytes.Buffer
	var seenAtDispatch string
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenAtDispatch = out.String()
		w.WriteHeader(http.StatusOK)
	})
	h := newIngressMiddleware(next, newLineWriter(&out), newInjector())
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody))
	h.ServeHTTP(httptest.NewRecorder(), r)
	var line ingressLine
	if err := json.Unmarshal([]byte(strings.TrimSpace(seenAtDispatch)), &line); err != nil || line.Phase != "arrival" {
		t.Fatalf("no arrival line before dispatch: %q (%v)", seenAtDispatch, err)
	}
}

func TestIngressMiddleware_MalformedBodyIsCountedNotRejected(t *testing.T) {
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	var out bytes.Buffer
	h := newIngressMiddleware(next, newLineWriter(&out), newInjector())
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader("{not json"))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("middleware must not reject: status %d", w.Code)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	var line ingressLine
	if err := json.Unmarshal([]byte(lines[0]), &line); err != nil {
		t.Fatalf("no ledger line for malformed body: %v", err)
	}
	if line.BodySHA256 != sha("{not json") || line.BodyLen != 9 || line.Method != "" || line.Phase != "arrival" {
		t.Errorf("line = %+v", line)
	}
}

// syncBuffer is a mutex-protected buffer. lineWriter already serialises its
// own writes; this gives the test's reads the same protection while a server
// goroutine is still writing the response line.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// statusOf reads a response line's status. A nil status means the line carried
// no status key at all: arrival lines do that, response lines must not.
func statusOf(t *testing.T, l ingressLine) int {
	t.Helper()
	if l.Status == nil {
		t.Fatalf("line carries no status key: %+v", l)
	}
	return *l.Status
}

func ingressLines(t *testing.T, text string) []ingressLine {
	t.Helper()
	var lines []ingressLine
	for _, raw := range strings.Split(strings.TrimSpace(text), "\n") {
		if raw == "" {
			continue
		}
		var l ingressLine
		if err := json.Unmarshal([]byte(raw), &l); err != nil {
			t.Fatalf("bad ingress line %q: %v", raw, err)
		}
		lines = append(lines, l)
	}
	return lines
}

// waitForIngressLines polls until n lines are present: the response line is
// written by the server goroutine, which can lag the client's observation of
// a closed connection.
func waitForIngressLines(t *testing.T, buf *syncBuffer, n int) []ingressLine {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		lines := ingressLines(t, buf.String())
		if len(lines) >= n {
			return lines
		}
		if time.Now().After(deadline) {
			t.Fatalf("want %d ingress lines, got %d: %q", n, len(lines), buf.String())
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// The delivery is counted before the injection fires, so an arrival exists for
// a request the SDK never saw. The a2a-go body's work item is "go-dump".
func TestIngress_Http503BeforeDispatch_ArrivalCountedHandlerNotCalled(t *testing.T) {
	var out bytes.Buffer
	inj := newInjector()
	inj.arm(modeHTTP503BeforeDispatch, "go-dump")
	called := 0
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { called++; w.WriteHeader(http.StatusOK) })
	h := newIngressMiddleware(next, newLineWriter(&out), inj)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody)))

	if called != 0 {
		t.Errorf("handler was invoked %d times, want 0", called)
	}
	if w.Code != http.StatusServiceUnavailable {
		t.Errorf("status = %d, want 503", w.Code)
	}
	if got := strings.TrimSpace(w.Body.String()); got != `{"error":"injected"}` {
		t.Errorf("body = %q, want {\"error\":\"injected\"}", got)
	}
	lines := ingressLines(t, out.String())
	if len(lines) != 2 {
		t.Fatalf("want an arrival line and a response line, got %d: %q", len(lines), out.String())
	}
	if lines[0].Phase != "arrival" || lines[0].LogicalWorkItemID != "go-dump" || lines[0].Injection != "" {
		t.Errorf("arrival = %+v", lines[0])
	}
	if lines[1].Phase != "response" || statusOf(t, lines[1]) != http.StatusServiceUnavailable || lines[1].Injection != modeHTTP503BeforeDispatch {
		t.Errorf("response = %+v", lines[1])
	}
	if mode, ok := inj.take("go-dump"); ok {
		t.Errorf("work item still armed with %q after firing", mode)
	}
}

// close-after-read needs a real connection to hijack, so this one runs over
// httptest.NewServer. Keep-alives are off, so net/http cannot replay the
// request on a connection it found dead (it only retries reused connections).
func TestIngress_CloseAfterRead_ArrivalCountedConnectionClosed(t *testing.T) {
	out := &syncBuffer{}
	inj := newInjector()
	inj.arm(modeCloseAfterRead, "go-dump")
	var called atomic.Int32
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { called.Add(1); w.WriteHeader(http.StatusOK) })
	srv := httptest.NewServer(newIngressMiddleware(next, newLineWriter(out), inj))
	defer srv.Close()

	client := &http.Client{Timeout: 5 * time.Second, Transport: &http.Transport{DisableKeepAlives: true}}
	resp, err := client.Post(srv.URL+"/", "application/json", strings.NewReader(a2aGoSendMessageBody))
	if err == nil {
		_ = resp.Body.Close()
		t.Fatalf("want a transport error, got status %d", resp.StatusCode)
	}
	if !strings.Contains(err.Error(), "EOF") {
		t.Errorf("client error = %v, want one mentioning EOF", err)
	}
	if n := called.Load(); n != 0 {
		t.Errorf("handler was invoked %d times, want 0", n)
	}
	lines := waitForIngressLines(t, out, 2)
	if lines[0].Phase != "arrival" || lines[0].LogicalWorkItemID != "go-dump" {
		t.Errorf("arrival = %+v", lines[0])
	}
	if lines[1].Phase != "response" || statusOf(t, lines[1]) != 0 || lines[1].Injection != modeCloseAfterRead {
		t.Errorf("response = %+v, want phase response, status 0, injection close-after-read", lines[1])
	}
	// The wire form, not the parsed struct: an absent key would unmarshal to 0
	// too, and a jq filter on .status would then read null on this receiver and
	// 0 on the Python one for the same event.
	raw := strings.Split(strings.TrimSpace(out.String()), "\n")
	if !strings.Contains(raw[1], `"status":0`) {
		t.Errorf("response line omits an explicit status 0 on the wire: %s", raw[1])
	}
	if strings.Contains(raw[0], `"status"`) {
		t.Errorf("arrival line carries a status key: %s", raw[0])
	}
}

func TestIngress_UnarmedRequestUnchanged(t *testing.T) {
	var out bytes.Buffer
	inj := newInjector()
	inj.arm(modeHTTP503BeforeDispatch, "some-other-work-item")
	called := 0
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { called++; w.WriteHeader(http.StatusCreated) })
	h := newIngressMiddleware(next, newLineWriter(&out), inj)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody)))

	if called != 1 || w.Code != http.StatusCreated {
		t.Errorf("handler calls = %d, status = %d, want 1 and 201", called, w.Code)
	}
	lines := ingressLines(t, out.String())
	if len(lines) != 2 || statusOf(t, lines[1]) != http.StatusCreated || lines[1].Injection != "" {
		t.Errorf("lines = %+v, want an unchanged pair with no injection", lines)
	}
	if mode, ok := inj.take("some-other-work-item"); !ok || mode != modeHTTP503BeforeDispatch {
		t.Errorf("the other work item was disarmed by an unrelated request")
	}
}

// A request with no work item must never consult the injector: the agent card
// fetch and any non-JSON-RPC delivery carry no work item, and an empty key
// would otherwise match an empty arming.
func TestIngress_EmptyWorkItemIsNeverInjected(t *testing.T) {
	var out bytes.Buffer
	inj := newInjector()
	inj.arm(modeHTTP503BeforeDispatch, "")
	called := 0
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { called++; w.WriteHeader(http.StatusOK) })
	h := newIngressMiddleware(next, newLineWriter(&out), inj)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/.well-known/agent-card.json", nil))
	if called != 1 || w.Code != http.StatusOK {
		t.Errorf("handler calls = %d, status = %d, want 1 and 200", called, w.Code)
	}
}

// Recorded on 2026-09-05 from the a2a-sdk 1.1.2 (a2a-python) client against
// the same dump listener; same shape as the Go client's, plus an empty
// configuration object and a different key order.
const a2aPythonSendMessageBody = `{"method":"SendMessage","params":{"message":{"messageId":"3534b263-1d7c-45b6-a6cb-cc165fe5e1b5","role":"ROLE_USER","parts":[{"text":"lwi:py-dump hello"}],"metadata":{"logical_work_item_id":"py-dump"}},"configuration":{}},"id":"0de35010-f9b9-48c4-9c03-b7a3c3774d19","jsonrpc":"2.0"}`

func TestParseIngress_A2APythonSendMessageBody(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aPythonSendMessageBody))
	r.Header.Set("A2A-Version", "1.0")
	line := parseIngress(r, []byte(a2aPythonSendMessageBody))
	if line.Method != "SendMessage" || line.ID != "0de35010-f9b9-48c4-9c03-b7a3c3774d19" || line.MessageID != "3534b263-1d7c-45b6-a6cb-cc165fe5e1b5" || line.LogicalWorkItemID != "py-dump" || line.A2AVersion != "1.0" {
		t.Errorf("got method=%q id=%q messageId=%q lwi=%q ver=%q", line.Method, line.ID, line.MessageID, line.LogicalWorkItemID, line.A2AVersion)
	}
}
