package main

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// decoded is the tolerant view of a request body used by these tests. It reads
// the same fields the worker's pre-dispatch ingress parser reads, so a body the
// harness builds can be checked against what the receiver will record.
type decoded struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	ID      string `json:"id"`
	Params  struct {
		Message struct {
			MessageID string         `json:"messageId"`
			TaskID    string         `json:"taskId"`
			Role      string         `json:"role"`
			Metadata  map[string]any `json:"metadata"`
			Parts     []struct {
				Text string `json:"text"`
			} `json:"parts"`
		} `json:"message"`
	} `json:"params"`
}

func mustBuild(t *testing.T, id, messageID, lwi, text string) []byte {
	t.Helper()
	b, err := buildBody(id, messageID, lwi, text)
	if err != nil {
		t.Fatalf("buildBody: %v", err)
	}
	return b
}

func decode(t *testing.T, b []byte) decoded {
	t.Helper()
	var d decoded
	if err := json.Unmarshal(b, &d); err != nil {
		t.Fatalf("body does not parse as JSON: %v; body=%s", err, b)
	}
	return d
}

// M1 is the byte-identical redelivery: the same JSON-RPC id and the same
// messageId, so the second attempt is indistinguishable from the first at every
// layer that only looks at bytes.
func TestAttempts_M1_SecondBodyIdenticalBytes(t *testing.T) {
	first, second, err := attempts("M1", "lwi-m1", "hello")
	if err != nil {
		t.Fatalf("attempts: %v", err)
	}
	if len(first) == 0 || len(second) == 0 {
		t.Fatalf("attempts returned empty bodies: first=%d second=%d bytes", len(first), len(second))
	}
	if !bytes.Equal(first, second) {
		t.Fatalf("M1 bodies differ.\nfirst:  %s\nsecond: %s", first, second)
	}
}

// M2 changes only the JSON-RPC id: the transport-level request is new, the A2A
// message identity is the one already delivered.
func TestAttempts_M2_DiffersOnlyInJSONRPCID(t *testing.T) {
	first, second, err := attempts("M2", "lwi-m2", "hello")
	if err != nil {
		t.Fatalf("attempts: %v", err)
	}
	a, b := decode(t, first), decode(t, second)
	if a.ID == b.ID {
		t.Errorf("M2 reused the JSON-RPC id %q; a new id is what this mode changes", a.ID)
	}
	if a.Params.Message.MessageID != b.Params.Message.MessageID {
		t.Errorf("M2 changed messageId: %q then %q; only the JSON-RPC id may change",
			a.Params.Message.MessageID, b.Params.Message.MessageID)
	}
	// Everything except the id must survive, which is checked by rebuilding the
	// second body with the first body's id and comparing the bytes.
	rebuilt := mustBuild(t, a.ID, b.Params.Message.MessageID, "lwi-m2", "hello")
	if !bytes.Equal(first, rebuilt) {
		t.Errorf("M2 changed more than the JSON-RPC id.\nfirst:            %s\nsecond minus id:  %s", first, rebuilt)
	}
}

// M3 is a fresh message for the same work item: new JSON-RPC id and new
// messageId, with the logical work item unchanged.
func TestAttempts_M3_DiffersOnlyInIDAndMessageID(t *testing.T) {
	first, second, err := attempts("M3", "lwi-m3", "hello")
	if err != nil {
		t.Fatalf("attempts: %v", err)
	}
	a, b := decode(t, first), decode(t, second)
	if a.ID == b.ID {
		t.Errorf("M3 reused the JSON-RPC id %q", a.ID)
	}
	if a.Params.Message.MessageID == b.Params.Message.MessageID {
		t.Errorf("M3 reused the messageId %q", a.Params.Message.MessageID)
	}
	if got, want := b.Params.Message.Metadata["logical_work_item_id"], "lwi-m3"; got != want {
		t.Errorf("M3 second body work item = %v, want %q", got, want)
	}
	rebuilt := mustBuild(t, a.ID, a.Params.Message.MessageID, "lwi-m3", "hello")
	if !bytes.Equal(first, rebuilt) {
		t.Errorf("M3 changed more than the two ids.\nfirst:               %s\nsecond minus ids:    %s", first, rebuilt)
	}
}

// The body must carry every identity field the worker's parseIngress reads, or
// the ingress ledger records a delivery it cannot attribute to a work item.
func TestBuildBody_ParsesLikeTheWorkerIngress(t *testing.T) {
	const lwi = "lwi-ingress"
	body := mustBuild(t, "rpc-1", "msg-1", lwi, "hello")
	d := decode(t, body)

	if d.Method != "SendMessage" {
		t.Errorf("method = %q, want %q (the canonical A2A v1.0 operation name)", d.Method, "SendMessage")
	}
	if d.ID != "rpc-1" {
		t.Errorf("JSON-RPC id = %q, want %q", d.ID, "rpc-1")
	}
	if d.Params.Message.MessageID != "msg-1" {
		t.Errorf("params.message.messageId = %q, want %q", d.Params.Message.MessageID, "msg-1")
	}
	if got := d.Params.Message.Metadata["logical_work_item_id"]; got != lwi {
		t.Errorf("params.message.metadata.logical_work_item_id = %v, want %q", got, lwi)
	}
	if len(d.Params.Message.Parts) == 0 {
		t.Fatalf("no parts in the message")
	}
	if got, want := d.Params.Message.Parts[0].Text, "lwi:"+lwi+" hello"; got != want {
		t.Errorf("first text part = %q, want %q", got, want)
	}
	if d.Params.Message.TaskID != "" {
		t.Errorf("params.message.taskId = %q, want empty: this is a first message", d.Params.Message.TaskID)
	}
	if strings.Contains(string(body), `"taskId"`) {
		t.Errorf("body carries a taskId key: %s", body)
	}
}

// The harness must put the same bytes on the wire that a2a-go's own JSON-RPC
// client puts there, so a duplicate delivery differs from the load client's
// delivery only in the ids the mode changes. testdata/go-client-body.json is the
// SendMessage body recorded off the wire from the a2a-go client at v2.5.0
// (Gate 1 Task 4 dump, work item "go-dump"); this rebuilds it from its own ids
// and compares byte for byte.
func TestBuildBody_MatchesRecordedA2AGoClientEnvelope(t *testing.T) {
	recorded, err := os.ReadFile("testdata/go-client-body.json")
	if err != nil {
		t.Fatalf("read recorded body: %v", err)
	}
	recorded = bytes.TrimSpace(recorded)
	d := decode(t, recorded)

	got := mustBuild(t, d.ID, d.Params.Message.MessageID, "go-dump", "hello")
	if !bytes.Equal(got, recorded) {
		t.Fatalf("body encoding differs from the recorded a2a-go client body.\nrecorded: %s\nbuilt:    %s", recorded, got)
	}
}
