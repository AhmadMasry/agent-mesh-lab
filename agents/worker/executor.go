package main

import (
	"context"
	"io"
	"iter"

	"github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
)

// labExecutor is the agent's behaviour in model mode: for every dispatched
// message it drives one Task (submitted, working, then completed or failed)
// around exactly one model call. In a2a-go the executor decides Task-versus-
// Message by its first event; this executor always emits a submitted Task
// first, so a taskId always exists.
type labExecutor struct {
	name  string
	model *modelClient
	lw    *lineWriter
}

func newLabExecutor(name string, model *modelClient, out io.Writer) *labExecutor {
	return &labExecutor{name: name, model: model, lw: &lineWriter{out: out}}
}

func firstText(m *a2a.Message) string {
	if m == nil {
		return ""
	}
	for _, p := range m.Parts {
		if t, ok := p.Content.(a2a.Text); ok {
			return string(t)
		}
	}
	return ""
}

func (e *labExecutor) state(execCtx *a2asrv.ExecutorContext, st a2a.TaskState, errText string) {
	line := executionLine{Ledger: "execution", TS: now(), Event: "state", TaskID: string(execCtx.TaskID),
		ContextID: execCtx.ContextID, State: string(st), Error: errText}
	if execCtx.Message != nil {
		line.MessageID = execCtx.Message.ID
		line.LogicalWorkItemID = workItemOf(execCtx.Message)
	}
	e.lw.write(line)
}

func (e *labExecutor) Execute(ctx context.Context, execCtx *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) {
		// The SDK requires the first event to be a Task or a Message; emitting a
		// Task here is what makes every dispatched message become a Task.
		if execCtx.StoredTask == nil {
			e.state(execCtx, a2a.TaskStateSubmitted, "")
			if !yield(a2a.NewSubmittedTask(execCtx, execCtx.Message), nil) {
				return
			}
		}
		e.state(execCtx, a2a.TaskStateWorking, "")
		if !yield(a2a.NewStatusUpdateEvent(execCtx, a2a.TaskStateWorking, nil), nil) {
			return
		}
		id := identity{WorkItem: workItemOf(execCtx.Message), TaskID: string(execCtx.TaskID), Caller: e.name}
		if execCtx.Message != nil {
			id.MessageID = execCtx.Message.ID
		}
		answer, err := e.model.complete(ctx, id, firstText(execCtx.Message))
		if err != nil {
			e.state(execCtx, a2a.TaskStateFailed, err.Error())
			msg := a2a.NewMessageForTask(a2a.MessageRoleAgent, execCtx, a2a.NewTextPart(err.Error()))
			yield(a2a.NewStatusUpdateEvent(execCtx, a2a.TaskStateFailed, msg), nil)
			return
		}
		if !yield(a2a.NewArtifactEvent(execCtx, a2a.NewTextPart(answer)), nil) {
			return
		}
		e.state(execCtx, a2a.TaskStateCompleted, "")
		yield(a2a.NewStatusUpdateEvent(execCtx, a2a.TaskStateCompleted, nil), nil)
	}
}

func (e *labExecutor) Cancel(_ context.Context, execCtx *a2asrv.ExecutorContext) iter.Seq2[a2a.Event, error] {
	return func(yield func(a2a.Event, error) bool) {
		e.state(execCtx, a2a.TaskStateCanceled, "")
		yield(a2a.NewStatusUpdateEvent(execCtx, a2a.TaskStateCanceled, nil), nil)
	}
}
