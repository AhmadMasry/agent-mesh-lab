package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Recorded on 2026-09-05 from the a2a-go v2.5.0 client against a request-dump
// listener (see the Task 4 report). Only the ids differ between runs.
const a2aGoSendMessageBody = `{"jsonrpc":"2.0","method":"SendMessage","params":{"message":{"messageId":"01a06f19-cf55-7daf-af2b-a251c81a0375","metadata":{"logical_work_item_id":"go-dump"},"parts":[{"text":"lwi:go-dump hello"}],"role":"ROLE_USER"}},"id":"66f3ae4b-47df-4346-8fdb-0aacc23d7869"}`

// Hand-written in the pre-1.0 (0.3) JSON-RPC shape: snake-free field names,
// method message/send, numeric id, kind-tagged parts.
const v03MessageSendBody = `{"jsonrpc":"2.0","id":7,"method":"message/send","params":{"message":{"messageId":"m-03","role":"user","parts":[{"kind":"text","text":"lwi:x hi"}],"metadata":{"logical_work_item_id":"x"}}}}`

func sha(b string) string {
	h := sha256.Sum256([]byte(b))
	return hex.EncodeToString(h[:])
}

func TestParseIngress_A2AGoSendMessageBody(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody))
	r.Header.Set("A2A-Version", "1.0")
	r.Header.Set("Content-Type", "application/json")
	line := parseIngress(r, []byte(a2aGoSendMessageBody))
	if line.Method != "SendMessage" {
		t.Errorf("method = %q, want SendMessage", line.Method)
	}
	if line.ID != "66f3ae4b-47df-4346-8fdb-0aacc23d7869" {
		t.Errorf("id = %q", line.ID)
	}
	if line.MessageID != "01a06f19-cf55-7daf-af2b-a251c81a0375" {
		t.Errorf("messageId = %q", line.MessageID)
	}
	if line.LogicalWorkItemID != "go-dump" {
		t.Errorf("logical_work_item_id = %q", line.LogicalWorkItemID)
	}
	if line.TaskID != "" {
		t.Errorf("taskId = %q, want empty", line.TaskID)
	}
	if line.A2AVersion != "1.0" {
		t.Errorf("a2a_version = %q, want 1.0", line.A2AVersion)
	}
	if line.BodySHA256 != sha(a2aGoSendMessageBody) || line.BodyLen != len(a2aGoSendMessageBody) {
		t.Errorf("body hash/len = %s/%d", line.BodySHA256, line.BodyLen)
	}
	if line.Ledger != "ingress" || line.TSArrival == "" || line.ContentType != "application/json" {
		t.Errorf("ledger/ts/content_type = %q/%q/%q", line.Ledger, line.TSArrival, line.ContentType)
	}
}

func TestParseIngress_ZeroPointThreeBodyIsCountedToo(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(v03MessageSendBody))
	line := parseIngress(r, []byte(v03MessageSendBody))
	if line.Method != "message/send" || line.ID != "7" || line.MessageID != "m-03" || line.LogicalWorkItemID != "x" {
		t.Errorf("got method=%q id=%q messageId=%q lwi=%q", line.Method, line.ID, line.MessageID, line.LogicalWorkItemID)
	}
	if line.A2AVersion != "" {
		t.Errorf("a2a_version = %q, want empty when the header is absent", line.A2AVersion)
	}
}

func TestParseIngress_NonJSONRPCRequestStillCounted(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/.well-known/agent-card.json", nil)
	line := parseIngress(r, nil)
	if line.Method != "GET /.well-known/agent-card.json" || line.ID != "" || line.MessageID != "" || line.BodyLen != 0 {
		t.Errorf("got %+v", line)
	}
}

