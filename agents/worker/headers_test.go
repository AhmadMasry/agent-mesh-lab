package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"reflect"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2asrv"

	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
)

// The authorization value every test sends. It must never appear in a ledger
// line, whatever the setting.
const secretAuthorization = "Bearer do-not-record-this-value"

// rawLines splits a ledger stream into its raw JSON lines.
func rawLines(text string) []string {
	var out []string
	for _, l := range strings.Split(strings.TrimSpace(text), "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

// masked replaces the three things that differ between two deliveries of the
// same bytes — the arrival stamp, the end stamp and the client's port — so two
// lines can be compared byte for byte.
var (
	maskTSArrival = regexp.MustCompile(`"ts_arrival":"[^"]*"`)
	maskTSEnd     = regexp.MustCompile(`"ts_end":"[^"]*"`)
	maskRemote    = regexp.MustCompile(`"remote":"[^"]*"`)
)

func masked(line string) string {
	line = maskTSArrival.ReplaceAllString(line, `"ts_arrival":"-"`)
	line = maskTSEnd.ReplaceAllString(line, `"ts_end":"-"`)
	return maskRemote.ReplaceAllString(line, `"remote":"-"`)
}

// serveOnce sends one request with the given headers through the ingress
// middleware built with opts, in front of a handler that answers 200, and
// returns the ledger's raw lines.
func serveOnce(t *testing.T, headers http.Header, body string, opts ...ingressOption) []string {
	t.Helper()
	out := &syncBuffer{}
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":"x","result":{}}`))
	})
	srv := httptest.NewServer(newIngressMiddleware(next, newLineWriter(out), newInjector(), opts...))
	defer srv.Close()
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/", strings.NewReader(body))
	for k, vs := range headers {
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	srv.Close()
	return rawLines(out.String())
}

func identityHeaders() http.Header {
	h := http.Header{}
	h.Set("Content-Type", "application/json")
	h.Set("A2A-Version", "1.0")
	h.Set("Authorization", secretAuthorization)
	h.Add("X-Forwarded-For", "10.0.0.1")
	h.Add("X-Forwarded-For", "10.0.0.2")
	h.Set("X-Forwarded-Proto", "http")
	h.Set("X-Forwarded-Client-Cert", "By=spiffe://cluster.local/ns/lab/sa/worker;URI=spiffe://cluster.local/ns/lab/sa/default")
	h.Set("X-Caller", "orchestrator")
	h.Set("X-Logical-Work-Item-Id", "lwi-headers")
	h.Set("Traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
	return h
}

// The setting is off unless it reads exactly "on", and off is what main builds
// when the variable is empty — the way MODEL_RETRIES' and REFUSE_OPERATION's
// defaults are asserted.
func TestLedgerHeaders_DefaultOff(t *testing.T) {
	t.Setenv(ledgerHeadersEnv, "")
	on, err := ledgerHeadersFrom(os.Getenv(ledgerHeadersEnv))
	if on || err != nil {
		t.Fatalf("empty setting = %v, %v; want off with no error", on, err)
	}
	var cfg ingressConfig
	for _, o := range []ingressOption{withHeaderReading(on)} {
		o(&cfg)
	}
	if cfg.headers {
		t.Fatal("withHeaderReading(false) switched the reading on")
	}
	for _, l := range serveOnce(t, identityHeaders(), a2aGoSendMessageBody, withHeaderReading(on)) {
		if strings.Contains(l, `"headers"`) {
			t.Errorf("with the setting off a line carries a headers key: %s", l)
		}
	}
}

func TestLedgerHeadersFrom_OnlyOnTurnsItOn(t *testing.T) {
	if on, err := ledgerHeadersFrom("on"); !on || err != nil {
		t.Fatalf(`"on" = %v, %v; want on`, on, err)
	}
	for _, v := range []string{"ON", "On", " on", "on ", "1", "true", "yes", "off", "0", "false",
		"${LEDGER_HEADERS}", "on,values", "authorization"} {
		on, err := ledgerHeadersFrom(v)
		if on || err == nil {
			t.Errorf("%q = %v, %v; want an error and off", v, on, err)
			continue
		}
		if !strings.Contains(err.Error(), ledgerHeadersEnv) {
			t.Errorf("%q: the error %q does not name the setting", v, err)
		}
	}
}

// With the setting off every ledger line is byte for byte what the middleware
// wrote before the setting existed: the same keys in the same order, the same
// values. Checked three ways: the option absent and the option off write the
// same bytes; neither carries a headers key; and the arrival line's keys are
// exactly the list the ledger had on 2026-09-24 before this change.
func TestLedgerHeaders_OffLinesAreByteForByteToday(t *testing.T) {
	for _, body := range []string{a2aGoSendMessageBody, a2aStreamingMessageBody, a2aSubscribeToTaskBody, "not json"} {
		absent := serveOnce(t, identityHeaders(), body)
		off := serveOnce(t, identityHeaders(), body, withHeaderReading(false))
		if len(absent) != 2 || len(off) != 2 {
			t.Fatalf("lines: absent %d, off %d; want 2 each", len(absent), len(off))
		}
		for i := range absent {
			if masked(absent[i]) != masked(off[i]) {
				t.Errorf("line %d differs:\nabsent %s\noff    %s", i, absent[i], off[i])
			}
		}
		var arrival map[string]json.RawMessage
		if err := json.Unmarshal([]byte(off[0]), &arrival); err != nil {
			t.Fatal(err)
		}
		if _, ok := arrival["headers"]; ok {
			t.Errorf("off arrival carries headers: %s", off[0])
		}
		if strings.Contains(off[0]+off[1], "do-not-record") {
			t.Errorf("the authorization value reached a line with the setting off")
		}
	}
	// The key order of today's arrival line for a SubscribeToTask sent with the
	// work-item header, the widest line an arrival can be: every key, in the
	// struct's order, and nothing else.
	lines := serveOnce(t, identityHeaders(), a2aSubscribeToTaskBody)
	want := []string{"ledger", "phase", "ts_arrival", "remote", "method", "id", "messageId", "taskId",
		"logical_work_item_id", "a2a_version", "content_type", "body_sha256", "body_len", "lwi_source"}
	if got := keyOrder(t, lines[0]); !reflect.DeepEqual(got, want) {
		t.Errorf("arrival keys = %v\nwant           %v", got, want)
	}
	wantResp := []string{"ledger", "phase", "ts_arrival", "remote", "method", "id", "messageId", "taskId",
		"logical_work_item_id", "a2a_version", "content_type", "body_sha256", "body_len", "status", "lwi_source"}
	if got := keyOrder(t, lines[1]); !reflect.DeepEqual(got, wantResp) {
		t.Errorf("response keys = %v\nwant            %v", got, wantResp)
	}
}

// keyOrder reads a JSON object's keys in the order they were written.
func keyOrder(t *testing.T, line string) []string {
	t.Helper()
	dec := json.NewDecoder(strings.NewReader(line))
	if _, err := dec.Token(); err != nil {
		t.Fatal(err)
	}
	var keys []string
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			t.Fatal(err)
		}
		keys = append(keys, tok.(string))
		var skip json.RawMessage
		if err := dec.Decode(&skip); err != nil {
			t.Fatal(err)
		}
	}
	return keys
}

