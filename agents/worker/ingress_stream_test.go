package main

import (
	"bufio"
	"bytes"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
)

// Hand-written in the shape the recorded SendMessage body in ingress_test.go
// has, with the method name A2A v1.0 gives the streaming send (specification
// v1.0.1 §9.4.2).
const a2aStreamingMessageBody = `{"jsonrpc":"2.0","method":"SendStreamingMessage","params":{"message":{"messageId":"01a06f19-cf55-7daf-af2b-a251c81a0375","metadata":{"logical_work_item_id":"go-stream"},"parts":[{"text":"lwi:go-stream hello"}],"role":"ROLE_USER"}},"id":"66f3ae4b-47df-4346-8fdb-0aacc23d7869"}`

// Hand-written from specification v1.0.1 §9.4.6: the request names a task and
// carries no Message at all.
const a2aSubscribeToTaskBody = `{"jsonrpc":"2.0","method":"SubscribeToTask","params":{"id":"task-uuid-1"},"id":"sub-1"}`

// stampAtOrAfter parses two ledger stamps and says whether the first is at or
// after the second.
func stampAtOrAfter(t *testing.T, later, earlier string) bool {
	t.Helper()
	a, err := time.Parse(time.RFC3339Nano, later)
	if err != nil {
		t.Fatalf("ts_end %q does not parse: %v", later, err)
	}
	b, err := time.Parse(time.RFC3339Nano, earlier)
	if err != nil {
		t.Fatalf("ts_arrival %q does not parse: %v", earlier, err)
	}
	return !a.Before(b)
}

// sseHandler writes n SSE events and returns, the way the SDK's writer does:
// headers first, one flushed block per event.
func sseHandler(n int) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		for i := 0; i < n; i++ {
			_, _ = w.Write([]byte("data: {\"jsonrpc\":\"2.0\"}\n\n"))
			w.(http.Flusher).Flush()
		}
	})
}

// A streamed response's line says when the stream ended and how. A stream that
// ran to its end reads complete.
func TestIngress_StreamThatEndedNormallyRecordsComplete(t *testing.T) {
	var out bytes.Buffer
	h := newIngressMiddleware(sseHandler(2), newLineWriter(&out), newInjector())
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aStreamingMessageBody))
	r.Header.Set("Content-Type", "application/json")
	h.ServeHTTP(httptest.NewRecorder(), r)

	lines := ingressLines(t, out.String())
	if len(lines) != 2 {
		t.Fatalf("want two lines, got %d: %q", len(lines), out.String())
	}
	if lines[0].Method != "SendStreamingMessage" || lines[0].LogicalWorkItemID != "go-stream" || lines[0].MessageID == "" {
		t.Errorf("arrival = %+v", lines[0])
	}
	if lines[0].StreamEnd != "" || lines[0].TSEnd != "" {
		t.Errorf("an arrival line carries a stream ending: %+v", lines[0])
	}
	if lines[1].StreamEnd != streamEndComplete || statusOf(t, lines[1]) != http.StatusOK {
		t.Errorf("response = %+v, want stream_end complete and status 200", lines[1])
	}
	// Parsed, not compared as text: this receiver's stamps are RFC3339Nano,
	// which drops trailing zeros, so a later stamp can sort before an earlier
	// one as a string. Anything that reads these two fields has to parse them.
	if !stampAtOrAfter(t, lines[1].TSEnd, lines[1].TSArrival) {
		t.Errorf("ts_end = %q, ts_arrival = %q", lines[1].TSEnd, lines[1].TSArrival)
	}
}

// A unary response is not a stream, whatever it answers: no ending is recorded
// for one, because there is no stream whose ending could be observed.
func TestIngress_UnaryResponseRecordsNoStreamEnding(t *testing.T) {
	var out bytes.Buffer
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0"}`))
	})
	h := newIngressMiddleware(next, newLineWriter(&out), newInjector())
	h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody)))
	lines := ingressLines(t, out.String())
	if lines[1].StreamEnd != "" || lines[1].TSEnd != "" {
		t.Errorf("unary response = %+v, want no stream_end and no ts_end", lines[1])
	}
}

