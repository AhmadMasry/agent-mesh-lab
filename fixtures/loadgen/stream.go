package main

// Experiment B's two modes: MODE=stream sends ONE SendStreamingMessage, and
// MODE=subscribe ONE SubscribeToTask for TASK_ID. Neither holds any retry,
// resend or reconnect logic. A B row that resubscribes runs two Jobs, and the
// second is a separate stimulus sent once; no process of this client waits for
// anything and sends again. What each mode records is described on streamEvent
// and streamEnd.
//
// The HTTP client these modes use is httpclient.New's with one setting changed,
// recorded here under rule 4 (CLAUDE.md):
//
//   - http.Client.Timeout is 0. net/http's Timeout "includes connection time,
//     any redirects, and reading the response body", so the unary client's 90 s
//     would end every stream at 90 s by itself. The request context is the bound
//     instead: main's 2-minute context, the same one the unary send has.
//   - Everything else is httpclient.New's, unchanged: ResponseHeaderTimeout 90 s
//     (the answer's head, not its body), keep-alives on, HTTP/2 off, no proxy,
//     the dial and TLS timeouts. No retrying transport is ever built for these
//     modes: checkModeKnobs refuses CLIENT_RETRIES and CLIENT_SDK_RESEND.
//   - Each Job is a new process, so its connection pool starts empty. The only
//     connection its POST can reuse is the one its own card GET opened a moment
//     before; no connection of an earlier Job, and none a lost stream left
//     behind, can be. On that one connection Go's transport can still send the
//     POST again if it finds the connection dead before writing any of it --
//     the replay internal/httpclient records, which never reaches a server --
//     and a POST is never replayed once written.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"iter"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2aclient"
	"github.com/a2aproject/a2a-go/v2/a2aclient/agentcard"

	"github.com/AhmadMasry/agent-mesh-lab/internal/a2areq"
	"github.com/AhmadMasry/agent-mesh-lab/internal/httpclient"
	labotel "github.com/AhmadMasry/agent-mesh-lab/internal/otel"
)

// clientMode is what the one request of this process is.
type clientMode string

const (
	// modeUnary is the SendMessage every run before Experiment B sent.
	modeUnary clientMode = ""
	// modeStream is one SendStreamingMessage.
	modeStream clientMode = "stream"
	// modeSubscribe is one SubscribeToTask for the task id it is given.
	modeSubscribe clientMode = "subscribe"
)

type modeConfig struct {
	mode   clientMode
	taskID string
}

// modeFromEnv reads MODE and TASK_ID. Like CLIENT_DIAL, and unlike the retry
// knobs, a value it does not know is refused before anything is sent: falling
// back to the unary send would run a row that sent something other than what it
// is recorded as, and in subscribe mode would start a new Task where a
// resubscription was asked for. For the same reason TASK_ID is required with
// MODE=subscribe and refused with any other mode, and an unsubstituted template
// placeholder is never a task id.
func modeFromEnv() (modeConfig, error) {
	v, task := os.Getenv("MODE"), os.Getenv("TASK_ID")
	var m modeConfig
	switch v {
	case "":
		m.mode = modeUnary
	case string(modeStream):
		m.mode = modeStream
	case string(modeSubscribe):
		m.mode = modeSubscribe
	default:
		return modeConfig{}, fmt.Errorf("MODE=%q is not a value this client knows; it is %q, %q or unset, and nothing was sent", v, string(modeStream), string(modeSubscribe))
	}
	switch {
	case strings.Contains(task, "${"):
		return modeConfig{}, fmt.Errorf("TASK_ID=%q is an unsubstituted template placeholder, not a task id; nothing was sent", task)
	case m.mode == modeSubscribe && task == "":
		return modeConfig{}, errors.New("MODE=subscribe needs TASK_ID, the task to subscribe to; nothing was sent")
	case m.mode != modeSubscribe && task != "":
		return modeConfig{}, fmt.Errorf("TASK_ID=%q is set, but MODE=%q sends no subscription; nothing was sent", task, v)
	}
	m.taskID = task
	return m, nil
}

// checkModeKnobs refuses a retry knob in the stream and subscribe modes: each of
// them sends one request, and a B row that retried would not be the row it is
// recorded as. The unary send keeps the A.2 knobs as they were.
func checkModeKnobs(mode clientMode, k knobs) error {
	if mode == modeUnary {
		return nil
	}
	if k.retries > 0 || k.sdkResend {
		return fmt.Errorf("MODE=%s sends one request and takes no retry knob (CLIENT_RETRIES=%d, CLIENT_SDK_RESEND=%v); nothing was sent", mode, k.retries, k.sdkResend)
	}
	return nil
}