type readingOnLine struct {
	Phase   string        `json:"phase"`
	Headers *headerRecord `json:"headers"`
}

// With the setting on the arrival line records every header name, the values of
// the fixed list only, and whether an authorization header was present — never
// its value. The response line is what it is with the setting off.
func TestLedgerHeaders_OnRecordsNamesTheListedValuesAndAuthorizationPresence(t *testing.T) {
	h := identityHeaders()
	h.Set("User-Agent", "lab-test/1")
	lines := serveOnce(t, h, a2aGoSendMessageBody, withHeaderReading(true))
	if len(lines) != 2 {
		t.Fatalf("lines = %d, want 2", len(lines))
	}
	if strings.Contains(lines[0]+lines[1], "do-not-record") {
		t.Fatalf("the authorization value reached a ledger line: %s", lines[0])
	}
	var arrival, response readingOnLine
	_ = json.Unmarshal([]byte(lines[0]), &arrival)
	_ = json.Unmarshal([]byte(lines[1]), &response)
	if arrival.Phase != "arrival" || arrival.Headers == nil {
		t.Fatalf("arrival = %s, want a headers object", lines[0])
	}
	if response.Headers != nil {
		t.Errorf("the response line carries headers: %s", lines[1])
	}
	got := arrival.Headers
	wantNames := []string{"a2a-version", "accept-encoding", "authorization", "content-length", "content-type",
		"host", "traceparent", "user-agent", "x-caller", "x-forwarded-client-cert", "x-forwarded-for",
		"x-forwarded-proto", "x-logical-work-item-id"}
	if !reflect.DeepEqual(got.Names, wantNames) {
		t.Errorf("names = %v\nwant    %v", got.Names, wantNames)
	}
	if !sort.StringsAreSorted(got.Names) {
		t.Errorf("names are not sorted: %v", got.Names)
	}
	if !got.AuthorizationPresent {
		t.Errorf("authorization_present = false with an Authorization header sent")
	}
	wantValues := map[string]string{
		"user-agent":              "lab-test/1",
		"x-forwarded-for":         "10.0.0.1, 10.0.0.2",
		"x-forwarded-proto":       "http",
		"x-forwarded-client-cert": "By=spiffe://cluster.local/ns/lab/sa/worker;URI=spiffe://cluster.local/ns/lab/sa/default",
		"x-caller":                "orchestrator",
	}
	// host is the test server's address, whatever port it drew.
	if !strings.HasPrefix(got.Values["host"], "127.0.0.1:") {
		t.Errorf("values[host] = %q, want the address the request named", got.Values["host"])
	}
	delete(got.Values, "host")
	if !reflect.DeepEqual(got.Values, wantValues) {
		t.Errorf("values = %v\nwant     %v", got.Values, wantValues)
	}
	for _, notListed := range []string{"authorization", "traceparent", "x-logical-work-item-id", "a2a-version"} {
		if _, ok := got.Values[notListed]; ok {
			t.Errorf("values carries %q, which is not on the list", notListed)
		}
	}
	// The key order: the headers object last, after every key the line had.
	keys := keyOrder(t, lines[0])
	if keys[len(keys)-1] != "headers" {
		t.Errorf("arrival keys = %v, want headers last", keys)
	}
	var obj map[string]json.RawMessage
	_ = json.Unmarshal([]byte(lines[0]), &obj)
	if got := keyOrder(t, string(obj["headers"])); !reflect.DeepEqual(got, []string{"names", "values", "authorization_present"}) {
		t.Errorf("headers keys = %v", got)
	}
}

