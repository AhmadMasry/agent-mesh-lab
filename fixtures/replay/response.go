package main

import "encoding/json"

// responseInfo is what one attempt's response contributes to the client ledger
// line. It never carries a judgement: a JSON-RPC error and a body that is not
// JSON are both recorded outcomes of a delivery that happened.
type responseInfo struct {
	Status     int
	ResultKind string // task | message | error | none
	TaskID     string
	State      string
	ErrorCode  int
	Error      string
}

// rpcEnvelope is the tolerant view of a JSON-RPC response: result and error are
// both optional and neither shape is rejected.
type rpcEnvelope struct {
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

// resultShape reads both encodings of a SendMessage result seen in Gate 1: the
// A2A v1.0 event union, where the payload sits under "task" or "message" (what
// a2a-python writes), and the bare object (what a2a-go writes).
type resultShape struct {
	Task *struct {
		ID     string `json:"id"`
		Status struct {
			State string `json:"state"`
		} `json:"status"`
	} `json:"task"`
	Message *struct {
		MessageID string `json:"messageId"`
		TaskID    string `json:"taskId"`
	} `json:"message"`

	// Bare-object fields. A Task has id and status; a Message has messageId.
	ID     string `json:"id"`
	Status *struct {
		State string `json:"state"`
	} `json:"status"`
	MessageID string `json:"messageId"`
	TaskID    string `json:"taskId"`
}

// parseResponse turns one HTTP status and response body into the fields the
// client ledger records. Anything it cannot read is reported as result_kind
// "none" with the status kept, so an unreadable response is still a counted
// delivery.
func parseResponse(status int, body []byte) responseInfo {
	info := responseInfo{Status: status, ResultKind: "none"}

	var env rpcEnvelope
	if len(body) == 0 || json.Unmarshal(body, &env) != nil {
		return info
	}
	if env.Error != nil {
		info.ResultKind = "error"
		info.ErrorCode = env.Error.Code
		info.Error = env.Error.Message
		return info
	}
	var res resultShape
	if len(env.Result) == 0 || json.Unmarshal(env.Result, &res) != nil {
		return info
	}

	switch {
	case res.Task != nil:
		info.ResultKind = "task"
		info.TaskID = res.Task.ID
		info.State = res.Task.Status.State
	case res.Message != nil:
		info.ResultKind = "message"
		info.TaskID = res.Message.TaskID
	case res.MessageID != "":
		info.ResultKind = "message"
		info.TaskID = res.TaskID
	case res.Status != nil || res.ID != "":
		info.ResultKind = "task"
		info.TaskID = res.ID
		if res.Status != nil {
			info.State = res.Status.State
		}
	}
	return info
}
