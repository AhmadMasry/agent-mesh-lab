package main

import (
	"bytes"
	"context"
	"iter"
	"testing"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
)

// completingExecutor is the smallest executor that creates a Task: it emits
// working then completed for whatever message arrives.
type completingExecutor struct{}

func (completingExecutor) Execute(_ context.Context, execCtx *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) {
		if !yield(a2a.NewSubmittedTask(execCtx, execCtx.Message), nil) {
			return
		}
		if !yield(a2a.NewStatusUpdateEvent(execCtx, a2a.TaskStateWorking, nil), nil) {
			return
		}
		yield(a2a.NewStatusUpdateEvent(execCtx, a2a.TaskStateCompleted, nil), nil)
	}
}

func (completingExecutor) Cancel(_ context.Context, execCtx *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) {
		yield(a2a.NewStatusUpdateEvent(execCtx, a2a.TaskStateCanceled, nil), nil)
	}
}

// The wrapper's entry line says the SDK accepted a request, so it is named
// "received"; "dispatched" is now the executor's own "execute" line.
func TestExecutionLedger_OneReceivedAndOneResultLinePerSendMessage(t *testing.T) {
	var out bytes.Buffer
	inner := a2asrv.NewHandler(completingExecutor{})
	h := newExecutionLedger(inner, newLineWriter(&out))

	msg := a2a.NewMessage(a2a.MessageRoleUser, a2a.NewTextPart("lwi:w1 hi"))
	msg.ID = "msg-1"
	msg.Metadata = map[string]any{"logical_work_item_id": "w1"}
	res, err := h.SendMessage(context.Background(), &a2a.SendMessageRequest{Message: msg})
	if err != nil {
		t.Fatalf("SendMessage: %v", err)
	}
	task, ok := res.(*a2a.Task)
	if !ok {
		t.Fatalf("result is %T, want *a2a.Task", res)
	}

	var received, result []executionLine
	all := executionLines(t, out.String())
	for _, l := range all {
		if l.Ledger != "execution" {
			t.Errorf("ledger = %q", l.Ledger)
		}
		if l.Event == "dispatch" {
			t.Errorf("a line named dispatch remains: %+v", l)
		}
		switch l.Event {
		case "received":
			received = append(received, l)
		case "result":
			result = append(result, l)
		}
	}
	if len(all) == 0 || all[0].Event != "received" {
		t.Fatalf("first wrapper line is %q, want received: %s", all[0].Event, out.String())
	}
	if len(received) != 1 || len(result) != 1 {
		t.Fatalf("received=%d result=%d lines, want 1 and 1: %s", len(received), len(result), out.String())
	}
	if received[0].MessageID != "msg-1" || received[0].LogicalWorkItemID != "w1" || received[0].Method != "SendMessage" {
		t.Errorf("received line = %+v", received[0])
	}
	if result[0].ResultKind != "task" || result[0].TaskID != string(task.ID) || result[0].State != string(a2a.TaskStateCompleted) || result[0].MessageID != "msg-1" {
		t.Errorf("result line = %+v (task %s %s)", result[0], task.ID, task.Status.State)
	}
}

func TestExecutionLedger_DelegatesGetTask(t *testing.T) {
	var out bytes.Buffer
	inner := a2asrv.NewHandler(completingExecutor{})
	h := newExecutionLedger(inner, newLineWriter(&out))
	msg := a2a.NewMessage(a2a.MessageRoleUser, a2a.NewTextPart("hi"))
	msg.ID = "msg-2"
	res, err := h.SendMessage(context.Background(), &a2a.SendMessageRequest{Message: msg})
	if err != nil {
		t.Fatal(err)
	}
	task := res.(*a2a.Task)
	got, err := h.GetTask(context.Background(), &a2a.GetTaskRequest{ID: task.ID})
	if err != nil || got.ID != task.ID {
		t.Fatalf("GetTask through the wrapper: %v, %+v", err, got)
	}
}