// Without an Authorization header the presence reads false, and a request with
// none of the listed headers but Host still carries an empty-but-present values
// object, so "absent" and "not read" stay distinguishable.
func TestLedgerHeaders_OnWithNoAuthorization(t *testing.T) {
	h := http.Header{}
	h.Set("Content-Type", "application/json")
	lines := serveOnce(t, h, a2aGoSendMessageBody, withHeaderReading(true))
	if !strings.Contains(lines[0], `"authorization_present":false`) {
		t.Errorf("arrival = %s, want authorization_present false", lines[0])
	}
	var arrival readingOnLine
	_ = json.Unmarshal([]byte(lines[0]), &arrival)
	if arrival.Headers == nil || arrival.Headers.Values == nil {
		t.Fatalf("arrival = %s, want a values object", lines[0])
	}
	for k := range arrival.Headers.Values {
		if k != "host" && k != "user-agent" {
			t.Errorf("values carries %q, which was not sent", k)
		}
	}
}

// net/http takes Host, Transfer-Encoding and Trailer out of Request.Header. The
// reading puts their names back, so the list is what arrived on the wire and
// the Go receiver's list can be compared with the Python receiver's, whose ASGI
// server keeps every header in the list it hands over.
func TestLedgerHeaders_NamesIncludeWhatNetHTTPMovesOutOfHeader(t *testing.T) {
	out := &syncBuffer{}
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusOK)
	})
	srv := httptest.NewServer(newIngressMiddleware(next, newLineWriter(out), newInjector(), withHeaderReading(true)))
	defer srv.Close()
	conn, err := net.Dial("tcp", strings.TrimPrefix(srv.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	body := a2aGoSendMessageBody
	raw := "POST / HTTP/1.1\r\nHost: worker.lab.internal\r\nContent-Type: application/json\r\n" +
		"Transfer-Encoding: chunked\r\nTrailer: X-Check\r\n\r\n" +
		strings.ToLower(strconvHex(len(body))) + "\r\n" + body + "\r\n0\r\nX-Check: 1\r\n\r\n"
	if _, err := conn.Write([]byte(raw)); err != nil {
		t.Fatal(err)
	}
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	srv.Close()
	lines := rawLines(out.String())
	var arrival readingOnLine
	_ = json.Unmarshal([]byte(lines[0]), &arrival)
	want := []string{"content-type", "host", "trailer", "transfer-encoding"}
	if arrival.Headers == nil || !reflect.DeepEqual(arrival.Headers.Names, want) {
		t.Fatalf("arrival = %s\nwant names %v", lines[0], want)
	}
	if arrival.Headers.Values["host"] != "worker.lab.internal" {
		t.Errorf("values[host] = %q, want worker.lab.internal", arrival.Headers.Values["host"])
	}
}

func strconvHex(n int) string {
	const digits = "0123456789abcdef"
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{digits[n%16]}, b...)
		n /= 16
	}
	return string(b)
}

