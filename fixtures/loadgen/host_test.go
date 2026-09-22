package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
)

// CLIENT_HOST (the author's note of 2026-09-22, "in Experiment B the Go receiver
// is reached through the ingress by a Host setting"): the request's Host, on
// every request the process makes, in every mode. These tests pin that it is
// off unless asked for, refused unless it is a bare host name, carried on the
// card GET and on the POST alike, and that nothing else on a request changes.

// The setting is off unless the environment names a value: unset and empty both
// leave every request naming the host of the URL it is sent to. The Job
// template renders CLIENT_HOST empty on every row that is not a B row that
// names it, so this is the test that keeps those rows what they were.
func TestHost_DefaultOff(t *testing.T) {
	for _, set := range []bool{false, true} {
		if set {
			t.Setenv("CLIENT_HOST", "")
		} else {
			t.Setenv("CLIENT_HOST", "x")
			unsetenv(t, "CLIENT_HOST")
		}
		host, err := hostFromEnv()
		if err != nil || host != "" {
			t.Errorf("set-empty=%v: got %q, %v; want off and no error", set, host, err)
		}
	}
}

// A bare host name, as an HTTPRoute's hostnames field takes one without a
// wildcard, is the one form accepted.
func TestHostFromEnv_ABareHostNameIsTaken(t *testing.T) {
	for _, v := range []string{"worker.lab.internal", "localhost", "a-b.c1", "x", strings.Repeat("a", 63) + ".b"} {
		t.Setenv("CLIENT_HOST", v)
		if host, err := hostFromEnv(); err != nil || host != v {
			t.Errorf("CLIENT_HOST=%q: got %q, %v", v, host, err)
		}
	}
}

// Anything else stops the Job before it sends. Like CLIENT_DIAL, a value this
// client does not take is not read as off: a Host dropped would send the row
// to whatever the ingress's catch-all route names, and it would be recorded as
// the row it was not.
func TestHostFromEnv_AnythingElseIsRefused(t *testing.T) {
	for _, v := range []string{"worker.lab.internal:80", "http://worker.lab.internal", "worker.lab.internal/",
		"Worker.lab.internal", " worker", "worker ", "worker..lab", ".worker", "worker.", "-worker", "worker-",
		"wor_ker", "10.0.0.1", "[::1]", "::1", "${CLIENT_HOST}", "*.lab.internal", "user@worker",
		strings.Repeat("a", 64) + ".b", strings.Repeat("a.", 127) + "ab"} {
		t.Setenv("CLIENT_HOST", v)
		_, err := hostFromEnv()
		if err == nil || !strings.Contains(err.Error(), fmt.Sprintf("%q", v)) {
			t.Errorf("CLIENT_HOST=%q: got %v, want a refusal that names the value", v, err)
		}
	}
}

// main's opening refuses what hostFromEnv refuses, in every mode, and carries
// what it accepts.
func TestConfigFromEnv_TheHostSettingIsWiredIn(t *testing.T) {
	base := map[string]string{"TARGET_URL": "http://t.example:8080", "LWI": "lwi-1", "CLIENT_DIAL": "",
		"MODE": "", "TASK_ID": "", "CLIENT_RETRIES": "", "CLIENT_SDK_RESEND": "", "CLIENT_RETRY_ON": "", "TEXT": "",
		"CANCEL_AFTER_MS": "", "CLIENT_HOST": ""}
	setAll := func(over map[string]string) {
		for k, v := range base {
			t.Setenv(k, v)
		}
		for k, v := range over {
			t.Setenv(k, v)
		}
	}
	modes := []map[string]string{{}, {"MODE": "stream"}, {"MODE": "subscribe", "TASK_ID": "task-9"}}
	for _, m := range modes {
		for _, host := range []string{"", "worker.lab.internal"} {
			over := map[string]string{"CLIENT_HOST": host}
			for k, v := range m {
				over[k] = v
			}
			setAll(over)
			c, _, err := configFromEnv()
			if err != nil || c.host != host {
				t.Errorf("%v: got host %q, %v; want %q", over, c.host, err, host)
			}
		}
		for _, bad := range []string{"${CLIENT_HOST}", "worker.lab.internal:80"} {
			over := map[string]string{"CLIENT_HOST": bad}
			for k, v := range m {
				over[k] = v
			}
			setAll(over)
			if _, _, err := configFromEnv(); err == nil {
				t.Errorf("%v: accepted", over)
			}
		}
	}
}

// seenRequest is one request as the recording server received it.
type seenRequest struct {
	method string
	path   string
	host   string
	header http.Header
	rpc    string
}

// hostServer serves an agent card advertising itself and answers each JSON-RPC
// method the way the lab's receivers do, recording every request with the Host
// it named.
type hostServer struct {
	*httptest.Server
	mu   sync.Mutex
	seen []seenRequest
}

func (s *hostServer) requests() []seenRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]seenRequest(nil), s.seen...)
}

