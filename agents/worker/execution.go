package main

import (
	"context"
	"iter"
	"time"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
)

// executionLine is one execution/task ledger record: what the SDK received,
// when the executor was entered, what came back, and the Task states the
// executor emits.
type executionLine struct {
	Ledger            string `json:"ledger"`
	TS                string `json:"ts"`
	Event             string `json:"event"` // received | execute | result | state | delivered
	Method            string `json:"method,omitempty"`
	MessageID         string `json:"messageId"`
	TaskID            string `json:"taskId"`
	ContextID         string `json:"contextId,omitempty"`
	LogicalWorkItemID string `json:"logical_work_item_id"`
	ResultKind        string `json:"result_kind,omitempty"` // task | message | status-update | artifact-update
	State             string `json:"state,omitempty"`
	Error             string `json:"error,omitempty"`
	// StreamEnd is written on the result line of a streamed request only:
	// consumer-gone when the transport went away, error when the sequence
	// yielded an error while the transport was still up, and complete when the
	// sequence ran out. A unary request's result line carries none of them.
	//
	// The three are not interchangeable, and which one a cut stream gets is
	// decided by the request context rather than by the presence of an error:
	// measured over a socket, a2a-go answers a cut with the error
	// `queue read failed: context canceled`, so reading any error as a server
	// error would file every cut stream as one. A refusal alone cannot tell them
	// apart either, because this SDK's own consumer stops on the first error.
	//
	// A consumer-gone line therefore may carry that cancellation text, where the
	// Python receiver's carries none — GeneratorExit is not an error there. The
	// two receivers agree on stream_end, which is the field to count; the error
	// string is evidence beside it, not a discriminator.
	//
	// complete says the sequence ran out, not that a terminal event was sent:
	// whether the last state was terminal is read from the executor's state
	// lines, and what the stream carried from the delivered lines.
	StreamEnd string `json:"stream_end,omitempty"`
}

const (
	execStreamEndComplete     = "complete"
	execStreamEndConsumerGone = "consumer-gone"
	execStreamEndError        = "error"
)

// eventKind names an SDK event for the ledger, in the vocabulary A2A v1.0 uses
// for what a stream carries (specification v1.0.1 §3.1.5).
func eventKind(ev a2a.Event) string {
	switch ev.(type) {
	case *a2a.Task:
		return "task"
	case *a2a.Message:
		return "message"
	case *a2a.TaskStatusUpdateEvent:
		return "status-update"
	case *a2a.TaskArtifactUpdateEvent:
		return "artifact-update"
	default:
		return ""
	}
}

func now() string { return time.Now().UTC().Format(time.RFC3339Nano) }

func workItemOf(m *a2a.Message) string {
	if m == nil || m.Metadata == nil {
		return ""
	}
	v, _ := m.Metadata["logical_work_item_id"].(string)
	return v
}

// executionLedger decorates an a2asrv.RequestHandler. Embedding delegates the
// eleven protocol methods; the two send methods are wrapped to record what the
// SDK received and what it returned. The SDK, not this wrapper, decides whether
// a Task exists. The executor writes its own "execute" line when it is entered.
type executionLedger struct {
	a2asrv.RequestHandler
	lw *lineWriter
}

func newExecutionLedger(inner a2asrv.RequestHandler, lw *lineWriter) *executionLedger {
	return &executionLedger{RequestHandler: inner, lw: lw}
}

// received records that the SDK accepted this request. It is written before
// the inner handler is called; the executor's "execute" line, not this one, is
// what says agent behaviour started.
func (e *executionLedger) received(method string, req *a2a.SendMessageRequest) executionLine {
	line := executionLine{Ledger: "execution", TS: now(), Event: "received", Method: method}
	if req != nil && req.Message != nil {
		line.MessageID = req.Message.ID
		line.TaskID = string(req.Message.TaskID)
		line.ContextID = req.Message.ContextID
		line.LogicalWorkItemID = workItemOf(req.Message)
	}
	e.lw.write(line)
	return line
}

// delivered records one event handed on for the transport to write. The line is
// written before the event reaches the SSE writer's channel and before any byte
// leaves the socket, so it counts what this handler produced, never what a
// client received: a delivered line and a lost stream are not a contradiction.
//
// It is not a Task state line either: the executor writes those from inside the
// detached execution, once per transition whether anyone is reading or not, and
// doubling them here would make "the Task continued" uncountable the moment a
// second stream reads the same task.
func (e *executionLedger) delivered(base executionLine, ev a2a.Event) {
	line := executionLine{Ledger: "execution", TS: now(), Event: "delivered", Method: base.Method,
		MessageID: base.MessageID, TaskID: base.TaskID, LogicalWorkItemID: base.LogicalWorkItemID,
		ResultKind: eventKind(ev)}
	switch v := ev.(type) {
	case *a2a.Task:
		line.TaskID = string(v.ID)
		line.ContextID = v.ContextID
		line.State = string(v.Status.State)
	case *a2a.Message:
		line.TaskID = string(v.TaskID)
		line.ContextID = v.ContextID
	case *a2a.TaskStatusUpdateEvent:
		line.TaskID = string(v.TaskID)
		line.ContextID = v.ContextID
		line.State = string(v.Status.State)
	case *a2a.TaskArtifactUpdateEvent:
		line.TaskID = string(v.TaskID)
		line.ContextID = v.ContextID
	}
	e.lw.write(line)
}