// Over the chain main serves: the reading is on the arrival line of a streamed
// request and of a card fetch alike, and nothing else in the ledger moves — the
// execution lines and the ingress response line are the same with the setting
// on as off, stamps, ports and minted ids aside.
func TestLedgerHeaders_OnMovesNoOtherLine(t *testing.T) {
	run := func(on bool) []string {
		_, model := newFakeModel(http.StatusOK)
		defer model.Close()
		out := &syncBuffer{}
		lw := newLineWriter(out)
		srv := httptest.NewServer(newServerHandler("worker", workerA2AMux(t, model.URL, lw), lw, newInjector(), withHeaderReading(on)))
		defer srv.Close()
		req, _ := http.NewRequest(http.MethodPost, srv.URL+"/", strings.NewReader(a2aGoSendMessageBody))
		req.Header = identityHeaders()
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
		srv.Close()
		return rawLines(out.String())
	}
	off, on := run(false), run(true)
	if len(off) != len(on) {
		t.Fatalf("lines: off %d, on %d", len(off), len(on))
	}
	strip := regexp.MustCompile(`,"headers":\{.*\}\}$`)
	ids := regexp.MustCompile(`"(ts|taskId|contextId)":"[^"]*"`)
	for i := range off {
		a := ids.ReplaceAllString(masked(off[i]), `"$1":"-"`)
		b := ids.ReplaceAllString(masked(strip.ReplaceAllString(on[i], "}")), `"$1":"-"`)
		if a != b {
			t.Errorf("line %d:\noff %s\non  %s", i, a, b)
		}
	}
	if !strings.Contains(on[0], `"headers":{`) || strings.Contains(strings.Join(on[1:], ""), `"headers":{`) {
		t.Errorf("want the reading on the first line (the arrival) only:\n%s", strings.Join(on, "\n"))
	}
}

// main stops at start on a value that is not "on", naming the setting, and with
// "on" it starts, says so, and writes the reading on an arrival line. Run as a
// child process of this test binary, the way the process is run.
func TestMain_LedgerHeadersIsReadAtStart(t *testing.T) {
	if os.Getenv("WORKER_MAIN_CHILD") == "1" {
		main()
		return
	}
	run := func(value string) (*exec.Cmd, *syncBuffer, *syncBuffer) {
		cmd := exec.Command(os.Args[0], "-test.run=^TestMain_LedgerHeadersIsReadAtStart$")
		cmd.Env = append(os.Environ(), "WORKER_MAIN_CHILD=1", ledgerHeadersEnv+"="+value,
			"LISTEN_ADDR=127.0.0.1:0", "OTEL_EXPORTER_OTLP_ENDPOINT=", "OTEL_SDK_DISABLED=true")
		stderr, stdout := &syncBuffer{}, &syncBuffer{}
		cmd.Stderr, cmd.Stdout = stderr, stdout
		return cmd, stderr, stdout
	}
	for _, v := range []string{"ON", "true", "on "} {
		cmd, stderr, _ := run(v)
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
			if !strings.Contains(stderr.String(), ledgerHeadersEnv) || strings.Contains(stderr.String(), "listening") {
				t.Errorf("%q: stderr = %q, want the setting named and no listening line", v, stderr.String())
			}
		case <-time.After(10 * time.Second):
			_ = cmd.Process.Kill()
			t.Errorf("%q: the process was still running after 10 s, want it stopped at start", v)
		}
	}

	for _, v := range []string{"", "on"} {
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		addr := l.Addr().String()
		_ = l.Close()
		cmd, stderr, stdout := run(v)
		cmd.Env = append(cmd.Env, "LISTEN_ADDR="+addr)
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		deadline := time.Now().Add(10 * time.Second)
		for !strings.Contains(stderr.String(), "listening") && time.Now().Before(deadline) {
			time.Sleep(20 * time.Millisecond)
		}
		if !strings.Contains(stderr.String(), ledgerHeadersEnv+"="+`"`+v+`"`) {
			t.Errorf("%q: stderr = %q, want a listening line naming the setting's value", v, stderr.String())
		}
		for {
			conn, err := net.Dial("tcp", addr)
			if err == nil {
				_ = conn.Close()
				_ = post(t, "http://"+addr+"/", a2aSubscribeToTaskBody)
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("the process never accepted a connection on %s", addr)
			}
			time.Sleep(20 * time.Millisecond)
		}
		for !strings.Contains(stdout.String(), `"phase":"response"`) && time.Now().Before(deadline) {
			time.Sleep(20 * time.Millisecond)
		}
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		arrival := rawLines(stdout.String())[0]
		if has := strings.Contains(arrival, `"headers":{`); has != (v == "on") {
			t.Errorf("%q: arrival = %s; headers present = %v, want %v", v, arrival, has, v == "on")
		}
	}
}

