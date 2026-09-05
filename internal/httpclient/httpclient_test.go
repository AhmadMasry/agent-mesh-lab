package httpclient

import (
	"net/http"
	"testing"
	"time"
)

// The lab's HTTP clients must carry no replay path beyond what net/http does
// on its own. These assertions pin the transport settings the baseline entry records.
func TestNew_TransportHasNoRetryCapableFeatures(t *testing.T) {
	c := New(30 * time.Second)
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
		t.Errorf("DisableKeepAlives = true, want false (keep-alives on so the stale scenario is real)")
	}
	if tr.MaxIdleConnsPerHost <= 0 {
		t.Errorf("MaxIdleConnsPerHost = %d, want > 0", tr.MaxIdleConnsPerHost)
	}
	if tr.Proxy != nil {
		t.Errorf("Proxy set, want nil (no environment proxy)")
	}
	if tr.ResponseHeaderTimeout <= 0 || tr.TLSHandshakeTimeout <= 0 || tr.IdleConnTimeout <= 0 {
		t.Errorf("timeouts not all explicit: response-header %v, tls %v, idle %v", tr.ResponseHeaderTimeout, tr.TLSHandshakeTimeout, tr.IdleConnTimeout)
	}
}

func TestNew_EachCallReturnsIndependentTransport(t *testing.T) {
	a, b := New(time.Second), New(time.Second)
	if a.Transport == b.Transport {
		t.Fatalf("two clients share one transport; per-caller pools are expected")
	}
}