// The stream is cut mid-flight: the client goes away while the handler is still
// holding the response open. The delivery was counted on arrival, and its
// response line says the ending was the client's.
func TestIngress_StreamCutByTheClientRecordsClientGone(t *testing.T) {
	out := &syncBuffer{}
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("data: {\"jsonrpc\":\"2.0\"}\n\n"))
		w.(http.Flusher).Flush()
		// The SDK's streaming handler returns on the request context, and so
		// does this one: nothing here reconnects or re-sends.
		<-r.Context().Done()
	})
	srv := httptest.NewServer(newIngressMiddleware(next, newLineWriter(out), newInjector()))
	defer srv.Close()

	conn, err := net.Dial("tcp", srv.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	req := "POST / HTTP/1.1\r\nHost: worker\r\nContent-Type: application/json\r\n" +
		fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(a2aStreamingMessageBody), a2aStreamingMessageBody)
	if _, err := io.WriteString(conn, req); err != nil {
		t.Fatal(err)
	}
	if err := conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	for {
		text, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("reading the stream: %v", err)
		}
		if strings.HasPrefix(text, "data: ") {
			break
		}
	}
	// The cut.
	_ = conn.Close()

	lines := waitForIngressLines(t, out, 2)
	if lines[0].Phase != "arrival" || lines[0].Method != "SendStreamingMessage" {
		t.Errorf("arrival = %+v", lines[0])
	}
	if lines[1].StreamEnd != streamEndClientGone {
		t.Errorf("response = %+v, want stream_end %s", lines[1], streamEndClientGone)
	}
	if lines[1].TSEnd == "" {
		t.Errorf("response line carries no ts_end: %+v", lines[1])
	}
}

// The client's connection is reset rather than closed in an orderly way, so the
// writes that follow fail instead of the handler simply being cancelled. That is
// the one ending this boundary reads from the write itself, and it is the
// nearest thing a unit test has to a proxy that went away mid-stream.
func TestIngress_StreamWhoseWritesFailRecordsWriteFailed(t *testing.T) {
	out := &syncBuffer{}
	handlerErr := make(chan error, 1)
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("data: {\"jsonrpc\":\"2.0\"}\n\n"))
		w.(http.Flusher).Flush()
		// Keep writing at the gone client until a write says it cannot. The
		// handler does not watch the request context here on purpose: this test
		// is about the write error, which the recorder reports ahead of a
		// cancellation. Nothing here re-sends: every write is new bytes.
		block := bytes.Repeat([]byte("data: {\"jsonrpc\":\"2.0\"}\n\n"), 256)
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if _, err := w.Write(block); err != nil {
				handlerErr <- err
				return
			}
			w.(http.Flusher).Flush()
		}
		handlerErr <- nil
	})
	srv := httptest.NewServer(newIngressMiddleware(next, newLineWriter(out), newInjector()))
	defer srv.Close()

	conn, err := net.Dial("tcp", srv.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	// A zero linger makes Close send a reset, so the peer's writes fail rather
	// than being swallowed by an orderly shutdown.
	if tcpConn, ok := conn.(*net.TCPConn); ok {
		if err := tcpConn.SetLinger(0); err != nil {
			t.Fatal(err)
		}
	} else {
		t.Fatalf("dialled connection is %T, want *net.TCPConn", conn)
	}
	req := "POST / HTTP/1.1\r\nHost: worker\r\nContent-Type: application/json\r\n" +
		fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(a2aStreamingMessageBody), a2aStreamingMessageBody)
	if _, err := io.WriteString(conn, req); err != nil {
		t.Fatal(err)
	}
	if err := conn.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	for {
		text, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("reading the stream: %v", err)
		}
		if strings.HasPrefix(text, "data: ") {
			break
		}
	}
	_ = conn.Close()

	select {
	case err := <-handlerErr:
		if err == nil {
			t.Fatal("no write to the gone client failed within the deadline")
		}
		t.Logf("the write to the gone client returned: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("the handler never returned")
	}

	lines := waitForIngressLines(t, out, 2)
	if lines[1].StreamEnd != streamEndWriteFailed {
		t.Errorf("response = %+v, want stream_end %s", lines[1], streamEndWriteFailed)
	}
	if lines[1].TSEnd == "" {
		t.Errorf("response line carries no ts_end: %+v", lines[1])
	}
}