// workerA2AMux is the A2A mux main builds, with a real executor calling the
// model at modelURL.
func workerA2AMux(t *testing.T, modelURL string, lw *lineWriter) http.Handler {
	t.Helper()
	executor := newLabExecutor("worker", newModelClient(modelURL+"/v1", "mock", "unused", httpclient.New(10*time.Second)), lw)
	mux := http.NewServeMux()
	mux.Handle(a2asrv.WellKnownAgentCardPath, a2asrv.NewStaticAgentCardHandler(buildCard("worker", "http://worker")))
	mux.Handle("/", a2asrv.NewJSONRPCHandler(newRequestHandler(executor, lw, "")))
	return mux
}

// Every name on the fixed list, sent once each, has its value recorded, and
// the list is exactly the ten names the Python orchestrator reads
// (agents/orchestrator/tests/test_ledger_headers.py, GO_LIST). Added by D-2
// for D-1's review item M3: with via dropped from the list the suite still
// passed, because no test sent a Via header; this one sends every listed
// header, so dropping any one of them fails it.
func TestLedgerHeaders_OnRecordsEveryListedValue(t *testing.T) {
	want := []string{"host", "user-agent", "x-caller", "forwarded", "x-forwarded-for", "x-forwarded-proto",
		"x-forwarded-host", "x-real-ip", "via", "x-forwarded-client-cert"}
	if !reflect.DeepEqual(headerValuesRead, want) {
		t.Fatalf("headerValuesRead = %v\nwant              %v", headerValuesRead, want)
	}
	sent := map[string]string{
		"User-Agent":              "lab-test/2",
		"X-Caller":                "orchestrator",
		"Forwarded":               "for=10.0.0.9;proto=http",
		"X-Forwarded-For":         "10.0.0.9",
		"X-Forwarded-Proto":       "http",
		"X-Forwarded-Host":        "worker.lab.internal",
		"X-Real-Ip":               "10.0.0.9",
		"Via":                     "1.1 agentgateway",
		"X-Forwarded-Client-Cert": "URI=spiffe://cluster.local/ns/lab/sa/default",
	}
	h := http.Header{}
	h.Set("Content-Type", "application/json")
	for k, v := range sent {
		h.Set(k, v)
	}
	lines := serveOnce(t, h, a2aGoSendMessageBody, withHeaderReading(true))
	if len(lines) != 2 {
		t.Fatalf("lines = %d, want 2", len(lines))
	}
	var arrival readingOnLine
	if err := json.Unmarshal([]byte(lines[0]), &arrival); err != nil || arrival.Headers == nil {
		t.Fatalf("arrival = %s, want a headers object (%v)", lines[0], err)
	}
	for k, v := range sent {
		name := strings.ToLower(k)
		if got, ok := arrival.Headers.Values[name]; !ok || got != v {
			t.Errorf("values[%q] = %q (present %v), want %q", name, got, ok, v)
		}
	}
	if !strings.HasPrefix(arrival.Headers.Values["host"], "127.0.0.1:") {
		t.Errorf("values[host] = %q, want the address the request named", arrival.Headers.Values["host"])
	}
	if len(arrival.Headers.Values) != len(want) {
		t.Errorf("values has %d names, want %d: %v", len(arrival.Headers.Values), len(want), arrival.Headers.Values)
	}
}
