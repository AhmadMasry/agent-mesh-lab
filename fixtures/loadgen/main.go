// Command loadgen sends exactly one A2A SendMessage with the a2a-go client and
// prints one client-ledger line per attempt. It contains no retry logic of its
// own: the a2a-go client has no retry option, and the HTTP client comes from
// internal/httpclient, whose default carries none.
//
// Two knobs exist for Experiment A.2, which asks what a client puts on the wire
// when it retries. Both are read from the environment, both default to off, and
// TestKnobs_DefaultOff asserts that:
//
//   - CLIENT_RETRIES=<n>     n > 0 builds the HTTP client with
//     httpclient.NewRetryingOn, which re-sends the same bytes when the send
//     fails. Unset, empty, or anything that is not a positive integer leaves the
//     no-retry client in place.
//   - CLIENT_RETRY_ON=<mode> what CLIENT_RETRIES re-sends on: "transport"
//     (default; a transport error only) or "transport+503" (also one re-send on
//     an HTTP 503 response, and on no other status). The mode is not a switch:
//     with CLIENT_RETRIES unset there is no retry to widen.
//   - CLIENT_SDK_RESEND=on   after a failed send, invoke the SDK's SendMessage
//     once more with the same request object, and print a second client line
//     with attempt 2. Any other value leaves it off.
//
// The A.2 run script sets one of them for one measured repetition. Nothing else
// in the lab sets either, so every other run sends exactly once.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2aclient"
	"github.com/a2aproject/a2a-go/v2/a2aclient/agentcard"

	"github.com/AhmadMasry/agent-mesh-lab/internal/a2areq"
	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
)

// identityTransport puts the two identity headers a load client knows on every
// request it sends: the work item this Job exists to send, and its own name.
// They are static because one Job sends one work item.
//
// They exist because an A2A request carries the work item inside
// Message.metadata, which no HTTP instrumentation reads, so the receiver's
// server span would otherwise have nothing to attribute it to. Nothing about
// the A2A message changes: these are HTTP headers beside it, and the body is
// untouched.
type identityTransport struct {
	base     http.RoundTripper
	workItem string
}

func (t identityTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	// A RoundTripper may not modify the request it was given.
	next := req.Clone(req.Context())
	next.Header.Set("X-Logical-Work-Item-Id", t.workItem)
	next.Header.Set("X-Caller", "loadgen")
	return t.base.RoundTrip(next)
}

// instrument wraps a client's transport so its requests carry the identity
// headers and a trace context. The client's own settings, including whichever
// retry knob built it, are the ones it was constructed with; nothing here adds
// a retry or changes a timeout.
func instrument(hc *http.Client, workItem string) *http.Client {
	hc.Transport = labotel.Transport(identityTransport{base: hc.Transport, workItem: workItem})
	return hc
}