// The server's own write deadline must not end a stream. With the deadline in
// force a stream that outlives it is cut by this receiver, and the cut is
// indistinguishable at every ledger from a transport that went away: the
// request context is cancelled and the SDK answers "queue read failed: context
// canceled". The deadline here is 300 ms and the stream runs past it; the test
// asserts the client saw the whole stream and the line reads complete.
func TestIngress_StreamOutlivesTheServerWriteDeadline(t *testing.T) {
	const writeDeadline = 300 * time.Millisecond
	const events = 6
	const gap = 100 * time.Millisecond

	out := &syncBuffer{}
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		for i := 0; i < events; i++ {
			if _, err := w.Write([]byte("data: {\"jsonrpc\":\"2.0\"}\n\n")); err != nil {
				t.Errorf("write %d failed: %v", i, err)
				return
			}
			w.(http.Flusher).Flush()
			select {
			case <-time.After(gap):
			case <-r.Context().Done():
				t.Errorf("the request context was cancelled after event %d: %v", i, r.Context().Err())
				return
			}
		}
	})
	srv := httptest.NewUnstartedServer(newWriteDeadlineLift(
		labotel.Handler("worker", newIngressMiddleware(next, newLineWriter(out), newInjector()))))
	srv.Config.WriteTimeout = writeDeadline
	srv.Start()
	defer srv.Close()

	conn, err := net.Dial("tcp", srv.Listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close() }()
	req := "POST / HTTP/1.1\r\nHost: worker\r\nContent-Type: application/json\r\n" +
		fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(a2aStreamingMessageBody), a2aStreamingMessageBody)
	if _, err := io.WriteString(conn, req); err != nil {
		t.Fatal(err)
	}
	if err := conn.SetReadDeadline(time.Now().Add(30 * time.Second)); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(conn)
	read := 0
	for read < events {
		text, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("the stream ended after %d of %d events (deadline %s): %v", read, events, writeDeadline, err)
		}
		if strings.HasPrefix(text, "data: ") {
			read++
		}
	}

	lines := waitForIngressLines(t, out, 2)
	if lines[1].StreamEnd != streamEndComplete {
		t.Errorf("response = %+v, want stream_end %s after %s of streaming past a %s deadline",
			lines[1], streamEndComplete, time.Duration(events)*gap, writeDeadline)
	}
}

// servedChain starts the handler chain main assembles — the write-deadline lift,
// the tracing instrumentation, the root mux and the ingress ledger — in front of
// a handler the test supplies, with the server's write deadline set short.
// Asserting against that function, rather than against a chain the test builds
// itself, is what ties the two properties below to what this process serves.
func servedChain(t *testing.T, out *syncBuffer, deadline time.Duration, inner http.Handler) *httptest.Server {
	t.Helper()
	srv := httptest.NewUnstartedServer(newServerHandler("worker", inner, newLineWriter(out), newInjector()))
	srv.Config.WriteTimeout = deadline
	srv.Start()
	t.Cleanup(srv.Close)
	return srv
}

func postRaw(t *testing.T, addr, body string) *bufio.Reader {
	t.Helper()
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	req := "POST / HTTP/1.1\r\nHost: worker\r\nContent-Type: application/json\r\n" +
		fmt.Sprintf("Content-Length: %d\r\n\r\n%s", len(body), body)
	if _, err := io.WriteString(conn, req); err != nil {
		t.Fatal(err)
	}
	if err := conn.SetReadDeadline(time.Now().Add(30 * time.Second)); err != nil {
		t.Fatal(err)
	}
	return bufio.NewReader(conn)
}

// The chain main serves lifts the deadline for a streamed response. Without the
// lift in that chain this receiver cuts its own stream at the deadline, and the
// cut is indistinguishable from a transport that went away — B's central
// observation, manufactured by the receiver itself.
func TestServerHandler_LiftsTheDeadlineForAStreamedResponse(t *testing.T) {
	const deadline = 300 * time.Millisecond
	const events = 6
	const gap = 100 * time.Millisecond

	out := &syncBuffer{}
	srv := servedChain(t, out, deadline, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		for i := 0; i < events; i++ {
			if _, err := w.Write([]byte("data: {\"jsonrpc\":\"2.0\"}\n\n")); err != nil {
				t.Errorf("write %d failed: %v", i, err)
				return
			}
			w.(http.Flusher).Flush()
			select {
			case <-time.After(gap):
			case <-r.Context().Done():
				t.Errorf("the request context was cancelled after event %d: %v", i, r.Context().Err())
				return
			}
		}
	}))

	reader := postRaw(t, srv.Listener.Addr().String(), a2aStreamingMessageBody)
	read := 0
	for read < events {
		text, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("the stream ended after %d of %d events (deadline %s): %v", read, events, deadline, err)
		}
		if strings.HasPrefix(text, "data: ") {
			read++
		}
	}
	lines := waitForIngressLines(t, out, 2)
	if lines[1].StreamEnd != streamEndComplete {
		t.Errorf("response = %+v, want stream_end %s", lines[1], streamEndComplete)
	}
}

// And it lifts it for nothing else. The bound on a unary response is what keeps
// a handler from holding a connection open indefinitely, so a lift applied to
// every response would remove it everywhere while every other test still passed.
func TestServerHandler_KeepsTheDeadlineForAUnaryResponse(t *testing.T) {
	const deadline = 300 * time.Millisecond

	out := &syncBuffer{}
	srv := servedChain(t, out, deadline, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		// Past the deadline, then an ordinary JSON answer: with the bound in
		// force the server ends the connection instead of sending it.
		time.Sleep(3 * deadline)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","result":{}}`))
	}))

	reader := postRaw(t, srv.Listener.Addr().String(), a2aGoSendMessageBody)
	line, err := reader.ReadString('\n')
	if err == nil {
		t.Errorf("the unary response arrived (%q) although it was written past the %s deadline: the bound is gone",
			strings.TrimSpace(line), deadline)
	}
}

