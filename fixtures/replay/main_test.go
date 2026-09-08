package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// The harness is a fixture, so it carries no replay path of its own. These are
// the same assertions internal/httpclient's own test makes, applied to the
// client the harness builds, so the setting is recorded on this binary too.
func TestHarnessClient_HasNoRetryCapableFeatures(t *testing.T) {
	c := newClient(30 * time.Second)
	if c.Timeout != 30*time.Second {
		t.Fatalf("client timeout = %v, want 30s", c.Timeout)
	}
	tr, ok := c.Transport.(*http.Transport)
	if !ok {
		t.Fatalf("transport is %T, want *http.Transport", c.Transport)
	}
	if tr.ForceAttemptHTTP2 {
		t.Errorf("ForceAttemptHTTP2 = true, want false")
	}
	if tr.TLSNextProto == nil || len(tr.TLSNextProto) != 0 {
		t.Errorf("TLSNextProto = %v, want empty non-nil map (HTTP/2 off)", tr.TLSNextProto)
	}
	if tr.DisableKeepAlives {
		t.Errorf("DisableKeepAlives = true, want false")
	}
	if tr.MaxIdleConnsPerHost <= 0 {
		t.Errorf("MaxIdleConnsPerHost = %d, want > 0", tr.MaxIdleConnsPerHost)
	}
	if tr.Proxy != nil {
		t.Errorf("Proxy set, want nil (no environment proxy)")
	}
	if tr.ResponseHeaderTimeout <= 0 || tr.TLSHandshakeTimeout <= 0 || tr.IdleConnTimeout <= 0 {
		t.Errorf("timeouts not all explicit: response-header %v, tls %v, idle %v",
			tr.ResponseHeaderTimeout, tr.TLSHandshakeTimeout, tr.IdleConnTimeout)
	}
}

// One attempt is one request. A harness that sent an attempt twice would make
// every count in Gate 2 meaningless, so the arrival count is asserted here
// against a server that records what it received.
func TestSend_MakesExactlyOneRequestPerAttempt(t *testing.T) {
	var arrivals atomic.Int64
	var gotVersion, gotContentType, gotHost string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		arrivals.Add(1)
		gotVersion = r.Header.Get("A2A-Version")
		gotContentType = r.Header.Get("Content-Type")
		gotHost = r.Host
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":"x","result":{"id":"t1","status":{"state":"TASK_STATE_COMPLETED"}}}`))
	}))
	defer srv.Close()

	client := newClient(10 * time.Second)
	body := mustBuild(t, "rpc-1", "msg-1", "lwi-send", "hello")
	res := send(context.Background(), client, srv.URL, "worker.lab.internal", body)

	if got := arrivals.Load(); got != 1 {
		t.Fatalf("server saw %d requests for one attempt, want 1", got)
	}
	if res.info.Status != 200 || res.info.ResultKind != "task" || res.info.TaskID != "t1" {
		t.Errorf("attempt result = %+v, want status 200, kind task, taskId t1", res.info)
	}
	if res.err != nil {
		t.Errorf("transport error on a served request: %v", res.err)
	}
	if gotVersion != "1.0" {
		t.Errorf("A2A-Version header = %q, want %q (set explicitly by the harness)", gotVersion, "1.0")
	}
	if gotContentType != "application/json" {
		t.Errorf("Content-Type = %q, want %q", gotContentType, "application/json")
	}
	if gotHost != "worker.lab.internal" {
		t.Errorf("Host header = %q, want %q (HOST overrides the authority for host-based routing)", gotHost, "worker.lab.internal")
	}

	send(context.Background(), client, srv.URL, "", body)
	if got := arrivals.Load(); got != 2 {
		t.Fatalf("server saw %d requests after two attempts, want 2", got)
	}
}

// A transport failure is reported, not retried: the attempt is recorded with no
// status and the error text, and nothing is sent a second time.
func TestSend_TransportFailureIsRecordedNotRetried(t *testing.T) {
	var arrivals atomic.Int64
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
		arrivals.Add(1)
	}))
	target := srv.URL
	srv.Close() // nothing is listening on this address any more

	res := send(context.Background(), newClient(2*time.Second), target, "", mustBuild(t, "rpc-1", "msg-1", "lwi-dead", "hello"))
	if res.err == nil {
		t.Fatalf("send to a closed listener returned no error: %+v", res.info)
	}
	if res.info.Status != 0 || res.info.ResultKind != "none" {
		t.Errorf("failed attempt recorded as %+v, want status 0 and result_kind none", res.info)
	}
	if got := arrivals.Load(); got != 0 {
		t.Errorf("server saw %d requests, want 0", got)
	}
}
