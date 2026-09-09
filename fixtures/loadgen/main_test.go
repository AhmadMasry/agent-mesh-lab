package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
)

// The two retry knobs this fixture carries for the A.2 runs are off unless the
// environment asks for them. Rule 4 of CLAUDE.md is that the fixtures contain no
// retry logic; the knobs exist so one measured repetition can switch a retry on,
// and this test is what keeps their absence from every other run a fact rather
// than an intention.
func TestKnobs_DefaultOff(t *testing.T) {
	t.Setenv("CLIENT_RETRIES", "")
	t.Setenv("CLIENT_SDK_RESEND", "")
	t.Setenv("CLIENT_RETRY_ON", "")

	k := knobsFromEnv()
	if k.retries != 0 {
		t.Errorf("retries = %d, want 0 with CLIENT_RETRIES unset", k.retries)
	}
	if k.sdkResend {
		t.Errorf("sdkResend = true, want false with CLIENT_SDK_RESEND unset")
	}
	if k.retryOn != httpclient.RetryOnTransport {
		t.Errorf("retryOn = %q, want %q with CLIENT_RETRY_ON unset", k.retryOn, httpclient.RetryOnTransport)
	}
	tr := k.httpClient(time.Second).Transport
	if _, plain := tr.(*http.Transport); !plain {
		t.Errorf("the default client's transport is %T, want the plain *http.Transport httpclient.New builds", tr)
	}
}

func TestKnobs_ReadFromEnvironment(t *testing.T) {
	t.Setenv("CLIENT_RETRIES", "1")
	t.Setenv("CLIENT_SDK_RESEND", "on")

	k := knobsFromEnv()
	if k.retries != 1 {
		t.Errorf("retries = %d, want 1", k.retries)
	}
	if !k.sdkResend {
		t.Errorf("sdkResend = false, want true")
	}
	if _, plain := k.httpClient(time.Second).Transport.(*http.Transport); plain {
		t.Errorf("CLIENT_RETRIES=1 left the plain transport in place; the retrying client was expected")
	}
}

// A value that is not a positive count leaves the knob off rather than guessing
// what was meant, so a typo in a run script cannot silently add a retry.
func TestKnobs_UnreadableValuesLeaveTheKnobOff(t *testing.T) {
	for _, v := range []string{"yes", "-1", "0", "1.5", " "} {
		t.Setenv("CLIENT_RETRIES", v)
		if got := knobsFromEnv().retries; got != 0 {
			t.Errorf("CLIENT_RETRIES=%q gave retries = %d, want 0", v, got)
		}
	}
	for _, v := range []string{"true", "1", "yes", "ON "} {
		t.Setenv("CLIENT_SDK_RESEND", v)
		if knobsFromEnv().sdkResend {
			t.Errorf("CLIENT_SDK_RESEND=%q turned the knob on; only the exact value \"on\" does", v)
		}
	}
	for _, v := range []string{"", "503", "transport+500", " transport+503", "TRANSPORT+503", "on", "transport"} {
		t.Setenv("CLIENT_RETRY_ON", v)
		if got := knobsFromEnv().retryOn; got != httpclient.RetryOnTransport {
			t.Errorf("CLIENT_RETRY_ON=%q gave mode %q, want %q; only the exact value \"transport+503\" widens it", v, got, httpclient.RetryOnTransport)
		}
	}
}

// The 503 mode is what A.2's second HTTP-layer sub-row needs: behind a gateway
// that answers 503 for a receiver whose connection went away, that is the only
// thing an HTTP-layer retry can act on. It is named explicitly or not used.
func TestKnobs_RetryOnModeIsAskedForByName(t *testing.T) {
	t.Setenv("CLIENT_RETRIES", "1")
	t.Setenv("CLIENT_RETRY_ON", "transport+503")

	k := knobsFromEnv()
	if k.retryOn != httpclient.RetryOnTransportOr503 {
		t.Errorf("retryOn = %q, want %q", k.retryOn, httpclient.RetryOnTransportOr503)
	}
	if _, plain := k.httpClient(time.Second).Transport.(*http.Transport); plain {
		t.Errorf("the retrying client was expected with CLIENT_RETRIES=1")
	}

	// The mode on its own switches nothing on: CLIENT_RETRIES still decides
	// whether there is a retry at all.
	t.Setenv("CLIENT_RETRIES", "0")
	if _, plain := knobsFromEnv().httpClient(time.Second).Transport.(*http.Transport); !plain {
		t.Errorf("CLIENT_RETRY_ON alone wrapped the transport; the mode is not a switch")
	}
}

// An A2A request carries the logical work item inside Message.metadata, where no
// HTTP instrumentation can see it. The load client therefore also sends it as a
// header, along with the name of the caller, so the receiver's server span can
// be attributed to the work item. One Job sends one work item, so both values
// are fixed for the life of the process.
func TestLoadgen_RequestsCarryIdentityHeaders(t *testing.T) {
	arrived := make(chan http.Header, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		arrived <- r.Header.Clone()
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	client := instrument(httpclient.New(10*time.Second), "lwi-1")
	resp, err := client.Get(srv.URL)
	if err != nil {
		t.Fatalf("sending the request: %v", err)
	}
	_ = resp.Body.Close()

	header := <-arrived
	if got := header.Get("X-Logical-Work-Item-Id"); got != "lwi-1" {
		t.Errorf("X-Logical-Work-Item-Id: got %q, want %q", got, "lwi-1")
	}
	if got := header.Get("X-Caller"); got != "loadgen" {
		t.Errorf("X-Caller: got %q, want %q", got, "loadgen")
	}
}