// A message-less request is still a delivery of some work item's, and the line
// says where that identity came from.
func TestParseIngress_SubscribeToTaskTakesItsWorkItemFromTheHeader(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aSubscribeToTaskBody))
	r.Header.Set("X-Logical-Work-Item-Id", "w-sub")
	line := parseIngress(r, []byte(a2aSubscribeToTaskBody))
	if line.Method != "SubscribeToTask" || line.ID != "sub-1" || line.TaskID != "task-uuid-1" {
		t.Errorf("method/id/taskId = %q/%q/%q", line.Method, line.ID, line.TaskID)
	}
	if line.MessageID != "" {
		t.Errorf("messageId = %q, want empty: the request carries no Message", line.MessageID)
	}
	if line.LogicalWorkItemID != "w-sub" || line.LWISource != "header" {
		t.Errorf("lwi = %q from %q, want w-sub from header", line.LogicalWorkItemID, line.LWISource)
	}
}

// The fallback is for JSON-RPC deliveries only. The card fetch carries the same
// header and stays outside the work item's collection, where it has always been.
func TestParseIngress_CardFetchKeepsItsEmptyWorkItem(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/.well-known/agent-card.json", nil)
	r.Header.Set("X-Logical-Work-Item-Id", "w-card")
	line := parseIngress(r, nil)
	if line.LogicalWorkItemID != "" || line.LWISource != "" {
		t.Errorf("card fetch = %+v, want an empty work item and no source", line)
	}
}

// A body that carried the work item says nothing about a header: the absence of
// lwi_source is what says the body carried it.
func TestParseIngress_BodyWorkItemIsNotMarkedAsAHeaderOne(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody))
	r.Header.Set("X-Logical-Work-Item-Id", "w-other")
	line := parseIngress(r, []byte(a2aGoSendMessageBody))
	if line.LogicalWorkItemID != "go-dump" || line.LWISource != "" {
		t.Errorf("lwi = %q from %q, want go-dump from the body", line.LogicalWorkItemID, line.LWISource)
	}
}

// maskIngressLine blanks the two fields that differ between runs. Everything
// else, including the order of the keys, is compared byte for byte.
func maskIngressLine(raw string) string {
	masked := regexp.MustCompile(`"ts_arrival":"[^"]*"`).ReplaceAllString(raw, `"ts_arrival":"<TS>"`)
	return regexp.MustCompile(`"remote":"[^"]*"`).ReplaceAllString(masked, `"remote":"<REMOTE>"`)
}

// The unary pair, byte for byte, with the header that a streamed request's line
// now reads an identity from present on the request. Streaming added keys to the
// record; this is the assertion that it added none to a unary delivery's.
func TestIngress_UnaryLinesAreByteForByteWhatTheyWere(t *testing.T) {
	var out bytes.Buffer
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0"}`))
	})
	h := newIngressMiddleware(next, newLineWriter(&out), newInjector())
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody))
	r.Header.Set("Content-Type", "application/json")
	r.Header.Set("A2A-Version", "1.0")
	r.Header.Set("X-Logical-Work-Item-Id", "go-dump")
	h.ServeHTTP(httptest.NewRecorder(), r)

	head := `"ledger":"ingress","phase":%q,"ts_arrival":"<TS>","remote":"<REMOTE>","method":"SendMessage",` +
		`"id":"66f3ae4b-47df-4346-8fdb-0aacc23d7869","messageId":"01a06f19-cf55-7daf-af2b-a251c81a0375",` +
		`"taskId":"","logical_work_item_id":"go-dump","a2a_version":"1.0","content_type":"application/json",` +
		`"body_sha256":%q,"body_len":262`
	want := []string{
		"{" + fmt.Sprintf(head, "arrival", sha(a2aGoSendMessageBody)) + "}",
		"{" + fmt.Sprintf(head, "response", sha(a2aGoSendMessageBody)) + `,"status":200}`,
	}
	got := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(got) != len(want) {
		t.Fatalf("want %d lines, got %d: %q", len(want), len(got), out.String())
	}
	for i := range want {
		if masked := maskIngressLine(got[i]); masked != want[i] {
			t.Errorf("line %d differs\n got: %s\nwant: %s", i, masked, want[i])
		}
	}
}
