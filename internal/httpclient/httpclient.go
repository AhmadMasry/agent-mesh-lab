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