// streamHTTPClient is httpclient.New(headerTimeout) with Timeout set to 0; the
// package comment above says why and what stays as it was.
func streamHTTPClient(headerTimeout time.Duration) *http.Client {
	hc := httpclient.New(headerTimeout)
	hc.Timeout = 0
	return hc
}

// runConfig is what one process needs to know. One Job sends one request.
type runConfig struct {
	target    string
	workItem  string
	text      string
	sdkResend bool
	dial      dialMode
	mode      modeConfig
}

// runMode makes this process's one request in the mode asked for and prints its
// client lines to out. The unary send is send(), unchanged.
func runMode(ctx context.Context, hc *http.Client, c runConfig, out io.Writer) int {
	switch c.mode.mode {
	case modeStream, modeSubscribe:
		return streamOnce(ctx, hc, c, out)
	default:
		return send(ctx, hc, sendConfig{target: c.target, workItem: c.workItem, text: c.text, sdkResend: c.sdkResend, dial: c.dial}, out)
	}
}

// streamEvent is one client line per event the SDK yielded, written when the
// SDK handed it over: its kind in A2A v1.0's vocabulary (task, message,
// status-update, artifact-update), its task, and its state where the event
// carries one (an artifact update carries none).
type streamEvent struct {
	Ledger            string `json:"ledger"`
	TS                string `json:"ts"`
	Mode              string `json:"mode"`
	Method            string `json:"method"`
	Line              string `json:"line"` // "event"
	Seq               int    `json:"seq"`
	LogicalWorkItemID string `json:"logical_work_item_id"`
	MessageID         string `json:"messageId"`
	TaskID            string `json:"taskId"`
	ContextID         string `json:"contextId"`
	Kind              string `json:"kind"`
	State             string `json:"state"`
}

// streamEnd is the one line written when the request is over, whatever ended
// it. It is always the last line.
//
// stream_end is how the SDK's iteration ended: "eof" when it ran out with no
// error, "error" when the SDK yielded one (its text is in error), "not-sent"
// when the card or the client failed and no request left. It does not say a
// terminal event arrived: a2a-go's SSE reader ends quietly on a clean end of
// the body, whatever the body carried, so terminal_seen is recorded beside it.
//
// http_status, content_type and wire_error_code / wire_error_message are read
// from the bytes of the one POST's answer as the SDK read them (wireObserver),
// not from the SDK: a2a-python answers a refused SubscribeToTask with a plain
// JSON body, which a2a-go's SSE reader skips line by line, so the SDK yields
// nothing and raises nothing and the refusal exists only on the wire. The first
// JSON-RPC error object found there is recorded, whether it came as a plain JSON
// body or as an event; 0 and "" mean none was found.
//
// posts counts the POST round trips the SDK handed to this process's outermost
// transport, the wireObserver. That is not a count of POSTs on the wire: a POST
// re-sent below the observer would not be counted. What reached the receiver is
// its ingress ledger's count. The tests count POSTs at the server, and nothing
// in this client sends twice.
type streamEnd struct {
	Ledger               string   `json:"ledger"`
	TS                   string   `json:"ts"`
	Mode                 string   `json:"mode"`
	Method               string   `json:"method"`
	Line                 string   `json:"line"` // "end"
	LogicalWorkItemID    string   `json:"logical_work_item_id"`
	MessageID            string   `json:"messageId"`
	TaskID               string   `json:"taskId"`
	RequestedTaskID      string   `json:"requested_task_id"`
	TSSent               string   `json:"ts_sent"`
	Events               int      `json:"events"`
	FirstKind            string   `json:"first_kind"`
	FirstState           string   `json:"first_state"`
	FirstTaskID          string   `json:"first_task_id"`
	LastKind             string   `json:"last_kind"`
	LastState            string   `json:"last_state"`
	TerminalSeen         bool     `json:"terminal_seen"`
	StreamEnd            string   `json:"stream_end"`
	Error                string   `json:"error"`
	HTTPStatus           int      `json:"http_status"`
	ContentType          string   `json:"content_type"`
	WireErrorCode        int      `json:"wire_error_code"`
	WireErrorMessage     string   `json:"wire_error_message"`
	Posts                int      `json:"posts"`
	A2AVersion           string   `json:"a2a_version"`
	CardProtocolVersions []string `json:"card_protocol_versions"`
	CardStreaming        bool     `json:"card_streaming"`
	AdvertisedURLs       []string `json:"advertised_urls"`
	DialledURL           string   `json:"dialled_url"`
}