type clientLine struct {
	Ledger string `json:"ledger"`
	TS     string `json:"ts"`
	// Attempt is 1 on the only send this fixture makes unless CLIENT_SDK_RESEND
	// asked for a second one, which prints its own line with attempt 2.
	Attempt              int      `json:"attempt"`
	LogicalWorkItemID    string   `json:"logical_work_item_id"`
	MessageID            string   `json:"messageId"`
	TaskID               string   `json:"taskId"`
	ResultKind           string   `json:"result_kind"`
	State                string   `json:"state"`
	A2AVersion           string   `json:"a2a_version"`
	CardProtocolVersions []string `json:"card_protocol_versions"`
	Error                string   `json:"error,omitempty"`
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// knobs holds the opt-in retry settings, read once from the environment.
type knobs struct {
	retries   int
	retryOn   httpclient.RetryOn
	sdkResend bool
}

// knobsFromEnv reads the knobs. A value that is not a positive integer, or a
// resend value that is not exactly "on", leaves the knob off: a run script typo
// must not turn into a retry nobody asked for.
func knobsFromEnv() knobs {
	k := knobs{retryOn: httpclient.ParseRetryOn(os.Getenv("CLIENT_RETRY_ON"))}
	if n, err := strconv.Atoi(os.Getenv("CLIENT_RETRIES")); err == nil && n > 0 {
		k.retries = n
	}
	k.sdkResend = os.Getenv("CLIENT_SDK_RESEND") == "on"
	return k
}

// httpClient builds the client these knobs ask for: the lab's no-retry client
// unless CLIENT_RETRIES asked for more.
func (k knobs) httpClient(timeout time.Duration) *http.Client {
	if k.retries > 0 {
		return httpclient.NewRetryingOn(timeout, k.retries, k.retryOn)
	}
	return httpclient.New(timeout)
}

func main() {
	target := os.Getenv("TARGET_URL")
	lwi := os.Getenv("LWI")
	if target == "" || lwi == "" {
		fmt.Fprintln(os.Stderr, "loadgen: TARGET_URL and LWI are required")
		os.Exit(2)
	}
	text := getenv("TEXT", "hello")
	k := knobsFromEnv()
	line := clientLine{Ledger: "client", Attempt: 1, LogicalWorkItemID: lwi, A2AVersion: string(a2a.Version)}
	emit := func() {
		line.TS = time.Now().UTC().Format(time.RFC3339Nano)
		b, _ := json.Marshal(line)
		fmt.Println(string(b))
	}

	// Tracing, if OTEL_EXPORTER_OTLP_ENDPOINT names a collector; nothing at all
	// otherwise. This process is a Job that exits as soon as its one send is
	// done, and a batch span processor flushes on a timer, so every exit path
	// below goes through done(), which shuts the provider down first.
	otelShutdown, err := labotel.Setup(context.Background())
	if err != nil {
		fmt.Fprintln(os.Stderr, "loadgen: tracing setup:", err)
		os.Exit(2)
	}
	done := func(code int) {
		flushCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := otelShutdown(flushCtx); err != nil {
			fmt.Fprintln(os.Stderr, "loadgen: tracing shutdown:", err)
		}
		os.Exit(code)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	hc := instrument(k.httpClient(90*time.Second), lwi)

	card, err := agentcard.NewResolver(hc).Resolve(ctx, target)
	if err != nil {
		line.Error = "resolve card: " + err.Error()
		emit()
		done(3)
	}
	for _, iface := range card.SupportedInterfaces {
		line.CardProtocolVersions = append(line.CardProtocolVersions, string(iface.ProtocolVersion))
	}
	client, err := a2aclient.NewFromCard(ctx, card, a2aclient.WithDefaultsDisabled(), a2aclient.WithJSONRPCTransport(hc))
	if err != nil {
		line.Error = "create client: " + err.Error()
		emit()
		done(3)
	}

	req := a2areq.Build(lwi, text)
	line.MessageID = req.Message.ID
	res, err := client.SendMessage(ctx, req)
	if err != nil {
		// A failed attempt is a recorded outcome, printed before anything else
		// happens, so the line exists whatever the next attempt does.
		line.Error = err.Error()
		emit()
		if !k.sdkResend {
			// The process exits non-zero only because no result object exists
			// to describe.
			done(3)
		}
		// The SDK-layer resend asked for by CLIENT_SDK_RESEND: the same request
		// object, handed to SendMessage a second time. What the SDK then puts on
		// the wire is what A.2 measures, so nothing here is changed for it.
		line.Attempt = 2
		line.Error = ""
		res, err = client.SendMessage(ctx, req)
		if err != nil {
			line.Error = err.Error()
			emit()
			done(3)
		}
	}
	switch r := res.(type) {
	case *a2a.Task:
		line.ResultKind = "task"
		line.TaskID = string(r.ID)
		line.State = string(r.Status.State)
	case *a2a.Message:
		line.ResultKind = "message"
		line.TaskID = string(r.TaskID)
	default:
		line.ResultKind = fmt.Sprintf("%T", res)
	}
	emit()
	done(0)
}
