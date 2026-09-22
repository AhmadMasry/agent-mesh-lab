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
//
// One more knob says WHERE the one send goes, and is not a retry knob:
//
//   - CLIENT_DIAL=target     the SendMessage POST is sent to TARGET_URL, the
//     address the card was resolved at, instead of the URL the card advertises.
//     The card is still resolved, and still recorded; the client is built from
//     a copy of it whose interface entries carry TARGET_URL and are otherwise
//     what the card advertised. Unset or empty, the client dials the advertised
//     URL, as an A2A client does and as every run before 2026-09-19 did. Any
//     other value is refused before anything is sent: see dialFromEnv.
//
// It exists for the A.3 rows that address the Python receiver's Service. That
// receiver's card advertises the agentgateway ingress, so without the knob only
// the card GET crosses the Service's own route and the POST enters through the
// ingress (docs/proposal-notes.md, the second note of 2026-09-19). It adds no
// send, no re-send and no transport: the HTTP client and the factory options are
// the ones every other run uses.
//
// One more switch says WHAT the one request is, for Experiment B (stream.go):
//
//   - MODE=stream            one SendStreamingMessage instead of the SendMessage.
//   - MODE=subscribe         one SubscribeToTask for TASK_ID.
//
// Unset or empty, the client sends the SendMessage every run before Experiment B
// sent, and prints the same line (TestMode_DefaultOff,
// TestMode_UnsetSendsTheUnaryMessageAndItsLine). Any other MODE, a TASK_ID
// without MODE=subscribe or MODE=subscribe without one is refused before
// anything is sent (modeFromEnv), and so is either mode with a retry knob on
// (checkModeKnobs). The HTTP client of the two modes differs from the unary one
// in one setting, recorded in stream.go.
//
// One more setting, for Experiment B's control row (cancel.go):
//
//   - CANCEL_AFTER_MS=<k>    with MODE=stream only: the stream's request context
//     is cancelled k ms after the send, once, and nothing is sent after it.
//
// Unset or empty it is off (TestCancel_DefaultOff). Anything that is not a
// positive whole number below the process's bound, and the setting with any
// other mode, is refused before anything is sent (cancelFromEnv).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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