const (
	streamEndEOF     = "eof"
	streamEndError   = "error"
	streamEndNotSent = "not-sent"
)

// eventFacts reads what a line records from one SDK event.
func eventFacts(ev a2a.Event) (kind, taskID, contextID, state string, terminal bool) {
	switch e := ev.(type) {
	case *a2a.Task:
		return "task", string(e.ID), e.ContextID, string(e.Status.State), e.Status.State.Terminal()
	case *a2a.TaskStatusUpdateEvent:
		return "status-update", string(e.TaskID), e.ContextID, string(e.Status.State), e.Status.State.Terminal()
	case *a2a.TaskArtifactUpdateEvent:
		return "artifact-update", string(e.TaskID), e.ContextID, "", false
	case *a2a.Message:
		return "message", string(e.TaskID), e.ContextID, "", false
	default:
		return fmt.Sprintf("%T", ev), "", "", "", false
	}
}

// streamOnce resolves the card, sends the one streaming request and prints a
// line per event and the end line. It returns 0 when the iteration ran out with
// no error after a terminal event and no refusal was on the wire, 3 otherwise:
// a Job's status is a summary, and the lines are the record.
func streamOnce(ctx context.Context, hc *http.Client, c runConfig, out io.Writer) int {
	obs := &wireObserver{base: hc.Transport}
	observed := *hc
	observed.Transport = obs

	method := "SendStreamingMessage"
	if c.mode.mode == modeSubscribe {
		method = "SubscribeToTask"
	}
	end := streamEnd{Ledger: "client", Mode: string(c.mode.mode), Method: method, Line: "end",
		LogicalWorkItemID: c.workItem, RequestedTaskID: c.mode.taskID, A2AVersion: string(a2a.Version),
		StreamEnd: streamEndNotSent}
	finish := func() int {
		end.Posts, end.HTTPStatus, end.ContentType = obs.facts()
		end.WireErrorCode, end.WireErrorMessage = obs.wireError()
		end.TS = time.Now().UTC().Format(time.RFC3339Nano)
		b, _ := json.Marshal(end)
		fmt.Fprintln(out, string(b))
		if end.StreamEnd == streamEndEOF && end.TerminalSeen && end.Error == "" && end.WireErrorCode == 0 {
			return 0
		}
		return 3
	}

	card, err := agentcard.NewResolver(&observed).Resolve(ctx, c.target)
	if err != nil {
		end.Error = "resolve card: " + err.Error()
		return finish()
	}
	for _, iface := range card.SupportedInterfaces {
		end.CardProtocolVersions = append(end.CardProtocolVersions, string(iface.ProtocolVersion))
		end.AdvertisedURLs = append(end.AdvertisedURLs, iface.URL)
	}
	// What the card says about streaming decides, inside a2a-go, whether a
	// SendStreamingMessage is sent as one or as a plain SendMessage (client.go,
	// v2.5.0). It is recorded, not acted on; the receiver's ingress ledger
	// records which method arrived.
	end.CardStreaming = card.Capabilities.Streaming
	dialled := cardToDial(card, c.dial, c.target)
	agent := agentFromCard(dialled)
	end.DialledURL = agent.URL
	client, err := a2aclient.NewFromCard(ctx, dialled, a2aclient.WithDefaultsDisabled(), a2aclient.WithJSONRPCTransport(&observed))
	if err != nil {
		end.Error = "create client: " + err.Error()
		return finish()
	}

	var events iter.Seq2[a2a.Event, error]
	var invoke *labotel.AgentSpan
	callCtx := ctx
	if c.mode.mode == modeSubscribe {
		end.TaskID = c.mode.taskID
		events = client.SubscribeToTask(ctx, &a2a.SubscribeToTaskRequest{ID: a2a.TaskID(c.mode.taskID)})
	} else {
		req := a2areq.Build(c.workItem, c.text)
		end.MessageID = req.Message.ID
		// One invoke_agent span covers the stream, as it covers the unary send.
		// A subscription invokes nothing; its HTTP client span is its trace.
		callCtx, invoke = labotel.InvokeAgent(ctx, agent,
			labotel.Identity{WorkItem: c.workItem, MessageID: req.Message.ID, Caller: "loadgen"})
		events = client.SendStreamingMessage(callCtx, req)
	}

	end.TSSent = time.Now().UTC().Format(time.RFC3339Nano)
	end.StreamEnd = streamEndEOF
	var iterErr error
	for ev, err := range events {
		if err != nil {
			iterErr = err
			break
		}
		kind, taskID, contextID, state, terminal := eventFacts(ev)
		end.Events++
		line := streamEvent{Ledger: "client", TS: time.Now().UTC().Format(time.RFC3339Nano), Mode: string(c.mode.mode),
			Method: method, Line: "event", Seq: end.Events, LogicalWorkItemID: c.workItem, MessageID: end.MessageID,
			TaskID: taskID, ContextID: contextID, Kind: kind, State: state}
		b, _ := json.Marshal(line)
		fmt.Fprintln(out, string(b))
		if end.Events == 1 {
			end.FirstKind, end.FirstState, end.FirstTaskID = kind, state, taskID
			if end.TaskID == "" {
				end.TaskID = taskID
			}
			invoke.Conversation(contextID)
		}
		end.LastKind, end.LastState = kind, state
		if terminal {
			end.TerminalSeen = true
		}
	}
	if iterErr != nil {
		end.StreamEnd = streamEndError
		end.Error = iterErr.Error()
	}
	invoke.End(iterErr)
	return finish()
}

