package main

import (
	"flag"
	"fmt"
	"io"
	"net"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
)

// updateGolden rewrites the golden files below. They were written once, from
// the tree before the delay mode existed, and are compared on every later tree:
// that is how this file proves an existing mode's wire bytes and ledger lines
// did not move.
var updateGolden = flag.Bool("update-golden", false, "rewrite testdata/*.golden from this tree")

var (
	maskTS      = regexp.MustCompile(`"ts":"[^"]*"`)
	maskLatency = regexp.MustCompile(`"latency_ms":[0-9.e+-]+`)
	maskDate    = regexp.MustCompile(`(?m)^Date: .*\r$`)
)

// rawExchange sends one raw HTTP/1.1 request on a new connection and returns
// every byte the server sent until it closed the connection. No client library
// sits in between, so nothing is re-sent, re-framed or hidden.
func rawExchange(t *testing.T, addr, lwi, body string, keepAlive bool) string {
	t.Helper()
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	connHeader := "Connection: close\r\n"
	if keepAlive {
		connHeader = ""
	}
	req := fmt.Sprintf("POST /v1/chat/completions HTTP/1.1\r\nHost: mockllm\r\nContent-Type: application/json\r\n"+
		"X-Logical-Work-Item-Id: %s\r\n%sContent-Length: %d\r\n\r\n%s", lwi, connHeader, len(body), body)
	if _, err := io.WriteString(conn, req); err != nil {
		t.Fatalf("write request: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	got, _ := io.ReadAll(conn)
	return string(got)
}

// waitInvocations waits until buf holds n invocation lines, so the next
// exchange cannot interleave its lines with this one's.
func waitInvocations(t *testing.T, buf *syncBuffer, n int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		count := 0
		for _, l := range parseLedgerLines(buf.String()) {
			if l.Ledger == "invocation" {
				count++
			}
		}
		if count >= n {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("waited for %d invocation lines, have %d:\n%s", n, count, buf.String())
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func compareGolden(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join("testdata", name)
	if *updateGolden {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	if string(want) != got {
		t.Errorf("%s moved.\n--- want\n%s\n--- got\n%s", name, want, got)
	}
}

// Every mode that existed before the delay mode, and a call with no injection,
// JSON and streamed: the bytes on the wire (Date masked) and the ledger lines in
// the order written, key order included (ts and latency_ms masked), must be
// exactly what they were. The chain is the one main served before this change.
func TestExistingModes_WireAndLedgerUnchanged(t *testing.T) {
	ledger := &syncBuffer{}
	s := newServer(testConfig(), ledger)
	ts := httptest.NewUnstartedServer(nil)
	s.configureHTTPServer(ts.Config)
	ts.Config.Handler = labotel.Handler("mockllm", ts.Config.Handler)
	ts.Start()
	t.Cleanup(ts.Close)
	addr := ts.Listener.Addr().String()

	const unary = `{"model":"m","messages":[{"role":"user","content":"hi"}]}`
	const streamed = `{"model":"m","stream":true,"messages":[{"role":"user","content":"hi"}]}`
	steps := []struct {
		name, lwi, body, inject string
		keepAlive               bool
		lines                   int
	}{
		{"none-json", "g-none", unary, "", false, 1},
		{"none-stream", "g-sse", streamed, "", false, 1},
		{"http500", "g-500", unary, `{"mode":"http500","lwi":"g-500"}`, false, 1},
		{"close", "g-close", unary, `{"mode":"close","lwi":"g-close"}`, false, 1},
		{"delay-then-close", "g-dtc", unary, `{"mode":"delay-then-close","lwi":"g-dtc","delay_ms":50}`, false, 1},
		{"stale", "g-stale", unary, `{"mode":"stale","lwi":"g-stale"}`, true, 2},
		{"count-keyed-http500", "g-count", unary, `{"mode":"http500","at_count":1}`, false, 1},
	}
	var wire strings.Builder
	total := 0
	for _, st := range steps {
		mustReset(t, ts.URL)
		if st.inject != "" {
			if code, body := injectResponse(t, ts.URL, st.inject); code != 204 {
				t.Fatalf("%s: inject status %d: %s", st.name, code, body)
			}
		}
		got := rawExchange(t, addr, st.lwi, st.body, st.keepAlive)
		total += st.lines
		waitInvocations(t, ledger, total)
		// Carriage returns are spelled out, so the golden holds no CRLF for a
		// line-ending setting to rewrite and every CR the server sent stays visible.
		got = strings.ReplaceAll(maskDate.ReplaceAllString(got, "Date: <masked>\r"), "\r", `\r`)
		fmt.Fprintf(&wire, "=== %s\n%s\n", st.name, got)
	}
	compareGolden(t, "existing-modes-wire.golden", wire.String())

	lines := maskLatency.ReplaceAllString(maskTS.ReplaceAllString(ledger.String(), `"ts":"<masked>"`), `"latency_ms":<masked>`)
	compareGolden(t, "existing-modes-ledger.golden", lines)
}