func resultLine(base executionLine, res a2a.SendMessageResult, err error) executionLine {
	line := base
	line.TS = now()
	line.Event = "result"
	if err != nil {
		line.Error = err.Error()
	}
	switch r := res.(type) {
	case *a2a.Task:
		line.ResultKind = "task"
		line.TaskID = string(r.ID)
		line.ContextID = r.ContextID
		line.State = string(r.Status.State)
	case *a2a.Message:
		line.ResultKind = "message"
		line.TaskID = string(r.TaskID)
		line.ContextID = r.ContextID
	}
	return line
}

func (e *executionLedger) result(base executionLine, res a2a.SendMessageResult, err error) {
	e.lw.write(resultLine(base, res, err))
}

func (e *executionLedger) SendMessage(ctx context.Context, req *a2a.SendMessageRequest) (a2a.SendMessageResult, error) {
	base := e.received("SendMessage", req)
	res, err := e.RequestHandler.SendMessage(ctx, req)
	e.result(base, res, err)
	return res, err
}

// streamEvents records a streamed sequence of events as it passes to the
// transport: one "delivered" line per event, then one "result" line saying what
// the last Task or Message was and how the sequence ended. The result line is
// written whether the sequence ran out, yielded an error or lost its consumer,
// so a cut stream leaves a record here as well as at the ingress boundary.
//
// The result line's state is the last Task or Message the stream carried, which
// on a streamed send is the submitted Task the stream opens with, not the task's
// final state: a Task object is sent once and the transitions that follow are
// status updates. Final state is the executor's state lines.
//
// It records; it does not repeat. When the consumer stops, so does this.
//
// One shape leaves no result line at all and is not fixed here: a panic in the
// executor unwinds through this function, and a2a-go recovers it in its own
// goroutine (a2asrv/jsonrpc.go's panicChan) after the stack has left. The
// request is then counted at the ingress ledger with no execution result beside
// it. Pre-existing, unchanged by this step, and noted so that a missing result
// line is read as what it is rather than as a lost line.
func (e *executionLedger) streamEvents(ctx context.Context, base executionLine, inner iter.Seq2[a2a.Event, error]) iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) {
		var last a2a.SendMessageResult
		var lastErr error
		consumerRefused := false
		for ev, err := range inner {
			if err != nil {
				lastErr = err
			}
			if ev != nil {
				e.delivered(base, ev)
			}
			switch v := ev.(type) {
			case *a2a.Task:
				last = v
			case *a2a.Message:
				last = v
			}
			if !yield(ev, err) {
				consumerRefused = true
				break
			}
		}
		line := resultLine(base, last, lastErr)
		switch {
		case ctx.Err() != nil:
			// The request context is done, so the transport went away. Measured
			// over a socket, that is how a cut arrives here: a2a-go cancels the
			// request context when the SSE handler returns and the subscription
			// then yields `queue read failed: context canceled`
			// (internal/taskexec/subscription.go l.94). Reading that error as a
			// server error would file every cut stream as one — the opposite of
			// the distinction this field exists for — so the context decides
			// whether the transport went and the error text stays on the line as
			// the evidence for it.
			line.StreamEnd = execStreamEndConsumerGone
		case lastErr != nil:
			// An error with the transport still up is the server's. a2a-go's own
			// consumer also refuses the next event once one is yielded, so the
			// refusal alone could not have told the two apart.
			line.StreamEnd = execStreamEndError
		case consumerRefused:
			line.StreamEnd = execStreamEndConsumerGone
		default:
			line.StreamEnd = execStreamEndComplete
		}
		e.lw.write(line)
	}
}

func (e *executionLedger) SendStreamingMessage(ctx context.Context, req *a2a.SendMessageRequest) iter.Seq2[a2a.Event, error] {
	base := e.received("SendStreamingMessage", req)
	return e.streamEvents(ctx, base, e.RequestHandler.SendStreamingMessage(ctx, req))
}

// SubscribeToTask records a resubscription as an arrival of its own. Without
// this the call falls through the embedded handler and the execution ledger
// holds no line for it at all, so a second stream onto a running task would be
// invisible here and countable only at the ingress boundary.
//
// The request carries no Message and so no messageId, contextId or work item
// (A2A v1.0, specification v1.0.1 §9.4.6): the taskId it names is the whole of
// its identity, and the line says only that. What the server answered first is
// the first "delivered" line after it — a Task for a task still running, an
// error on the result line otherwise.
func (e *executionLedger) SubscribeToTask(ctx context.Context, req *a2a.SubscribeToTaskRequest) iter.Seq2[a2a.Event, error] {
	base := executionLine{Ledger: "execution", TS: now(), Event: "received", Method: "SubscribeToTask"}
	if req != nil {
		base.TaskID = string(req.ID)
	}
	e.lw.write(base)
	return e.streamEvents(ctx, base, e.RequestHandler.SubscribeToTask(ctx, req))
}