// wireObserver is the outermost transport of the stream and subscribe modes.
// It counts POSTs, and for the first one keeps the status, the Content-Type and
// a copy of the body bytes as the SDK reads them, up to maxObservedBody. It
// sends nothing of its own, reads nothing ahead of the SDK and changes nothing
// the SDK sees: the copy is made by an io.TeeReader on the reads the SDK makes.
type wireObserver struct {
	base http.RoundTripper

	mu          sync.Mutex
	posts       int
	status      int
	contentType string
	body        cappedBuffer
}

const maxObservedBody = 256 << 10

func (o *wireObserver) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.Method != http.MethodPost {
		return o.base.RoundTrip(req)
	}
	o.mu.Lock()
	o.posts++
	first := o.posts == 1
	o.mu.Unlock()
	resp, err := o.base.RoundTrip(req)
	if err != nil || !first || resp == nil {
		return resp, err
	}
	o.mu.Lock()
	o.status = resp.StatusCode
	o.contentType = resp.Header.Get("Content-Type")
	o.mu.Unlock()
	if resp.Body != nil {
		resp.Body = teeBody{Reader: io.TeeReader(resp.Body, &o.body), Closer: resp.Body}
	}
	return resp, nil
}

func (o *wireObserver) facts() (posts, status int, contentType string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.posts, o.status, o.contentType
}

// wireError returns the first JSON-RPC error object in the observed body: the
// whole body when it is not an event stream, otherwise each "data:" payload in
// order.
func (o *wireObserver) wireError() (int, string) {
	o.mu.Lock()
	ct := o.contentType
	o.mu.Unlock()
	raw := o.body.Bytes()
	if !strings.HasPrefix(ct, "text/event-stream") {
		return rpcError(raw)
	}
	sc := bufio.NewScanner(bytes.NewReader(raw))
	sc.Buffer(make([]byte, 0, 64<<10), maxObservedBody)
	for sc.Scan() {
		line := sc.Bytes()
		if !bytes.HasPrefix(line, []byte("data:")) {
			continue
		}
		if code, msg := rpcError(bytes.TrimSpace(line[len("data:"):])); code != 0 || msg != "" {
			return code, msg
		}
	}
	return 0, ""
}

func rpcError(raw []byte) (int, string) {
	var r struct {
		Error *struct {
			Code    int    `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if json.Unmarshal(raw, &r) != nil || r.Error == nil {
		return 0, ""
	}
	return r.Error.Code, r.Error.Message
}

type teeBody struct {
	io.Reader
	io.Closer
}

// cappedBuffer keeps the first maxObservedBody bytes written to it and accepts,
// without keeping, the rest, so the tee never fails a read the SDK makes.
type cappedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (c *cappedBuffer) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if room := maxObservedBody - c.buf.Len(); room > 0 {
		if len(p) > room {
			c.buf.Write(p[:room])
		} else {
			c.buf.Write(p)
		}
	}
	return len(p), nil
}

func (c *cappedBuffer) Bytes() []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]byte(nil), c.buf.Bytes()...)
}