func newHostServer(t *testing.T) *hostServer {
	t.Helper()
	s := &hostServer{}
	s.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var req struct {
			Method string          `json:"method"`
			ID     json.RawMessage `json:"id"`
		}
		_ = json.Unmarshal(raw, &req)
		s.mu.Lock()
		s.seen = append(s.seen, seenRequest{method: r.Method, path: r.URL.Path, host: r.Host, header: r.Header.Clone(), rpc: req.Method})
		s.mu.Unlock()
		switch {
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "agent-card.json"):
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(&a2a.AgentCard{
				Name: "hosted", Description: "a receiver behind a host-routed proxy", Version: "0.0.1",
				Capabilities: a2a.AgentCapabilities{Streaming: true},
				SupportedInterfaces: []*a2a.AgentInterface{{
					URL: s.URL, ProtocolBinding: a2a.TransportProtocolJSONRPC, ProtocolVersion: a2a.Version,
				}},
			})
		case r.Method == http.MethodPost && req.Method == "SendMessage":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":` + string(req.ID) +
				`,"result":{"task":{"id":"task-1","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}}`))
		case r.Method == http.MethodPost && req.Method == "SendStreamingMessage":
			sseStart(w)
			sseEvent(t, w, req.ID, taskEvent(a2a.TaskStateSubmitted))
			sseEvent(t, w, req.ID, statusEvent(a2a.TaskStateCompleted))
		case r.Method == http.MethodPost && req.Method == "SubscribeToTask":
			sseStart(w)
			sseEvent(t, w, req.ID, taskEvent(a2a.TaskStateWorking))
			sseEvent(t, w, req.ID, statusEvent(a2a.TaskStateCompleted))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(s.Close)
	return s
}

var hostModes = []modeConfig{{mode: modeUnary}, {mode: modeStream}, {mode: modeSubscribe, taskID: "task-1"}}

// runWithHost runs one process's worth of the mode the way main does -- the
// client from clientFor, then runMode -- and returns the exit status, the lines
// and every request the server saw.
func runWithHost(t *testing.T, m modeConfig, host string) (int, []map[string]any, []seenRequest, string) {
	t.Helper()
	srv := newHostServer(t)
	c := runConfig{target: srv.URL, workItem: "lwi-b4", text: "hello", mode: m, host: host}
	var out bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	code := runMode(ctx, clientFor(c, knobs{}), c, &out)
	// Give a would-be second request time to arrive before counting.
	time.Sleep(200 * time.Millisecond)
	u, _ := url.Parse(srv.URL)
	return code, parseLines(t, out.String()), srv.requests(), u.Host
}

// The Host is on EVERY request the process makes -- the card GET and the one
// POST -- in all three modes, and the process makes exactly those two requests.
// The request still goes to the URL it is sent to: the server that saw it is
// the one TARGET_URL names.
func TestHost_EveryRequestNamesItInEveryMode(t *testing.T) {
	for _, m := range hostModes {
		t.Run(string(m.mode)+"-mode", func(t *testing.T) {
			code, lines, reqs, _ := runWithHost(t, m, "worker.lab.internal")
			if code != 0 {
				t.Errorf("exit status %d, want 0; lines %v", code, lines)
			}
			var gets, posts int
			for _, r := range reqs {
				switch r.method {
				case http.MethodGet:
					gets++
				case http.MethodPost:
					posts++
				}
				if r.host != "worker.lab.internal" {
					t.Errorf("%s %s named Host %q, want worker.lab.internal", r.method, r.path, r.host)
				}
			}
			if gets != 1 || posts != 1 || len(reqs) != 2 {
				t.Errorf("server saw %d GET and %d POST (%d requests), want exactly the card GET and the one POST", gets, posts, len(reqs))
			}
			last := lines[len(lines)-1]
			wantField(t, last, "host", "worker.lab.internal")
		})
	}
}

// Empty, the setting changes nothing: every request names the host of the URL
// it is sent to, as every run before it did, and no line carries a host key.
func TestHost_EmptyLeavesEveryRequestNamingItsURLsHost(t *testing.T) {
	for _, m := range hostModes {
		t.Run(string(m.mode)+"-mode", func(t *testing.T) {
			code, lines, reqs, urlHost := runWithHost(t, m, "")
			if code != 0 || len(reqs) != 2 {
				t.Errorf("exit status %d, %d requests; want 0 and 2", code, len(reqs))
			}
			for _, r := range reqs {
				if r.host != urlHost {
					t.Errorf("%s %s named Host %q, want the URL's %q", r.method, r.path, r.host, urlHost)
				}
			}
			for _, l := range lines {
				if _, ok := l["host"]; ok {
					t.Errorf("a line carries a host key with the setting off: %v", l)
				}
			}
		})
	}
}

// Nothing else on a request changes: with the setting on, each request has the
// method, the path, the JSON-RPC method and the headers it has with the setting
// off. (The Host is not in r.Header on the server; net/http moves it to r.Host.)
func TestHost_NothingElseOnARequestChanges(t *testing.T) {
	shape := func(r seenRequest) string {
		var keys []string
		for k, v := range r.header {
			switch k {
			case "Traceparent", "Tracestate":
				// per-run trace context, when a tracer is set
				keys = append(keys, k)
			default:
				keys = append(keys, k+"="+strings.Join(v, ","))
			}
		}
		sort.Strings(keys)
		return r.method + " " + r.path + " " + r.rpc + " " + strings.Join(keys, ";")
	}
	for _, m := range hostModes {
		t.Run(string(m.mode)+"-mode", func(t *testing.T) {
			_, _, off, _ := runWithHost(t, m, "")
			_, _, on, _ := runWithHost(t, m, "worker.lab.internal")
			if len(off) != len(on) {
				t.Fatalf("requests off %d, on %d", len(off), len(on))
			}
			for i := range off {
				if a, b := shape(off[i]), shape(on[i]); a != b {
					t.Errorf("request %d differs beyond its Host:\n off %s\n on  %s", i+1, a, b)
				}
			}
		})
	}
}
