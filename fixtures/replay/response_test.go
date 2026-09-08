package main

import "testing"

// a2a-python wraps the SendMessage result in the A2A v1.0 event union, so a Task
// arrives under a "task" key. Observed in Gate 1 from the orchestrator.
func TestParseResponse_WrappedTask(t *testing.T) {
	body := []byte(`{"jsonrpc":"2.0","id":"rpc-1","result":{"task":{"id":"task-9","contextId":"ctx-1","status":{"state":"TASK_STATE_COMPLETED"}}}}`)
	got := parseResponse(200, body)

	if got.ResultKind != "task" {
		t.Errorf("result_kind = %q, want %q", got.ResultKind, "task")
	}
	if got.TaskID != "task-9" {
		t.Errorf("taskId = %q, want %q", got.TaskID, "task-9")
	}
	if got.State != "TASK_STATE_COMPLETED" {
		t.Errorf("state = %q, want %q", got.State, "TASK_STATE_COMPLETED")
	}
	if got.Status != 200 {
		t.Errorf("status = %d, want 200", got.Status)
	}
}

// a2a-go's JSON-RPC server returns the Task as the result itself, with no event
// wrapper. Observed in Gate 1 from the worker.
func TestParseResponse_BareTask(t *testing.T) {
	body := []byte(`{"jsonrpc":"2.0","id":"rpc-1","result":{"id":"task-7","contextId":"ctx-2","status":{"state":"TASK_STATE_WORKING"}}}`)
	got := parseResponse(200, body)

	if got.ResultKind != "task" {
		t.Errorf("result_kind = %q, want %q", got.ResultKind, "task")
	}
	if got.TaskID != "task-7" {
		t.Errorf("taskId = %q, want %q", got.TaskID, "task-7")
	}
	if got.State != "TASK_STATE_WORKING" {
		t.Errorf("state = %q, want %q", got.State, "TASK_STATE_WORKING")
	}
}

// SendMessage may answer with a Message instead of a Task. Both encodings are
// parsed: wrapped, as a2a-python writes it, and bare, as a2a-go writes it.
func TestParseResponse_Message(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
	}{
		{"wrapped", `{"jsonrpc":"2.0","id":"rpc-1","result":{"message":{"messageId":"msg-4","taskId":"task-3","role":"ROLE_AGENT","parts":[{"text":"ok"}]}}}`},
		{"bare", `{"jsonrpc":"2.0","id":"rpc-1","result":{"messageId":"msg-4","taskId":"task-3","role":"ROLE_AGENT","parts":[{"text":"ok"}]}}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := parseResponse(200, []byte(tc.body))
			if got.ResultKind != "message" {
				t.Errorf("result_kind = %q, want %q", got.ResultKind, "message")
			}
			if got.TaskID != "task-3" {
				t.Errorf("taskId = %q, want %q", got.TaskID, "task-3")
			}
			if got.State != "" {
				t.Errorf("state = %q, want empty: a Message carries no task state", got.State)
			}
		})
	}
}

// A JSON-RPC error is a counted outcome, not a failure of the harness: the code
// and the message are recorded and the attempt is still one delivery.
func TestParseResponse_JSONRPCError(t *testing.T) {
	body := []byte(`{"jsonrpc":"2.0","id":"rpc-1","error":{"code":-32602,"message":"invalid params"}}`)
	got := parseResponse(200, body)

	if got.ResultKind != "error" {
		t.Errorf("result_kind = %q, want %q", got.ResultKind, "error")
	}
	if got.ErrorCode != -32602 {
		t.Errorf("error_code = %d, want -32602", got.ErrorCode)
	}
	if got.Error != "invalid params" {
		t.Errorf("error = %q, want %q", got.Error, "invalid params")
	}
}

// A body that is not JSON at all still describes a delivery: the HTTP status is
// what the run is counting, and the result kind says there was no A2A result.
func TestParseResponse_NonJSON(t *testing.T) {
	got := parseResponse(503, []byte("upstream connect error or disconnect/reset before headers"))

	if got.ResultKind != "none" {
		t.Errorf("result_kind = %q, want %q", got.ResultKind, "none")
	}
	if got.Status != 503 {
		t.Errorf("status = %d, want 503", got.Status)
	}
	if got.TaskID != "" || got.State != "" {
		t.Errorf("identity fields filled from a non-JSON body: taskId=%q state=%q", got.TaskID, got.State)
	}
}
