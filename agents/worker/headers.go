package main

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
)

// ledgerHeadersEnv names the ledger setting that makes the pre-dispatch ingress
// ledger read the request's headers (Experiment C's open thread after C-10:
// which headers reach the application, and does any caller identity arrive in
// one). The Python orchestrator reads the same name with the same values and
// writes the same fields, so one setting reads the same on both receivers.
//
//	unset or empty   off: every ledger line is byte for byte what it was before
//	                 the setting existed (TestLedgerHeaders_DefaultOff,
//	                 TestLedgerHeaders_OffLinesAreByteForByteToday)
//	on               the arrival line gains one key, "headers", described at
//	                 headerRecord; the response line does not
//	anything else    the process stops at start (main), so a typo cannot leave
//	                 a run believing it read headers it did not
const ledgerHeadersEnv = "LEDGER_HEADERS"

// ledgerHeadersFrom reads the setting's value. Matched exactly, as
// REFUSE_OPERATION is: no trimming, no case folding.
func ledgerHeadersFrom(v string) (bool, error) {
	switch v {
	case "":
		return false, nil
	case "on":
		return true, nil
	}
	return false, fmt.Errorf("%s=%q is not a value this agent reads; want on, or empty for off", ledgerHeadersEnv, v)
}

// headerValuesRead is the fixed list of headers whose VALUES the reading
// records, lower-cased as they are compared. Every other header is recorded by
// name only. Each is here because it can carry who called or how the request
// was routed:
//
//	host                     the name the caller addressed; the ingress routes
//	                         on it (worker.lab.internal)
//	user-agent               which client library sent the request
//	x-caller                 the orchestrator's own declaration of itself,
//	                         set by its forwarder on every request
//	forwarded                RFC 7239's forwarding record
//	x-forwarded-for          the de-facto forwarding records a proxy may add
//	x-forwarded-proto
//	x-forwarded-host
//	x-real-ip
//	via                      RFC 9110's record of intermediaries
//	x-forwarded-client-cert  the header a proxy uses to pass the caller's
//	                         client certificate on, SPIFFE URI included
//
// authorization is deliberately NOT on it: its presence is recorded as
// authorization_present, and its value is never read into a line.
var headerValuesRead = []string{
	"host", "user-agent", "x-caller",
	"forwarded", "x-forwarded-for", "x-forwarded-proto", "x-forwarded-host", "x-real-ip", "via",
	"x-forwarded-client-cert",
}

// headerRecord is the reading, written as the arrival line's last key.
//
//	names                  every header name that arrived, lower-cased, each
//	                       once, sorted
//	values                 name -> value for the names on headerValuesRead that
//	                       arrived; a header sent more than once is joined with
//	                       ", " in arrival order. Always an object, empty when
//	                       none arrived, so "none arrived" and "not read" differ
//	authorization_present  whether an Authorization header arrived; its value is
//	                       never recorded
type headerRecord struct {
	Names                []string          `json:"names"`
	Values               map[string]string `json:"values"`
	AuthorizationPresent bool              `json:"authorization_present"`
}

// readHeaders builds the reading from what net/http handed the handler. net/http
// moves three headers out of Request.Header while it parses the request — Host
// into Request.Host, Transfer-Encoding into Request.TransferEncoding and Trailer
// into Request.Trailer (net/http server.go and transfer.go) — so their names are
// put back here, and host's value is read from Request.Host. The ASGI server the
// Python receiver runs keeps every header in its list, so with this the two
// receivers' lists name what arrived on the wire.
func readHeaders(r *http.Request) *headerRecord {
	seen := map[string]bool{}
	for k := range r.Header {
		seen[strings.ToLower(k)] = true
	}
	if r.Host != "" {
		seen["host"] = true
	}
	if len(r.TransferEncoding) > 0 {
		seen["transfer-encoding"] = true
	}
	if r.Trailer != nil {
		seen["trailer"] = true
	}
	rec := &headerRecord{Names: make([]string, 0, len(seen)), Values: map[string]string{}}
	for k := range seen {
		rec.Names = append(rec.Names, k)
	}
	sort.Strings(rec.Names)
	for _, name := range headerValuesRead {
		if name == "host" {
			if r.Host != "" {
				rec.Values["host"] = r.Host
			}
			continue
		}
		if vs := r.Header.Values(name); len(vs) > 0 {
			rec.Values[name] = strings.Join(vs, ", ")
		}
	}
	rec.AuthorizationPresent = len(r.Header.Values("Authorization")) > 0
	return rec
}

// ingressConfig is what the ingress middleware is built with beyond its
// handler, writer and injector. Its zero value is the ledger as it was before
// any option existed.
type ingressConfig struct {
	headers bool
}

type ingressOption func(*ingressConfig)

// withHeaderReading switches the header reading on or off.
func withHeaderReading(on bool) ingressOption {
	return func(c *ingressConfig) { c.headers = on }
}
