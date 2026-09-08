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
	Event             string `json:"event"` // received | execute | result | state
	Method            string `json:"method,omitempty"`
	MessageID         string `json:"messageId"`
	TaskID            string `json:"taskId"`
	ContextID         string `json:"contextId,omitempty"`
	LogicalWorkItemID string `json:"logical_work_item_id"`
	ResultKind        string `json:"result_kind,omitempty"` // task | message
	State             string `json:"state,omitempty"`
	Error             string `json:"error,omitempty"`
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

func (e *executionLedger) result(base executionLine, res a2a.SendMessageResult, err error) {
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
	e.lw.write(line)
}

func (e *executionLedger) SendMessage(ctx context.Context, req *a2a.SendMessageRequest) (a2a.SendMessageResult, error) {
	base := e.received("SendMessage", req)
	res, err := e.RequestHandler.SendMessage(ctx, req)
	e.result(base, res, err)
	return res, err
}

func (e *executionLedger) SendStreamingMessage(ctx context.Context, req *a2a.SendMessageRequest) iter.Seq2[a2a.Event, error] {
	base := e.received("SendStreamingMessage", req)
	inner := e.RequestHandler.SendStreamingMessage(ctx, req)
	return func(yield func(a2a.Event, error) bool) {
		var last a2a.SendMessageResult
		var lastErr error
		for ev, err := range inner {
			if err != nil {
				lastErr = err
			}
			switch v := ev.(type) {
			case *a2a.Task:
				last = v
			case *a2a.Message:
				last = v
			case *a2a.TaskStatusUpdateEvent:
				e.lw.write(executionLine{Ledger: "execution", TS: now(), Event: "state", MessageID: base.MessageID,
					LogicalWorkItemID: base.LogicalWorkItemID, TaskID: string(v.TaskID), ContextID: v.ContextID, State: string(v.Status.State)})
			}
			if !yield(ev, err) {
				break
			}
		}
		e.result(base, last, lastErr)
	}
}
