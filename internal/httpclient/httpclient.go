// Package httpclient builds the one HTTP client every lab binary uses to talk
// to another lab component. It exists so the retry-relevant transport settings
// are written once and recorded once.
//
// Settings, and what they leave in place:
//   - HTTP/2 is off (ForceAttemptHTTP2=false, TLSNextProto set to an empty map),
//     so the http2 client's own retry on GOAWAY or REFUSED_STREAM cannot occur.
//   - Keep-alives are on and the idle pool is small, so a reused connection can
//     go stale; that is a scenario the baseline runs on purpose.
//   - No Proxy function: the environment's proxy variables are ignored.
//   - Dial, TLS handshake, response-header, and idle timeouts are explicit; the
//     client's overall Timeout is the caller's.
//   - No Idempotency-Key or X-Idempotency-Key header is ever set by lab code.
//
// What net/http still does on its own with these settings, from
// net/http/transport.go (persistConn.shouldRetryRequest) and request.go
// (Request.isReplayable):
//   - On a reused connection where nothing was written before the connection
//     failed, the transport redials and sends the request again if the body can
//     be rewound (Request.GetBody is set, which http.NewRequest does for bytes
//     and strings readers). That replay never reached the server, so a
//     server-side ledger cannot see it and it cannot cause duplicate work.
//   - A request that was written and then lost its reused connection
//     (transportReadFromServerError, errServerClosedIdle) is retried only if it
//     is replayable: GET, HEAD, OPTIONS, TRACE, or any method carrying an
//     Idempotency-Key header. That replay does reach the server twice. The lab's
//     A2A operations are POST without an idempotency header and are never
//     replayed once written; the agent-card fetch is a GET and can be.
package httpclient

import (
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"time"
)

// New returns a client whose transport is built by hand with the settings
// documented on the package. Each call returns an independent connection pool.
func New(timeout time.Duration) *http.Client {
	tr := &http.Transport{
		Proxy: nil,
		DialContext: (&net.Dialer{
			Timeout:   5 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2:     false,
		TLSNextProto:          map[string]func(string, *tls.Conn) http.RoundTripper{},
		DisableKeepAlives:     false,
		MaxIdleConns:          4,
		MaxIdleConnsPerHost:   2,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   5 * time.Second,
		ResponseHeaderTimeout: timeout,
		ExpectContinueTimeout: 0,
	}
	return &http.Client{Transport: tr, Timeout: timeout}
}

// RetryOn names the failures the opt-in retry re-sends on. It exists because
// A.2 measured what a receiver-side connection close looks like to a client
// through an agentgateway waypoint: the waypoint answers 503, so a client that
// re-sends only on a transport error never re-sends at all on that path.
type RetryOn string

const (
	// RetryOnTransport re-sends only when the transport itself returned an
	// error, so any response, of any status, ends the request. This is the
	// default everywhere.
	RetryOnTransport RetryOn = "transport"
	// RetryOnTransportOr503 also re-sends once on an HTTP 503 response, and on
	// no other status. It is the narrowest mode that can re-send at all behind a
	// gateway that turns an upstream connection failure into a 503.
	RetryOnTransportOr503 RetryOn = "transport+503"
)

// ParseRetryOn reads a mode name. Only the exact string "transport+503" selects
// the 503 mode; everything else, including an empty or misspelt value, is the
// default, so a run-script typo cannot widen what a client re-sends on.
func ParseRetryOn(s string) RetryOn {
	if RetryOn(s) == RetryOnTransportOr503 {
		return RetryOnTransportOr503
	}
	return RetryOnTransport
}

// retryTransport re-sends a request when the wrapped transport returns a
// transport error and, in RetryOnTransportOr503, when it returns a 503. It is
// the lab's own HTTP-layer retry, added for the A.2 client-retry-identity runs
// and used only where a caller asks for it with NewRetrying or NewRetryingOn.
//
// What it re-sends is the same bytes: the body is rewound with Request.GetBody,
// which http.NewRequest sets for a bytes, strings or bytes.Buffer body, and no
// header is added, so the receiver's pre-dispatch ledger sees the second
// delivery carrying the same JSON-RPC id, the same messageId and the same body
// hash as the first. A request whose body cannot be rewound is not re-sent and
// its error or response is returned unchanged, because a second delivery with an
// empty body would be a different message rather than a retry.
type retryTransport struct {
	base    http.RoundTripper
	retries int
	on      RetryOn
}

func (t *retryTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := t.base.RoundTrip(req)
	for attempt := 0; attempt < t.retries && t.resend(resp, err); attempt++ {
		next, rewindErr := rewind(req)
		if rewindErr != nil {
			return resp, err
		}
		// A response the caller will never see is finished with first: its body
		// is drained and closed, so no reader is left open and the connection can
		// be reused rather than abandoned mid-body.
		if err == nil && resp != nil && resp.Body != nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
		}
		resp, err = t.base.RoundTrip(next)
	}
	return resp, err
}

// resend says whether this outcome is one this mode re-sends on. A transport
// error always is. A response is only ever a 503, and only in the 503 mode: this
// is a narrow allowance for one measured gateway behaviour, not a
// retry-on-failure policy.
func (t *retryTransport) resend(resp *http.Response, err error) bool {
	if err != nil {
		return true
	}
	return t.on == RetryOnTransportOr503 && resp != nil && resp.StatusCode == http.StatusServiceUnavailable
}

// rewind copies a request for another attempt with a fresh reader over the same
// bytes. A RoundTripper may not modify the request it was given, and the first
// attempt has already consumed and closed the original body, so the copy carries
// a new body from GetBody.
func rewind(req *http.Request) (*http.Request, error) {
	next := req.Clone(req.Context())
	if req.Body == nil {
		return next, nil
	}
	if req.GetBody == nil {
		return nil, errNotRewindable
	}
	body, err := req.GetBody()
	if err != nil {
		return nil, err
	}
	next.Body = body
	return next, nil
}

var errNotRewindable = errors.New("request body cannot be rewound (GetBody is nil)")

// NewRetrying returns the client New returns, with its transport wrapped so a
// request that fails at the transport is re-sent up to retries more times with
// the same bytes. Any response, of any status, ends the request; NewRetryingOn
// is how a caller asks for anything wider. retries <= 0 returns exactly the
// client New returns, so the default is the no-retry client.
//
// This exists for one measurement: Experiment A.2 asks what a client's retry
// puts on the wire the second time, which needs a retry that a lab binary can
// switch on for one run. Nothing enables it by default.
func NewRetrying(timeout time.Duration, retries int) *http.Client {
	return NewRetryingOn(timeout, retries, RetryOnTransport)
}

// NewRetryingOn is NewRetrying with the mode named. RetryOnTransportOr503 is the
// mode A.2 needs to measure an HTTP-layer retry on a path where the gateway
// answers 503 for a receiver whose connection went away; it re-sends the same
// bytes on that one status and on no other.
func NewRetryingOn(timeout time.Duration, retries int, on RetryOn) *http.Client {
	c := New(timeout)
	if retries > 0 {
		c.Transport = &retryTransport{base: c.Transport, retries: retries, on: on}
	}
	return c
}