// agentFromCard reads onto the invoke_agent span what the resolved card says
// about the agent: its name, version and description, each Conditionally
// Required "When available." in the conventions, and the URL the client will
// dial, which server.address and server.port come from. That URL is taken only
// when the card advertises exactly one interface -- a lab card does -- because
// with several the client's own choice of interface, not this function's, is the
// one being dialled.
//
// It is given the card the client is BUILT from, which with CLIENT_DIAL=target is
// the copy whose entries carry TARGET_URL: the span has to say what the wire did,
// and a span that named the advertised ingress on a request sent to the Service
// would say the opposite.
func agentFromCard(card *a2a.AgentCard) labotel.Agent {
	agent := labotel.Agent{Name: card.Name, Version: card.Version, Description: card.Description}
	if len(card.SupportedInterfaces) == 1 {
		agent.URL = card.SupportedInterfaces[0].URL
	}
	return agent
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
	// Appended on 2026-09-19, after every key the line already had, so the
	// earlier line is a byte-for-byte prefix of this one
	// (TestClientLine_ExistingKeysAreUnchangedByteForByte). AdvertisedURLs is the
	// URL of each interface entry as the resolved card gave it, in the card's
	// order, beside CardProtocolVersions. DialledURL is the URL the client was
	// built to send to, the same value the invoke_agent span takes its address
	// from: the advertised one unless CLIENT_DIAL=target, and empty when the card
	// advertises several interfaces, where the choice is the SDK's.
	AdvertisedURLs []string `json:"advertised_urls"`
	DialledURL     string   `json:"dialled_url"`
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

// dialMode is where the SendMessage POST is sent.
type dialMode string

const (
	// dialAdvertised is the URL the resolved card advertises.
	dialAdvertised dialMode = ""
	// dialTarget is TARGET_URL, the address the card was resolved at.
	dialTarget dialMode = "target"
)

// dialFromEnv reads CLIENT_DIAL. Unlike the retry knobs above, a value it does
// not know is an error and not "off". Those fall back to the state every other
// run is in, so a typo costs one row its retry and the counts show it. This one
// would fall back to the ingress: the row would run, complete, and be recorded
// as a row that addressed the Service when no request did.
func dialFromEnv() (dialMode, error) {
	switch v := os.Getenv("CLIENT_DIAL"); v {
	case "":
		return dialAdvertised, nil
	case string(dialTarget):
		return dialTarget, nil
	default:
		return "", fmt.Errorf("CLIENT_DIAL=%q is not a value this client knows; it is %q or unset, and nothing was sent", v, string(dialTarget))
	}
}

// cardToDial returns the card the client is built from. With the knob unset that
// is the resolved card itself, as it always was. With CLIENT_DIAL=target it is a
// copy whose interface entries carry the target URL. The entries are pointers, so
// each is copied before its URL is written: the resolved card keeps what it
// advertised, which the ledger line records. Binding, tenant and protocol version
// stay as advertised. a2a.NewAgentInterface is not used: it stamps the SDK's own
// protocol version on the entry, and a card advertising 0.x would then be sent to
// as if it advertised 1.0 (rule 7; TestDial_ACardAdvertising0xIsRefusedEitherWay).
func cardToDial(card *a2a.AgentCard, dial dialMode, target string) *a2a.AgentCard {
	if dial != dialTarget {
		return card
	}
	dialled := *card
	dialled.SupportedInterfaces = make([]*a2a.AgentInterface, len(card.SupportedInterfaces))
	for i, iface := range card.SupportedInterfaces {
		entry := *iface
		entry.URL = target
		dialled.SupportedInterfaces[i] = &entry
	}
	return &dialled
}

// sendConfig is what one send needs to know. One Job sends one work item.
type sendConfig struct {
	target    string
	workItem  string
	text      string
	sdkResend bool
	dial      dialMode
}

// configFromEnv reads everything main needs from the environment and refuses,
// before anything is sent, what must never run: a missing TARGET_URL or LWI, an
// unknown CLIENT_DIAL or MODE, a TASK_ID the mode cannot use, a retry knob on a
// stream or a subscription, and a CANCEL_AFTER_MS that is not a positive whole
// number below requestBound or that comes with any mode but the stream. It is main's
// opening, moved here on 2026-09-21 so a test can assert the refusals are wired
// in and not only written; its messages are the ones main printed before.
func configFromEnv() (runConfig, knobs, error) {
	target := os.Getenv("TARGET_URL")
	lwi := os.Getenv("LWI")
	if target == "" || lwi == "" {
		return runConfig{}, knobs{}, errors.New("TARGET_URL and LWI are required")
	}
	dial, err := dialFromEnv()
	if err != nil {
		return runConfig{}, knobs{}, err
	}
	mode, err := modeFromEnv()
	if err != nil {
		return runConfig{}, knobs{}, err
	}
	k := knobsFromEnv()
	if err := checkModeKnobs(mode.mode, k); err != nil {
		return runConfig{}, knobs{}, err
	}
	cancelAfter, err := cancelFromEnv(mode.mode)
	if err != nil {
		return runConfig{}, knobs{}, err
	}
	return runConfig{target: target, workItem: lwi, text: getenv("TEXT", "hello"), sdkResend: k.sdkResend, dial: dial, mode: mode,
		cancelAfter: cancelAfter}, k, nil
}

// requestBound is the whole process's bound on its one request, the context
// main gives it: the same 2 minutes the unary send always had. A CANCEL_AFTER_MS
// at or past it could never be made, so cancelFromEnv refuses one.
const requestBound = 2 * time.Minute

// httpClientFor is the HTTP client this process's one request is sent with: the
// knobs' client for the unary send, as it always was, and the stream client for
// the two Experiment B modes (stream.go says what differs).
func httpClientFor(mode clientMode, k knobs, timeout time.Duration) *http.Client {
	if mode != modeUnary {
		return streamHTTPClient(timeout)
	}
	return k.httpClient(timeout)
}

func main() {
	c, k, err := configFromEnv()
	if err != nil {
		fmt.Fprintln(os.Stderr, "loadgen:", err)
		os.Exit(2)
	}

	// Tracing, if OTEL_EXPORTER_OTLP_ENDPOINT names a collector; nothing at all
	// otherwise. This process is a Job that exits as soon as its one send is
	// done, and a batch span processor flushes on a timer, so the one way out
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

	ctx, cancel := context.WithTimeout(context.Background(), requestBound)
	defer cancel()
	hc := instrument(httpClientFor(c.mode.mode, k, 90*time.Second), c.workItem)

	done(runMode(ctx, hc, c, os.Stdout))
}

// send resolves the card, makes the one send and prints the client ledger
// line(s) to out. It returns the process's exit status: 0 when a result came
// back, 3 when the card, the client or the send failed. It is main's body from
// the card on, moved here unchanged on 2026-09-19 so that a test can run it
// against two servers and count where the GET and the POST land; the only
// statements it gained are the ones CLIENT_DIAL needs.
func send(ctx context.Context, hc *http.Client, c sendConfig, out io.Writer) int {
	lwi := c.workItem
	line := clientLine{Ledger: "client", Attempt: 1, LogicalWorkItemID: lwi, A2AVersion: string(a2a.Version)}
	emit := func() {
		line.TS = time.Now().UTC().Format(time.RFC3339Nano)
		b, _ := json.Marshal(line)
		fmt.Fprintln(out, string(b))
	}

	card, err := agentcard.NewResolver(hc).Resolve(ctx, c.target)
	if err != nil {
		line.Error = "resolve card: " + err.Error()
		emit()
		return 3
	}
	for _, iface := range card.SupportedInterfaces {
		line.CardProtocolVersions = append(line.CardProtocolVersions, string(iface.ProtocolVersion))
		line.AdvertisedURLs = append(line.AdvertisedURLs, iface.URL)
	}
	// The card the client is built from, and what the span and the line say was
	// dialled. Same factory options either way: no default transports, the one
	// JSON-RPC transport over the lab's HTTP client, whose retry settings are
	// the ones internal/httpclient recorded.
	dialled := cardToDial(card, c.dial, c.target)
	agent := agentFromCard(dialled)
	line.DialledURL = agent.URL
	client, err := a2aclient.NewFromCard(ctx, dialled, a2aclient.WithDefaultsDisabled(), a2aclient.WithJSONRPCTransport(hc))
	if err != nil {
		line.Error = "create client: " + err.Error()
		emit()
		return 3
	}

	req := a2areq.Build(lwi, c.text)
	line.MessageID = req.Message.ID

	// The GenAI `invoke_agent <name>` client span. It wraps the send, not the
	// card fetch above and not the knob branches below: one span is one logical
	// invocation, whatever CLIENT_SDK_RESEND then puts on the wire, and the
	// resend code is untouched. What it says about the agent is what the
	// resolved card said, its address is the one the client dials, and the
	// identity is what this Job exists to send.
	sendCtx, invoke := labotel.InvokeAgent(ctx, agent,
		labotel.Identity{WorkItem: lwi, MessageID: req.Message.ID, Caller: "loadgen"})

	res, err := client.SendMessage(sendCtx, req)
	if err != nil {
		// A failed attempt is a recorded outcome, printed before anything else
		// happens, so the line exists whatever the next attempt does.
		line.Error = err.Error()
		emit()
		if !c.sdkResend {
			// The process exits non-zero only because no result object exists
			// to describe.
			invoke.End(err)
			return 3
		}
		// The SDK-layer resend asked for by CLIENT_SDK_RESEND: the same request
		// object, handed to SendMessage a second time. What the SDK then puts on
		// the wire is what A.2 measures, so nothing here is changed for it.
		line.Attempt = 2
		line.Error = ""
		res, err = client.SendMessage(sendCtx, req)
		if err != nil {
			line.Error = err.Error()
			invoke.End(err)
			emit()
			return 3
		}
	}
	switch r := res.(type) {
	case *a2a.Task:
		line.ResultKind = "task"
		line.TaskID = string(r.ID)
		line.State = string(r.Status.State)
		// The A2A contextId is the conversation identifier the conventions ask
		// for, and it exists only when the answer was a Task.
		invoke.Conversation(r.ContextID)
	case *a2a.Message:
		line.ResultKind = "message"
		line.TaskID = string(r.TaskID)
		invoke.Conversation(r.ContextID)
	default:
		line.ResultKind = fmt.Sprintf("%T", res)
	}
	invoke.End(nil)
	emit()
	return 0
}