func TestIngressMiddleware_PassesBodyThroughUnchangedAndRecordsStatus(t *testing.T) {
	var seen []byte
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
	})
	var out bytes.Buffer
	h := newIngressMiddleware(next, newLineWriter(&out))
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody))
	r.Header.Set("A2A-Version", "1.0")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if string(seen) != a2aGoSendMessageBody {
		t.Fatalf("downstream body differs from the wire body")
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("want an arrival line and a response line, got %d: %q", len(lines), out.String())
	}
	var arrival, response ingressLine
	if err := json.Unmarshal([]byte(lines[0]), &arrival); err != nil {
		t.Fatalf("arrival line is not JSON: %v", err)
	}
	if err := json.Unmarshal([]byte(lines[1]), &response); err != nil {
		t.Fatalf("response line is not JSON: %v", err)
	}
	if arrival.Phase != "arrival" || arrival.Status != 0 || arrival.MessageID == "" || arrival.Ledger != "ingress" {
		t.Errorf("arrival = %+v", arrival)
	}
	if response.Phase != "response" || response.Status != http.StatusCreated || response.MessageID != arrival.MessageID || response.TSArrival != arrival.TSArrival || response.BodySHA256 != arrival.BodySHA256 {
		t.Errorf("response = %+v", response)
	}
}

// The arrival line must exist even when the handler never returns normally: it is
// written before dispatch, so a delivery is counted the moment it is read.
func TestIngressMiddleware_ArrivalLineIsWrittenBeforeDispatch(t *testing.T) {
	var out bytes.Buffer
	var seenAtDispatch string
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenAtDispatch = out.String()
		w.WriteHeader(http.StatusOK)
	})
	h := newIngressMiddleware(next, newLineWriter(&out))
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aGoSendMessageBody))
	h.ServeHTTP(httptest.NewRecorder(), r)
	var line ingressLine
	if err := json.Unmarshal([]byte(strings.TrimSpace(seenAtDispatch)), &line); err != nil || line.Phase != "arrival" {
		t.Fatalf("no arrival line before dispatch: %q (%v)", seenAtDispatch, err)
	}
}

func TestIngressMiddleware_MalformedBodyIsCountedNotRejected(t *testing.T) {
	next := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusOK) })
	var out bytes.Buffer
	h := newIngressMiddleware(next, newLineWriter(&out))
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader("{not json"))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != http.StatusOK {
		t.Fatalf("middleware must not reject: status %d", w.Code)
	}
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	var line ingressLine
	if err := json.Unmarshal([]byte(lines[0]), &line); err != nil {
		t.Fatalf("no ledger line for malformed body: %v", err)
	}
	if line.BodySHA256 != sha("{not json") || line.BodyLen != 9 || line.Method != "" || line.Phase != "arrival" {
		t.Errorf("line = %+v", line)
	}
}

// Recorded on 2026-09-05 from the a2a-sdk 1.1.2 (a2a-python) client against
// the same dump listener; same shape as the Go client's, plus an empty
// configuration object and a different key order.
const a2aPythonSendMessageBody = `{"method":"SendMessage","params":{"message":{"messageId":"3534b263-1d7c-45b6-a6cb-cc165fe5e1b5","role":"ROLE_USER","parts":[{"text":"lwi:py-dump hello"}],"metadata":{"logical_work_item_id":"py-dump"}},"configuration":{}},"id":"0de35010-f9b9-48c4-9c03-b7a3c3774d19","jsonrpc":"2.0"}`

func TestParseIngress_A2APythonSendMessageBody(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(a2aPythonSendMessageBody))
	r.Header.Set("A2A-Version", "1.0")
	line := parseIngress(r, []byte(a2aPythonSendMessageBody))
	if line.Method != "SendMessage" || line.ID != "0de35010-f9b9-48c4-9c03-b7a3c3774d19" || line.MessageID != "3534b263-1d7c-45b6-a6cb-cc165fe5e1b5" || line.LogicalWorkItemID != "py-dump" || line.A2AVersion != "1.0" {
		t.Errorf("got method=%q id=%q messageId=%q lwi=%q ver=%q", line.Method, line.ID, line.MessageID, line.LogicalWorkItemID, line.A2AVersion)
	}
}
