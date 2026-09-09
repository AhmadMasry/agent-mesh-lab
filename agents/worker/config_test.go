package main

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func TestModelTimeout_DefaultAndOverride(t *testing.T) {
	t.Setenv("MODEL_TIMEOUT_S", "")
	if got := modelTimeout(); got != 60*time.Second {
		t.Fatalf("default = %v, want 60s", got)
	}
	t.Setenv("MODEL_TIMEOUT_S", "5")
	if got := modelTimeout(); got != 5*time.Second {
		t.Fatalf("override = %v, want 5s", got)
	}
	t.Setenv("MODEL_TIMEOUT_S", "nonsense")
	if got := modelTimeout(); got != 60*time.Second {
		t.Fatalf("bad value = %v, want the 60s default", got)
	}
}

// MODEL_RETRIES is the worker's only retry knob, added for the A.3 rows that ask
// what a retry between the agent and the model duplicates. Rule 4 of CLAUDE.md
// is that nothing in this lab retries unless a run switched it on, so the
// default is checked the way the A.2 client knobs are: by the type of the
// transport the client was built with, not by sending anything.
func TestModelRetries_DefaultOff(t *testing.T) {
	for _, v := range []string{"", "0", "-1", "yes", "1.5", " ", "on"} {
		t.Setenv("MODEL_RETRIES", v)
		if got := modelRetries(); got != 0 {
			t.Errorf("MODEL_RETRIES=%q gave %d, want 0", v, got)
		}
		tr := newModelHTTPClient(time.Second).Transport
		if _, plain := tr.(*http.Transport); !plain {
			t.Errorf("MODEL_RETRIES=%q built a client whose transport is %T, want the plain *http.Transport httpclient.New builds", v, tr)
		}
	}
}

// With the knob on, the model client re-sends once on a 503 and sends the same
// bytes. The mode is transport+503 and not the plain transport mode because A.2
// measured what a receiver-side failure looks like through an agentgateway
// waypoint: it arrives as a 503, which a transport-error-only retry can never
// act on.
func TestModelRetries_OnResendsOnceOn503(t *testing.T) {
	t.Setenv("MODEL_RETRIES", "1")

	var mu sync.Mutex
	var bodies [][]byte
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		bodies = append(bodies, body)
		n := len(bodies)
		mu.Unlock()
		if n == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"answered"}}]}`))
	}))
	defer srv.Close()

	client := newModelClient(srv.URL+"/v1", "mock", "unused", newModelHTTPClient(10*time.Second))
	got, err := client.complete(context.Background(), identity{WorkItem: "lwi-1", MessageID: "m-1", Caller: "worker"}, "hello")
	if err != nil {
		t.Fatalf("complete: %v", err)
	}
	if got != "answered" {
		t.Errorf("content = %q, want %q", got, "answered")
	}

	mu.Lock()
	defer mu.Unlock()
	if len(bodies) != 2 {
		t.Fatalf("the model endpoint read %d request(s), want 2 (one 503 and one re-send)", len(bodies))
	}
	if !bytes.Equal(bodies[0], bodies[1]) {
		t.Errorf("the re-send carried different bytes:\nfirst  %s\nsecond %s", bodies[0], bodies[1])
	}
}
